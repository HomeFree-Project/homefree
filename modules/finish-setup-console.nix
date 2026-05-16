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
    green="$ESC[1;32m"     # redirect active (the normal, helpful state)
    yellow="$ESC[1;33m"    # redirect disabled (override engaged)
    home="$ESC[H"          # cursor to top-left
    clr_eos="$ESC[J"       # clear from cursor to end of screen
    clr_eol="$ESC[K"       # clear from cursor to end of line
    hide_cursor="$ESC[?25l"
    show_cursor="$ESC[?25h"

    cleanup() { printf '%s' "$show_cursor"; }
    ## EXIT always runs cleanup. INT/TERM must ALSO exit: a bare
    ## `trap cleanup TERM` runs the handler and then RESUMES the loop,
    ## so systemd's SIGTERM on stop was swallowed and the unit hung the
    ## full 90s TimeoutStopSec before SIGKILL — which made
    ## switch-to-configuration (and the whole rebuild) report failure.
    trap cleanup EXIT
    trap 'exit 0' INT TERM

    ## Full reset + clear on entry: wipes any boot-log text still on the
    ## console and resets scroll/attributes before the first draw. `tput
    ## reset` does the heavy lifting; the explicit clear/home guarantees a
    ## known cursor position. Subsequent redraws just overwrite in place.
    tput reset 2>/dev/null || true
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

      ## Captive-portal redirect status. The redirect only ever intercepts
      ## plain-HTTP requests (HTTPS sites load normally either way); when ON
      ## it bounces them to the wizard so a connected device finds it
      ## automatically. The override sentinel turns that bouncing off.
      if [ -f ${portalDisabledSentinel} ]; then
        redirect_state="''${yellow}OFF''${reset}"
        redirect_hint="HTTP requests are NOT being redirected to the wizard."
        key_action="re-enable"
      else
        redirect_state="''${green}ON''${reset}"
        redirect_hint="HTTP requests on the LAN are redirected to the wizard."
        key_action="disable"
      fi

      ## Redraw in place. Home the cursor, then print each line followed by
      ## ESC[K (clear to end of line) BEFORE the newline — so a line that got
      ## shorter since the last frame (e.g. the long "(none yet ...)"
      ## fallback being replaced by a short IP) doesn't leave stale tail
      ## characters behind. A final clear-to-end-of-screen mops up any lines
      ## removed from the bottom.
      printf '%s' "$home"
      while IFS= read -r line; do
        printf '%s%s\n' "$line" "$clr_eol"
      done <<EOF

  ''${bold}HomeFree - finish setup''${reset}
  -----------------------------------------------

  Setup is NOT finished. Complete it from a browser
  on another device connected to the LAN port.

    LAN port (${lanInterface}):  $link
    LAN address (detected):    $lan_ip

    Open:   ''${bold}http://${lanAddress}/''${reset}
            (or http://${wizardHost}/ )

    Setup redirect:  $redirect_state
    $redirect_hint

  Connect a laptop or phone to the LAN port and open
  the address above. Most devices will offer a
  "Sign in to network" prompt automatically.

  -----------------------------------------------
  Press ''${bold}d''${reset} to $key_action the setup redirect. Disable it if
  you need a device to browse the web (e.g. to fetch a
  DNS token) before finishing setup. HTTPS sites always
  work either way. This screen refreshes automatically.
EOF
      printf '%s' "$clr_eos"

      ## Wait up to 5s for a keypress, then refresh.
      ## `d` TOGGLES the override: create the sentinel if absent, remove it
      ## if present. Caddy's portal matcher checks the sentinel at request
      ## time, so the change takes effect on the next request — no reload.
      ## The status line above flips colour on the next redraw, so the user
      ## sees the toggle land.
      if read -r -n1 -t5 key 2>/dev/null; then
        if [ "$key" = "d" ] || [ "$key" = "D" ]; then
          if [ -f ${portalDisabledSentinel} ]; then
            rm -f ${portalDisabledSentinel} 2>/dev/null || true
          else
            mkdir -p /var/lib/homefree-secrets 2>/dev/null || true
            touch ${portalDisabledSentinel} 2>/dev/null || true
          fi
        fi
      fi
    done
  '';
in
{
  ## Run the status screen on tty1 while setup is pending.
  ##
  ## Console-ownership — the hard part, and the source of two earlier bugs.
  ##
  ##  WHY NOT `Conflicts=getty@tty1`: a `Conflicts` dependency is resolved
  ##  when the START JOB is enqueued — BEFORE `ConditionPathExists` is
  ##  evaluated. So on a finished box (`.setup-complete` present) this
  ##  unit's start job still stopped getty@tty1 as a conflict, then the
  ##  unit itself skipped on the condition — leaving tty1 with no getty
  ##  and nothing to bring it back. The physical console was dead on
  ##  every boot of a set-up box.
  ##
  ##  INSTEAD: no `Conflicts`. getty@tty1 is stopped by `ExecStartPre`,
  ##  which runs AFTER the condition check — so it only ever runs when
  ##  setup is genuinely pending. A finished box never touches getty.
  ##  Ordered `after getty@tty1` so getty is up first and the ExecStartPre
  ##  stop is deterministic (not racing getty's own start).
  ##
  ##  - `Type = "idle"`: systemd holds ExecStart until pending job output
  ##    has drained — same mechanism getty uses so the screen is not
  ##    overprinted by boot messages.
  ##  - `Restart = "on-failure"`: relaunch only on a genuine crash; a
  ##    clean exit means setup finished and tty1 is being handed back.
  ##  - `ExecStopPost` restarts getty@tty1 when this unit stops. With no
  ##    `Conflicts` in play this is a plain start with no circular
  ##    stop/start transaction, so it returns immediately instead of
  ##    hanging the 90s stop timeout (the second earlier bug).
  systemd.services.homefree-finish-setup-console = {
    description = "HomeFree finish-setup console status screen (tty1)";
    after = [
      "homefree-setup-state.service"
      "systemd-user-sessions.service"
      "getty@tty1.service"
    ];
    wantedBy = [ "multi-user.target" ];

    unitConfig = {
      ## Only take over the console while setup is genuinely pending.
      ## Checked before ExecStartPre/ExecStart — see the comment above.
      ConditionPathExists = "!${completeSentinel}";
    };

    serviceConfig = {
      Type = "idle";
      ## Stop getty ourselves, post-condition. The `-` prefix tolerates
      ## getty already being inactive. This replaces `Conflicts` so a
      ## skipped unit (finished box) never disturbs the login.
      ExecStartPre = "-${pkgs.systemd}/bin/systemctl stop getty@tty1.service";
      ExecStart = "${consoleScript}";
      ## Hand tty1 back to a normal login when the TUI exits.
      ExecStopPost = "-${pkgs.systemd}/bin/systemctl --no-block start getty@tty1.service";
      StandardInput = "tty";
      StandardOutput = "tty";
      StandardError = "journal";
      TTYPath = "/dev/tty1";
      TTYReset = true;
      TTYVHangup = true;
      Restart = "on-failure";
      RestartSec = 1;
      ## Backstop: never let a stuck stop drag past 5s and fail the
      ## rebuild (the 90s default once did exactly that).
      TimeoutStopSec = "5s";
    };
  };

  ## Login breadcrumb. NOT `users.motd` — that is static text baked in at
  ## build time, so it claimed "setup is NOT finished" forever, even after
  ## setup completed (it cannot see the sentinel). Instead this runs at
  ## LOGIN time via environment.loginShellInit (sourced by /etc/profile
  ## for every login shell — console and SSH) and checks `.setup-complete`
  ## live, so the notice disappears the instant setup is done — no rebuild
  ## needed.
  environment.loginShellInit = ''
    if [ ! -e ${completeSentinel} ]; then
      echo
      echo '********************************************************'
      echo '*  HomeFree setup is NOT finished.                     *'
      echo '*                                                      *'
      echo '*  Open  http://${lanAddress}/                         *'
      echo '*  (or   http://${wizardHost}/ )                       *'
      echo '*  from a device connected to the LAN port to finish.  *'
      echo '********************************************************'
      echo
    fi
  '';
}
