"""
Restore-from-backup setup service — drives the "Restore from backup" branch of
the post-install Finish Setup wizard.

It bootstraps a fresh box from an existing restic backup:

  open()   Using operator-supplied restic credentials + their SSH private key,
           pull the backup's `system-config` snapshot (just homefree-config.json
           + secrets.yaml) into a tmpfs staging dir, summarize it, and verify the
           private key can actually decrypt the backed-up secrets.

  apply()  Re-key the backed-up secrets.yaml to THIS box's host key (recovering
           every secret — restic password, DNS token, service masterkeys), merge
           the backup's logical config (optionally onto a NEW domain, with new
           DNS-01 + ddclient secrets), and trigger a rebuild.

  cancel() Drop the staging dir.

After apply()'s rebuild succeeds the wizard runs the existing
POST /api/backups/restore-all to restore service DATA, then marks setup complete.

SECURITY. The operator's SSH private key is written ONLY to a 0600 file under
/run (tmpfs), used for a single sops invocation, and unlinked in a `finally`. It
is never logged, never placed in argv, never persisted. Decrypted secrets are
written only to 0600 tmpfs files and removed immediately.

The re-key reuses SecretsManager._build_age_recipients so the recipient scheme
matches the rest of HomeFree (host age1 + each authorized key as native ssh).
"""

import json
import logging
import os
import secrets as pysecrets
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Dict, List, Optional

from services.secrets_manager import (
    SecretsManager, SECRETS_FILE, SYSTEM_SSH_PRIVATE_KEY,
)

logger = logging.getLogger("homefree-installer")

# tmpfs root for staging + transient key/plaintext files.
RUN_DIR = Path("/run")
STAGING_ROOT = RUN_DIR / "homefree-restore"

# The restic repo that carries /etc/nixos (domain, authorizedKeys, secrets.yaml).
SYSTEM_CONFIG_LABEL = "system-config"

# Paths we pull out of the system-config snapshot (relative to the snapshot root).
BACKUP_CONFIG_PATH = "etc/nixos/homefree-config.json"
BACKUP_SECRETS_PATH = "etc/nixos/secrets/secrets.yaml"

# Logical config sections restored from the backup. Machine-specific sections
# (network, storage, mounts) and hardware files are deliberately NOT restored —
# the new box keeps its own.
RESTORE_SECTIONS = [
    "system", "dns", "backups", "services",
    "service-config", "proxied-domains", "snapshots", "alerts",
]

# In-memory sessions: session_id -> {"staging": <dir>}. Holds NO secrets; the
# restic creds and private key are transient and re-supplied to apply().
_SESSIONS: Dict[str, Dict] = {}


class RestoreSetupError(Exception):
    """A user-facing restore error (the message is safe to show)."""


def _run(cmd: List[str], env: Optional[Dict] = None, input_text: Optional[str] = None):
    return subprocess.run(
        cmd, capture_output=True, text=True,
        env=env, input=input_text,
    )


def _restic_repo_and_env(params: Dict) -> (str, Dict):
    """Build the restic repository URI + environment for a given source.

    params: {source, restic_password, b2_bucket, b2_account_id, b2_account_key,
             local_path}
    Raises RestoreSetupError on missing/invalid inputs.
    """
    source = (params.get("source") or "").strip()
    restic_password = params.get("restic_password") or ""
    if not restic_password:
        raise RestoreSetupError("The restic repository password is required.")

    env = os.environ.copy()
    env["RESTIC_PASSWORD"] = restic_password

    if source == "backblaze":
        bucket = (params.get("b2_bucket") or "").strip()
        account_id = (params.get("b2_account_id") or "").strip()
        account_key = (params.get("b2_account_key") or "").strip()
        if not (bucket and account_id and account_key):
            raise RestoreSetupError(
                "Backblaze restore needs a bucket name, account ID and account key.")
        env["B2_ACCOUNT_ID"] = account_id
        env["B2_ACCOUNT_KEY"] = account_key
        repo = f"b2:{bucket}:{SYSTEM_CONFIG_LABEL}"
    elif source == "local":
        local_path = (params.get("local_path") or "").strip().rstrip("/")
        if not local_path:
            raise RestoreSetupError("A local backup path is required.")
        repo = f"{local_path}/{SYSTEM_CONFIG_LABEL}"
        if not Path(repo).is_dir():
            raise RestoreSetupError(
                f"No '{SYSTEM_CONFIG_LABEL}' restic repository found under {local_path}.")
    else:
        raise RestoreSetupError("Backup source must be 'local' or 'backblaze'.")

    return repo, env


