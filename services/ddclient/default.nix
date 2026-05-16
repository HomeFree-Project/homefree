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
    PATH=${lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.gnugrep ]}

    HETZNER_API="https://api.hetzner.cloud/v1"

    ## Resolve the box's current public addresses the same way
    ## ddclient does. If a lookup fails we skip that family rather
    ## than create a record with a bogus value — ddclient will still
    ## create nothing, but at least we don't publish garbage.
    wan4="$(curl -fsS --max-time 10 https://ipinfo.io/ip 2>/dev/null || true)"
    wan6="$(curl -fsS --max-time 10 https://v6.ipinfo.io/ip 2>/dev/null || true)"

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

      ## Existing rrset ids look like "<name>/<type>"; collect them so
      ## we only create what is genuinely missing.
      local existing
      existing="$(curl -fsS --max-time 15 \
        -H "Authorization: Bearer $token" \
        "$HETZNER_API/zones/$zone_id/rrsets" 2>/dev/null \
        | jq -r '.rrsets[] | "\(.name)/\(.type)"')"

      local name type value
      for name in "''${domains[@]}"; do
        ## A name that already resolves via CNAME must not also get an
        ## A/AAAA record — Hetzner rejects it ("(*, CNAME) conflicts
        ## with (*, A)") and the CNAME already does the job (and never
        ## needs IP updates). Skip the whole name in that case.
        if printf '%s\n' "$existing" | grep -qxF "$name/CNAME"; then
          echo "ddclient-bootstrap: $name in $zone_name is a CNAME, skipping" >&2
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
