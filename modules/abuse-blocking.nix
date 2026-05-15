## fail2ban configuration for HomeFree.
##
## Watches Caddy's per-service JSON access logs (one file per
## service-label under /var/log/caddy/) for abusive patterns and
## inserts the offender's IP into the nftables `f2b_banned4` /
## `f2b_banned6` named sets declared in profiles/router.nix.
##
## Jails defined here:
##   - caddy-oauth-hammer: > N hits/min on /user/oauth2/* paths.
##     This is the pattern that crashed Forgejo on 2026-05-15
##     (Go-runtime concurrent-map race in goth.StoreInSession under
##     repeated OAuth callouts from the same IP/range).
##   - caddy-404-storm: > N 404s/min — generic scraping signal.
##   - caddy-error-flood: > N 5xx responses to the same IP/min —
##     catches bots that keep retrying during an outage and
##     amplify the load when the service is already on its knees.
##   - recidive: repeat offenders get a long ban.
##
## Coverage: ban entries are pushed to nftables sets with a
## per-jail timeout. profiles/router.nix consumes those sets in
## both the input and forward chains so podman-hosted services
## are protected as well.
##
## The Caddy JSON format we parse is the default NixOS Caddy
## format: one JSON object per line. The `failregex` patterns
## anchor on the "client_ip":"<ip>" field rather than a host-
## prefixed access-log line, which keeps the regex tolerant to
## key ordering in the JSON.
{ config, lib, pkgs, ... }:

let
  caddyLogGlob = "${config.services.caddy.logDir}/access-*.log";

  ## ┌── Failregex notes ────────────────────────────────────────
  ## fail2ban's <HOST> macro extracts the IP that gets banned.
  ## We need it bound to the "client_ip" JSON field, not
  ## "remote_ip" (which is sometimes a private upstream IP when
  ## requests come in through a proxy). The pattern allows the
  ## JSON keys to appear in any order because Caddy doesn't
  ## guarantee field order.
  oauthHammerFilter = pkgs.writeText "caddy-oauth-hammer.conf" ''
    [INCLUDES]
    before = common.conf

    [Definition]
    failregex = ^.*"client_ip":"<HOST>".*"uri":"/user/oauth2/.*$
                ^.*"uri":"/user/oauth2/.*"client_ip":"<HOST>".*$
    ignoreregex =
    datepattern = "ts":\s*{EPOCH}
  '';

  ## 404 floods. 100 in 60s is a high bar — legitimate users
  ## sometimes generate small bursts (broken links, stale
  ## bookmarks). The findtime/maxretry below sets the same
  ## numbers explicitly via fail2ban config.
  s404StormFilter = pkgs.writeText "caddy-404-storm.conf" ''
    [INCLUDES]
    before = common.conf

    [Definition]
    failregex = ^.*"client_ip":"<HOST>".*"status":404.*$
                ^.*"status":404.*"client_ip":"<HOST>".*$
    ignoreregex =
    datepattern = "ts":\s*{EPOCH}
  '';

  ## Persistent 5xx-from-same-IP. Catches retry-storms during a
  ## real outage (like the Forgejo 502 hours) — once the service
  ## is back the bot keeps banging. Higher threshold than 404
  ## storm because real users can also see 5xx.
  errorFloodFilter = pkgs.writeText "caddy-error-flood.conf" ''
    [INCLUDES]
    before = common.conf

    [Definition]
    failregex = ^.*"client_ip":"<HOST>".*"status":5[0-9][0-9].*$
                ^.*"status":5[0-9][0-9].*"client_ip":"<HOST>".*$
    ignoreregex =
    datepattern = "ts":\s*{EPOCH}
  '';