def _friendly_restic_error(stderr: str) -> str:
    low = (stderr or "").lower()
    if "wrong password" in low or "invalid data returned" in low:
        return "Incorrect restic repository password."
    if "does not exist" in low or "unable to open" in low or "no such" in low:
        return f"No '{SYSTEM_CONFIG_LABEL}' backup found at this location."
    if "b2_account" in low or "authoriz" in low or "401" in low or "403" in low:
        return "Backblaze authentication failed — check the bucket, ID and key."
    # Keep it short; never echo secrets (restic does not print them).
    return f"Could not read the backup: {(stderr or '').strip()[:200]}"


def _write_private_key_tmpfile(private_key: str) -> str:
    """Write the operator's SSH private key to a 0600 tmpfs file. Caller MUST
    unlink it in a finally. ssh keys must end with a newline to parse."""
    fd, path = tempfile.mkstemp(dir=str(RUN_DIR), suffix=".restore-key")
    try:
        os.fchmod(fd, 0o600)
        body = private_key if private_key.endswith("\n") else private_key + "\n"
        with os.fdopen(fd, "w") as handle:
            handle.write(body)
    except Exception:
        try:
            os.unlink(path)
        except OSError:
            pass
        raise
    return path


def _decrypt_with_private_key(secrets_path: str, private_key: str) -> str:
    """Decrypt a sops file using the operator's SSH private key as a native age
    ssh identity. Returns plaintext YAML. Raises RestoreSetupError if the key is
    not a recipient (or the file is unreadable)."""
    key_path = _write_private_key_tmpfile(private_key)
    try:
        env = os.environ.copy()
        env["SOPS_AGE_SSH_PRIVATE_KEY_FILE"] = key_path
        res = _run(["sops", "--decrypt", "--input-type", "yaml",
                    "--output-type", "yaml", secrets_path], env=env)
        if res.returncode != 0:
            raise RestoreSetupError(
                "Your SSH private key could not decrypt this backup's secrets. "
                "Use the private key matching one of the backup's authorized keys. "
                "(If the backup predates native-SSH recipients, only the old host "
                "key can decrypt it.)")
        return res.stdout
    finally:
        try:
            os.unlink(key_path)
        except OSError:
            pass


def _summarize_config(config: Dict) -> Dict:
    system = config.get("system", {}) or {}
    auth_keys = []
    for key in system.get("authorizedKeys", []) or []:
        parts = (key or "").split()
        if len(parts) >= 2:
            auth_keys.append({
                "type": parts[0],
                "comment": parts[2] if len(parts) >= 3 else "",
            })
    dns = config.get("dns", {}) or {}
    backups = config.get("backups", {}) or {}
    return {
        "domain": system.get("domain", ""),
        "authorized_keys": auth_keys,
        "backups": {
            "enable": backups.get("enable", False),
            "to-path": backups.get("to-path", ""),
            "backblaze": {"enable": (backups.get("backblaze", {}) or {}).get("enable", False),
                          "bucket": (backups.get("backblaze", {}) or {}).get("bucket", "")},
        },
        "dns": {
            "provider": (dns.get("cert-management", {}) or {}).get("provider", ""),
            "zones": [z.get("zone", "") for z in (dns.get("dynamic-dns", {}) or {}).get("zones", []) or []],
        },
    }


