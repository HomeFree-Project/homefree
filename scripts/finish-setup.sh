#!/usr/bin/env bash
#
# finish-setup.sh — complete post-install configuration on an already-installed
# HomeFree box.
#
# The ISO installer never collects an SSH authorized key, DNS-01 (wildcard cert)
# credentials, or ddclient (dynamic DNS) credentials — because the kiosk
# installer has no way for the operator to paste keys/tokens from their laptop.
# Without an authorized key, HomeFree cannot encrypt any secrets; without DNS-01,
# Caddy cannot issue a cert for admin.<domain>.
#
# This script walks through those three items, writing into /etc/nixos exactly
# as the admin UI would. It reuses the backend's SecretsManager (SOPS/age) rather
# than reimplementing the crypto. It does NOT run a rebuild — it prints the
# command for the operator to run themselves.
#
# Run on the box, as root:
#     sudo bash scripts/finish-setup.sh
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Paths & constants
# ----------------------------------------------------------------------------
NIXOS_DIR="/etc/nixos"
CONFIG_FILE="${NIXOS_DIR}/homefree-config.json"
SECRETS_FILE="${NIXOS_DIR}/secrets/secrets.yaml"
SOPS_CONFIG_FILE="${NIXOS_DIR}/.sops.yaml"
SYSTEM_HOST_KEY="/etc/ssh/ssh_host_ed25519_key"
SECRETS_BASE="/var/lib/homefree-secrets"

