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
##
## Dev/VM mode: a redirect is unusable when the box is reached at an address
## that is not its own LAN identity (a QEMU port-forward, or a dev box on an
## existing LAN). In that mode the `:80` catch-all SERVES the wizard inline
## instead of redirecting — see `devMode` below.
{ config, lib, pkgs, ... }:

let
  cfg = config.homefree;

  ## Dev/VM mode. On a dev box or a VM the machine is reached at an address
  ## that is NOT its own LAN identity — a QEMU port-forward (localhost:8080),
  ## or a dev box sitting on an existing LAN where `admin.<localDomain>`
  ## already resolves to a *different*, production HomeFree. A redirect is
  ## therefore unusable: whatever target we pick, the client resolves it on
  ## the wrong network. So in dev mode the `:80` catch-all SERVES the wizard
  ## inline (same response, no redirect) — whatever address reached the box
  ## is where the wizard appears.
  ##
  ## `homefree.development` is set by the installer in
  ## /etc/nixos/development-overrides.nix when "Development mode" is chosen.
  devMode = cfg.development;

  ## The finish-setup wizard IS the admin UI (admin-web serves the same
  ## frontend). Inline-serving reproduces admin-web's serving config:
  ## static frontend files + an /api reverse-proxy to the admin backend.
  ## The SSO gate is intentionally omitted — in dev mode on an unfinished
  ## box SSO is not provisioned and the wizard must be reachable pre-SSO.
  frontendPath = ../../web-platform/frontend;

  ## Where the wizard lives. We redirect to the box's bare LAN IP, NOT a
  ## hostname: a hostname in a redirect is resolved by whatever client
  ## follows it, and that client may resolve admin.<localDomain> to a
  ## *different* HomeFree box (a stale DNS entry, a second box, a VM tester
  ## whose host network maps the name to their production instance). The IP
  ## is unambiguous — it is always this box on this LAN.
  ##
  ## admin-web registers this exact address as an explicit virtualHost
  ## (`extra-http-hosts`), so http://<lan-ip>/ serves the admin UI directly
  ## and is more specific than this `:80` catch-all — no redirect loop.
  wizardUrl = "http://${cfg.network.lan-address}/";

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

  ## Caddyfile served by the `:80` catch-all in DEV/VM mode: serve the
  ## wizard (= the admin UI frontend) inline for every host, with /api
  ## proxied to the admin backend. No redirect — see `devMode` above.
  devInlineConfig = ''
    ## API + health -> admin backend. Mirrors admin-web's @api handler,
    ## including the graceful fallback when the backend is briefly down.
    @api path /api/* /health
    handle @api {
      reverse_proxy localhost:8000 {
        @backend_down status 502 503 504
        handle_response @backend_down {
          root * /var/lib/homefree-admin
          rewrite * /service-state.json
          file_server
        }
      }
    }

    ## Everything else: the static frontend, with SPA fallback so deep
    ## links resolve to index.html.
    handle {
      root * ${frontendPath}
      try_files {path} /index.html
      file_server
    }
  '';

  ## Caddyfile served by the `:80` catch-all in PRODUCTION: the captive-
  ## portal redirect.
  ##
  ## Caddyfile design — why `handle` ordering instead of negated matchers:
  ## the `file` matcher only has a reliable positive form (file EXISTS) —
  ## the same form the existing `@sso_gate` uses. Nesting it inside
  ## `not { file { ... } }` does not adapt correctly (the file matcher's
  ## root/try_files are lost). So instead of negating, we test the positive
  ## case and rely on `handle` ordering: the FIRST matching `handle` wins.
  ## The bail-out conditions (setup complete, override engaged, allowlisted)
  ## are earlier `handle` blocks; anything past them should be redirected.
  ## `route { }` keeps the handles in written order.
  prodRedirectConfig = ''
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
      ## By elimination: setup pending, override off, host not allowlisted.
      ## Redirect to the wizard. OS probes are redirected too — a 302
      ## (instead of their expected 204 / success body) is the standard
      ## "this network is captive" signal that pops the device's
      ## "Sign in to network" prompt.
      handle {
        redir * ${wizardUrl} 302
      }
    }
  '';
in
{
  ## Contributed via normal option-merging into the Caddy config built by
  ## services/caddy. Keeping it in its own module (rather than woven into
  ## that file's large virtualHosts generator) means it can be reviewed and
  ## disabled independently.
  services.caddy.virtualHosts.":80" = {
    extraConfig = if devMode then devInlineConfig else prodRedirectConfig;
  };
}
