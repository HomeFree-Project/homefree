#!/usr/bin/env bash
##
## test-zitadel-sso-bootstrap.sh — wipe Zitadel state and exercise the
## Phase 1–4 SSO bootstrap path end-to-end on a dev machine.
##
## Walks through:
##   1. Stop Zitadel + related units, drop persistent state
##   2. Prompt for the admin password (the one that should be both
##      your shell password AND your Zitadel password)
##   3. Pre-seed /var/lib/homefree-secrets/zitadel/admin-password
##   4. Run nixos-rebuild switch
##   5. Wait for podman-zitadel to come up, FirstInstance to write
##      pat-bootstrap, and zitadel-provision to complete
##   6. Print verification table (per-service OIDC secrets, PAT, sentinel)
##
## A single rebuild is sufficient — the SSO oauth2 gate is enforced
## at request time inside Caddy via a `file` matcher on the sentinel,
## not at Nix-eval time, so admin.${domain} starts redirecting to SSO
## the moment zitadel-provision touches the sentinel.
##
## Idempotent in the sense that re-running it is safe — it always
## re-prompts and starts from a clean slate.
##
## DESTRUCTIVE: drops the zitadel, immich, and nextcloud databases
## AND wipes the corresponding service data directories. Only run on
## a dev machine where loss of ALL service state is acceptable.
##
## The full wipe set (zitadel + downstream SSO consumers) is the
## minimum that's actually safe to mix-and-match: Zitadel's masterkey
## and its postgres database have to be wiped together (a new
## masterkey can't decrypt old DB rows → "malformed encrypted value"
## token errors). Same coupling applies to Immich and Nextcloud:
## they have OIDC client_id/secret persisted in their own databases,
## and zitadel-provision will mint NEW client IDs on the fresh
## Zitadel instance — so the consumer DBs need to be wiped too,
## otherwise they end up pointing at OIDC apps that no longer exist
## in Zitadel.
##
## The actual rebuild is delegated to scripts/build.sh so it picks up
## the local working-tree changes via `nix flake lock --update-input
## homefree-local` (which is what `nixos-rebuild switch` alone does
## NOT do — that command would just re-evaluate /etc/nixos/flake.nix
## against whatever git ref it currently points at).

set -euo pipefail

readonly SECRETS_ROOT=/var/lib/homefree-secrets
readonly ZITADEL_DATA=/var/lib/zitadel
readonly OAUTH2_DATA=/var/lib/oauth2-proxy
readonly NEXTCLOUD_DATA=/var/lib/nextcloud-podman
readonly FORGEJO_DATA=/var/lib/forgejo
readonly IMMICH_DATA=/var/lib/immich
readonly IMMICH_CACHE=/var/cache/immich
readonly HEADSCALE_DATA=/var/lib/headscale       # only the api-key/pat is wiped; node DB stays
readonly SENTINEL=$SECRETS_ROOT/.sso-provisioned
readonly PAT_FILE=$ZITADEL_DATA/pat-bootstrap

## postgres-vectorchord listens on this port — used to drop the
## immich DB. The container's POSTGRES_PASSWORD is hardcoded to
## 'changeme' in services/postgres-vectorchord-podman.nix.
readonly VCHORD_HOST=127.0.0.1
readonly VCHORD_PORT=6432
readonly VCHORD_ADMIN_USER=postgres
readonly VCHORD_ADMIN_PASS=changeme

