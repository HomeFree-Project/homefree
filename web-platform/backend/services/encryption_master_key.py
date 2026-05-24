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
import string
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
    unlock path."""
    return {
        "master_key_configured": is_configured(),
        "tpm_present": tpm_present(),
        "secure_boot_pending": secure_boot_pending(),
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
    one is already configured — that's the rotation path, which is a
    separate, future flow (the rotation needs to luksChangeKey across every
    pool's LUKS containers).

    Returns the plaintext value so the UI can display it ONCE for the admin
    to copy. Subsequent reads need to go through the backend."""
    if is_configured():
        raise PermissionError(
            "A master encryption key is already configured. Rotation is "
            "not supported in this release — to change the value, all "
            "encrypted pools would have to be rekeyed.")
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
    length + character set; refuses if a key is already configured."""
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
    _write_passphrase(value.encode("ascii"))
    logger.info(
        "Persisted user-provided master encryption key (length=%d).",
        len(value))
