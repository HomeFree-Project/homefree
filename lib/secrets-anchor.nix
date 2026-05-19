## ─── Anchor auto-generated secrets into /etc/nixos/secrets ──────────
##
## PROBLEM. Several services generate a secret at first boot (a
## masterkey, a cookie secret, a DB password) directly into
## `/var/lib/homefree-secrets/<svc>/<key>`. That directory is NOT part
## of the backup set — only `/etc/nixos` is. So on a restore to fresh
## hardware the generator runs again and produces a NEW value. For a
## value that encrypts persistent data (Zitadel's masterkey, Matrix's
## signing key, Forgejo's secret-key) that is catastrophic: the
## backed-up database can no longer be decrypted.
##
## The intended design is that EVERY secret lives encrypted in
## `/etc/nixos/secrets/secrets.yaml` (sops, backed up with /etc/nixos)
## and is decrypted to `/var/lib/homefree-secrets` at boot. This helper
## makes a runtime-generated secret obey that design.
##
## MECHANISM. For each secret, on every boot:
##   1. If `<svc>/<key>` is present in the encrypted secrets.yaml,
##      decrypt it and write the runtime copy. The anchored copy is
##      authoritative — this is what makes a restore re-materialize
##      the ORIGINAL value.
##   2. Else, if a runtime copy already exists on disk (a box that
##      generated the secret before this helper existed), adopt that
##      value: anchor it into secrets.yaml so it survives the next
##      restore. No new value is generated.
##   3. Else, generate a fresh value with the caller's command, anchor
##      it, and write the runtime copy.
##
## Encryption uses the system SSH host key (ed25519) converted to age —
## the SAME key sops-nix already uses to DECRYPT secrets.yaml
## (profiles/secrets.nix). The host key always exists at activation
## time, so this works on a headless fresh-rebuild box with no user
## SSH key configured. When secrets.yaml already exists, the secret is
## (re)encrypted to whatever recipient set the file already uses, so a
## user-managed recipient added later by the admin UI is preserved.
##
## USAGE — from a service module's activation script / oneshot, with
## `lib` and `pkgs` in scope:
##
##   anchor = import ../../lib/secrets-anchor.nix { inherit lib pkgs; };
##   ...
##   script = ''
##     ${anchor.preamble}
##     ${anchor.anchorSecret {
##         service = "zitadel";
##         key     = "masterkey";
##         dir     = "/var/lib/homefree-secrets/zitadel";
##         mode    = "600";
##         generate = "${pkgs.openssl}/bin/openssl rand -hex 16";
##         onGenerate = ''echo "generated a fresh zitadel masterkey"'';
##       }}
##   '';
##
## `generate` is a shell command whose stdout is the secret value
## (trailing newline is stripped). `onGenerate` (optional) is shell run
## ONLY on a genuinely-fresh generation — use it for a journal banner.
## After the snippet runs, `$ANCHOR_SECRET_FILE` holds the runtime
## file path and `$ANCHOR_SECRET_FRESH` is `1` iff freshly generated.

{ lib, pkgs }:

