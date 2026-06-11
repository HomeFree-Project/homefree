{ config, lib, pkgs, ... }:
let
  cfg = config.homefree.dns.remote.dynamic-dns;

  ## Zones we can bootstrap. ddclient is an *updater* — it only ever
  ## PUTs to records that already exist. Hetzner returns 422
  ## ("can't update records with this endpoint") when ddclient tries
  ## to update a name that was never created, so a freshly-added zone
  ## fails on every run until someone hand-creates the records in the
  ## Hetzner console. That breaks the low-touch promise: adding a
  ## domain in the admin UI should Just Work.
  ##
  ## This bootstrap covers the gap. For each enabled `hetzner` zone it
  ## ensures every configured `domains` entry has an A rrset (and an
  ## AAAA rrset when IPv6 updates are enabled), creating any that are
  ## missing via the Hetzner POST endpoint. It never modifies an
  ## existing rrset — ddclient owns the IP from then on.
  bootstrapZones = lib.filter
    (zone: zone.disable == false && zone.protocol == "hetzner")
    cfg.zones;

  ## IPv6 is bootstrapped only when ddclient itself is configured to
  ## update v6 (a non-empty usev6). Otherwise we'd create AAAA records
  ## nothing keeps current.
  bootstrapIpv6 = cfg.usev6 != "";

  bootstrapScript = pkgs.writeShellScript "ddclient-bootstrap-rrsets" ''
    set -u
    ## gnugrep is required — the rrset-existence checks below use
    ## `grep -qxF`. Omitting it made every check fail with "grep: command
    ## not found", so the script could neither detect existing records
    ## nor reliably create missing ones.
    PATH=${lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.gnugrep pkgs.gawk ]}

    HETZNER_API="https://api.hetzner.cloud/v1"

    ## The live config ddclient is about to run. ddclient-multi writes it
    ## here in its preStart, which is ordered before this bootstrap in the
    ## ddclient-multi ExecStartPre chain, so the file already exists on the
    ## timer/manual-start path. (The standalone bootstrap unit has no such
    ## file; strip_host_from_conf below is a no-op there.)
    DDCLIENT_CONF="/run/ddclient/ddclient.conf"

    ## ddclient's state cache (matches `cache=` in ddclient-multi.nix). We
    ## clear this below if a published record has drifted from the current
    ## WAN IP — see the cache_stale logic.
    DDCLIENT_CACHE="/var/lib/ddclient/ddclient.cache"

    ## Drop a host from ddclient.conf's comma-separated host list. ddclient
    ## is an A/AAAA updater; a name that already exists as a CNAME must not
    ## be handed to it, or every run PATCHes it and Hetzner answers 422
    ## ("(*, CNAME) conflicts with (*, A)"). The bootstrap already skips
    ## *creating* A/AAAA for CNAME names; this keeps ddclient itself from
    ## *updating* them, so the two stay consistent and the log stays clean.
    ## The CNAME already follows whatever it points at, so it needs no IP
    ## updates. Only the line where the FQDN appears as an exact comma field
    ## is touched, so config lines that merely contain commas (e.g. usev4)
    ## are left alone.
    strip_host_from_conf() {
      local fqdn="$1" tmp
      [ -f "$DDCLIENT_CONF" ] || return 0
      tmp="$(mktemp)" || return 0
      awk -v target="$fqdn" '
        {
          n = split($0, f, ",")
          hit = 0
          for (i = 1; i <= n; i++) if (f[i] == target) hit = 1
          if (!hit) { print; next }
          out = ""; cnt = 0
          for (i = 1; i <= n; i++) {
            if (f[i] == target) continue
            out = (cnt ? out "," f[i] : f[i]); cnt++
          }
          if (cnt > 0) print out   # else drop the now-empty host line
        }
      ' "$DDCLIENT_CONF" > "$tmp" && cat "$tmp" > "$DDCLIENT_CONF"
      rm -f "$tmp"
      echo "ddclient-bootstrap: removed CNAME $fqdn from ddclient host list" >&2
    }

    ## Resolve the box's current public addresses the same way
    ## ddclient does. If a lookup fails we skip that family rather
    ## than create a record with a bogus value — ddclient will still
    ## create nothing, but at least we don't publish garbage.
    wan4="$(curl -fsS --max-time 10 https://ipinfo.io/ip 2>/dev/null || true)"
    wan6="$(curl -fsS --max-time 10 https://v6.ipinfo.io/ip 2>/dev/null || true)"

    ## Set to 1 by bootstrap_zone when it finds a managed record whose
    ## published value no longer matches the box's WAN IP. Drives the
    ## one-shot cache clear at the end of the script.
    cache_stale=0

    ## ── per-zone bootstrap ────────────────────────────────────────
    bootstrap_zone() {
      local zone_name="$1" password_file="$2"
      shift 2
      local domains=( "$@" )

      if [ ! -s "$password_file" ]; then
        echo "ddclient-bootstrap: no token at $password_file for $zone_name, skipping" >&2
        return 0
      fi
      local token
      token="$(tr -d '\n' < "$password_file")"

      ## Look up the zone id by name.
      local zone_id
      zone_id="$(curl -fsS --max-time 15 \
        -H "Authorization: Bearer $token" \
        "$HETZNER_API/zones?name=$zone_name" 2>/dev/null \
        | jq -r '.zones[0].id // empty')"
      if [ -z "$zone_id" ]; then
        echo "ddclient-bootstrap: zone $zone_name not found for this token, skipping" >&2
        return 0
      fi

      ## Fetch the zone's rrsets once. `existing` is the set of
      ## "<name>/<type>" ids (so we only create what is genuinely
      ## missing); `existing_values` pairs each id with every value it
      ## currently holds (so we can tell when a record has drifted away
      ## from the box's current WAN IP).
      local rrsets_json existing existing_values
      rrsets_json="$(curl -fsS --max-time 15 \
        -H "Authorization: Bearer $token" \
        "$HETZNER_API/zones/$zone_id/rrsets" 2>/dev/null)"
      existing="$(printf '%s' "$rrsets_json" | jq -r '.rrsets[] | "\(.name)/\(.type)"')"
      existing_values="$(printf '%s' "$rrsets_json" \
        | jq -r '.rrsets[] | .name as $n | .type as $t | .records[] | "\($n)/\($t)\t\(.value)"')"

      local name type value
      for name in "''${domains[@]}"; do
        ## A name that already resolves via CNAME must not also get an
        ## A/AAAA record — Hetzner rejects it ("(*, CNAME) conflicts
        ## with (*, A)") and the CNAME already does the job (and never
        ## needs IP updates). Skip the whole name in that case.
        if printf '%s\n' "$existing" | grep -qxF "$name/CNAME"; then
          echo "ddclient-bootstrap: $name in $zone_name is a CNAME, skipping" >&2
          if [ "$name" = "@" ]; then
            strip_host_from_conf "$zone_name"
          else
            strip_host_from_conf "$name.$zone_name"
          fi
          continue
        fi
        for type in A AAAA; do
          if [ "$type" = "A" ]; then
            value="$wan4"
          else
            ${lib.optionalString (!bootstrapIpv6) ''continue''}
            value="$wan6"
          fi
          [ -z "$value" ] && continue
          if printf '%s\n' "$existing" | grep -qxF "$name/$type"; then
            ## The record exists, so the bootstrap leaves it alone —
            ## ddclient owns the IP from here. But if its published value
            ## no longer matches the box's current WAN IP, ddclient's cache
            ## may have desynced: it believes it already pushed the new IP
            ## and "skips update because ... already set" on every run,
            ## leaving the public record stale indefinitely (the failure
            ## mode the historical apex-write bug left behind; a manual
            ## edit in the Hetzner console does the same). Flag it so the
            ## cache is cleared below, forcing ddclient to re-push.
            if ! printf '%s\n' "$existing_values" \
                 | awk -F'\t' -v k="$name/$type" -v v="$value" \
                       '$1 == k && $2 == v { ok = 1 } END { exit !ok }'; then
              echo "ddclient-bootstrap: $name/$type in $zone_name does not match current WAN ($value) — will clear ddclient cache to force a re-push" >&2
              cache_stale=1
            fi
            continue
          fi
          echo "ddclient-bootstrap: creating $name/$type in $zone_name" >&2
          curl -fsS --max-time 15 -X POST \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            "$HETZNER_API/zones/$zone_id/rrsets" \
            -d "$(jq -nc --arg n "$name" --arg t "$type" --arg v "$value" \
                  '{name:$n, type:$t, ttl:60, records:[{value:$v}]}')" \
            >/dev/null 2>&1 \
            || echo "ddclient-bootstrap: failed to create $name/$type in $zone_name" >&2
        done
      done
    }

    ${lib.concatMapStringsSep "\n"
      (zone: ''
        bootstrap_zone ${lib.escapeShellArg zone.zone} \
          ${lib.escapeShellArg (toString zone.passwordFile)} \
          ${lib.escapeShellArgs zone.domains}
      '')
      bootstrapZones}

    ## If any managed record drifted from the current WAN IP, drop
    ## ddclient's cache so the ExecStart that follows this ExecStartPre
    ## re-evaluates against the live API and pushes the correct value,
    ## instead of short-circuiting on a stale "already set" cache entry.
    ## Only fires on real drift, so steady-state runs keep the cache (and
    ## ddclient's skip optimisation) intact.
    if [ "''${cache_stale:-0}" = 1 ] && [ -f "$DDCLIENT_CACHE" ]; then
      echo "ddclient-bootstrap: published records drifted from the current WAN IP; clearing stale ddclient cache $DDCLIENT_CACHE" >&2
      rm -f "$DDCLIENT_CACHE"
    fi

    exit 0
  '';
