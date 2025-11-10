{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.homefree;

  # Path to installer-web directory in this repository
  # This works because the whole homefree repo is in the nix store when building
  installerWebPath = ../installer-web;

  # Python environment with required packages
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    fastapi
    uvicorn
    psutil
    pyudev
    pydantic
  ]);

  # Admin backend service package
  # Uses the same installer-web backend, but in admin mode
  admin-backend = pkgs.writeShellScriptBin "homefree-admin-backend" ''
    #!/usr/bin/env bash
    cd ${installerWebPath}/backend
    exec ${pythonEnv}/bin/python simple_main.py
  '';

  # Generate service configuration JSON
  admin-config = {
    wanInterface = cfg.network.wan-interface;
    lanInterface = cfg.network.lan-interface;
    services =
    let
      filtered = lib.filter (service-config: service-config.admin.show == true && service-config.reverse-proxy.enable == true) cfg.service-config;
      compareByName = a: b: a.name < b.name;
      sorted = builtins.sort compareByName filtered;
    in
    lib.map (service-config:
      let
        path = if service-config.admin.urlPathOverride != null then service-config.admin.urlPathOverride else "";
        subdomain = builtins.head service-config.reverse-proxy.subdomains;
        domain = if (builtins.length service-config.reverse-proxy.https-domains > 0) then (builtins.head service-config.reverse-proxy.https-domains)
                 else if (builtins.length service-config.reverse-proxy.http-domains > 0) then (builtins.head service-config.reverse-proxy.http-domains)
                 else "";
      in
      {
        service-config = service-config;
        url = ''https://${subdomain}.${domain}${path}'';
      }
    ) sorted;
  };
  config-json = (pkgs.formats.json {}).generate "admin-config.json" admin-config;

  preStart = ''
    ${pkgs.coreutils}/bin/mkdir -p /run/homefree/admin
    ${pkgs.coreutils}/bin/cp ${config-json} /run/homefree/admin/config.json
  '';

in
{
  config = mkIf (cfg.admin-page.enable or true) {

    # Admin API backend service
    systemd.services.admin-api = {
      description = "HomeFree Admin API Backend";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        Type = "simple";
        User = "root";
        Group = "root";
        StateDirectory = "homefree-admin";
        WorkingDirectory = "/var/lib/homefree-admin";
        ExecStartPre = [ "!${pkgs.writeShellScript "homefree-admin-prestart" preStart}" ];
        ExecStart = "${admin-backend}/bin/homefree-admin-backend";
        Restart = "always";
        RestartSec = "10s";

        # Environment
        Environment = [
          "PATH=${lib.makeBinPath [ pkgs.nixos-rebuild pkgs.nix pkgs.git pkgs.systemd ]}"
        ];
      };
    };

    # Admin UI service configuration (served by Caddy)
    homefree.service-config = [
      {
        label = "admin";
        name = "HomeFree Admin";
        project-name = "HomeFree Admin";

        systemd-service-names = [
          "admin-api"
          "caddy"
        ];

        admin = {
          show = false;  # Don't show itself in admin UI
        };

        reverse-proxy = {
          enable = true;
          description = "HomeFree Administration Interface";
          subdomains = [ "admin" ];
          http-domains = [
            "homefree.${cfg.system.localDomain}"
            cfg.system.localDomain
          ];
          https-domains = [ cfg.system.domain ] ++ cfg.system.additionalDomains;

          # Use static-path for serving files
          static-path = "${installerWebPath}/frontend";

          # Admin UI public access setting
          public = cfg.admin-page.public;

          extraCaddyConfig = ''
            # Override default behavior - proxy API first, then serve static files
            @api {
              path /api/* /health
            }
            handle @api {
              reverse_proxy localhost:8000
            }

            # Override default caching for JS/CSS - disable aggressive caching
            # This runs after the default @assets matcher, overriding those headers
            @jscss {
              path *.js *.css
            }
            header @jscss Cache-Control "no-cache, must-revalidate"
          '';
        };
      }

      # API backend (separate entry for monitoring)
      {
        label = "admin-api";
        name = "HomeFree Admin API";
        project-name = "HomeFree Admin API";

        systemd-service-names = [
          "admin-api"
          "caddy"
        ];

        admin = {
          show = false;
        };

        reverse-proxy = {
          enable = false;  # API is proxied through admin frontend
        };
      }
    ];
  };
}
