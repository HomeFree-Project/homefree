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
  ##
  ## Why this only matches status:404 (and error-flood only matches
  ## status:5xx): the apex landing site emits 429 from
  ## mholt/caddy-ratelimit when the per-IP request-rate cap fires
  ## (see services/landing-page/default.nix `rateLimit`). A surge of
  ## legitimate HN/Reddit visitors should trip the 429 layer first
  ## — that's the *intended* behaviour — and they MUST NOT then be
  ## banned at the firewall. Narrow status matchers keep 429 out of
  ## both jails by construction; do not loosen to a class match
  ## (`status":4[0-9][0-9]`) without also excluding 429 here.
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

  ## ── Seed-once default abuse-block list ──────────────────────────
  ## On a fresh install, homefree-config.json has no
  ## network.abuseBlockCidrs key. This activation step seeds it ONCE
  ## with known abusive scraper ranges so a new box gets baseline
  ## protection without the user having to discover the setting.
  ##
  ## Idempotent and seed-ONLY: it writes the key only when it is
  ## entirely absent. Once present — even as an empty list — the step
  ## is a no-op forever. So a user who disables or deletes the seeded
  ## entries via the admin UI is never re-seeded.
  ##
  ## Caveat: Nix evaluation reads homefree-config.json *before*
  ## activation runs, so on the very first rebuild the seeded ranges
  ## are written but not yet enforced — they take effect on the next
  ## rebuild. Acceptable: it's a one-time, first-install-only delay.
  ##
  ## Alibaba Cloud (AS45102 / AS37963) — 47.74.0.0/15, 47.76.0.0/14,
  ## 47.80.0.0/13. Confirmed scraping a HomeFree forgejo on
  ## 2026-05-15 (Go-runtime crash under sustained /user/oauth2/*
  ## hammering from 47.79.*/47.82.*).
  homefreeConfigPath = "/etc/nixos/homefree-config.json";

  ## The seeding logic, as a standalone Python file. Kept out of a
  ## shell heredoc on purpose — heredocs inside Nix `''..''` strings
  ## mangle Python's significant indentation. The default ranges are
  ## defined here, in one place.
  seedAbuseCidrsPy = pkgs.writeText "seed-abuse-block-cidrs.py" ''
    import json, sys, os, tempfile

    path = sys.argv[1]
    try:
        with open(path) as f:
            cfg = json.load(f)
    except (OSError, ValueError) as e:
        print("seed-abuse-block-cidrs: cannot read %s: %s" % (path, e),
              file=sys.stderr)
        sys.exit(0)  # don't fail activation over this

    net = cfg.setdefault("network", {})
    if "abuseBlockCidrs" in net:
        # Key already present (possibly empty) — user owns it now.
        sys.exit(0)

    _c = ("Alibaba Cloud (AS45102/AS37963) — scraper network, "
          "seeded by HomeFree default")
    net["abuseBlockCidrs"] = [
        {"cidr": "47.74.0.0/15", "enabled": True, "comment": _c},
        {"cidr": "47.76.0.0/14", "enabled": True, "comment": _c},
        {"cidr": "47.80.0.0/13", "enabled": True, "comment": _c},
    ]

    # Atomic write — temp file in the same dir, then rename.
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".homefree-config.")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(cfg, f, indent=2)
            f.write("\n")
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise
    print("seed-abuse-block-cidrs: seeded network.abuseBlockCidrs")
  '';

  seedAbuseCidrs = pkgs.writeShellScript "seed-abuse-block-cidrs" ''
    set -eu
    CONFIG=${homefreeConfigPath}
    [ -f "$CONFIG" ] || exit 0   # no config file yet — nothing to seed
    ${pkgs.python3}/bin/python3 ${seedAbuseCidrsPy} "$CONFIG"
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

  ## Seed the default abuse-block CIDR list on first install. Runs
  ## during activation; seeds only when network.abuseBlockCidrs is
  ## absent from homefree-config.json (see seedAbuseCidrs above).
  system.activationScripts.seedAbuseBlockCidrs = {
    text = "${seedAbuseCidrs}";
    deps = [];
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