let
  secretsFile = "/etc/nixos/secrets/secrets.yaml";
  sopsConfig = "/etc/nixos/.sops.yaml";
  hostKey = "/etc/ssh/ssh_host_ed25519_key";

  ## Shell helpers sourced once per script. Defines:
  ##   _anchor_age_recipients   -> echoes the comma-separated age
  ##                               recipient set to encrypt with
  ##   _anchor_get <svc/key>    -> echoes the decrypted value, or
  ##                               nothing (exit 1) if absent
  ##   _anchor_set <svc/key> <value-file>
  ##                            -> sets the key in secrets.yaml
  preamble = ''
    set -eu

    _ANCHOR_SOPS=${pkgs.sops}/bin/sops
    _ANCHOR_SSH_TO_AGE=${pkgs.ssh-to-age}/bin/ssh-to-age
    _ANCHOR_SECRETS_FILE=${secretsFile}
    _ANCHOR_SOPS_CONFIG=${sopsConfig}
    _ANCHOR_HOST_KEY=${hostKey}
    _ANCHOR_LOCK=${secretsFile}.anchor-lock

    ## CONCURRENCY. secrets.yaml is a single shared file, and many
    ## services' prepare-secrets units run in parallel at boot. Every
    ## anchor operation is a read-modify-write of the WHOLE file
    ## (`sops --set` rewrites it); `sops` does no locking, so two
    ## concurrent writers interleave and corrupt the file. We serialise
    ## the entire check-and-anchor critical section for one secret
    ## under a single exclusive flock — held across the get AND the
    ## set, so two units cannot both decide a key is absent and both
    ## create/overwrite the file. `_anchor_locked CMD...` runs CMD with
    ## the lock held; the lock auto-releases when the subshell exits.
    _anchor_locked() {
      ## The lock file lives beside secrets.yaml; ensure its directory
      ## exists first (a fresh box may not have /etc/nixos/secrets yet).
      mkdir -p "$(dirname "$_ANCHOR_LOCK")"
      chmod 700 "$(dirname "$_ANCHOR_LOCK")"
      ( ${pkgs.util-linux}/bin/flock 9
        "$@"
      ) 9>"$_ANCHOR_LOCK"
    }

    ## Age private key derived from the SSH host key — sops reads this
    ## from SOPS_AGE_KEY for both decrypt and --set.
    _anchor_export_age_key() {
      SOPS_AGE_KEY=$(${pkgs.ssh-to-age}/bin/ssh-to-age -private-key \
        -i "$_ANCHOR_HOST_KEY")
      export SOPS_AGE_KEY
    }

    ## Recipients to encrypt to. If secrets.yaml already exists we must
    ## keep whatever recipients it already uses (the user's key may
    ## have been folded in by the admin UI) — sops --set preserves the
    ## file's existing recipients automatically, so this is only used
    ## when CREATING the file: the system host key alone. A user key
    ## added later is merged in by SecretsManager.add_user_authorized_key.
    _anchor_system_recipient() {
      ${pkgs.ssh-to-age}/bin/ssh-to-age -i "$_ANCHOR_HOST_KEY.pub"
    }

    ## Echo the decrypted value for sops key $1 ("svc/key"); exit 1 if
    ## the file or key is absent.
    _anchor_get() {
      [ -s "$_ANCHOR_SECRETS_FILE" ] || return 1
      _anchor_export_age_key
      ## --extract pulls a single key; missing key => non-zero exit.
      $_ANCHOR_SOPS --decrypt --extract "[\"$1\"]" \
        "$_ANCHOR_SECRETS_FILE" 2>/dev/null
    }

    ## Set sops key $1 ("svc/key") to the contents of file $2.
    _anchor_set() {
      _anchor_export_age_key
      local _val
      _val=$(cat "$2")
      ## Create the encrypted file if it does not exist yet, with the
      ## system host key as the sole recipient.
      if [ ! -s "$_ANCHOR_SECRETS_FILE" ]; then
        mkdir -p "$(dirname "$_ANCHOR_SECRETS_FILE")"
        chmod 700 "$(dirname "$_ANCHOR_SECRETS_FILE")"
        local _rcpt
        _rcpt=$(_anchor_system_recipient)
        printf '{}' > "$_ANCHOR_SECRETS_FILE.plain"
        $_ANCHOR_SOPS --age "$_rcpt" --encrypt \
          --input-type yaml --output-type yaml \
          --output "$_ANCHOR_SECRETS_FILE" "$_ANCHOR_SECRETS_FILE.plain"
        rm -f "$_ANCHOR_SECRETS_FILE.plain"
      fi
      ## sops --set takes two JSON tokens (path, value). Both are built
      ## with a tiny here-doc through jq so any quote/newline/backslash
      ## in the value round-trips cleanly.
      local _path _json
      _path=$(${pkgs.jq}/bin/jq -nc --arg k "$1" '[$k]')
      _json=$(${pkgs.jq}/bin/jq -nc --arg v "$_val" '$v')
      $_ANCHOR_SOPS --set "$_path $_json" "$_ANCHOR_SECRETS_FILE"
    }
  '';

  ## Generate the per-secret snippet. See file header for argument docs.
  ##
  ## `service` / `key` form the sops key `service/key` in secrets.yaml.
  ## `dir`      directory the runtime copy is written into.
  ## `fileName` (default `key`) runtime filename, when it must differ
  ##            from the sops key — e.g. a sops key `wgSecretKey` whose
  ##            on-disk file is historically `wg-secret-key`.
  ## `mkdirMode` (default "700") mode for `dir` on creation. Set null
  ##            to NOT create/chmod `dir` — required when `dir` is a
  ##            shared service data dir whose mode/owner is managed
  ##            elsewhere (e.g. /var/lib/netbird).
  ## `generate` shell command whose stdout is the secret value.
  ## `onGenerate` shell run only on a genuinely-fresh generation.
  ## `extraInstall` shell run after the runtime copy exists, with
  ##            `$ANCHOR_SECRET_FILE` pointing at it — use to also copy
  ##            the secret to a second location (e.g. a container's
  ##            expected path) on every boot.
  ## `adoptExisting` (default true): on a pre-helper box that already
  ## has the secret on disk but not in secrets.yaml, copy the on-disk
  ## value into the encrypted store. Set false for a secret whose
  ## on-disk file goes STALE after first use (e.g. Zitadel's
  ## admin-password — Zitadel doesn't sync password changes back to
  ## disk). With false such a secret is anchored ONLY when freshly
  ## generated, so the encrypted store never holds a known-stale value.
  anchorSecret =
    { service
    , key
    , dir
    , fileName ? key
    , mkdirMode ? "700"
    , mode ? "600"
    , generate
    , onGenerate ? ""
    , extraInstall ? ""
    , adoptExisting ? true
    }:
    let
      sopsKey = "${service}/${key}";
      runtimeFile = "${dir}/${fileName}";
    in ''
      ## ── anchor: ${sopsKey} ──────────────────────────────────────
      ${lib.optionalString (mkdirMode != null) ''
      mkdir -p ${dir}
      chmod ${mkdirMode} ${dir}
      ''}
      ANCHOR_SECRET_FILE=${runtimeFile}
      ANCHOR_SECRET_FRESH=0

      ## The check-and-anchor critical section for this one secret.
      ## Runs under _anchor_locked (exclusive flock) because it does a
      ## read-modify-write of the shared secrets.yaml — concurrent
      ## prepare-secrets units would otherwise corrupt the file. Runs
      ## in a subshell, so it cannot export ANCHOR_SECRET_FRESH back;
      ## it signals "freshly generated" by writing the fresh-marker
      ## file, which the caller checks after the lock is released.
      _anchor_section_${service}_${lib.replaceStrings ["-" "."] ["_" "_"] key}() {
        _anchor_tmp=$(mktemp)
        _anchor_fresh_marker="$1"
        if _anchor_get "${sopsKey}" > "$_anchor_tmp" 2>/dev/null \
             && [ -s "$_anchor_tmp" ]; then
          ## (1) Anchored value exists — it is authoritative.
          ## Materialize the runtime copy from it (handles a restore).
          install -m ${mode} "$_anchor_tmp" "${runtimeFile}"
        elif [ -s "${runtimeFile}" ]; then
          ## (2) A pre-helper box generated this secret already.
          ${if adoptExisting then ''
          ## Adopt the on-disk value into the encrypted store so the
          ## NEXT restore keeps it. Do not generate anything new.
          _anchor_set "${sopsKey}" "${runtimeFile}"
          chmod ${mode} "${runtimeFile}"
          '' else ''
          ## adoptExisting=false: the on-disk file may be stale (the
          ## value can change at runtime without syncing back). Leave
          ## it as-is and do NOT anchor a possibly-wrong value. It is
          ## anchored only if/when it is next freshly generated.
          chmod ${mode} "${runtimeFile}"
          ''}
        else
          ## (3) Genuinely fresh — generate, anchor, materialize.
          ## `$(...)` strips all trailing newlines; printf re-emits the
          ## value with none, so the stored secret has no stray newline.
          printf '%s' "$( ${generate} )" > "$_anchor_tmp"
          _anchor_set "${sopsKey}" "$_anchor_tmp"
          install -m ${mode} "$_anchor_tmp" "${runtimeFile}"
          printf 1 > "$_anchor_fresh_marker"
        fi
        rm -f "$_anchor_tmp"
        chmod ${mode} "${runtimeFile}"
      }

      _anchor_fresh_marker=$(mktemp)
      _anchor_locked _anchor_section_${service}_${lib.replaceStrings ["-" "."] ["_" "_"] key} \
        "$_anchor_fresh_marker"
      [ -s "$_anchor_fresh_marker" ] && ANCHOR_SECRET_FRESH=1
      rm -f "$_anchor_fresh_marker"

      ${lib.optionalString (extraInstall != "") ''
      ## extraInstall — runs every boot with the runtime copy in place.
      ${extraInstall}
      ''}

      if [ "$ANCHOR_SECRET_FRESH" = "1" ]; then
        ${if onGenerate == "" then ":" else onGenerate}
      fi
    '';
in
{
  inherit preamble anchorSecret;
}
