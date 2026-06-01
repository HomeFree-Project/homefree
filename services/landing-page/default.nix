{ config, lib, pkgs, ... }:
let
  homefree-site = pkgs.callPackage ./site { };
  downloadsDir = "/var/lib/homefree/downloads";
  projectMode = config.homefree.system.project-mode;
  domain = config.homefree.system.domain;

  ## ─── Layer 7: opt-in CDN / edge fronting ─────────────────────────
  ## See `homefree.services.landing-page.edge.*` docstrings for the
  ## rationale (residential-uplink bandwidth defence) and operator
  ## responsibilities (DNS, origin-pull config, CDN-side header
  ## injection). The trusted-proxies CIDR list is emitted into
  ## Caddy's GLOBAL `servers { }` block over in
  ## services/caddy/default.nix (Caddy only allows trusted_proxies
  ## at the per-listener level); this block emits the SITE-level
  ## directives (origin-bypass shared-secret check + Vary header)
  ## that apply only to the apex landing vhost.
  edgeCfg = config.homefree.services.landing-page.edge;

  edgeFrontingConfig =
    if !edgeCfg.enable then ""
    else
      let
        originSecretCheck =
          if edgeCfg.originSharedSecretEnv == null then ''
            ## NO origin-shared-secret configured — origin-bypass
            ## protection is DISABLED. An attacker who knows the
            ## origin IP can hit it directly and bypass the CDN
            ## entirely. Strongly discouraged for production;
            ## configure `originSharedSecretEnv` to close this hole.
          '' else ''
            ## Origin-bypass protection: reject any request that
            ## doesn't carry the shared secret in X-Edge-Origin-Auth.
            ## The CDN injects this header on every origin pull
            ## (Cloudflare Transform Rule, bunny.net custom origin
            ## header, etc.); requests arriving without it must be
            ## hitting the origin directly and are dropped with 403.
            ## `{''$${edgeCfg.originSharedSecretEnv}}` is Caddy's
            ## env-var expansion at config-parse time, fed from the
            ## EnvironmentFile already loaded by the Caddy unit.
            @edge_bypass {
              not header X-Edge-Origin-Auth {''$${edgeCfg.originSharedSecretEnv}}
            }
            handle @edge_bypass {
              respond "Direct origin access not permitted." 403 {
                close
              }
            }
          '';
      in
      originSecretCheck + ''
        ## Tell intermediate caches (the CDN included) to vary
        ## responses by Cookie so a session-bound response can't be
        ## served to a different visitor. The landing routes don't
        ## set session cookies, but defence-in-depth.
        header Vary "Accept-Encoding, Cookie"
      '';

  ## Proactive per-IP request-rate cap on the landing site's HTML
  ## routes — see `homefree.services.landing-page.rateLimit` docstring.
  ## Emitted only when enabled; the directive itself uses the
  ## mholt/caddy-ratelimit plugin built in via the Caddy overlay.
  ## Matcher excludes `?v=*` hashed assets (already long-cached at
  ## the browser, no surge risk), `/downloads/*`, `/.well-known/*`,
  ## and the `/manual*` redirect — those have their own profiles or
  ## are too cheap to be worth rate-limiting.
  rateLimitConfig =
    if config.homefree.services.landing-page.rateLimit.enable then ''
      @landing_html {
        not query v=*
        not path /downloads/* /.well-known/* /manual /manual/*
      }
      rate_limit @landing_html {
        zone landing_html {
          key {http.request.remote_host}
          events ${toString config.homefree.services.landing-page.rateLimit.events}
          window ${config.homefree.services.landing-page.rateLimit.window}
        }
      }
    '' else "";

  ## Apex Caddy config when project-mode = true (the upstream
  ## homefree.host marketing instance). Keeps the original behavior:
  ## Matrix .well-known, /downloads/*, and a redirect for /manual/*
  ## back to manual.<domain>.
  projectModeApexCaddyConfig = edgeFrontingConfig + rateLimitConfig + ''
    # Matrix Synapse settings
    header /.well-known/matrix/* Content-Type application/json
    header /.well-known/matrix/* Access-Control-Allow-Origin *
    respond /.well-known/matrix/server `{"m.server": "matrix.${domain}:443"}`
    respond /.well-known/matrix/client `{"m.homeserver":{"base_url":"https://matrix.${domain}"}}`
    ## No identity server
    # respond /.well-known/matrix/client `{"m.homeserver":{"base_url":"https://matrix.${domain}"},"m.identity_server":{"base_url":"https://identity.${domain}"}}`

    # Public installer images. Served from outside the Nix store so
    # ISOs can be republished without a nixos-rebuild. `handle_path`
    # is a TOP-LEVEL directive — Caddy orders it before the site's
    # fallback `file_server`, so this branch wins for /downloads/*
    # without affecting the rest of the static site.
    handle_path /downloads/* {
      root * ${downloadsDir}
      file_server browse
    }

    ## "Manual" nav link on the apex site points at /manual/ for
    ## portability; redirect both that and any deep apex /manual/...
    ## URL to the dedicated subdomain.
    redir /manual https://manual.${domain}/ 302
    redir /manual/* https://manual.${domain}{uri} 302

    ## Typo / bare-path 301s — surge defence. A HN/Reddit commenter
    ## who writes "homefree.host/docs" or "homefree.host/install"
    ## instead of the canonical URL would otherwise generate a 404
    ## per visitor, and a thread-sized burst of distinct legitimate
    ## IPs eating the 404-storm jail's threshold (caddy-404-storm
    ## maxretry=100 / 60s per IP — high, but a popular wrong link
    ## also produces sub-bursts on a few IPs that hit refresh). 301
    ## (permanent) so search engines pick up the canonical target.
    ## Cheap to maintain — these are paths a writer is overwhelm-
    ## ingly likely to choose if they don't have the real URL in
    ## front of them.
    redir /docs           https://manual.${domain}/                       301
    redir /installation   https://manual.${domain}/installation/          301
    redir /install        https://manual.${domain}/installation/          301
    redir /hardware-setup https://manual.${domain}/hardware-setup/        301
    redir /hardware       https://manual.${domain}/hardware-setup/        301
    redir /setup          https://manual.${domain}/hardware-setup/        301
    redir /developers     https://manual.${domain}/developers/            301
    redir /dev            https://manual.${domain}/developers/            301
  '';

  ## Apex Caddy config when project-mode = false (any real personal
  ## deployment). The apex domain has no marketing site; visitors are
  ## redirected to home.<domain> where the SSO gate + user dashboard
  ## live.
  ##
  ## Ordering hazard: Caddy's directive order puts `redir` very early
  ## (slot ~2), well BEFORE `respond` and `handle_path`. A naked
  ## top-level `redir /* https://home...` would fire before the
  ## Matrix `.well-known` responder and `/downloads/*` handler, even
  ## though those are written first in source order — breaking Matrix
  ## federation and ISO downloads.
  ##
  ## Fix: keep `redir` at the top level but use a `not path` matcher
  ## to exclude paths we want preserved. The specific responders /
  ## handlers still get to run on their own paths because the redir
  ## skips them entirely.
  personalModeApexCaddyConfig = edgeFrontingConfig + rateLimitConfig + ''
    # Matrix Synapse settings — must respond with JSON, not redirect.
    header /.well-known/matrix/* Content-Type application/json
    header /.well-known/matrix/* Access-Control-Allow-Origin *
    respond /.well-known/matrix/server `{"m.server": "matrix.${domain}:443"}`
    respond /.well-known/matrix/client `{"m.homeserver":{"base_url":"https://matrix.${domain}"}}`

    # Public installer images — served from outside the Nix store.
    handle_path /downloads/* {
      root * ${downloadsDir}
      file_server browse
    }

    # Manual subdomain redirect for stale bookmarks.
    redir /manual https://manual.${domain}/ 302
    redir /manual/* https://manual.${domain}{uri} 302

    # Personal-mode apex catch-all: redirect everything else to the
    # user dashboard. The matcher excludes paths handled above so
    # Matrix .well-known, /downloads/*, and /manual/* keep working.
    # The home vhost runs the oauth2-proxy gate — anonymous visitors
    # bounce through sign-in there, authenticated users land on the
    # dashboard directly.
    #
    # /_matrix/* federation requests SHOULDN'T arrive here at all —
    # other servers discover us via /.well-known/matrix/server which
    # points at matrix.<domain>. But if a stale-discovery federator
    # does hit apex, 302'ing them to home.<domain> spirals into the
    # oauth2-proxy login flow (which they can't follow). Excluded
    # so the apex returns 404 in that edge case, prompting fresh
    # discovery.
    @apex_passthrough {
      not path /.well-known/matrix/*
      not path /_matrix/*
      not path /downloads/*
      not path /manual /manual/*
    }
    redir @apex_passthrough https://home.${domain}{uri} 302
  '';
in
{
  ## add homefree default site as a package
  nixpkgs.overlays = [
    (final: prev: {
      homefree-site = homefree-site;
    })
  ];

  ## Public-image download directory. Populated out-of-band by
  ## scripts/build-public-image.sh (rsync'd onto the box); built
  ## artifacts live OUTSIDE the Nix store so ISO publishing is
  ## decoupled from nixos-rebuild.
  systemd.tmpfiles.rules = [
    "d ${downloadsDir} 0755 caddy caddy -"
  ];

  homefree.service-config = [
    {
      label = "landing-page";
      name = "Landing Page";
      project-name = "HomeFree Landing Page";
      systemd-service-names = [
        "caddy"
      ];
      reverse-proxy = {
        enable = config.homefree.services.landing-page.enable;
        rootDomain = true;
        subdomains = [ "www" "homefree" ];
        http-domains = [ config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        ## Shared with the manual vhost below — the eleventy build is
        ## in the closure anyway (manual.<domain> serves it in both
        ## modes). In personal mode the redir /* catch-all means
        ## file_server is never actually reached, but Caddy still
        ## requires a root.
        static-path = config.homefree.services.landing-page.path;
        public = config.homefree.services.landing-page.public;
        ## Eleventy build emits content-hashed `?v=<hash>` asset
        ## URLs via the `assetVersion` filter (see site/eleventy.config.js).
        ## `vendor-hashed` keeps no-store on HTML and unhashed paths
        ## (preserves the /nix/store epoch-mtime 304 fix) and adds
        ## long+immutable on the hashed asset URLs — the bandwidth
        ## win that lets the apex survive a HN/Reddit traffic surge.
        staticCachePolicy = "vendor-hashed";
        extraCaddyConfig =
          if projectMode
          then projectModeApexCaddyConfig
          else personalModeApexCaddyConfig;
      };
    }
    {
      label = "manual";
      name = "Manual";
      project-name = "HomeFree Manual";
      systemd-service-names = [
        "caddy"
      ];
      reverse-proxy = {
        enable = config.homefree.services.landing-page.enable;
        subdomains = [ "manual" ];
        http-domains = [ config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        ## Same Eleventy build output as the landing page, served from the
        ## same root. Mirroring the landing-page vhost guarantees shared
        ## assets (/css/, /js/, /img/) resolve identically. Manual pages
        ## live under .../manual/... on disk; try_files below hides that
        ## prefix from URLs so the manual lives at manual.<domain>/X
        ## instead of the ugly manual.<domain>/manual/X.
        static-path = config.homefree.services.landing-page.path;
        public = config.homefree.services.landing-page.public;
        ## Same cache policy as the apex landing — Eleventy emits
        ## `?v=<hash>` URLs across the whole site, including under
        ## the manual rewrite chain, so hashed assets get the long
        ## immutable cache and HTML stays no-store.
        staticCachePolicy = "vendor-hashed";
        extraCaddyConfig = ''
          ## Internal rewrite chain for the manual vhost:
          ##   1. Try the literal path first — catches shared assets
          ##      (/css/main.css, /js/landing.js, /img/...) that live at
          ##      the apex root, plus /downloads/* and anything else
          ##      Eleventy emits at the top level.
          ##   2. Fall through to /manual{path} — catches manual content
          ##      (/installation, /hardware-setup, /apps/freshrss/, etc.).
          ##   3. Fall through to /manual{path}/index.html — Eleventy
          ##      emits clean-URL directories, so / resolves to
          ##      /manual/index.html and /installation/ to
          ##      /manual/installation/index.html.
          try_files {path} /manual{path} /manual{path}/index.html
        '';
      };
    }
  ];
}