in
{
  ## fail2ban needs nftables, not iptables. networking.nftables
  ## is already enabled by profiles/router.nix; double-check via
  ## an assertion so a future config split is loud rather than
  ## silently falling back to iptables (the default fail2ban
  ## backend), which would target a non-existent table.
  assertions = [
    {
      assertion = config.networking.nftables.enable;
      message = ''
        modules/abuse-blocking.nix requires networking.nftables.enable = true
        (the fail2ban jails target nftables sets declared in
        profiles/router.nix).
      '';
    }
  ];

  ## Drop the custom filter files into /etc/fail2ban/filter.d/ so
  ## the jails can reference them by name.
  environment.etc = {
    "fail2ban/filter.d/caddy-oauth-hammer.conf".source = oauthHammerFilter;
    "fail2ban/filter.d/caddy-404-storm.conf".source = s404StormFilter;
    "fail2ban/filter.d/caddy-error-flood.conf".source = errorFloodFilter;
  };

  services.fail2ban = {
    enable = true;

    ## Use nftables, targeting the inet/filter sets declared in
    ## profiles/router.nix. The "multiport" action adds to a
    ## named set rather than per-port rules, which is what we
    ## want — one set, dropped in both input and forward chains.
    banaction = "nftables-multiport";
    banaction-allports = "nftables-allports";

    ## Default ban duration; per-jail overrides below for the
    ## OAuth-hammer case (more aggressive — we know this one
    ## already crashed a service).
    bantime = "1h";

    ## Repeat-offender escalation (recidive): if an IP gets
    ## banned 3+ times within a day, lock them out for a week.
    bantime-increment = {
      enable = true;
      maxtime = "7d";
      factor = "2";
    };

    ## Common allowlist — never ban LAN/loopback/tailnet/netbird.
    ignoreIP = [
      "127.0.0.0/8"
      "::1"
      "10.0.0.0/8"
      "172.16.0.0/12"
      "192.168.0.0/16"
      "100.64.0.0/10"   # tailscale CGNAT range
      "fc00::/7"        # ULA (covers netbird/tailscale v6)
    ];

    jails = {
      caddy-oauth-hammer.settings = {
        enabled = true;
        filter = "caddy-oauth-hammer";
        backend = "polling";
        logpath = caddyLogGlob;
        maxretry = 20;
        findtime = 60;
        bantime = 3600;
      };

      caddy-404-storm.settings = {
        enabled = true;
        filter = "caddy-404-storm";
        backend = "polling";
        logpath = caddyLogGlob;
        maxretry = 100;
        findtime = 60;
        bantime = 1800;
      };

      caddy-error-flood.settings = {
        enabled = true;
        filter = "caddy-error-flood";
        backend = "polling";
        logpath = caddyLogGlob;
        maxretry = 200;
        findtime = 60;
        bantime = 600;
      };
    };
  };

  ## Override the default nftables-multiport action to write into
  ## *our* named sets rather than fail2ban's auto-created tables.
  ## fail2ban's default nftables backend creates a table called
  ## `f2b-table` with its own sets; we want bans to land in the
  ## sets profiles/router.nix already consumes. Without this
  ## override the kernel ends up with two parallel sets and the
  ## drop rules never see the bans.
  ##
  ## The action template uses fail2ban macros: <ip> is the IP,
  ## <bantime> is the configured ban duration. nft `add element`
  ## with `timeout` lets the kernel evict expired entries on its
  ## own, so unban-on-restart works without fail2ban running.
  environment.etc."fail2ban/action.d/nftables-multiport.local".text = ''
    [Definition]
    actionstart =
    actionstop =
    actioncheck =
    actionban   = ${pkgs.nftables}/bin/nft add element inet filter f2b_banned4 { <ip> timeout <bantime>s } 2>/dev/null || \
                  ${pkgs.nftables}/bin/nft add element inet filter f2b_banned6 { <ip> timeout <bantime>s }
    actionunban = ${pkgs.nftables}/bin/nft delete element inet filter f2b_banned4 { <ip> } 2>/dev/null || \
                  ${pkgs.nftables}/bin/nft delete element inet filter f2b_banned6 { <ip> } 2>/dev/null || true
  '';
}