# Resolve repo root so we can find the backend SecretsManager.
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )
  SOURCE=$(readlink "$SOURCE")
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )
REPO_ROOT=$( cd -P "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd )
BACKEND_DIR="${REPO_ROOT}/web-platform/backend"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[ OK ]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $1" >&2; }
section()     { echo; echo -e "${BLUE}==== $1 ====${NC}"; }

# ----------------------------------------------------------------------------
# Locate a Python interpreter that has the backend's dependencies (pyyaml etc.).
# On an installed box the admin-api runs via the `homefree-admin-backend`
# wrapper, which hard-codes `<pythonEnv>/bin/python` — extract that path so we
# reuse the exact interpreter the backend itself uses. Fall back to plain
# python3 only if the wrapper is unavailable.
# ----------------------------------------------------------------------------
find_python() {
  local wrapper py
  wrapper=$(command -v homefree-admin-backend 2>/dev/null || true)
  if [ -n "$wrapper" ]; then
    py=$(grep -oE '/nix/store/[^ ]*/bin/python[0-9.]*' "$wrapper" 2>/dev/null | head -n1 || true)
    if [ -n "$py" ] && [ -x "$py" ]; then
      echo "$py"; return 0
    fi
  fi
  echo "python3"
}
PYTHON_BIN="$(find_python)"

# ----------------------------------------------------------------------------
# Python bridge — reuse the backend's SecretsManager so the SOPS/age logic is
# never duplicated. SecretsManager reads /etc/nixos/homefree-config.json and the
# system host key directly, so we just import and call it.
# ----------------------------------------------------------------------------
py() {
  # Usage: py <function> [args...]   — runs a helper inside the backend module.
  "$PYTHON_BIN" - "$BACKEND_DIR" "$@" <<'PYEOF'
import sys, json
backend_dir = sys.argv[1]
sys.path.insert(0, backend_dir)
from services.secrets_manager import SecretsManager  # noqa: E402

fn = sys.argv[2]
args = sys.argv[3:]

if fn == "validate_key":
    ok, err = SecretsManager.validate_ssh_public_key(args[0])
    if not ok:
        print(err or "invalid key", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)

elif fn == "regen_sops_config":
    # args[0] = user public key
    system_key = SecretsManager.get_system_ssh_public_key()
    if not system_key:
        print("System SSH host key not found", file=sys.stderr)
        sys.exit(1)
    SecretsManager.create_sops_config(system_key, args[0])
    sys.exit(0)

elif fn == "reencrypt_existing":
    # Re-encrypt the existing secrets file so it carries the (new) recipient
    # set from .sops.yaml. No-op if there is no secrets file yet.
    import os, subprocess
    from services.secrets_manager import SECRETS_FILE, SOPS_CONFIG_FILE, SYSTEM_SSH_PRIVATE_KEY
    if not SECRETS_FILE.exists():
        sys.exit(0)
    age_priv = SecretsManager.ssh_private_to_age(SYSTEM_SSH_PRIVATE_KEY)
    if not age_priv:
        print("Failed to derive age key from system host key", file=sys.stderr)
        sys.exit(1)
    env = os.environ.copy()
    env["SOPS_AGE_KEY"] = age_priv
    subprocess.run(
        ["sops", "--config", str(SOPS_CONFIG_FILE), "updatekeys", "--yes", str(SECRETS_FILE)],
        check=True, env=env,
    )
    sys.exit(0)

elif fn == "set_secret":
    # args: service_label secret_key value
    ok, err = SecretsManager.set_secret(args[0], args[1], args[2])
    if not ok:
        print(err or "set_secret failed", file=sys.stderr)
        sys.exit(1)
    ok, err = SecretsManager.write_secret_files()
    if not ok:
        print(err or "write_secret_files failed", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)

elif fn == "decrypt_test":
    # Confirm the secrets file still decrypts with the system host key.
    import os, subprocess
    from services.secrets_manager import SECRETS_FILE, SOPS_CONFIG_FILE, SYSTEM_SSH_PRIVATE_KEY
    if not SECRETS_FILE.exists():
        sys.exit(0)
    age_priv = SecretsManager.ssh_private_to_age(SYSTEM_SSH_PRIVATE_KEY)
    if not age_priv:
        print("Failed to derive age key", file=sys.stderr)
        sys.exit(1)
    env = os.environ.copy()
    env["SOPS_AGE_KEY"] = age_priv
    subprocess.run(
        ["sops", "--config", str(SOPS_CONFIG_FILE), "--decrypt", str(SECRETS_FILE)],
        check=True, capture_output=True, env=env,
    )
    sys.exit(0)

else:
    print(f"unknown helper: {fn}", file=sys.stderr)
    sys.exit(2)
PYEOF
}

# ----------------------------------------------------------------------------
# 0. Preconditions
# ----------------------------------------------------------------------------
preconditions() {
  section "Preconditions"

  if [ "$(id -u)" -ne 0 ]; then
    log_error "Must run as root (needs the system SSH host key and write access to /etc/nixos)."
    log_info  "Re-run with: sudo bash ${BASH_SOURCE[0]}"
    exit 1
  fi

  if [ ! -f "$CONFIG_FILE" ]; then
    log_error "$CONFIG_FILE not found — this does not look like an installed HomeFree box."
    exit 1
  fi

  if [ ! -f "$SYSTEM_HOST_KEY" ]; then
    log_error "$SYSTEM_HOST_KEY not found — cannot encrypt secrets without the system host key."
    exit 1
  fi

  for tool in jq sops ssh-to-age curl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      log_error "Required tool '$tool' not found on PATH."
      exit 1
    fi
  done

  if [ ! -d "$BACKEND_DIR" ]; then
    log_error "Backend directory not found at $BACKEND_DIR — run this script from a HomeFree checkout."
    exit 1
  fi

  # The SecretsManager bridge needs pyyaml. Confirm the chosen interpreter has it.
  if ! "$PYTHON_BIN" -c 'import yaml' >/dev/null 2>&1; then
    log_error "Python interpreter '$PYTHON_BIN' is missing the 'yaml' module."
    log_info  "This script must run on an installed HomeFree box where the"
    log_info  "admin backend (and its Python environment) is available."
    exit 1
  fi

  log_success "Running as root; config and tooling present."

  # Timestamped backups before any mutation.
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  cp -a "$CONFIG_FILE" "${CONFIG_FILE}.bak-${ts}"
  log_info "Backed up config -> ${CONFIG_FILE}.bak-${ts}"
  if [ -f "$SECRETS_FILE" ]; then
    cp -a "$SECRETS_FILE" "${SECRETS_FILE}.bak-${ts}"
    log_info "Backed up secrets -> ${SECRETS_FILE}.bak-${ts}"
  fi
  if [ -f "$SOPS_CONFIG_FILE" ]; then
    cp -a "$SOPS_CONFIG_FILE" "${SOPS_CONFIG_FILE}.bak-${ts}"
    log_info "Backed up .sops.yaml -> ${SOPS_CONFIG_FILE}.bak-${ts}"
  fi
}

# Atomically replace homefree-config.json with the result of a jq program.
# Usage: update_config '<jq program>' [jq args...]
update_config() {
  local prog="$1"; shift
  local tmp; tmp=$(mktemp "${CONFIG_FILE}.XXXXXX")
  jq "$@" "$prog" "$CONFIG_FILE" > "$tmp"
  mv "$tmp" "$CONFIG_FILE"
}

# ----------------------------------------------------------------------------
# 1. SSH authorized key — REQUIRED. Gates every secret, since SOPS encrypts to
#    the system host key + the first user authorized key.
# ----------------------------------------------------------------------------
step_ssh_key() {
  section "Step 1/3 — SSH authorized key (required)"
  echo "An SSH public key is required before any secret can be saved: HomeFree"
  echo "encrypts secrets to the system host key PLUS your first authorized key."
  echo "Skipping this means DNS-01 and ddclient below cannot be configured, and"
  echo "you will have no SSH access to the box."
  echo

  local existing
  existing=$(jq -r '.system.authorizedKeys | length' "$CONFIG_FILE")
  if [ "$existing" -gt 0 ]; then
    log_info "$existing authorized key(s) already configured."
    read -r -p "Add another key anyway? [y/N] " ans
    [[ "${ans,,}" == "y" ]] || { log_info "Keeping existing keys."; return 0; }
  fi

  echo "Paste an SSH PUBLIC key (e.g. the contents of ~/.ssh/id_ed25519.pub):"
  read -r pubkey
  pubkey="${pubkey#"${pubkey%%[![:space:]]*}"}"   # ltrim
  pubkey="${pubkey%"${pubkey##*[![:space:]]}"}"   # rtrim

  if [ -z "$pubkey" ]; then
    log_error "No key entered. SSH key is required — aborting."
    exit 1
  fi

  if ! py validate_key "$pubkey"; then
    log_error "SSH key failed validation — aborting."
    exit 1
  fi
  log_success "SSH key format valid."

  # Idempotent append.
  if jq -e --arg k "$pubkey" '.system.authorizedKeys | index($k)' "$CONFIG_FILE" >/dev/null; then
    log_info "Key already present in config — not adding a duplicate."
  else
    update_config '.system.authorizedKeys += [$k]' --arg k "$pubkey"
    log_success "Key added to system.authorizedKeys."
  fi

  # Regenerate .sops.yaml with system + user recipients, then re-encrypt any
  # existing secrets file so it carries the new recipient set.
  py regen_sops_config "$pubkey"
  log_success "Regenerated $SOPS_CONFIG_FILE."
  py reencrypt_existing
  log_success "Re-encrypted existing secrets (if any) to the new recipient set."

  # Round-trip test.
  if py decrypt_test; then
    log_success "Secrets decrypt test passed."
  else
    log_error "Secrets no longer decrypt with the system host key — aborting."
    log_warning "Restore from the .bak-* files created above before retrying."
    exit 1
  fi
}

# ----------------------------------------------------------------------------
# 2. DNS-01 wildcard cert credentials — second priority. Without this,
#    admin.<domain> has no TLS cert and is unreachable over HTTPS.
# ----------------------------------------------------------------------------
step_dns01() {
  section "Step 2/3 — DNS-01 wildcard certificate (recommended)"
  echo "DNS-01 lets Caddy issue a *.<domain> certificate so admin.<domain> works"
  echo "over HTTPS. Skipping this leaves the admin UI reachable only over plain"
  echo "HTTP on the LAN (e.g. http://homefree.lan)."
  echo

  read -r -p "Configure DNS-01 now? [Y/n] " ans
  if [[ "${ans,,}" == "n" ]]; then
    log_warning "Skipped DNS-01 — admin.<domain> will have no certificate."
    return 0
  fi

  read -r -p "DNS provider [hetzner]: " provider
  provider="${provider:-hetzner}"

  echo "Paste the ${provider} API token:"
  read -r token
  token="${token#"${token%%[![:space:]]*}"}"; token="${token%"${token##*[![:space:]]}"}"
  if [ -z "$token" ]; then
    log_error "No token entered — skipping DNS-01."
    return 0
  fi

  # Write provider + resolvers into config (cert-management starts as null).
  update_config \
    '.dns["cert-management"] = {"provider": $p, "resolvers": ($r | split(","))}' \
    --arg p "$provider" --arg r "1.1.1.1"
  log_success "Set dns.cert-management.provider = ${provider}."

  # Store the token as a SOPS secret -> /var/lib/homefree-secrets/dns/api-token.
  if py set_secret "dns" "api-token" "$token"; then
    log_success "Encrypted DNS-01 token; wrote ${SECRETS_BASE}/dns/api-token."
  else
    log_error "Failed to store DNS-01 token."
    return 0
  fi

  # Read-only API test (Hetzner Cloud DNS). Warn-only so the operator can
  # proceed and fix a bad token later.
  if [ "$provider" = "hetzner" ]; then
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer ${token}" \
      "https://dns.hetzner.com/api/v1/zones" 2>/dev/null || echo "000")
    if [ "$code" = "200" ]; then
      log_success "Hetzner DNS API accepted the token (HTTP 200)."
    else
      log_warning "Hetzner DNS API returned HTTP ${code} — token may be wrong."
      log_warning "Setup will continue; fix the token via the admin UI if needed."
    fi
  fi
}

# ----------------------------------------------------------------------------
# 3. ddclient dynamic DNS — lowest priority. Only needed for publicly
#    reachable pages; HomeFree runs its own internal DNS.
# ----------------------------------------------------------------------------
step_ddclient() {
  section "Step 3/3 — ddclient dynamic DNS (optional)"
  echo "ddclient keeps public DNS records pointed at this box's WAN IP. It is"
  echo "only needed for pages you want reachable from the public internet."
  echo "Skipping this is fine if you only use HomeFree on your LAN."
  echo

  read -r -p "Configure a ddclient zone now? [y/N] " ans
  if [[ "${ans,,}" != "y" ]]; then
    log_info "Skipped ddclient."
    return 0
  fi

  while true; do
    read -r -p "Zone (e.g. example.com): " zone
    [ -z "$zone" ] && { log_info "No zone entered — done."; break; }
    read -r -p "Protocol [hetzner]: " protocol
    protocol="${protocol:-hetzner}"
    read -r -p "Username: " username
    read -r -p "Domains (space-separated) [@ *]: " domains
    domains="${domains:-@ *}"
    read -r -p "Password file key (short name for the secret) [password]: " seckey
    seckey="${seckey:-password}"
    echo "Paste the password / API token for this zone:"
    read -r zonepass
    zonepass="${zonepass#"${zonepass%%[![:space:]]*}"}"
    zonepass="${zonepass%"${zonepass##*[![:space:]]}"}"

    # Append the zone to dns.dynamic-dns.zones (domains -> JSON array).
    update_config \
      '.dns["dynamic-dns"].zones += [{
         "zone": $zone, "protocol": $proto, "username": $user,
         "domains": ($domains | split(" ") | map(select(length>0))),
         "password-secret-key": $key, "disable": false }]' \
      --arg zone "$zone" --arg proto "$protocol" --arg user "$username" \
      --arg domains "$domains" --arg key "$seckey"
    log_success "Added zone ${zone}."

    if [ -n "$zonepass" ]; then
      if py set_secret "ddclient" "$seckey" "$zonepass"; then
        if [ -s "${SECRETS_BASE}/ddclient/${seckey}" ]; then
          log_success "Stored credential -> ${SECRETS_BASE}/ddclient/${seckey}."
        else
          log_warning "Credential file ${SECRETS_BASE}/ddclient/${seckey} missing or empty."
        fi
      else
        log_error "Failed to store credential for key ${seckey}."
      fi
    else
      log_warning "No password entered for key ${seckey} — set it later via the admin UI."
    fi

    read -r -p "Add another zone? [y/N] " more
    [[ "${more,,}" == "y" ]] || break
  done
}

# ----------------------------------------------------------------------------
# Finish
# ----------------------------------------------------------------------------
finish() {
  section "Done"
  log_success "Configuration written to ${CONFIG_FILE} and ${SECRETS_FILE}."
  echo
  echo "To apply the changes, run a rebuild yourself:"
  echo
  echo -e "    ${GREEN}sudo ${REPO_ROOT}/scripts/build.sh -s${NC}"
  echo
  echo "After the rebuild, Caddy will request the wildcard certificate and"
  echo "https://admin.<domain> will become reachable. Backups of the previous"
  echo "config are kept alongside the originals as .bak-<timestamp> files."
}

main() {
  echo
  echo "HomeFree — finish post-install setup"
  echo "------------------------------------"
  preconditions
  step_ssh_key
  step_dns01
  step_ddclient
  finish
}

main "$@"
