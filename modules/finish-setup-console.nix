## Finish-setup console TUI + MOTD.
##
## A freshly-installed HomeFree box boots to a plain text console with no
## indication that post-install setup is unfinished or where the finish-setup
## wizard lives. This module adds two console-side discovery aids, both active
## only while setup is pending (gated on the `.setup-complete` sentinel from
## modules/setup-state.nix):
##
##  1. A live status screen on tty1 — shows the LAN interface link state, the
##     address to open, and a keybind to disable the captive-portal redirect.
##     This is the diagnostic layer: if the LAN cable is unplugged or in the
##     wrong port, the screen says so, which a static message cannot.
##
##  2. A login-prompt MOTD backstop — for a user who logs in at the console
##     rather than watching the status screen.
##
## The status screen replaces getty on tty1 while setup is pending. Once
## `.setup-complete` exists it exits and tty1 returns to a normal login.
{ config, lib, pkgs, ... }:

let
  cfg = config.homefree;
  lanInterface = cfg.network.lan-interface;
  lanAddress = cfg.network.lan-address;
  wizardHost = "admin.${cfg.system.localDomain}";

  completeSentinel = "/var/lib/homefree-secrets/.setup-complete";
  portalDisabledSentinel = "/var/lib/homefree-secrets/.setup-portal-disabled";

  ## Live status screen. Plain ANSI (no whiptail) so it re-renders cleanly on
  ## a timer and has no extra dependency. Reads link state straight from
  ## sysfs — the same signal NetworkService._has_carrier uses.
  ##
  ## ANSI escapes: a literal ESC byte is captured once into $ESC via
  ## printf — Nix double-quoted strings do not interpret `\033`, and a
  ## heredoc would print it literally, so we build the sequences explicitly.
  ## Redraw moves the cursor home and clears each line rather than running a
  ## full-screen `clear`, which avoids the visible flash on every refresh.
  consoleScript = pkgs.writeShellScript "homefree-finish-setup-console" ''
    set -u
    PATH=${lib.makeBinPath (with pkgs; [ coreutils gawk iproute2 ncurses ])}:$PATH

    carrier_file=/sys/class/net/${lanInterface}/carrier
    operstate_file=/sys/class/net/${lanInterface}/operstate

    ESC=$(printf '\033')
    bold="$ESC[1m"
    reset="$ESC[0m"
    home="$ESC[H"          # cursor to top-left
    clr_eos="$ESC[J"       # clear from cursor to end of screen
    hide_cursor="$ESC[?25l"
    show_cursor="$ESC[?25h"

    cleanup() { printf '%s' "$show_cursor"; }
    trap cleanup EXIT INT TERM

    ## Clear once on entry; subsequent redraws overwrite in place.
    printf '%s%s%s' "$hide_cursor" "$ESC[2J" "$home"

    while true; do
      ## Setup finished elsewhere (wizard + rebuild) — hand tty1 back.
      if [ -f ${completeSentinel} ]; then
        exit 0
      fi

      ## LAN link state.
      link="down"
      if [ -r "$carrier_file" ] && [ "$(cat "$carrier_file" 2>/dev/null)" = "1" ]; then
        link="LINKED"
      elif [ -r "$operstate_file" ]; then
        link="$(cat "$operstate_file" 2>/dev/null || echo down)"
      fi

      ## LAN IPv4 actually assigned to the interface.
      lan_ip="$(ip -4 -o addr show dev ${lanInterface} 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 | head -n1)"
      [ -z "$lan_ip" ] && lan_ip="(none yet - configured: ${lanAddress})"

      override="off"
      [ -f ${portalDisabledSentinel} ] && override="ON (LAN browsing allowed)"

      ## Redraw in place: home the cursor, print, then clear any leftover
      ## lines below. printf interprets the $ESC sequences in the variables.
      printf '%s' "$home"
      printf '%s\n' "" \
        "  ''${bold}HomeFree - finish setup''${reset}" \
        "  -----------------------------------------------" \
        "" \
        "  Setup is NOT finished. Complete it from a browser" \
        "  on another device connected to the LAN port." \
        "" \
        "    LAN port (${lanInterface}):  $link" \
        "    LAN address:               $lan_ip" \
        "" \
        "    Open:   ''${bold}http://${wizardHost}/''${reset}" \
        "            http://$lan_ip/   (if the name fails)" \
        "" \
        "    Setup redirect override: $override" \
        "" \
        "  Connect a laptop or phone to the LAN port and open" \
        "  the address above. Most devices will offer a" \
        '  "Sign in to network" prompt automatically.' \
        "" \
        "  -----------------------------------------------" \
        "  Press ''${bold}d''${reset} to disable the setup redirect (lets LAN" \
        "  devices browse the internet before you finish)." \
        "  This screen refreshes automatically." \
        ""
      printf '%s' "$clr_eos"

      ## Wait up to 5s for a keypress, then refresh.
      ## Caddy's portal matcher checks the sentinel at request time, so
      ## dropping the file takes effect on the next request - no reload.
      if read -r -n1 -t5 key 2>/dev/null; then
        if [ "$key" = "d" ] || [ "$key" = "D" ]; then
          mkdir -p /var/lib/homefree-secrets 2>/dev/null || true
          touch ${portalDisabledSentinel} 2>/dev/null || true
        fi
      fi
    done
  '';
in
{
  ## Run the status screen on tty1 while setup is pending. Conflicts with
  ## getty@tty1 — systemd's `Conflicts` stops getty so the screen owns the
  ## console; when this unit exits (setup complete), getty@tty1 comes back.
  systemd.services.homefree-finish-setup-console = {
    description = "HomeFree finish-setup console status screen (tty1)";
    after = [ "homefree-setup-state.service" ];
    wantedBy = [ "multi-user.target" ];
    conflicts = [ "getty@tty1.service" ];

    unitConfig = {
      ## Only take over the console while setup is genuinely pending.
      ConditionPathExists = "!${completeSentinel}";
    };

    serviceConfig = {
      ExecStart = "${consoleScript}";
      StandardInput = "tty";
      StandardOutput = "tty";
      TTYPath = "/dev/tty1";
      TTYReset = true;
      TTYVHangup = true;
      Restart = "no";
    };
  };

  ## MOTD backstop. Shown at the console login prompt. This is static text
  ## generated at build time — it cannot react to the sentinel live, so it
  ## may over-show on a finished box that hasn't rebuilt yet (harmless). The
  ## tty1 screen and captive portal are the live layers; this is the backstop.
  users.motd = ''

    ********************************************************
    *  HomeFree setup is NOT finished.                     *
    *                                                      *
    *  Open  http://${wizardHost}/
    *  (or   http://${lanAddress}/  if the name fails)
    *  from a device connected to the LAN port to finish.   *
    ********************************************************

  '';
}