class RestoreSetupService:

    @staticmethod
    def open_backup(params: Dict) -> Dict:
        """Pull + summarize the backup's system-config snapshot and verify the
        operator's private key can decrypt its secrets. Returns a summary +
        session id. Raises RestoreSetupError for user-facing problems."""
        private_key = params.get("private_key") or ""
        if not private_key.strip():
            raise RestoreSetupError("Your SSH private key is required to decrypt the backup.")

        repo, env = _restic_repo_and_env(params)

        # Verify access (and surface a friendly error) before restoring.
        check = _run(["restic", "-r", repo, "snapshots", "--json"], env=env)
        if check.returncode != 0:
            raise RestoreSetupError(_friendly_restic_error(check.stderr))

        STAGING_ROOT.mkdir(parents=True, exist_ok=True)
        os.chmod(STAGING_ROOT, 0o700)
        staging = tempfile.mkdtemp(dir=str(STAGING_ROOT))

        try:
            restore = _run([
                "restic", "-r", repo, "restore", "latest", "--target", staging,
                "--include", "/" + BACKUP_CONFIG_PATH,
                "--include", "/" + BACKUP_SECRETS_PATH,
            ], env=env)
            if restore.returncode != 0:
                raise RestoreSetupError(_friendly_restic_error(restore.stderr))

            config_file = Path(staging) / BACKUP_CONFIG_PATH
            secrets_file = Path(staging) / BACKUP_SECRETS_PATH
            if not config_file.is_file():
                raise RestoreSetupError(
                    "The backup's system-config snapshot has no homefree-config.json.")
            if not secrets_file.is_file():
                raise RestoreSetupError(
                    "The backup has no encrypted secrets (secrets.yaml) to restore.")

            try:
                config = json.loads(config_file.read_text())
            except json.JSONDecodeError as exc:
                raise RestoreSetupError(f"The backup's homefree-config.json is invalid: {exc}")

            # Verify the private key really is a recipient (decryption succeeds).
            _decrypt_with_private_key(str(secrets_file), private_key)

            session_id = pysecrets.token_urlsafe(24)
            _SESSIONS[session_id] = {"staging": staging}
            summary = _summarize_config(config)
            summary["session_id"] = session_id
            return summary
        except Exception:
            shutil.rmtree(staging, ignore_errors=True)
            raise

    @staticmethod
    def _rekey_secrets(staged_secrets: str, private_key: str, recipient_keys: List[str]):
        """Decrypt the staged secrets.yaml with the operator's private key and
        re-encrypt it to THIS box's host key + the given authorized keys, then
        install it as the live /etc/nixos/secrets/secrets.yaml.

        Verifies the new host key can still decrypt before swapping it in, so a
        bad re-key can never brick the box."""
        host_pub = SecretsManager.get_system_ssh_public_key()
        if not host_pub:
            raise RestoreSetupError("This box has no SSH host key yet.")

        recipients = SecretsManager._build_age_recipients(host_pub, recipient_keys)

        plaintext = _decrypt_with_private_key(staged_secrets, private_key)

        SecretsManager.ensure_secrets_dir()
        plain_path = None
        enc_path = str(SECRETS_FILE) + ".restore.tmp"
        try:
            fd, plain_path = tempfile.mkstemp(dir=str(RUN_DIR), suffix=".restore-plain")
            with os.fdopen(fd, "w") as handle:
                handle.write(plaintext)

            enc = _run(["sops", "--age", recipients, "--encrypt", "--input-type",
                        "yaml", "--output-type", "yaml", "--output", enc_path, plain_path])
            if enc.returncode != 0:
                raise RestoreSetupError(f"Failed to re-encrypt secrets: {enc.stderr.strip()[:200]}")

            # SAFETY: the NEW host key must decrypt the re-keyed file before swap.
            host_age_priv = SecretsManager.ssh_private_to_age(SYSTEM_SSH_PRIVATE_KEY)
            if not host_age_priv:
                raise RestoreSetupError("Could not derive this box's host age key.")
            verify_env = os.environ.copy()
            verify_env["SOPS_AGE_KEY"] = host_age_priv
            ver = _run(["sops", "--decrypt", "--input-type", "yaml",
                        "--output-type", "yaml", enc_path], env=verify_env)
            if ver.returncode != 0 or ver.stdout != plaintext:
                raise RestoreSetupError(
                    "Re-keyed secrets failed host-key verification; aborting restore.")

            os.chmod(enc_path, 0o600)
            os.replace(enc_path, str(SECRETS_FILE))
            enc_path = None
            # Keep .sops.yaml consistent with the new recipient set.
            SecretsManager.create_sops_config(host_pub, recipient_keys)
        finally:
            for path in (plain_path, enc_path):
                if path and os.path.exists(path):
                    try:
                        os.unlink(path)
                    except OSError:
                        pass

    @staticmethod
    def apply_restore(params: Dict) -> Dict:
        """Re-key + merge config + (optionally set new-domain secrets) + rebuild.

        params: {session_id, private_key, change_domain, new_domain,
                 dns_provider, dns_token, ddclient_zones:[{zone,protocol,username,
                 domains:[...],password_secret_key,password}]}
        """
        from services.config_writer import ConfigWriter
        from services.nix_operations import NixOperations
        from services.validation import ValidationService

        session_id = params.get("session_id") or ""
        private_key = params.get("private_key") or ""
        session = _SESSIONS.get(session_id)
        if not session:
            raise RestoreSetupError("Restore session expired — please re-open the backup.")
        if not private_key.strip():
            raise RestoreSetupError("Your SSH private key is required to finish the restore.")

        # Don't start if a rebuild is already running.
        if NixOperations.get_rebuild_status().get("running"):
            raise RestoreSetupError("A rebuild is already in progress. Please wait for it to finish.")

        staging = session["staging"]
        config_file = Path(staging) / BACKUP_CONFIG_PATH
        secrets_file = Path(staging) / BACKUP_SECRETS_PATH
        if not config_file.is_file() or not secrets_file.is_file():
            raise RestoreSetupError("Restore staging is missing — please re-open the backup.")

        backup_config = json.loads(config_file.read_text())
        backup_auth_keys = (backup_config.get("system", {}) or {}).get("authorizedKeys", []) or []
        if not backup_auth_keys:
            raise RestoreSetupError("The backup has no authorized SSH keys to restore.")

        change_domain = bool(params.get("change_domain"))
        new_domain = (params.get("new_domain") or "").strip()
        if change_domain and not new_domain:
            raise RestoreSetupError("Enter the new domain to use for this box.")

        # 1) Re-key the backed-up secrets to THIS box's host key (recovers all
        #    secrets). MUST happen before setting any new-domain secrets so they
        #    are not overwritten by the re-key.
        RestoreSetupService._rekey_secrets(str(secrets_file), private_key, backup_auth_keys)

        # 2) Merge the backup's logical config (keeping the new machine's
        #    network/storage/hardware untouched).
        merged: Dict = {}
        for section in RESTORE_SECTIONS:
            if section in backup_config:
                merged[section] = backup_config[section]

        if change_domain:
            system = dict(merged.get("system", {}) or {})
            system["domain"] = new_domain
            merged["system"] = system
            # Replace DNS with the operator's new-domain DNS-01 config; ddclient
            # zones come from the request (their passwords are set as secrets
            # below, after the re-key).
            zones = params.get("ddclient_zones") or []
            merged["dns"] = {
                "cert-management": {
                    "provider": (params.get("dns_provider") or "").strip() or None,
                    "resolvers": ["1.1.1.1"],
                },
                "dynamic-dns": {
                    "zones": [{
                        "zone": (z.get("zone") or "").strip(),
                        "protocol": (z.get("protocol") or "hetzner").strip(),
                        "username": (z.get("username") or "").strip(),
                        "domains": z.get("domains") or ["@", "*"],
                        "password-secret-key": (z.get("password_secret_key") or "password").strip(),
                        "disable": False,
                    } for z in zones if (z.get("zone") or "").strip()],
                },
            }

        if not ConfigWriter.write_config(merged):
            raise RestoreSetupError("Failed to write the restored configuration.")

        # 3) New-domain secrets (after re-key, before rebuild). The DNS-01 token
        #    and ddclient passwords belong to the NEW domain, so they are not in
        #    the backup; set them now so the rebuild materializes them.
        if change_domain:
            dns_token = (params.get("dns_token") or "").strip()
            if dns_token:
                ok, err = SecretsManager.set_secret("dns", "api-token", dns_token)
                if not ok:
                    raise RestoreSetupError(f"Failed to store the DNS-01 token: {err}")
            for z in (params.get("ddclient_zones") or []):
                pw = (z.get("password") or "").strip()
                if pw:
                    key = (z.get("password_secret_key") or "password").strip()
                    ok, err = SecretsManager.set_secret("ddclient", key, pw)
                    if not ok:
                        raise RestoreSetupError(f"Failed to store a ddclient password: {err}")

        # Re-validate the on-disk result before building.
        from services.config_reader import ConfigReader
        disk_config = ConfigReader.read_config()
        ok, errors = ValidationService.validate_config(disk_config)
        if not ok:
            raise RestoreSetupError(f"Restored configuration failed validation: {', '.join(errors)}")

        # 4) Rebuild. The wizard polls the existing rebuild-status endpoint and,
        #    on success, runs restore-all + marks setup complete.
        rebuild = NixOperations.rebuild_switch()

        # Staging no longer needed (config + secrets are now on the live box).
        shutil.rmtree(staging, ignore_errors=True)
        _SESSIONS.pop(session_id, None)

        return {
            "success": rebuild.get("success", False),
            "message": rebuild.get("message", ""),
            "pid": rebuild.get("pid"),
        }

    @staticmethod
    def cancel(session_id: str) -> None:
        session = _SESSIONS.pop(session_id, None)
        if session:
            shutil.rmtree(session.get("staging", ""), ignore_errors=True)
