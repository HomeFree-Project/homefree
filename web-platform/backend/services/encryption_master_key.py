"""
Master encryption key for the Storage feature.

The MASTER KEY = the LUKS recovery passphrase persisted at
`/etc/nixos/secrets/recovery-passphrase.txt`. It's the same value the user
types at the boot prompt to unlock the system disk's recovery slot, and the
same value every data-pool LUKS container is bound to.

- On installs with `use_encryption=true` the file is seeded by the installer
  (install.py:_copy_secrets_to_target / _generate_luks_secrets).
- On installs without encryption (or systems older than this feature) the
  file may be absent — the admin sets it up via the Storage page before the
  first encrypted pool can be created (generate or paste-in).
- The file is plain text, mode 0600, in a chmod-0700 directory under
  /etc/nixos which is the backed-up location.

Trailing newline: the file is written WITHOUT one. cryptsetup binds the LUKS
keyslot to the bytes the user types at the boot prompt (newline-stripped),
so the on-disk file must hold the same bytes for `cryptsetup --key-file` to
authorize. The installer's `_copy_secrets_to_target` writes a trailing newline
for human readability; both `storage_pool._materialize_master_passphrase` and
this module's `current_value` rstrip it so the unlock path always sees the
slot-bound bytes.
"""

import logging
import os
import re
import secrets
import shutil
import string
import subprocess
import tempfile
from typing import Dict, Optional

from utils.privileged import (
    mkdir_privileged,
    run_privileged,
    write_file_privileged,
)

logger = logging.getLogger(__name__)

# Single source of truth for the path. storage_pool.py uses the same constant.
RECOVERY_PP_PATH = "/etc/nixos/secrets/recovery-passphrase.txt"
SECRETS_DIR = "/etc/nixos/secrets"

# Either node indicates a usable TPM2.
_TPM_DEV_PATHS = ("/dev/tpmrm0", "/dev/tpm0")

# Generated passphrase entropy: 6 groups × 5 base36 chars = ~155 bits.
# Matches install.py:_generate_luks_secrets so the surface looks identical
# whether the passphrase came from the installer or from the admin UI flow.
_GROUP_LEN = 5
_GROUP_COUNT = 6
_ALPHABET = string.ascii_lowercase + string.digits

# Minimum length when the admin pastes their own passphrase. 20 chars at the
# install.py advanced-option validation threshold; matches.
_MIN_PASTED_LEN = 20

# Secure-Boot status file (written by install.py's homefree-secureboot-enroll
# oneshot at first boot when lanzaboote is enabled). Used by the UI to warn
# before encryption is enabled while SB enrollment is still pending — every
# data-pool TPM2 slot is bound to PCR 7, which SB enrollment WILL change.
_SECUREBOOT_STATUS_PATH = "/var/lib/homefree/secureboot-status"

# Disko's GPT partlabel convention for each system disk's root LUKS partition
# (web-platform/backend/services/disko_builder.py:114 -- `disk-d<N>-root`).
# We look these up by partlabel for verify-against-system-disk checks.
_SYSTEM_LUKS_PARTLABEL_FMT = "/dev/disk/by-partlabel/disk-d{n}-root"
_MAX_SYSTEM_DISKS = 8


def _find_system_luks_partition() -> Optional[str]:
    """Return the path of a system disk's LUKS partition we can probe to
    verify a candidate master passphrase, or None if no system LUKS is
    detected (unencrypted-system install). Disko names each disk's root
    LUKS via the GPT partlabel `disk-d<N>-root`; we try d1..d8."""
    for i in range(1, _MAX_SYSTEM_DISKS + 1):
        p = _SYSTEM_LUKS_PARTLABEL_FMT.format(n=i)
        if os.path.exists(p):
            return p
    return None


def system_is_encrypted() -> bool:
    """True iff this box's system disk uses LUKS (a `disk-d<N>-root`
    partlabel exists). Used by the master-key setup flow to decide
    whether to require the paste-existing-passphrase path vs allowing
    a fresh generate."""
    return _find_system_luks_partition() is not None