in
{
  nixpkgs.overlays = [
    (import ../../overlays/ddclient-hetzner-cloud.nix)
  ];
  #-----------------------------------------------------------------------------------------------------
  # Dynamic DNS
  #-----------------------------------------------------------------------------------------------------

  services.ddclient-multi = {
    enable = true;
    interval = cfg.interval;
    usev4 = cfg.usev4;
    usev6 = cfg.usev6;
    verbose = true;
    zones = lib.map (zone: {
      protocol = zone.protocol;
      username = zone.username;
      zone = zone.zone;
      domains = zone.domains;
      passwordFile = toString zone.passwordFile;
    }) cfg.zones;
  };

  ## Ensure the rrsets ddclient expects actually exist before it runs.
  ## Wired both as a standalone unit ordered Before ddclient-multi and
  ## as an ExecStartPre on ddclient-multi itself (belt-and-suspenders,
  ## per the oneshot-bootstrap pattern): the standalone unit covers the
  ## timer path, the ExecStartPre covers manual `systemctl start`.
  systemd.services.ddclient-bootstrap-rrsets = lib.mkIf (bootstrapZones != []) {
    description = "Create missing DNS rrsets for ddclient zones";
    before = [ "ddclient-multi.service" ];
    wantedBy = [ "ddclient-multi.service" ];
    after = [ "network-online.target" "dns-ready.service" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = bootstrapScript;
    };
  };

  systemd.services.ddclient-multi = lib.mkIf (bootstrapZones != []) {
    serviceConfig.ExecStartPre = [ "!${bootstrapScript}" ];
  };
}
