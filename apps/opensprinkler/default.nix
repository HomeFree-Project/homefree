{ config, lib, pkgs, ... }:
##
## OpenSprinkler UI — self-hosted, offline replacement for
## ui.opensprinkler.com.
##
## Newer OpenSprinkler firmware (ver 2.2.x) ships only a tiny HTML shell
## on the controller and loads the actual web UI (~4 MB of JS/CSS) from
## the vendor CDN https://ui.opensprinkler.com/js/home.js. That breaks
## HomeFree's no-external-requests promise (AGENTS.md rule 8) and leaves
## the controller useless if the CDN or WAN is down.
##
## OpenSprinkler makes the UI location configurable (the controller's
## `/su` page sets the "Javascript path", default
## https://ui.opensprinkler.com/js). This app vendors a mirror of that
## UI under ./ui (git-tracked, see ui/PROVENANCE.txt) and serves it as a
## static site on its own `*.<domain>` subdomain. home.js derives its
## base URL from its own <script> src, so once the controller's JS path
## points here it loads every sibling asset from THIS host — fully
## offline, no CDN, and (being a `*.<domain>` origin) already inside the
## controller page's Content-Security-Policy, so no CSP relaxation is
## needed.
##
## This app only HOSTS the UI. The controller itself stays an
## instance-level external-proxy entry (its LAN address is
## instance-specific — AGENTS.md rule 12). After enabling this app, set
## the controller's `/su` Javascript path to
## https://<subdomain>.<domain>/js and clear any `extra-csp-sources`
## stopgap on the controller's proxy entry.
##
let
  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Serve the OpenSprinkler web UI locally so the controller no
        longer loads it from ui.opensprinkler.com. After enabling, point
        the controller's `/su` Javascript path at
        https://<subdomain>.<domain>/js.
      '';
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Expose the UI host on the WAN interface (off = LAN only)";
    };

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "opensprinkler-ui";
      description = ''
        Subdomain the UI assets are served from. The controller's
        Javascript path must be set to https://<subdomain>.<domain>/js.
      '';
    };

    enable-maps = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Allow the OpenSprinkler UI's optional station-location map to
        load. The map (js/map.js, shown in an iframe from this host)
        pulls Google Maps at runtime, so this opens THIS vhost's CSP to
        the Google Maps origins. Default off keeps the app's no-external-
        requests promise intact (AGENTS.md rule 8) for everyone who does
        not use the map.

        This only covers the map iframe. The reverse-geocode feature in
        Options runs in the controller's OWN page context, so for that to
        work you must also add https://maps.googleapis.com to the
        controller proxy entry's "CSP Allow" (extra-csp-sources) field.

        Leave off unless you actually use the location map; Google Maps
        pulls from several hosts, so enabling it is a real (and broad)
        rule-8 exception scoped to this one subdomain.
      '';
    };
  };

  domain = config.homefree.system.domain;
  localDomain = config.homefree.system.localDomain;
  cfg = config.homefree.service-options.opensprinkler-ui;

  ## Origins the Google Maps JS API and its tiles/markers/fonts load
  ## from. Broad wildcards are unavoidable — Maps fans out across many
  ## googleapis/gstatic subdomains (khms*, maps, fonts, ...). Appended to
  ## this vhost's script/style/img/font/connect-src ONLY when
  ## enable-maps is set; see the reverse-proxy block below.
  mapsCspSources = [
    "https://*.googleapis.com"
    "https://*.gstatic.com"
    "https://maps.google.com"
  ];

  ## Served root = the vendored CDN mirror (./ui) plus our own setup page
  ## dropped in as _hf-setup.html. Keeping ./landing separate from ./ui
  ## leaves the mirror a faithful, re-crawlable copy (nothing of ours
  ## mixed in) while still serving both from one directory so a simple
  ## `rewrite` can surface the setup page at `/`.
  uiRoot = pkgs.runCommand "opensprinkler-ui-root" { } ''
    mkdir -p "$out"
    cp -r ${./ui}/. "$out"/
    chmod -R u+w "$out"
    cp ${./landing/index.html} "$out"/_hf-setup.html
  '';