def _verify_against_system_disk(value: bytes) -> Optional[str]:
    """Test the given passphrase against the system disk's LUKS slot(s)
    via `cryptsetup open --test-passphrase`. Returns:
      None  — verification passed, OR there is no system LUKS to test
              against, OR cryptsetup failed for tooling reasons (logged,
              fail-open so a transient glitch doesn't lock the admin out).
      <str> — a user-facing error message: the passphrase definitively
              does NOT match any slot on the system disk.

    Non-destructive: `--test-passphrase` only checks the unlock, it does
    NOT activate the device. The tempfile holding the value is shredded
    after, matching storage_pool.py's pattern for the same secret bytes.
    """
    part = _find_system_luks_partition()
    if part is None:
        return None  # unencrypted-system box — nothing to verify against
    cryptsetup = shutil.which("cryptsetup") or "/run/current-system/sw/bin/cryptsetup"
    if not os.path.exists(cryptsetup):
        logger.warning(
            "encryption_master_key: cryptsetup not found; skipping system-"
            "disk verification of pasted master passphrase.")
        return None
    fd, path = tempfile.mkstemp(prefix="hf-luks-verify-", dir="/run")
    try:
        os.fchmod(fd, 0o600)
        os.write(fd, value)
    finally:
        os.close(fd)
    try:
        p = subprocess.run(
            [cryptsetup, "open", "--test-passphrase", "--key-file", path, part],
            capture_output=True, text=True, timeout=30)
    except (subprocess.SubprocessError, OSError) as e:
        logger.warning(
            "encryption_master_key: cryptsetup --test-passphrase failed on "
            "%s (%s); skipping verification.", part, e)
        _shred(path)
        return None
    finally:
        _shred(path)
    if p.returncode == 0:
        return None  # one of the slots matched — passphrase is valid
    # Exit 2 = "no key available with this passphrase" (the typo case);
    # other non-zero = tooling problem (treat as fail-open).
    if p.returncode == 2:
        return (
            "That passphrase does not unlock this system's disk encryption. "
            "Check the recovery passphrase you saved at install time — it "
            "must match for new encrypted data volumes to share the same "
            "unlock with the system disk.")
    logger.warning(
        "encryption_master_key: cryptsetup --test-passphrase on %s exited "
        "%d (stderr: %s); treating as inconclusive and allowing the write.",
        part, p.returncode, (p.stderr or "").strip())
    return None


def _shred(path: str) -> None:
    """Best-effort shred + unlink of a tempfile holding key bytes."""
    try:
        subprocess.run(["shred", "-u", path], check=False, timeout=10)
    except (subprocess.SubprocessError, OSError):
        pass
    if os.path.exists(path):
        try:
            os.unlink(path)
        except OSError:
            pass


def get_master_pp_bytes() -> Optional[bytes]:
    """Public accessor for the materialized master-key bytes (newline-stripped).
    Returns None if the master key is not configured or unreadable. Callers
    that hand bytes to cryptsetup should write to a /run tempfile (mode 0600)
    and shred after — never let the value linger in a Python string longer
    than needed."""
    return _read_pp_bytes()


def master_key_unlocks(device_path: str) -> bool:
    """Non-destructive probe: would the master key unlock `device_path`?
    Returns True iff `cryptsetup open --test-passphrase --key-file <master>
    <device_path>` exits 0. False on:
      - master key not configured / empty
      - cryptsetup missing
      - any non-zero exit (wrong key OR transient tool error — fail closed
        so we never falsely advertise a one-click unlock that won't work).
    `--test-passphrase` does NOT activate the device, so this is safe to
    call from a list_* probe; the tempfile is shredded after."""
    pp = _read_pp_bytes()
    if not pp:
        return False
    cryptsetup = shutil.which("cryptsetup") or "/run/current-system/sw/bin/cryptsetup"
    if not os.path.exists(cryptsetup):
        return False
    fd, path = tempfile.mkstemp(prefix="hf-luks-probe-", dir="/run")
    try:
        os.fchmod(fd, 0o600)
        os.write(fd, pp)
    finally:
        os.close(fd)
    try:
        p = subprocess.run(
            [cryptsetup, "open", "--test-passphrase", "--key-file", path, device_path],
            capture_output=True, timeout=10)
        return p.returncode == 0
    except (subprocess.SubprocessError, OSError):
        return False
    finally:
        _shred(path)


def _read_pp_bytes() -> Optional[bytes]:
    try:
        with open(RECOVERY_PP_PATH, "rb") as f:
            return f.read().rstrip(b"\n")
    except (FileNotFoundError, PermissionError):
        return None
    except OSError as e:
        logger.warning("Could not read %s: %s", RECOVERY_PP_PATH, e)
        return None


def is_configured() -> bool:
    """True iff the master key file exists and has non-empty content."""
    pp = _read_pp_bytes()
    return bool(pp)


def tpm_present() -> bool:
    return any(os.path.exists(p) for p in _TPM_DEV_PATHS)


def secure_boot_pending() -> bool:
    """True iff the box is using lanzaboote BUT Secure Boot keys have not
    been enrolled yet — enrolling them WILL invalidate every TPM2-PCR7-bound
    LUKS slot at once. The UI uses this to flag the encrypt toggle so the
    admin can enroll SB FIRST and avoid the re-lock event."""
    try:
        with open(_SECUREBOOT_STATUS_PATH) as f:
            return f.read().strip() == "setup-mode-unavailable"
    except (FileNotFoundError, PermissionError, OSError):
        return False


