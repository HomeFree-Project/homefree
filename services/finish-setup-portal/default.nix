## Finish-setup captive portal.
##
## A freshly-installed HomeFree box can't be used until the finish-setup
## wizard is completed (SSH authorized key + DNS-01 provider). But nothing
## tells a non-technical user where the wizard is. This module makes the box
## behave like a captive-portal "sign in to network" page: while setup is
## pending, any LAN device that opens a plain-HTTP site — or whose OS runs a
## connectivity check — is redirected to the wizard.
##
## Mechanism: one extra Caddy site with the address `http://`, which Caddy
## treats as the catch-all for any :80 host NOT claimed by a more specific
## virtualHost. The HomeFree services (admin UI, landing page, etc.) all
## register explicit virtualHosts, so this site only ever sees "other" hosts:
## arbitrary websites the user browses to, bare IPs, and OS probe domains.
##
## Gating — request-time, no rebuild needed (mirrors the `.sso-provisioned`
## pattern in services/caddy):
##   - `.setup-complete` present  => redirect is inert (setup is done).
##   - `.setup-portal-disabled` present => redirect suppressed (the console
##     TUI's manual override; lets a trapped user browse before finishing).
## Both sentinels are maintained by modules/setup-state.nix and the console
## TUI; Caddy checks them per-request with `file` matchers, so toggling either
## only needs a `caddy reload`, not a config regeneration.
##
## Scope: HTTP only. Caddy cannot intercept HTTPS without a certificate the
## client would reject, so HTTPS sites simply load normally. This is fine —
## the OS-probe handling plus "open any http:// site" covers the common path.
{ config, lib, pkgs, ... }:

let
  cfg = config.homefree;

  ## Where the wizard lives. The admin UI is served at admin.<localDomain>
  ## (services/admin-web registers `subdomains = ["admin"]` against the local
  ## domain). HomeFree's own unbound generates an A record for every non-public
  ## reverse-proxy FQDN pointing at the LAN IP (services/unbound), so
  ## `admin.<localDomain>` resolves on a fresh box as long as HomeFree is the
  ## LAN's DNS server (the router-mode default).
  ##
  ## Note we do NOT need a separate bare-IP virtualHost: the `http://`
  ## catch-all below already matches a request to the bare LAN IP and
  ## redirects it here, so a user who types the IP still lands on the wizard.
  wizardUrl = "http://admin.${cfg.system.localDomain}/";

  ## Domains a user may legitimately need to reach BEFORE finishing setup —
  ## chiefly to generate a DNS-provider API token or fetch an SSH key. Plain-
  ## HTTP requests to these are passed through instead of redirected, so the
  ## portal never traps the "I need my token" case. (HTTPS to these already
  ## works regardless of the portal.)
  allowlistHosts = [
    "hetzner.com" "*.hetzner.com"
    "hetzner.cloud" "*.hetzner.cloud"
    "github.com" "*.github.com"
    "gitlab.com" "*.gitlab.com"
  ];
  allowlistMatcher = lib.concatStringsSep " " allowlistHosts;
in
{
  ## Contributed via normal option-merging into the Caddy config built by
  ## services/caddy. Keeping it in its own module (rather than woven into
  ## that file's large virtualHosts generator) means it can be reviewed and
  ## disabled independently.
  services.caddy.virtualHosts."http://" = {
    ## Caddyfile semantics used here:
    ##  - Lines inside a named-matcher block are AND-ed together.
    ##  - A `not { ... }` block inside a matcher negates its inner matchers.
    ##  - `redir @m` only fires for requests matching @m; non-matching
    ##    requests fall through to the next directive.
    ## So `@redirect` below is true exactly when:
    ##     setup pending  AND  override not engaged  AND  host not allowlisted
    ## by combining a negated file-matcher, a negated file-matcher, and a
    ## negated host-matcher — all within one matcher block.
    extraConfig = ''
      ## Fire the redirect only while setup is genuinely pending and not
      ## manually overridden, and never for an allowlisted host.
      @redirect {
        not file {
          root /
          try_files /var/lib/homefree-secrets/.setup-complete
        }
        not file {
          root /
          try_files /var/lib/homefree-secrets/.setup-portal-disabled
        }
        not host ${allowlistMatcher}
      }

      ## OS captive-portal probes: the connectivity-check URLs iOS,
      ## Android/Chrome, Windows and Firefox hit on joining a network.
      ## Redirecting them (rather than returning the 204 / success body
      ## they expect) is the standard "this network is captive" signal,
      ## which makes the OS pop its "Sign in to network" notification
      ## pointing at the wizard.
      ##
      ## These are matched independently of the allowlist (an OS probe
      ## host is never on it) but still respect the setup-pending and
      ## override sentinels.
      ## All probe hosts must be on ONE `host` line — repeating the
      ## `host` matcher within a block does not OR, it conflicts.
      @os_probe_redirect {
        host captive.apple.com www.apple.com connectivitycheck.gstatic.com clients3.google.com www.msftconnecttest.com www.msftncsi.com detectportal.firefox.com
        not file {
          root /
          try_files /var/lib/homefree-secrets/.setup-complete
        }
        not file {
          root /
          try_files /var/lib/homefree-secrets/.setup-portal-disabled
        }
      }

      ## Order matters: redirect matchers first, then the fall-through
      ## responses. A request that matches neither (setup done, override
      ## engaged, or allowlisted) lands on the plain 200 below.
      redir @os_probe_redirect ${wizardUrl} 302
      redir @redirect ${wizardUrl} 302

      ## Fall-through. For an OS probe that should NOT redirect (setup done
      ## or override on), 204 tells the OS the network is open. Everything
      ## else gets a bare 200 so the request doesn't error.
      @os_probe_open host captive.apple.com www.apple.com connectivitycheck.gstatic.com clients3.google.com www.msftconnecttest.com www.msftncsi.com detectportal.firefox.com
      respond @os_probe_open 204
      respond "HomeFree" 200
    '';
  };
}
