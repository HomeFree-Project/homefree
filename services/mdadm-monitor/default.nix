{ config, lib, pkgs, ... }:
## Wire upstream mdadm `mdmonitor.service` to ntfy.
##
## Background: nixpkgs's `boot.swraid` module ships
## `mdmonitor.service` straight from upstream mdadm. The service
## runs `mdadm --monitor --scan`, which exits 1 immediately unless
## `/etc/mdadm.conf` carries either `MAILADDR` or `PROGRAM`. Without
## either, mdmonitor fails on every boot AND every rebuild — and the
## box has had a silent gap for md array events (drive fail, array
## degraded, rebuild lifecycle) on every parity pool since the
## RAID6 was created.
##
## Fix: populate `boot.swraid.mdadmConf` with a `PROGRAM=` line
## pointing at a small script that POSTs to the same ntfy topic the
## homefree alerts engine uses (`/var/lib/homefree-secrets/ntfy/topic`,
## anchored via the standard secrets module). Same delivery path,
## same paired phone, same topic-as-bearer security model — and
## no separate alert source/channel to wire through the engine,
## because mdmonitor itself is the source.
##
## Why not ARRAY lines: array assembly already works via mdadm's
## homehost feature + NixOS's udev rules, with no /etc/mdadm.conf
## entries needed (see `modules/storage-pools.nix` comment near
## `boot.swraid.enable`). We are filling the monitor-config gap
## only, not adopting full mdadm.conf management.
##
## Event → priority mapping (per mdadm(8)):
##   Fail, FailSpare, DegradedArray, DeviceDisappeared
##                                                  → priority high
##   SpareActive, SparesMissing, RebuildStarted,
##   RebuildFinished, MoveSpare, NewArray           → priority default
##   Rebuild20/40/60/80 (progress ticks)            → priority low
##
## If ntfy is disabled (no topic file present) the script silently
## no-ops with exit 0, so mdmonitor still runs cleanly on boxes that
## haven't enabled ntfy — they just don't get pushes. The same
## mdadm.conf is harmless on those boxes.
let
  eventScript = pkgs.writeShellScript "homefree-mdadm-event" ''
    set -u

    EVENT="''${1:-}"
    ARRAY="''${2:-}"
    DEVICE="''${3:-}"

    TOPIC_FILE=/var/lib/homefree-secrets/ntfy/topic
    if [ ! -r "$TOPIC_FILE" ]; then
      exit 0
    fi
    TOPIC=$(${pkgs.coreutils}/bin/cat "$TOPIC_FILE")
    if [ -z "$TOPIC" ]; then
      exit 0
    fi

    case "$EVENT" in
      Fail|FailSpare|DegradedArray|DeviceDisappeared)
        PRIORITY=high
        TAGS=rotating_light,floppy_disk
        ;;
      SpareActive|SparesMissing|RebuildStarted|RebuildFinished|MoveSpare|NewArray)
        PRIORITY=default
        TAGS=white_check_mark,floppy_disk
        ;;
      Rebuild*)
        PRIORITY=low
        TAGS=arrows_counterclockwise,floppy_disk
        ;;
      *)
        PRIORITY=default
        TAGS=floppy_disk
        ;;
    esac

    TITLE="md $EVENT on $ARRAY"
    if [ -n "$DEVICE" ]; then
      BODY="$EVENT on $ARRAY (device $DEVICE)"
    else
      BODY="$EVENT on $ARRAY"
    fi

    ## ntfy POST. Localhost-only — short timeout, errors swallowed
    ## so a wedged ntfy can't cause mdmonitor to think an event
    ## failed delivery (mdadm would log "PROGRAM failed" and that
    ## noise is worse than the missed push).
    ${pkgs.curl}/bin/curl --silent --show-error --fail \
      --max-time 10 \
      -H "Title: $TITLE" \
      -H "Priority: $PRIORITY" \
      -H "Tags: $TAGS" \
      --data-binary "$BODY" \
      "http://127.0.0.1:2586/$TOPIC" >/dev/null 2>&1 || true
  '';
in
{
  config = lib.mkIf config.boot.swraid.enable {
    ## Single `PROGRAM` line — no ARRAY entries (assembly is via
    ## homehost + udev, see `modules/storage-pools.nix`). Setting
    ## `boot.swraid.mdadmConf` replaces the empty default that
    ## nixpkgs ships at /etc/mdadm.conf.
    ##
    ## mdadm.conf is space-separated, NOT `KEY=value`. Writing
    ## `PROGRAM=/path` makes mdadm tokenise the whole thing as one
    ## unknown keyword and exit with "Unknown keyword PROGRAM=/...".
    boot.swraid.mdadmConf = ''
      PROGRAM ${eventScript}
    '';
  };
}