def get_status() -> Dict[str, bool]:
    """Compact status object for `GET /api/storage/encryption/status`.

    Keys are chosen so a missing or stale TPM doesn't block the admin from
    enabling encryption — fallback is the passphrase prompt, still a valid
    unlock path. `system_encrypted` lets the UI default the master-key
    setup modal to the paste-in tab on a system-encrypted box, since
    generating a fresh random value there would NOT match the system
    disk's existing LUKS slot (the backend's generate() refuses too)."""
    return {
        "master_key_configured": is_configured(),
        "tpm_present": tpm_present(),
        "secure_boot_pending": secure_boot_pending(),
        "system_encrypted": system_is_encrypted(),
    }


def _ensure_secrets_dir() -> None:
    """Make sure /etc/nixos/secrets exists with mode 0700. On unencrypted-
    install boxes the dir was never created (install.py only mkdir's it in
    _copy_secrets_to_target, which is gated on use_encryption=true)."""
    if not os.path.isdir(SECRETS_DIR):
        mkdir_privileged(SECRETS_DIR)
    # Re-chmod regardless — defensive, cheap.
    run_privileged(["chmod", "700", SECRETS_DIR], check=True)


def _write_passphrase(value: bytes) -> None:
    """Write the passphrase to the canonical path, mode 0600, no trailing
    newline (see module docstring on the trailing-newline gotcha)."""
    _ensure_secrets_dir()
    # write_file_privileged takes str content; the passphrase is base36/
    # printable ASCII so str → bytes round-trip is safe.
    write_file_privileged(RECOVERY_PP_PATH, value.decode("ascii"))
    run_privileged(["chmod", "600", RECOVERY_PP_PATH], check=True)


def generate() -> str:
    """Generate and persist a fresh 6-base36-group passphrase. Refuses if
    one is already configured (rotation is a separate, future flow that
    has to luksChangeKey across every pool's LUKS containers).

    Also refuses when the SYSTEM disk is encrypted but the master-key file
    is missing — a freshly-generated random value would NOT unlock the
    system disk, silently splitting "the unlock passphrase" into two
    different ones. The admin must paste their existing recovery
    passphrase (set_user_value) in that case.

    Returns the plaintext value so the UI can display it ONCE for the admin
    to copy. Subsequent reads need to go through the backend."""
    if is_configured():
        raise PermissionError(
            "A master encryption key is already configured. Rotation is "
            "not supported in this release — to change the value, all "
            "encrypted pools would have to be rekeyed.")
    if system_is_encrypted():
        raise PermissionError(
            "This system's disk is already encrypted, so generating a "
            "fresh random master key would NOT match its existing LUKS "
            "slot. Use the 'I have a passphrase' tab and paste the "
            "recovery passphrase you saved at install time instead — "
            "that keeps one passphrase unlocking both the system disk "
            "and any new encrypted data volumes.")
    groups = ["".join(secrets.choice(_ALPHABET) for _ in range(_GROUP_LEN))
              for _ in range(_GROUP_COUNT)]
    value = "-".join(groups)
    _write_passphrase(value.encode("ascii"))
    logger.info("Generated and persisted master encryption key (length=%d).",
                len(value))
    return value


_USER_VALUE_RE = re.compile(r"^[\x20-\x7e]+$")  # printable ASCII only


def set_user_value(value: str) -> None:
    """Persist a user-provided passphrase as the master key. Validates
    length + character set; refuses if a key is already configured. On a
    box whose system disk uses LUKS, ALSO verifies that the value actually
    unlocks an existing slot on the system disk (via cryptsetup
    --test-passphrase) — catches a typo'd paste before it silently
    diverges from the system passphrase the admin will type at the boot
    prompt. Skipped on unencrypted-system boxes (nothing to verify)."""
    if is_configured():
        raise PermissionError(
            "A master encryption key is already configured.")
    value = (value or "").rstrip("\n")
    if len(value) < _MIN_PASTED_LEN:
        raise ValueError(
            f"Passphrase must be at least {_MIN_PASTED_LEN} characters.")
    if not _USER_VALUE_RE.match(value):
        raise ValueError(
            "Passphrase contains characters that cannot be typed at the "
            "boot prompt — use printable ASCII only.")
    # Verify against the system disk's LUKS slot(s) when there IS a system
    # disk to verify against. Returns None on pass / no-op / tool failure;
    # a string error message on definitive mismatch.
    mismatch = _verify_against_system_disk(value.encode("ascii"))
    if mismatch is not None:
        raise ValueError(mismatch)
    _write_passphrase(value.encode("ascii"))
    logger.info(
        "Persisted user-provided master encryption key (length=%d).",
        len(value))