## Resolve the path of build.sh sitting next to this script (handles
## symlinks the same way build.sh resolves itself).
SCRIPT_SOURCE=${BASH_SOURCE[0]}
while [ -L "$SCRIPT_SOURCE" ]; do
  DIR=$(cd -P "$(dirname "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd)
  SCRIPT_SOURCE=$(readlink "$SCRIPT_SOURCE")
  [[ $SCRIPT_SOURCE != /* ]] && SCRIPT_SOURCE=$DIR/$SCRIPT_SOURCE
done
readonly SCRIPT_DIR=$(cd -P "$(dirname "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd)
readonly BUILD_SCRIPT="$SCRIPT_DIR/build.sh"

## Colorised output if stdout is a tty.
if [ -t 1 ]; then
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
  C_BLUE=$'\e[34m'; C_BOLD=$'\e[1m'; C_RESET=$'\e[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

step() { printf '\n%s==== %s ====%s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"; }
ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
ask()  { printf '%s?%s %s ' "$C_YELLOW" "$C_RESET" "$*"; }

confirm() {
  local prompt="$1" reply
  ask "$prompt [y/N]"
  read -r reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This script needs root. Re-run with: sudo $0"
    exit 1
  fi
}

## ─── 1. Confirm + wipe ────────────────────────────────────────────────
require_root

step "Pre-flight"
echo "This will:"
echo "  - stop Zitadel + downstream service units (nextcloud, forgejo,"
echo "    immich, headplane, oauth2-proxy)"
echo "  - drop the 'zitadel', 'nextcloud', and 'immich' postgres databases"
echo "  - delete service data dirs ($ZITADEL_DATA, $NEXTCLOUD_DATA,"
echo "    $FORGEJO_DATA, $IMMICH_DATA, $OAUTH2_DATA)"
echo "  - delete $SECRETS_ROOT/{zitadel,zitadel-pam,nextcloud,forgejo,"
echo "    immich,netbird,headscale,adguard,home-assistant,.sso-provisioned}"
echo "  - re-prompt for the admin password and re-seed it"
echo "  - run 'nixos-rebuild switch' (you'll be asked first)"
echo "  ALL DATA IN THESE SERVICES WILL BE LOST."
echo
if ! confirm "Proceed?"; then
  echo "Aborted."
  exit 0
fi

step "Stopping units"
## Stop AND mask so systemd's auto-restart can't re-launch a service
## while we're mid-wipe (which would re-open a postgres connection
## and make the subsequent DROP DATABASE silently leave data behind).
## We unmask after the wipe and before the rebuild.
##
## The list is intentionally broad: any unit that holds a connection
## to one of the databases we're about to drop, or that would crash-
## loop if we wiped its data dir out from under it.
MASKED=()
for unit in zitadel-provision.service \
            podman-oauth2-proxy.service \
            podman-zitadel-login.service \
            podman-zitadel.service \
            zitadel-prepare-secrets.service \
            podman-nextcloud.service \
            podman-nextcloud-cron.service \
            podman-nextcloud-redis.service \
            podman-nextcloud-appapi-harp.service \
            podman-forgejo.service \
            podman-immich-server.service \
            podman-immich-machine-learning.service \
            podman-immich-redis.service \
            headplane.service \
            headscale-mint-api-key.service \
            headplane-prepare-secrets.service; do
  if systemctl is-loaded --quiet "$unit" 2>/dev/null \
     || systemctl list-unit-files --no-legend --type=service \
        | grep -q "^$unit "; then
    systemctl stop "$unit" 2>/dev/null \
      && ok "stopped $unit" \
      || warn "could not stop $unit (may not have been running)"
    systemctl mask "$unit" 2>/dev/null \
      && MASKED+=("$unit")
  else
    ok "$unit not present, skipping"
  fi
done

## Reset failed state in case prior provision attempts marked the
## unit Failed (StartLimitBurst tripped).
systemctl reset-failed zitadel-provision.service 2>/dev/null || true
systemctl reset-failed podman-zitadel.service 2>/dev/null || true

unmask_units() {
  for unit in "${MASKED[@]}"; do
    systemctl unmask "$unit" >/dev/null 2>&1 || true
  done
}
trap unmask_units EXIT

## Helper: drop a database AND its role from the HOST postgres
## (used for zitadel + nextcloud). Force-disconnect first so the
## drop can't silently no-op on a still-open backend connection,
## then verify the drop actually took.
drop_host_db() {
  local db="$1"
  if ! systemctl is-active --quiet postgresql.service; then
    warn "postgresql.service not running — skipping drop of '$db'"
    return 0
  fi
  local exists
  exists=$(sudo -u postgres psql -tAc \
    "SELECT 1 FROM pg_database WHERE datname='$db'" 2>/dev/null || echo "")
  if [ "$exists" != "1" ]; then
    ok "no '$db' database to drop"
    return 0
  fi
  sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 <<PSQL >/dev/null
SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
  WHERE datname = '$db';
DROP DATABASE "$db";
DROP ROLE IF EXISTS "$db";
PSQL
  local still
  still=$(sudo -u postgres psql -tAc \
    "SELECT 1 FROM pg_database WHERE datname='$db'" 2>/dev/null || echo "")
  if [ "$still" = "1" ]; then
    err "DROP DATABASE '$db' silently failed — db still exists."
    return 1
  fi
  ok "dropped database '$db' (and role of same name)"
}

## Helper: drop a database from the postgres-vectorchord CONTAINER
## (used for immich). Connects via TCP with the hardcoded password.
drop_vchord_db() {
  local db="$1"
  if ! PGPASSWORD="$VCHORD_ADMIN_PASS" timeout 5 \
       psql -h "$VCHORD_HOST" -p "$VCHORD_PORT" -U "$VCHORD_ADMIN_USER" \
            -tc "SELECT 1" >/dev/null 2>&1; then
    warn "postgres-vectorchord not reachable at $VCHORD_HOST:$VCHORD_PORT" \
         "— skipping drop of '$db'"
    return 0
  fi
  local exists
  exists=$(PGPASSWORD="$VCHORD_ADMIN_PASS" psql \
    -h "$VCHORD_HOST" -p "$VCHORD_PORT" -U "$VCHORD_ADMIN_USER" -tAc \
    "SELECT 1 FROM pg_database WHERE datname='$db'" 2>/dev/null || echo "")
  if [ "$exists" != "1" ]; then
    ok "no '$db' database to drop (vchord)"
    return 0
  fi
  PGPASSWORD="$VCHORD_ADMIN_PASS" psql \
    -h "$VCHORD_HOST" -p "$VCHORD_PORT" -U "$VCHORD_ADMIN_USER" -v ON_ERROR_STOP=1 \
    -d postgres <<PSQL >/dev/null
SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
  WHERE datname = '$db';
DROP DATABASE "$db";
DROP ROLE IF EXISTS "$db";
PSQL
  ok "dropped database '$db' from vchord (and role of same name)"
}

step "Dropping postgres databases"
drop_host_db "zitadel"     || true
drop_host_db "nextcloud"   || true
drop_vchord_db "immich"    || true

step "Deleting persistent state"
## Service data dirs (DBs already dropped above), then per-service
## secrets dirs (OIDC creds, admin passwords, mint-once tokens),
## then the global SSO sentinel that Caddy's request-time matcher
## uses to flip the oauth2 gate on. Keeping the netbird/headscale
## etc. secrets entries in this list even when those services
## don't have data dirs — the secrets-dir delete is still useful
## (forces zitadel-provision to mint fresh OIDC creds + machine
## PATs on the next run, so old IDs don't linger).
for path in "$ZITADEL_DATA" \
            "$OAUTH2_DATA" \
            "$NEXTCLOUD_DATA" \
            "$FORGEJO_DATA" \
            "$IMMICH_DATA" \
            "$IMMICH_CACHE" \
            "$SECRETS_ROOT/zitadel" \
            "$SECRETS_ROOT/zitadel-pam" \
            "$SECRETS_ROOT/netbird" \
            "$SECRETS_ROOT/immich" \
            "$SECRETS_ROOT/nextcloud" \
            "$SECRETS_ROOT/forgejo" \
            "$SECRETS_ROOT/headscale" \
            "$SECRETS_ROOT/adguard" \
            "$SECRETS_ROOT/home-assistant" \
            "$SENTINEL"; do
  if [ -e "$path" ]; then
    rm -rf -- "$path"
    ok "removed $path"
  fi
done

## ─── 2. Re-seed admin password ────────────────────────────────────────
step "Seeding admin-password"
echo "Zitadel's FirstInstance bootstrap reads this file to set the human"
echo "user's initial password. Use the SAME password as your OS admin"
echo "user (so the PAM sync stays a no-op for matching credentials)."
echo

while :; do
  ask "Admin password (input hidden):"
  read -rs pw1
  echo
  ask "Confirm:                       "
  read -rs pw2
  echo
  if [ -z "$pw1" ]; then
    warn "Empty password not allowed; try again."
    continue
  fi
  if [ "$pw1" != "$pw2" ]; then
    warn "Passwords didn't match; try again."
    continue
  fi
  break
done

mkdir -p "$SECRETS_ROOT/zitadel"
chmod 700 "$SECRETS_ROOT/zitadel"
## printf '%s' deliberately omits trailing newline — Zitadel reads the
## entire file as the password, newlines included.
printf '%s' "$pw1" > "$SECRETS_ROOT/zitadel/admin-password"
chmod 600 "$SECRETS_ROOT/zitadel/admin-password"
unset pw1 pw2
ok "wrote $SECRETS_ROOT/zitadel/admin-password"

## Unmask units before rebuild — nixos-rebuild needs to be able to
## start them as part of activation. The EXIT trap is a safety net for
## the abort path (Ctrl-C, build failure before we get here).
step "Unmasking units (so nixos-rebuild can start them)"
unmask_units
trap - EXIT
ok "units unmasked"

## ─── 3. Rebuild ───────────────────────────────────────────────────────
step "Rebuild via scripts/build.sh"
echo "build.sh runs 'nix flake lock --update-input homefree-local' so the"
echo "rebuild picks up your local working-tree changes (not just whatever"
echo "git ref /etc/nixos/flake.nix currently points at)."
echo

if [ ! -x "$BUILD_SCRIPT" ]; then
  err "build.sh not found or not executable at $BUILD_SCRIPT"
  err "Falling back to plain 'nixos-rebuild switch' is NOT what you want"
  err "for testing local changes — fix the script path and re-run."
  exit 1
fi

if ! confirm "Run '$BUILD_SCRIPT' now?"; then
  echo "Skipping rebuild. Run '$BUILD_SCRIPT' yourself, then run this"
  echo "script again to redo the wipe+verify (or skip directly to the"
  echo "verification commands at the end of this script)."
  exit 0
fi

if ! "$BUILD_SCRIPT"; then
  err "build.sh failed. Fix the eval/build error and re-run."
  exit 1
fi
ok "rebuild succeeded"

## ─── 4. Wait for the chain ────────────────────────────────────────────
## podman-zitadel takes ~30-60s to come up and run FirstInstance setup.
## zitadel-provision waits for healthz then provisions; should complete
## within another ~30s after Zitadel is healthy.
step "Waiting for podman-zitadel to start + write pat-bootstrap"
for i in $(seq 1 60); do
  if [ -s "$PAT_FILE" ]; then
    ok "pat-bootstrap appeared (after ${i}s)"
    break
  fi
  if [ "$i" -eq 60 ]; then
    err "pat-bootstrap did not appear within 60s"
    err "check: journalctl -u podman-zitadel -e"
    exit 1
  fi
  sleep 1
done

step "Waiting for zitadel-provision to complete"
## RemainAfterExit=true means "active" once finished; "activating" while
## still running. Cap at 5 minutes.
for i in $(seq 1 60); do
  state=$(systemctl is-active zitadel-provision.service 2>/dev/null || echo unknown)
  case "$state" in
    active)
      ok "zitadel-provision is active (exited)"
      break
      ;;
    failed)
      err "zitadel-provision failed"
      err "check: journalctl -u zitadel-provision -e"
      exit 1
      ;;
    activating|inactive|unknown)
      sleep 5
      ;;
    *)
      warn "unknown state '$state', continuing to poll"
      sleep 5
      ;;
  esac
  if [ "$i" -eq 60 ]; then
    err "zitadel-provision did not complete within 5 minutes"
    err "current state: $state"
    err "check: journalctl -u zitadel-provision -e"
    exit 1
  fi
done

## ─── 5. Verify ────────────────────────────────────────────────────────
step "Verification"

## Two flavours of file check: content (must be non-empty) and marker
## (mere existence). Sentinels and .provisioned markers are touched
## with zero bytes by design — `[ -s ]` would (incorrectly) fail them.
check_file() {
  local label="$1" path="$2"
  if [ -s "$path" ]; then
    ok "$label: $path"
  else
    err "$label MISSING: $path"
    return 1
  fi
}
check_marker() {
  local label="$1" path="$2"
  if [ -e "$path" ]; then
    ok "$label: $path"
  else
    err "$label MISSING: $path"
    return 1
  fi
}

errs=0
check_file "masterkey"            "$SECRETS_ROOT/zitadel/masterkey"             || errs=$((errs+1))
check_file "oauth2 cookie secret" "$SECRETS_ROOT/zitadel/oauth2-cookie-secret"  || errs=$((errs+1))
check_file "admin password"       "$SECRETS_ROOT/zitadel/admin-password"        || errs=$((errs+1))
check_file "FirstInstance PAT"    "$PAT_FILE"                                   || errs=$((errs+1))
check_file "login-client PAT"     "$ZITADEL_DATA/bootstrap/login-client.pat"    || errs=$((errs+1))
check_file   "PAM-sync PAT"       "$SECRETS_ROOT/zitadel-pam/pat"               || errs=$((errs+1))
check_marker "global sentinel"    "$SENTINEL"                                   || errs=$((errs+1))

echo
echo "Per-service OIDC secrets:"
for svc in zitadel headscale netbird immich nextcloud forgejo; do
  cid="$SECRETS_ROOT/$svc/oidc-client-id"
  csec="$SECRETS_ROOT/$svc/oidc-client-secret"
  prov="$SECRETS_ROOT/$svc/.provisioned"
  if [ -s "$cid" ]; then
    if [ -e "$prov" ]; then
      ok "$svc: client_id=$(head -c 32 "$cid")... (.provisioned ✓)"
    else
      warn "$svc: client_id present but .provisioned marker missing"
    fi
  else
    err "$svc: oidc-client-id MISSING"
    errs=$((errs+1))
  fi
done

if [ -s "$SECRETS_ROOT/netbird/mgmt-machine-token" ]; then
  ok "netbird: mgmt-machine-token present"
else
  err "netbird: mgmt-machine-token MISSING"
  errs=$((errs+1))
fi

if [ -s "$SECRETS_ROOT/netbird/data-store-encryption-key" ]; then
  ok "netbird: data-store-encryption-key present"
else
  err "netbird: data-store-encryption-key MISSING"
  errs=$((errs+1))
fi

echo
echo "Service unit states:"
for unit in podman-zitadel podman-zitadel-login podman-oauth2-proxy zitadel-provision; do
  state=$(systemctl is-active "$unit" 2>/dev/null || echo unknown)
  case "$state" in
    active)  ok "$unit: $state" ;;
    *)       err "$unit: $state (expected: active)"; errs=$((errs+1)) ;;
  esac
done

echo
if [ "$errs" -gt 0 ]; then
  err "$errs verification check(s) failed."
  err "Detailed logs:  journalctl -u zitadel-provision -e"
  exit 1
fi
ok "All verification checks passed."

## ─── 6. Next steps ────────────────────────────────────────────────────
admin_user=$(cat /var/lib/homefree-admin/admin-username 2>/dev/null || echo "<adminUsername>")
domain=$(awk -F'"' '/system\.domain/ {print $2; exit}' \
           /etc/nixos/homefree-configuration.nix 2>/dev/null \
         || echo "<your-domain>")

step "Next steps"
cat <<EOF

1. Try logging into Zitadel directly:

     ${C_BOLD}https://sso.${domain}${C_RESET}

   Username: ${C_BOLD}${admin_user}${C_RESET}    (no @zitadel.${domain} suffix)
   Password: (the one you just entered)

2. Visit the admin UI in a fresh browser (private window — old
   sessions will skip the SSO redirect):

     ${C_BOLD}https://admin.${domain}${C_RESET}

   You should see a 302 → auth.${domain}/oauth2/start → SSO login.
   No second rebuild needed — Caddy's request-time \`file\` matcher
   on the sentinel turned the gate on the moment provisioning
   touched it.

Live logs:
  journalctl -u zitadel-provision -e
  journalctl -u podman-zitadel -e
  journalctl -u podman-oauth2-proxy -e
  journalctl -t zitadel-pam-sync -e   (after running 'passwd' as ${admin_user})
EOF
