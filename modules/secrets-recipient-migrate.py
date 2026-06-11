"""
On-rebuild migration: fold every authorized SSH key into secrets.yaml as a
NATIVE age ssh recipient.

WHY. HomeFree encrypts secrets to the host key AND the user's authorized key,
but historically converted the user key with ssh-to-age, which only supports
ed25519. A user RSA key was silently skipped, so on those boxes only the host
key could decrypt secrets.yaml — and the host key is NOT in any backup. This
migration re-keys the encrypted store so each authorized key (rsa OR ed25519)
becomes a native age recipient; the operator's private key can then decrypt a
backup of this box on fresh hardware. The HOST recipient is kept exactly as it
was (ssh-to-age age1), so boot-time decryption is unchanged.

SAFETY. Idempotent (no-op once every authorized key is already a recipient,
checked from the cleartext sops metadata — no decryption). Re-keying decrypts
with the host key (always present on the box), re-encrypts to
{host age1, user(s) native ssh}, and VERIFIES the host key can still decrypt the
new file BEFORE atomically replacing secrets.yaml. On any error it leaves the
file untouched and exits 0 (never fails activation / bricks the box).

Run from modules/secrets-recipient-migrate.nix as a root activation script,
under the same flock the anchor units (lib/secrets-anchor.nix) use, so it never
races a concurrent read-modify-write of secrets.yaml. Keep the recipient logic
in sync with SecretsManager._build_age_recipients (secrets_manager.py).
"""

import json
import os
import subprocess
import sys
import tempfile

import yaml

SECRETS = "/etc/nixos/secrets/secrets.yaml"
SOPS_CFG = "/etc/nixos/.sops.yaml"
CONFIG = "/etc/nixos/homefree-config.json"
HOST_KEY = "/etc/ssh/ssh_host_ed25519_key"
HOST_PUB = HOST_KEY + ".pub"

# Key types age can natively encrypt to from an SSH key (ssh-rsa + ssh-ed25519).
SSH_RECIPIENT_TYPES = ("ssh-ed25519", "ssh-rsa")

# Decrypted plaintext is written here briefly during re-key. /run is tmpfs, so
# the cleartext never touches persistent storage.
PLAINTEXT_DIR = "/run"


def log(msg):
    print("[secrets-recipient-migrate] " + msg, flush=True)


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def normalize(key):
    """Canonicalize an SSH public key to 'type base64' (comment dropped), or
    None if age cannot encrypt to that key type. Matches
    SecretsManager._normalize_ssh_recipient so idempotency comparisons line up.
    """
    parts = (key or "").split()
    if len(parts) >= 2 and parts[0] in SSH_RECIPIENT_TYPES:
        return parts[0] + " " + parts[1]
    return None


def desired_user_recipients():
    cfg = json.load(open(CONFIG))
    out = []
    for key in cfg.get("system", {}).get("authorizedKeys", []):
        norm = normalize(key)
        if norm and norm not in out:
            out.append(norm)
    return out


def current_recipients():
    """Recipient set already on the file, read from the cleartext sops metadata
    (no decryption needed). ssh recipients are normalized so a stored
    comment/format variation still compares equal."""
    doc = yaml.safe_load(open(SECRETS)) or {}
    age = (doc.get("sops") or {}).get("age") or []
    have = set()
    for entry in age:
        rcpt = (entry.get("recipient") or "").strip()
        if rcpt:
            have.add(normalize(rcpt) or rcpt)
    return have


def main():
    if not os.path.exists(SECRETS):
        log("no secrets.yaml yet — nothing to migrate")
        return 0
    if not os.path.exists(HOST_KEY):
        log("host key missing — skipping")
        return 0

    try:
        users = desired_user_recipients()
    except Exception as exc:
        log("cannot read config (%s) — skipping" % exc)
        return 0
    if not users:
        log("no usable (rsa/ed25519) authorized keys — nothing to add")
        return 0

    try:
        have = current_recipients()
    except Exception as exc:
        log("cannot parse secrets.yaml metadata (%s) — skipping" % exc)
        return 0

    missing = [u for u in users if u not in have]
    if not missing:
        log("all authorized keys already recipients — no-op")
        return 0
    log("adding %d user recipient(s) to secrets.yaml" % len(missing))

    # Host recipient stays exactly as the box already uses it (ssh-to-age age1),
    # so the boot-time decryption path is unchanged. It is always first.
    host = run(["ssh-to-age", "-i", HOST_PUB])
    if host.returncode != 0 or not host.stdout.strip():
        log("ssh-to-age (host pub) failed: %s — skipping" % host.stderr.strip())
        return 0
    recipients = ",".join([host.stdout.strip()] + users)

    priv = run(["ssh-to-age", "-private-key", "-i", HOST_KEY])
    if priv.returncode != 0 or not priv.stdout.strip():
        log("ssh-to-age (host priv) failed: %s — skipping" % priv.stderr.strip())
        return 0
    env = dict(os.environ, SOPS_AGE_KEY=priv.stdout.strip())

    dec = run(["sops", "--decrypt", "--input-type", "yaml",
               "--output-type", "yaml", SECRETS], env=env)
    if dec.returncode != 0:
        log("host key cannot decrypt secrets.yaml (%s) — leaving unchanged"
            % dec.stderr.strip())
        return 0

    plain_path = None
    enc_path = SECRETS + ".rekey.tmp"
    try:
        # Plaintext goes to tmpfs (/run), never to persistent disk.
        fd, plain_path = tempfile.mkstemp(dir=PLAINTEXT_DIR, suffix=".secrets-plain")
        with os.fdopen(fd, "w") as handle:
            handle.write(dec.stdout)

        enc = run(["sops", "--age", recipients, "--encrypt", "--input-type",
                   "yaml", "--output-type", "yaml", "--output", enc_path,
                   plain_path], env=env)
        if enc.returncode != 0:
            log("re-encrypt failed: %s — leaving unchanged" % enc.stderr.strip())
            return 0

        # SAFETY BELT: the host key MUST still decrypt the re-keyed file, byte
        # for byte, before we replace the live secrets.yaml. Never swap in a
        # file the box cannot boot-decrypt.
        ver = run(["sops", "--decrypt", "--input-type", "yaml",
                   "--output-type", "yaml", enc_path], env=env)
        if ver.returncode != 0 or ver.stdout != dec.stdout:
            log("verify-after-rekey failed — refusing to replace secrets.yaml")
            return 0

        os.chmod(enc_path, 0o600)
        os.replace(enc_path, SECRETS)
        enc_path = None
        log("re-keyed secrets.yaml (now %d recipient(s))"
            % (1 + len(users)))
    finally:
        for path in (plain_path, enc_path):
            if path and os.path.exists(path):
                try:
                    os.unlink(path)
                except OSError:
                    pass

    # Keep .sops.yaml's creation rule consistent (not load-bearing for decrypt,
    # but avoids a stale/misleading recipient list).
    try:
        with open(SOPS_CFG, "w") as handle:
            yaml.dump({"creation_rules": [{
                "path_regex": r".*/secrets/.*\.yaml$",
                "age": recipients,
            }]}, handle, default_flow_style=False)
        os.chmod(SOPS_CFG, 0o600)
    except Exception as exc:
        log("warning: could not update .sops.yaml: %s" % exc)
    return 0


def entry():
    try:
        return main()
    except Exception as exc:  # never fail activation
        log("unexpected error: %s — leaving secrets.yaml unchanged" % exc)
        return 0


if __name__ == "__main__":
    sys.exit(entry())