in
{
  options.homefree.services.opensprinkler-ui = userOptions;
  options.homefree.service-options.opensprinkler-ui = userOptions // {
    label = lib.mkOption {
      type = lib.types.str;
      default = "opensprinkler-ui";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "OpenSprinkler UI";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "OpenSprinkler-App";
      internal = true;
      description = "Project name";
    };
  };

  config = {
    homefree.service-config = [{
      inherit (cfg) label name project-name;
      enable = cfg.enable;

      ## Host app (vendored static UI, no OCI image): current version is
      ## the mirrored UI release (see ui/PROVENANCE.txt); latest comes
      ## from upstream GitHub Releases. Bump current-version in lockstep
      ## with the vendored ui/ snapshot.
      version-tracking = {
        strategy = "github-releases";
        repo = "OpenSprinkler/OpenSprinkler-App";
        current-version = "2.4.1";
      };

      ## Caddy serves the static assets directly; there is no backend
      ## process. Track caddy for restart/health like other static
      ## entries (services/landing-page).
      systemd-service-names = [ "caddy" ];

      sso = {
        ## Static, open-source UI assets — no auth surface. The
        ## controller loads home.js cross-origin via a <script> tag, and
        ## an SSO redirect on the asset host would break that load.
        ## Access to the operator-facing UI is governed on the
        ## controller's own page vhost, not here.
        kind = "none";
        applicable = false;
      };

      reverse-proxy = {
        enable = cfg.enable;
        subdomains = [ cfg.subdomain ];
        http-domains = [ "homefree.lan" localDomain ];
        https-domains = [ domain ];
        public = cfg.public;

        ## Vendored mirror of ui.opensprinkler.com (see ui/PROVENANCE.txt),
        ## merged with our setup page (_hf-setup.html) — see uiRoot above.
        static-path = uiRoot;

        ## Only when the operator opts into the location map: widen this
        ## vhost's CSP to the Google Maps origins so the map.html iframe
        ## can load. Empty (no widening) by default — rule 8 stays intact
        ## for everyone who leaves the map off.
        extra-csp-sources = lib.optionals cfg.enable-maps mapsCspSources;

        extraCaddyConfig = ''
          ## home.js fetches modules.json (and other data) via XHR.
          ## Because the controller's page origin differs from this asset
          ## host, that cross-origin read needs CORS. Scripts/CSS load via
          ## tag injection (no CORS needed), but the JSON/data fetches do,
          ## and OpenSprinkler's own self-hosting guide specifies
          ## Access-Control-Allow-Origin: *.
          header Access-Control-Allow-Origin "*"

          ## Show a human-facing setup page at the root. The controller
          ## never requests `/` (it loads /js/home.js directly), so this
          ## only affects a person browsing to this host. `path /` is an
          ## EXACT match, so the vendored app shell (/index.html) and all
          ## assets (/js/*, /css/*, ...) fall through untouched. `rewrite`
          ## is ordered before `file_server`, so this needs no `handle`
          ## wrapper and can't be bypassed by directive ordering.
          @osui_setup path /
          rewrite @osui_setup /_hf-setup.html
        '';
      };

      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Serve the OpenSprinkler web UI locally so the controller no longer loads it from ui.opensprinkler.com";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make the UI host accessible from WAN";
        }
        {
          path = "enable-maps";
          type = "bool";
          default = false;
          description = "Allow the optional station-location map (opens this vhost's CSP to Google Maps; reverse-geocode in Options also needs https://maps.googleapis.com on the controller proxy entry's CSP Allow)";
        }
        {
          path = "subdomain";
          type = "string";
          default = "opensprinkler-ui";
          description = "Subdomain serving the UI; set the controller's /su Javascript path to https://<subdomain>.<domain>/js";
        }
      ];
    }];
  };
}
