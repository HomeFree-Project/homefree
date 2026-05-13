{ config, pkgs, ... }:
let
  homefree-site = pkgs.callPackage ./site { };
  downloadsDir = "/var/lib/homefree/downloads";
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
        static-path = config.homefree.services.landing-page.path;
        public = config.homefree.services.landing-page.public;
        extraCaddyConfig = ''
          # Matrix Synapse settings
          header /.well-known/matrix/* Content-Type application/json
          header /.well-known/matrix/* Access-Control-Allow-Origin *
          respond /.well-known/matrix/server `{"m.server": "matrix.${config.homefree.system.domain}:443"}`
          respond /.well-known/matrix/client `{"m.homeserver":{"base_url":"https://matrix.${config.homefree.system.domain}"}}`
          ## No identity server
          # respond /.well-known/matrix/client `{"m.homeserver":{"base_url":"https://matrix.${config.homefree.system.domain}"},"m.identity_server":{"base_url":"https://identity.${config.homefree.system.domain}"}}`

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
          redir /manual https://manual.${config.homefree.system.domain}/ 302
          redir /manual/* https://manual.${config.homefree.system.domain}{uri} 302
        '';
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
