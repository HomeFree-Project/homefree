{ config, lib, pkgs, ... }:
let
  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Radicale CalDAV/CardDAV service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };
  };

  version = "3.6.1.0";
  containerDataPath = "/var/lib/radicale-podman";
  port = 5232;

  ## Radicale 3.5+ supports an `oauth2` auth type which POSTs the
  ## user-supplied Basic credentials to an OAuth2 token endpoint
  ## (Resource Owner Password Credentials grant) and grants access
  ## iff the endpoint returns 200. Zitadel doesn't support ROPC
  ## directly, so we point Radicale at the in-house
  ## zitadel-password-shim (services/zitadel-password-shim.nix)
  ## which wraps Zitadel's Session V2 API to do the same job.
  ##
  ## Net effect: Radicale's web UI and every DAV client validates
  ## the user's homefree username + password against Zitadel — no
  ## second credential, no second login.
  shimUrl = "http://${config.homefree.network.lan-address}:${toString config.homefree.service-options.zitadel-password-shim.listen-port}/token";

  ## Static Radicale config. Mounted read-only into /config. The
  ## tomsquest image consumes everything under /config; we override
  ## the auth section only and rely on package defaults for storage,
  ## logging, and the rest.
  radicaleConfig = pkgs.writeText "radicale-config" ''
    [server]
    hosts = 0.0.0.0:5232

    [auth]
    type = oauth2
    oauth2_token_endpoint = ${shimUrl}
    ## Radicale 3.6 only accepts oauth2_token_endpoint in [auth];
    ## the client_id is hardcoded to "radicale" in the source and
    ## no client_secret is sent. The shim ignores both anyway.
    ##
    ## Cache successful auth for 5 minutes so a single DAV sync burst
    ## (PROPFIND -> REPORT -> GET -> ...) only hits Zitadel once.
    ## Failures cached for 1 minute to slow brute-force scanners.
    ## Default success TTL is 15s which is too short for typical
    ## sync windows.
    cache_logins = true
    cache_successful_logins_expiry = 300
    cache_failed_logins_expiry = 60

    [storage]
    filesystem_folder = /data/collections

    [logging]
    level = info
  '';

  preStart = ''
    mkdir -p ${containerDataPath}
    mkdir -p ${containerDataPath}/collections
    ## The tomsquest image runs as uid 2999. Make the data dir
    ## writable by that user.
    chown -R 2999:2999 ${containerDataPath} || true
    ## Replace the in-image config with ours on every boot so a
    ## config change in this .nix file lands without manual editing.
    install -m 644 ${radicaleConfig} ${containerDataPath}/config
  '';
in
{
  options.homefree.services.radicale = userOptions;
  options.homefree.service-options.radicale = userOptions // {
    label = lib.mkOption {
      type = lib.types.str;
      default = "radicale";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Contacts/Calendar (CalDAV/CardDAV)";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Radicale";
      internal = true;
      description = "Project name";
    };
  };

  config = {
  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.radicale.enable {
    radicale = {
      image = "tomsquest/docker-radicale:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:5232"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}:/data"
        ## Mount our generated config OVER the in-image default. The
        ## image expects /config to be a directory containing a file
        ## called `config` — we provide just that file.
        "${containerDataPath}/config:/config/config:ro"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
      };
    };
  };

  systemd.services.podman-radicale = lib.optionalAttrs config.homefree.service-options.radicale.enable  {
    after = [
      "dns-ready.service"
      "zitadel-password-shim.service"
    ];
    wants = [ "zitadel-password-shim.service" "dns-ready.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "radicale-prestart" preStart}" ];
    };
  };

  ## Radicale's `auth.type = oauth2` validates DAV-client credentials
  ## against the zitadel-password-shim. Register as a shim consumer so
  ## the shim's systemd unit runs whenever Radicale is enabled.
  homefree.service-options.zitadel-password-shim.consumers =
    lib.optionals config.homefree.service-options.radicale.enable [ "radicale" ];

    homefree.service-config = [{
      inherit (config.homefree.service-options.radicale) label name project-name;
      enable = config.homefree.service-options.radicale.enable;
      systemd-service-names = [
        "podman-radicale"
        "zitadel-password-shim"
      ];
      sso = {
        ## Native-OIDC-style flow: Radicale auth.type=oauth2 validates
        ## the user's homefree username+password against Zitadel via
        ## the local zitadel-password-shim. No Caddy gate — the auth
        ## happens inside Radicale on every request (DAV + web UI).
        kind = "native_oidc";
        ## Dev context (intentionally not surfaced in the admin UI):
        ## Uses Zitadel credentials directly via the
        ## zitadel-password-shim. Both the web UI and DAV clients
        ## (Thunderbird, iOS Calendar, etc.) authenticate with your
        ## homefree username + password.
      };
      reverse-proxy = {
        enable = config.homefree.service-options.radicale.enable;
        subdomains = [ "radicale" "dav" "caldav" "carddav" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.radicale.public;
        ## NOT SSO-gated at the Caddy layer. Radicale's built-in
        ## auth.type=oauth2 (via the shim) makes Caddy gating
        ## redundant AND breaks the UX (it would force a 2nd login).
        ## See sso.notes above.
      };
      backup = {
        paths = [
          containerDataPath
        ];
      };
      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable Radicale CalDAV/CardDAV service";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make service accessible from WAN";
        }
      ];
    }];
  };
}
