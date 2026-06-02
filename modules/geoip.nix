## Local GeoIP database, kept fresh on a timer.
##
## Downloads the DB-IP "IP to City Lite" database — a MaxMind-DB-format
## (.mmdb) file, free, CC-BY-4.0 licensed, no account or API key
## required. Published monthly at a predictable URL. We keep a single
## decompressed copy at /var/lib/geoip/dbip-city-lite.mmdb that the
## admin-api's abuse-blocking resolver reads to annotate traffic
## sources with country/city.
##
## Why a local DB rather than a geolocation API: per-IP API calls add
## a network round-trip (tens to hundreds of ms each) to every poll of
## the Abuse Blocking page. A local mmdb lookup is microseconds — the
## enrichment is effectively free once the file is on disk.
##
## ATTRIBUTION: DB-IP's free tier is CC-BY-4.0. Any page that displays
## results derived from it must link back to db-ip.com. The admin UI
## Abuse Blocking page carries that link — see
## abuse-blocking-module.js.
##
## Failure handling: the updater keeps the last good file if a fetch
## fails (network down, URL not yet published for the new month). The
## resolver degrades gracefully to "—" if the file is entirely
## absent, so a fresh install before the first successful fetch is
## not a hard error.
{ config, lib, pkgs, ... }:

let
  geoipDir = "/var/lib/geoip";
  dbPath = "${geoipDir}/dbip-city-lite.mmdb";

  ## The updater. Tries the current month's file first; if that 404s
  ## (DB-IP sometimes publishes a few days into the month), falls
  ## back to the previous month. Only replaces the live file on a
  ## fully successful download + decompress, so a partial transfer
  ## can't leave a corrupt mmdb in place.
  updateScript = pkgs.writeShellScript "geoip-update" ''
    set -euo pipefail

    DEST="${dbPath}"
    TMP="$(${pkgs.coreutils}/bin/mktemp -d)"
    trap '${pkgs.coreutils}/bin/rm -rf "$TMP"' EXIT

    ## Build the two candidate URLs: current month, then previous.
    CUR=$(${pkgs.coreutils}/bin/date -u +%Y-%m)
    PREV=$(${pkgs.coreutils}/bin/date -u -d 'last month' +%Y-%m)
    BASE="https://download.db-ip.com/free"

    fetched=""
    for ym in "$CUR" "$PREV"; do
      url="$BASE/dbip-city-lite-$ym.mmdb.gz"
      echo "geoip-update: trying $url"
      if ${pkgs.curl}/bin/curl -fsSL --max-time 30 -o "$TMP/db.mmdb.gz" "$url"; then
        fetched="$ym"
        break
      fi
      echo "geoip-update: $url not available"
    done

    if [ -z "$fetched" ]; then
      if [ -s "$DEST" ]; then
        echo "geoip-update: no new database available; keeping existing $DEST" >&2
        exit 0
      fi
      echo "geoip-update: no database available and no existing copy — giving up" >&2
      exit 1
    fi

    ${pkgs.gzip}/bin/gzip -dc "$TMP/db.mmdb.gz" > "$TMP/db.mmdb"

    ## Sanity check: a valid mmdb is well over 1 MB (the City Lite
    ## file is ~125 MB). Refuse anything implausibly small rather
    ## than clobber a good DB with a courtesy error page.
    size=$(${pkgs.coreutils}/bin/stat -c%s "$TMP/db.mmdb")
    if [ "$size" -lt 1048576 ]; then
      echo "geoip-update: downloaded file is only $size bytes — refusing to install" >&2
      [ -s "$DEST" ] && exit 0 || exit 1
    fi

    ${pkgs.coreutils}/bin/install -D -m 0644 "$TMP/db.mmdb" "$DEST"
    echo "geoip-update: installed $fetched database ($size bytes) at $DEST"
  '';
in
## Gated on homefree.network.geoip.enable (default true). When
## disabled, neither the updater nor the timer exist — the server
## never contacts db-ip.com — and the admin-api's resolver degrades
## to null country/city (the UI drops the Location column).
lib.mkIf config.homefree.network.geoip.enable {
  ## State dir, world-readable so the admin-api (running as root
  ## anyway, but future-proof) and any other consumer can open the
  ## mmdb. The file itself is 0644.
  systemd.tmpfiles.rules = [
    "d ${geoipDir} 0755 root root - -"
  ];

  systemd.services.geoip-update = {
    description = "Update the local DB-IP GeoIP database";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    ## Run once at activation so a fresh system gets a DB without
    ## waiting for the first timer tick. Idempotent — re-running just
    ## re-fetches the current month.
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = updateScript;
      ## Hard cap: two curl attempts at --max-time 30 plus gzip/install
      ## fits well under 90s. If the unit isn't done by then, DB-IP is
      ## down — fail the unit so multi-user.target stops waiting and
      ## the rebuild moves on. The weekly timer will retry.
      TimeoutStartSec = "90s";
    };
  };

  systemd.timers.geoip-update = {
    description = "Weekly refresh of the local DB-IP GeoIP database";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      ## DB-IP publishes monthly; weekly is plenty and means a
      ## fresh install / missed window self-heals within 7 days.
      OnCalendar = "weekly";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };
}
