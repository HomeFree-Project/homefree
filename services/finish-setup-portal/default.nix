## Finish-setup captive portal.
##
## A freshly-installed HomeFree box can't be used until the finish-setup
## wizard is completed (SSH authorized key + DNS-01 provider). But nothing
## tells a non-technical user where the wizard is. This module makes the box
## behave like a captive-portal "sign in to network" page: while setup is
## pending, any LAN device that opens a plain-HTTP site — or whose OS runs a
## connectivity check — is redirected to the wizard.
##
## Mechanism: one extra Caddy site with the address `:80`, which Caddy treats
## as the catch-all for any host on port 80 NOT claimed by a more specific
## (named-host) virtualHost. Caddy routes by host specificity, so the
## HomeFree services (admin UI, landing page, etc.) — all registered as
## explicit `http://<host>` virtualHosts — still win for their own hostnames;
## this `:80` site only ever sees "other" hosts: arbitrary websites the user
## browses to, bare IPs, and OS probe domains.
##
## Gating — request-time, no rebuild needed (mirrors the `.sso-provisioned`
## pattern in services/caddy):
##   - `.setup-complete` present  => redirect is inert (setup is done).
##   - `.setup-portal-disabled` present => redirect suppressed (the console
##     TUI's manual override; lets a trapped user browse before finishing).
## Both sentinels are maintained by modules/setup-state.nix and the console
## TUI; Caddy checks them per-request with `file` matchers, so toggling either
## takes effect on the very next request — no `caddy reload`, no rebuild.
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
  ## Note we do NOT need a separate bare-IP virtualHost: the `:80`
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
  services.caddy.virtualHosts.":80" = {
    ## Caddyfile design — why `handle` ordering instead of negated matchers:
    ##
    ## The `file` matcher only has a reliable positive form (file EXISTS) —
    ## the same form the existing `@sso_gate` uses. Nesting it inside
    ## `not { file { ... } }` does not adapt correctly (the file matcher's
    ## root/try_files are lost). So instead of negating, we test the
    ## positive case and rely on `handle` ordering: the FIRST matching
    ## `handle` wins and the rest are skipped. We arrange the bail-out
    ## conditions (setup complete, override engaged, allowlisted host)
    ## as earlier `handle` blocks; anything that falls past them is, by
    ## elimination, a request that should be redirected.
    ##
    ## `route { }` keeps these handles in written order regardless of
    ## Caddy's normal directive sorting.
    extraConfig = ''
      ## `@setup_done` / `@override_on` use the proven positive `file`
      ## matcher: true when the sentinel file exists.
      @setup_done file {
        root /
        try_files /var/lib/homefree-secrets/.setup-complete
      }
      @override_on file {
        root /
        try_files /var/lib/homefree-secrets/.setup-portal-disabled
      }
      ## Hosts the user may need before finishing setup — never redirected.
      @allowlisted host ${allowlistMatcher}
      ## OS captive-portal probe hosts (iOS / Android / Windows / Firefox).
      ## All on ONE `host` line — a repeated `host` matcher conflicts.
      @os_probe host captive.apple.com www.apple.com connectivitycheck.gstatic.com clients3.google.com www.msftconnecttest.com www.msftncsi.com detectportal.firefox.com

      route {
        ## --- Bail-out cases (checked first; first match wins) ----------
        ## Setup finished, or the console override is engaged: behave like
        ## open internet. OS probes get the 204 they expect; everything
        ## else a bare 200. No redirect.
        handle @setup_done {
          respond @os_probe 204
          respond "HomeFree" 200
        }
        handle @override_on {
          respond @os_probe 204
          respond "HomeFree" 200
        }
        ## Allowlisted host (DNS provider / code host): pass through so the
        ## user can fetch an API token or SSH key before finishing setup.
        handle @allowlisted {
          respond "HomeFree" 200
        }

        ## --- Redirect case (everything else) ---------------------------
        ## By elimination this is: setup pending, override off, host not
        ## allowlisted. Redirect to the wizard. OS probes are redirected
        ## too — a 302 (instead of their expected 204 / success body) is
        ## the standard "this network is captive" signal that makes the
        ## device pop its "Sign in to network" prompt.
        handle {
          redir * ${wizardUrl} 302
        }
      }
    '';
  };
}
