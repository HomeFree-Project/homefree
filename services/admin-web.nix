{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.homefree;

  # Path to web-platform directory in this repository
  # This works because the whole homefree repo is in the nix store when building
  installerWebPath = ../web-platform;

  # Python environment with required packages
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    fastapi
    uvicorn
    psutil
    pyudev
    pydantic
    pyyaml
  ]);

  # Admin backend service package
  # Uses the same web-platform backend, but in admin mode
  admin-backend = pkgs.writeShellScriptBin "homefree-admin-backend" ''
    #!/usr/bin/env bash
    cd ${installerWebPath}/backend
    exec ${pythonEnv}/bin/python simple_main.py
  '';

  # Generate list of all available service names from homefree.services
  # This extracts all top-level service names that have an 'enable' option
  all-services-list = builtins.attrNames (lib.filterAttrs
    (name: value: value ? enable)
    cfg.services
  );
  all-services-json = (pkgs.formats.json {}).generate "all-services.json" all-services-list;

  # Generate service metadata map for ALL services (enabled or not)
  # This maps service labels to their display names and project names
  # First, get metadata from service-config for enabled services
  service-config-map = builtins.listToAttrs (
    map (sc: {
      name = sc.label;
      value = {
        name = sc.name;
        project-name = sc.project-name;
      };
    }) cfg.service-config
  );

  # Generate metadata for ALL services from service-options
  # This includes services that are disabled, ensuring metadata is always available
  default-service-metadata = builtins.listToAttrs (
    lib.filter (entry: entry != null) (
      map (service-name:
        let
          service-opts = cfg.service-options.${service-name} or null;
        in
        if service-opts != null && service-opts ? name && service-opts ? project-name then
          {
            name = service-opts.label or service-name;
            value = {
              name = service-opts.name;
              project-name = service-opts.project-name;
            };
          }
        else
          null
      ) all-services-list
    )
  );

  # Merge: prefer service-config metadata, fall back to defaults
  all-service-metadata = default-service-metadata // service-config-map;
  service-metadata-json = (pkgs.formats.json {}).generate "service-metadata.json" all-service-metadata;

  # Generate secrets schema for all services
  # This extracts secrets options from service-options for each service
  secrets-schema = builtins.listToAttrs (
    lib.filter (entry: entry != null) (
      map (service-name:
        let
          service-opts = cfg.service-options.${service-name} or null;
          secrets = if service-opts != null && service-opts ? secrets then service-opts.secrets else null;
        in
        if secrets != null then
          {
            name = service-opts.label or service-name;
            value = builtins.mapAttrs (secret-key: secret-opt: {
              type = secret-opt.type.name or "path";
              description = secret-opt.description or "";
              required = !(secret-opt ? default) || secret-opt.default == null;
            }) secrets;
          }
        else
          null
      ) all-services-list
    )
  );
  secrets-schema-json = (pkgs.formats.json {}).generate "service-secrets-schema.json" secrets-schema;

  # Generate service options schema
  # Automatically extracts schema from service-options definitions
  # This introspects the actual option declarations to build the schema
  # No manual maintenance required - new options are picked up automatically

  # Helper: Normalize NixOS type names to UI-friendly strings
  normalizeTypeName = typeName:
    let
      # Handle nullOr types recursively
      nullOrMatch = builtins.match "null or (.*)" typeName;
      # Handle list types recursively
      listMatch = builtins.match "list of (.*)" typeName;
    in
    if nullOrMatch != null then
      "nullOr " + (normalizeTypeName (builtins.head nullOrMatch))
    else if listMatch != null then
      "listOf " + (normalizeTypeName (builtins.head listMatch))
    else if typeName == "string" || typeName == "str" then "string"
    else if typeName == "signed integer" || typeName == "positive integer, meaning >0" then "int"
    else if typeName == "boolean" then "bool"
    else if typeName == "path" then "path"
    else typeName;

  # Helper: Check if an option should be excluded from the schema
  # (internal metadata options, not user-facing configuration)
  isInternalOption = optName:
    builtins.elem optName ["label" "name" "project-name" "secrets" "_uiSchema"];

  # Helper: Extract type name from an option definition
  getTypeName = opt:
    if opt ? type then
      if opt.type ? name then normalizeTypeName opt.type.name
      else if opt.type ? description then normalizeTypeName opt.type.description
      else "unknown"
    else "unknown";

  # Build schema by introspecting service-options for each service
  service-options-schema = builtins.listToAttrs (
    map (service-name:
      let
        service-opts = cfg.service-options.${service-name} or null;

        # Extract schema for all non-internal options
        extracted-options = if service-opts != null then
          lib.mapAttrs (optName: optDef: {
            type = getTypeName optDef;
            description = optDef.description or "";
            default = if optDef ? default then optDef.default else null;
          }) (lib.filterAttrs (optName: optDef: !(isInternalOption optName)) service-opts)
        else {};

        # Standard options present in all services (fallback if not extracted)
        default-options = {
          enable = { type = "bool"; description = "Enable this service"; default = false; };
          public = { type = "bool"; description = "Open to public on WAN port"; default = false; };
        };

        # Merge: use extracted values, fall back to defaults for enable/public
        all-options = default-options // extracted-options;
      in
      {
        name = service-name;
        value = all-options;
      }
    ) all-services-list
  );
  service-options-schema-json = (pkgs.formats.json {}).generate "service-options-schema.json" service-options-schema;

  # Generate service configuration JSON
  admin-config = {
    wanInterface = cfg.network.wan-interface;
    lanInterface = cfg.network.lan-interface;
    services =
    let
      # Include all service-configs that should be shown in admin UI
      filtered = lib.filter (service-config: service-config.admin.show == true) cfg.service-config;
      compareByName = a: b: a.name < b.name;
      sorted = builtins.sort compareByName filtered;
    in
    lib.map (service-config:
      let
        path = if service-config.admin.urlPathOverride != null then service-config.admin.urlPathOverride else "";
        # Generate URL if reverse-proxy has subdomains configured (regardless of enable state)
        hasReverseProxyConfig = (builtins.length service-config.reverse-proxy.subdomains > 0);
        subdomain = if hasReverseProxyConfig then builtins.head service-config.reverse-proxy.subdomains else "";
        domain = if hasReverseProxyConfig then (
          if (builtins.length service-config.reverse-proxy.https-domains > 0) then (builtins.head service-config.reverse-proxy.https-domains)
          else if (builtins.length service-config.reverse-proxy.http-domains > 0) then (builtins.head service-config.reverse-proxy.http-domains)
          else ""
        ) else "";
        url = if hasReverseProxyConfig && domain != "" then ''https://${subdomain}.${domain}${path}'' else "";
      in
      {
        service-config = service-config;
        url = url;
      }
    ) sorted;
  };
  config-json = (pkgs.formats.json {}).generate "admin-config.json" admin-config;

  preStart = ''
    ${pkgs.coreutils}/bin/mkdir -p /run/homefree/admin
    ${pkgs.coreutils}/bin/cp ${config-json} /run/homefree/admin/config.json
    ${pkgs.coreutils}/bin/cp ${all-services-json} /run/homefree/admin/all-services.json
    ${pkgs.coreutils}/bin/cp ${service-metadata-json} /run/homefree/admin/service-metadata.json
    ${pkgs.coreutils}/bin/cp ${secrets-schema-json} /run/homefree/admin/service-secrets-schema.json
    ${pkgs.coreutils}/bin/cp ${service-options-schema-json} /run/homefree/admin/service-options-schema.json
  '';

in
{
  # Admin service is always enabled - no enable check needed
  config = {

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
          "PATH=${lib.makeBinPath [ pkgs.nixos-rebuild pkgs.nix pkgs.git pkgs.systemd pkgs.sops pkgs.ssh-to-age ]}"
        ];

        # Prevent automatic restart during system activation
        # Admin service will be manually restarted after rebuild if it changed
        X-RestartIfChanged = false;
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
          show = true;
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
          public = cfg.services.admin.public;

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
