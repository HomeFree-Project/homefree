{ config, pkgs, ... }:
let
  homefree-site = pkgs.callPackage ./site { };
  downloadsDir = "/var/lib/homefree/downloads";
  projectMode = config.homefree.system.project-mode;
  domain = config.homefree.system.domain;

  ## Apex Caddy config when project-mode = true (the upstream
  ## homefree.host marketing instance). Keeps the original behavior:
  ## Matrix .well-known, /downloads/*, and a redirect for /manual/*
  ## back to manual.<domain>.
  projectModeApexCaddyConfig = ''
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
  personalModeApexCaddyConfig = ''
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
