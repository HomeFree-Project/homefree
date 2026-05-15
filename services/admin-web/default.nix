{ config, lib, pkgs, options, ... }:

with lib;

let
  cfg = config.homefree;

  # Path to web-platform directory in this repository
  # This works because the whole homefree repo is in the nix store when building
  installerWebPath = ../../web-platform;

  # Python environment with required packages
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    fastapi
    uvicorn
    psutil
    pyudev
    pydantic
    pyyaml
    babel
    httpx
    ## GeoIP lookups for the Abuse Blocking page's traffic-source
    ## table. Reads the DB-IP mmdb maintained by modules/geoip.nix.
    geoip2
  ]);

  # Admin backend service package
  # Uses the same web-platform backend, but in admin mode
  admin-backend = pkgs.writeShellScriptBin "homefree-admin-backend" ''
    #!/usr/bin/env bash
    cd ${installerWebPath}/backend
    exec ${pythonEnv}/bin/python simple_main.py
  '';

  # Generate list of all available service labels (not option names)
  # This extracts labels from service option definitions
  all-services-list = lib.filter (label: label != null) (
    lib.mapAttrsToList (optName: optDef:
      if optDef ? enable then
        # Try to get label from option definition's default value
        (if optDef ? label && optDef.label ? default
         then optDef.label.default
         else optName)
      else null
    ) options.homefree.service-options
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
      # Service secrets from service-options
      (map (service-name:
        let
          service-opts = cfg.service-options.${service-name} or null;
          service-opts-def = options.homefree.service-options.${service-name};

          # Check if secrets option exists and is not marked as internal
          hasSecrets = service-opts != null && service-opts ? secrets;
          secretsOption = if service-opts-def ? secrets then service-opts-def.secrets else null;
          secretsInternal = if secretsOption != null then (secretsOption.internal or false) else false;

          # Per-field UI-visibility filter: drop secrets whose
          # mkOption declaration sets `visible = false` or
          # `internal = true`. Used to hide auto-provisioned
          # secrets while leaving the option intact for the service
          # module to consume. Most auto-provisioned secrets don't
          # need an option declaration at all — the service writes
          # them directly to /var/lib/homefree-secrets/<svc>/<key>
          # and reads them via preStart. This filter is a safety
          # net for cases where the option must exist (e.g. to feed
          # a Nix-config-consuming downstream).
          #
          # `secretsOption` here is a plain attrset of children
          # (`secrets = { foo = mkOption {...}; }` — NOT wrapped in
          # mkOption itself), so we read child attrs directly. Each
          # child is an option declaration with `.visible` /
          # `.internal` / `.type` / `.description` / etc.
          isFieldHidden = key:
            let opt = (secretsOption.${key} or {}); in
            (opt.visible or true) == false || (opt.internal or false);

          secrets =
            if hasSecrets && !secretsInternal
            then lib.filterAttrs (k: _: !(isFieldHidden k)) service-opts.secrets
            else null;
        in
        if secrets != null && secrets != {} then
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
      ) all-services-list)
      # Add backup secrets as a special case
      ++ [
        (let
          backupSecrets = cfg.backups.secrets or null;
          backupSecretsDef = options.homefree.backups.secrets;
        in
        if backupSecrets != null then
          {
            name = "backup";
            value = builtins.mapAttrs (secret-key: secret-opt: {
              type = secret-opt.type.name or "str";
              description = secret-opt.description or "";
              required = !(secret-opt ? default) || secret-opt.default == null;
            }) backupSecrets;
          }
        else
          null)
      ]
    )
  );
  secrets-schema-json = (pkgs.formats.json {}).generate "service-secrets-schema.json" secrets-schema;

  # Generate service options schema by extracting metadata from option definitions
  # This reads directly from options.homefree.service-options.* to get type, default, etc.
  # Custom attributes (ui-hint, category) are attached via // operator in service files

  # Helper function to extract full type string from an option
  getTypeName = opt:
    let
      typeName = opt.type.name or "unknown";
      # For wrapped types (nullOr, listOf, etc), access the wrapped type via nestedTypes.elemType
      wrappedType =
        if opt.type ? nestedTypes && opt.type.nestedTypes ? elemType then
          opt.type.nestedTypes.elemType
        else
          null;
      wrappedName = if wrappedType != null then (wrappedType.name or "unknown") else null;
    in
      # Handle composite types
      if typeName == "nullOr" && wrappedName != null then
        "nullOr ${wrappedName}"
      else if typeName == "listOf" && wrappedName != null then
        "listOf ${wrappedName}"
      else if typeName == "attrsOf" && wrappedName != null then
        "attrsOf ${wrappedName}"
      else
        typeName;

  # Helper function to extract metadata from an option definition
  optionToSchema = opt: {
    type = getTypeName opt;
    description = opt.description or "";
    default = opt.default or null;
    required = !(opt ? default);
    category = opt.category or "basic";
    ui-hint = opt.ui-hint or null;
    submodule-fields =
      let
        typeName = getTypeName opt;
        # Check if this is a submodule type
        isSubmodule = typeName == "submodule" || typeName == "listOf submodule" || typeName == "nullOr submodule";
        # For submodules, extract their nested options
        # Handle listOf submodule by getting the inner submodule type
        submoduleType =
          if opt.type.name == "listOf" && opt.type ? nestedTypes && opt.type.nestedTypes ? elemType then
            opt.type.nestedTypes.elemType
          else if opt.type.name == "nullOr" && opt.type ? nestedTypes && opt.type.nestedTypes ? elemType then
            opt.type.nestedTypes.elemType
          else
            opt.type;
        subOpts = if isSubmodule && (submoduleType ? getSubOptions) then
          (submoduleType.getSubOptions [])
        else {};
      in
        if isSubmodule && subOpts != {} then
          let
            # Filter out internal NixOS fields like _module
            subOptNames = lib.filter (name: name != "_module") (builtins.attrNames subOpts);
          in
          (map (subOptName:
            let subOpt = subOpts.${subOptName};
            in {
              path = subOptName;
              type = getTypeName subOpt;
              description = subOpt.description or "";
              default = subOpt.default or null;
              required = !(subOpt ? default);
              ui-hint = subOpt.ui-hint or null;
            }
          ) subOptNames)
        else null;
  };

  # Helper function to convert metadata entry to schema format (for services with options-metadata)
  # Recursively processes nested submodules
  metadataToSchema = metadata: {
    type = if (metadata.nullable or false) then "nullOr ${metadata.type}" else metadata.type;
    description = metadata.description or "";
    default = metadata.default or null;
    required = metadata.required or false;
    category = metadata.category or "basic";
    ui-hint = metadata.ui-hint or null;
    enum-values = metadata.enum-values or null;
    "sops-managed" = metadata."sops-managed" or false;
    submodule-fields =
      let subfields = metadata.submodule-fields or null;
      in if subfields != null then
        (map (field:
          let
            hasNestedSubmodule = field ? submodule-fields && field.submodule-fields != null;
            nestedFields = if hasNestedSubmodule then
              (map (nestedField: {
                path = nestedField.path;
                type = if (nestedField.nullable or false) then "nullOr ${nestedField.type}" else nestedField.type;
                description = nestedField.description or "";
                default = nestedField.default or null;
                required = nestedField.required or false;
                ui-hint = nestedField.ui-hint or null;
                enum-values = nestedField.enum-values or null;
                "sops-managed" = nestedField."sops-managed" or false;
              }) field.submodule-fields)
            else null;
          in {
            path = field.path;
            type = if (field.nullable or false) then "nullOr ${field.type}" else field.type;
            description = field.description or "";
            default = field.default or null;
            required = field.required or false;
            ui-hint = field.ui-hint or null;
            enum-values = field.enum-values or null;
            "sops-managed" = field."sops-managed" or false;
            submodule-fields = nestedFields;
          }
        ) subfields)
      else null;
  };

  # Extract metadata from ALL services using HYBRID approach:
  # 1. If service has options-metadata defined, use that (preserves complex types)
  # 2. Otherwise, auto-extract from option definitions (for simpler services)
  all-service-option-names = builtins.attrNames options.homefree.service-options;

  service-options-schema = builtins.listToAttrs (
    lib.filter (entry: entry != null) (
      map (service-option-name:
        let
          # Get the option definitions for this service
          service-opts-def = options.homefree.service-options.${service-option-name};
          # Get the config values for this service
          service-opts-cfg = cfg.service-options.${service-option-name} or null;
          # Use label from config if available, otherwise use option name
          label = if service-opts-cfg != null && service-opts-cfg ? label
                  then service-opts-cfg.label
                  else service-option-name;

          # Check if service has options-metadata defined
          # First check in service-options (MediaWiki, Minecraft)
          # Then check in service-config (Frigate) - which is a LIST, not attrset
          hasMetadataInOpts = service-opts-def ? options-metadata;
          metadataFromOpts = if hasMetadataInOpts then service-opts-def.options-metadata.default or [] else [];

          # Search service-config list for matching label
          serviceConfigEntry = lib.findFirst (entry: entry.label == label) null cfg.service-config;
          hasMetadataInConfig = serviceConfigEntry != null && serviceConfigEntry ? options-metadata;
          metadataFromConfig = if hasMetadataInConfig then serviceConfigEntry.options-metadata or [] else [];

          # Prefer service-options metadata, fall back to service-config
          hasMetadata = hasMetadataInOpts || hasMetadataInConfig;
          metadata = if metadataFromOpts != [] then metadataFromOpts else metadataFromConfig;
        in
        # Only include services that have an enable option
        if service-opts-def ? enable then
          if hasMetadata && metadata != [] then
            # Use options-metadata (for Frigate, MediaWiki, Minecraft, etc.)
            {
              name = label;
              value = builtins.listToAttrs (
                map (opt: {
                  name = opt.path;
                  value = metadataToSchema opt;
                }) metadata
              );
            }
          else
            # Auto-extract from option definitions (for simpler services)
            let
              # Get all option names, filtering out internal options, secrets, and _module
              optNames = builtins.attrNames service-opts-def;
              visibleOpts = lib.filter (name:
                let opt = service-opts-def.${name};
                in !(opt.internal or false) && name != "secrets" && name != "_module"
              ) optNames;
            in
            if visibleOpts != [] then
              {
                name = label;
                value = builtins.listToAttrs (
                  map (optName: {
                    name = optName;
                    value = optionToSchema service-opts-def.${optName};
                  }) visibleOpts
                );
              }
            else
              null
        else
          null
      ) all-service-option-names
    )
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

  # Per-service icons for the home.<domain> app launcher (and any
  # future admin UI that wants them). Sources, in priority order:
  #
  #   1. Per-service `icon = <path>` override on service-config.
  #      Wins over (2). Useful for third-party service modules that
  #      ship their own icon, or for child instances (mediawiki_*,
  #      minecraft_*) that want a different icon than the parent.
  #
  #   2. Convention: apps/<service-label>/icon.svg, the bundled SVG
  #      that ships next to each app's default.nix. Discovered at
  #      eval time by scanning apps/*/icon.svg.
  #
  # The discovery walks apps/ rather than each service-config entry
  # so a service module's directory name effectively becomes its
  # icon key. Service modules whose label doesn't match their
  # directory name (rare — see apps/zitadel which declares both
  # `zitadel` and `oauth2proxy` labels) need an explicit `icon = ./icon.svg`
  # on the service-config to pick the icon up.
  #
  # All resolved icons land at /run/homefree/admin/icons/<label>.<ext>
  # at runtime, and Caddy serves them from /icons/* on home + admin
  # vhosts. The frontend hard-codes ".svg" in its URL template; any
  # other extension simply 404s and the initial-letter fallback in
  # user-app.js takes over.
  appsDir = ../../apps;
  service-icons-pkg =
    let
      # (1) Explicit per-service overrides from service-config.
      explicitOverrides = builtins.listToAttrs (lib.map
        (sc: { name = sc.label; value = sc.icon; })
        (lib.filter (sc: (sc.icon or null) != null) cfg.service-config));

      # (2) Convention scan: apps/<dir>/icon.svg, keyed by <dir>.
      appDirsWithIcon =
        if builtins.pathExists appsDir
        then
          let
            entries = builtins.readDir appsDir;
            dirs = lib.filterAttrs (n: t: t == "directory") entries;
            withIcon = lib.filterAttrs
              (dir: _:
                builtins.pathExists "${appsDir}/${dir}/icon.svg")
              dirs;
          in
          lib.mapAttrs' (dir: _: {
            name = dir;
            value = "${appsDir}/${dir}/icon.svg";
          }) withIcon
        else { };

      # Overrides win, then conventions, by left-precedence in //.
      resolved = appDirsWithIcon // explicitOverrides;

      copyLines = lib.concatStringsSep "\n" (lib.mapAttrsToList
        (label: src:
          let n = baseNameOf (toString src);
              dot = lib.strings.match ".*(\\.[^.]+)$" n;
              ext = if dot != null then builtins.head dot else "";
          in ''cp ${src} "$out/${label}${ext}"'')
        resolved);
    in
    pkgs.runCommand "homefree-service-icons" {} ''
      mkdir -p $out
      ${copyLines}
    '';

  preStart = ''
    ${pkgs.coreutils}/bin/mkdir -p /run/homefree/admin
    ${pkgs.coreutils}/bin/cp ${config-json} /run/homefree/admin/config.json
    ${pkgs.coreutils}/bin/cp ${all-services-json} /run/homefree/admin/all-services.json
    ${pkgs.coreutils}/bin/cp ${service-metadata-json} /run/homefree/admin/service-metadata.json
    ${pkgs.coreutils}/bin/cp ${secrets-schema-json} /run/homefree/admin/service-secrets-schema.json
    ${pkgs.coreutils}/bin/cp ${service-options-schema-json} /run/homefree/admin/service-options-schema.json

    # Icons. rm+ln keeps the live path stable across rebuilds even
    # though the underlying derivation hash changes.
    ${pkgs.coreutils}/bin/rm -rf /run/homefree/admin/icons
    ${pkgs.coreutils}/bin/ln -s ${service-icons-pkg} /run/homefree/admin/icons
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

      ## restartIfChanged = false used to live here, with a separate
      ## activation script (`reconcile-admin-api`, below) that did a
      ## deferred systemd-run restart. That introduced a 15-20s
      ## window post-rebuild where the OLD admin-api kept serving
      ## requests with stale code — and the same auto-restart
      ## mechanism we needed for code-only changes is what NixOS
      ## already does natively when `restartIfChanged` is the
      ## default (true).
      ##
      ## Letting NixOS restart admin-api on activation is now safe
      ## because the rebuild itself runs in a transient unit
      ## (homefree-rebuild.service, see nix_operations.py) owned by
      ## PID 1 — admin-api going down mid-rebuild doesn't kill the
      ## rebuild. The HTTP response to /api/rebuild dies, but the
      ## frontend's polling on /api/config/rebuild-status picks it
      ## up again as soon as the new admin-api is up (~2s).

      serviceConfig = {
        Type = "simple";
        User = "root";
        Group = "root";
        StateDirectory = "homefree-admin";
        WorkingDirectory = "/var/lib/homefree-admin";
        ExecStart = "${admin-backend}/bin/homefree-admin-backend";
        Restart = "always";
        RestartSec = "10s";

        # Stop only the main process, not the entire control group. The
        # rebuild now runs in its own transient systemd unit
        # (homefree-rebuild.service) launched via systemd-run, so admin-api
        # stopping should never affect it. KillMode=process is belt-and-
        # suspenders for any other detached helpers we spawn.
        KillMode = "process";

        # Environment
        # NB: coreutils + standard userspace tools are needed because the
        # rebuild we spawn (nixos-rebuild-ng) shells out to bare commands like
        # `test`, `mkdir`, `cat`, etc. without absolute paths. systemd-run
        # inherits this PATH into the transient unit, so anything missing
        # here will fail mid-rebuild with [Errno 2] No such file or directory.
        Environment = [
          "PATH=${lib.makeBinPath [
            pkgs.nixos-rebuild
            pkgs.nix
            pkgs.git
            pkgs.systemd
            pkgs.sops
            pkgs.ssh-to-age
            pkgs.coreutils
            pkgs.bash
            pkgs.gnused
            pkgs.gnugrep
            pkgs.findutils
            ## chpasswd, used by the OS password sync in
            ## /api/users/me/password and /api/users/{id}/password
            ## (Zitadel→OS direction). The PAM bridge handles the
            ## reverse OS→Zitadel direction.
            pkgs.shadow
            ## fail2ban-client + nft, used by resolvers/abuse_blocking.py
            ## to read jail status, nftables sets, and run targeted
            ## unbans. Without these on PATH the Abuse Blocking page
            ## shows the layer as Down even when fail2ban is happily
            ## running under systemd.
            pkgs.fail2ban
            pkgs.nftables
          ]}"
          # Path of the served frontend bundle, used by the closure-id
          # endpoint. Embeds the nix-store hash, so it changes IFF the
          # frontend itself changed (not on every unrelated rebuild).
          "HOMEFREE_FRONTEND_PATH=${installerWebPath}/frontend"
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
          show = true;
        };

        sso = {
          kind = "caddy_gated";
          notes = "HomeFree admin UI itself — Caddy SSO gate enforces oauth2-proxy + homefree-admin role.";
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

          ## Gate the admin UI behind oauth2-proxy. The actual gate
          ## runs at request time inside Caddy via a `file` matcher
          ## on /var/lib/homefree-secrets/.sso-provisioned (see
          ## services/caddy.nix's @no_auth matcher) — that way a
          ## fresh install doesn't lock the user out before the
          ## sentinel exists, AND doesn't require a second rebuild
          ## to flip oauth2 on after provisioning lands.
          ##
          ## Honour the per-service.admin.enable opt-out for
          ## environments that don't want SSO on the admin UI even
          ## once provisioned.
          oauth2 = cfg.sso.per-service.admin.enable or true;
          ## Admin UI is the central control panel — strictly
          ## restricted to users with the homefree-admin project
          ## role. Caddy chains oauth2-proxy then admin-api's
          ## /api/auth/admin-check; non-admin authenticated users
          ## get a 403 at the gate.
          ##
          ## NOTE: the admin-api ALSO performs the same role check
          ## in its middleware as a defense-in-depth layer, but the
          ## Caddy gate is what catches the failure cleanly — so
          ## the user lands on a clear 403 page rather than seeing
          ## the SPA boot and then bailing in-app.
          require-admin-role = cfg.sso.per-service.admin.enable or true;

          extraCaddyConfig = ''
            # Service state endpoint - always available (served directly by Caddy)
            handle /api/service-state {
              root * /var/lib/homefree-admin
              try_files service-state.json
              file_server
            }

            # Per-service icons for the app launcher. Aggregated at
            # eval time from each service-config's `icon` path (see
            # service-icons-pkg above) and exposed at /run/homefree/
            # admin/icons. Same handler served from admin.<domain>
            # and home.<domain> so both can use them.
            handle_path /icons/* {
              root * /run/homefree/admin/icons
              file_server
            }

            # Override default behavior - proxy API first, then serve static files
            @api {
              path /api/* /health
            }
            handle @api {
              reverse_proxy localhost:8000 {
                # Handle backend unavailability gracefully
                @backend_down status 502 503 504
                handle_response @backend_down {
                  # Serve state file when backend is down
                  root * /var/lib/homefree-admin
                  rewrite * /service-state.json
                  file_server
                }
              }
            }

            # Disable caching entirely for the admin UI's static files.
            # The frontend is served straight from /nix/store, where every
            # file has mtime=epoch (1970-01-01) and Caddy's file_server
            # generates an empty/identical ETag. Combined with
            # `Cache-Control: no-cache` (which only requires revalidation,
            # not skipping the cache), the browser sends `If-None-Match: ""`
            # + `If-Modified-Since: epoch`, Caddy returns 304, and the
            # browser serves the OLD cached file even after a rebuild —
            # nothing short of shift+reload picks up new JS.
            #
            # `no-store` forces a fresh fetch every time and side-steps
            # the validation entirely. Cost is trivial on a LAN; benefit
            # is "Refresh" actually works.
            @adminstatic {
              path *.js *.css *.html *.svg *.png *.woff *.woff2
            }
            header @adminstatic {
              Cache-Control "no-store"
              -ETag
              -Last-Modified
            }
          '';
        };
      }

      ## Per-user dashboard (home.<domain>). Same frontend tree as the
      ## admin UI — the SPA dispatches between admin-app and user-app
      ## by hostname (see web-platform/frontend/src/app.js). Same
      ## admin-api backend, reached via the same /api/* proxy. The
      ## difference is the Caddy auth gate: oauth2-proxy is required,
      ## but the homefree-admin role is NOT — any authenticated user
      ## can see their dashboard.
      ##
      ## Backend self-service endpoints (/api/users/me/*,
      ## /api/services/visible-to-me) must be allowed through the
      ## TrustedHeaderAuthMiddleware's admin-role gate so non-admins
      ## can hit them. See SELF_SERVICE_PATHS in simple_main.py.
      {
        label = "home";
        name = "HomeFree Dashboard";
        project-name = "HomeFree Dashboard";

        systemd-service-names = [
          "admin-api"
          "caddy"
        ];

        admin = {
          show = false;
        };

        sso = {
          kind = "caddy_gated";
          notes = "Per-user dashboard — oauth2-proxy gate only, no admin role required.";
        };

        reverse-proxy = {
          enable = true;
          description = "HomeFree Per-user Dashboard";
          subdomains = [ "home" ];
          http-domains = [
            "homefree.${cfg.system.localDomain}"
            cfg.system.localDomain
          ];
          https-domains = [ cfg.system.domain ] ++ cfg.system.additionalDomains;

          ## Same on-disk frontend bundle as admin; the SPA chooses
          ## which app to mount based on window.location.hostname.
          static-path = "${installerWebPath}/frontend";

          public = cfg.services.admin.public;

          ## oauth2-proxy gate, same sentinel-based bootstrap as admin.
          oauth2 = cfg.sso.per-service.home.enable or true;
          ## Critical difference vs admin: NO admin-role check. Every
          ## authenticated Zitadel user can reach their dashboard.
          require-admin-role = false;

          extraCaddyConfig = ''
            # Service state endpoint - always available (served directly by Caddy)
            handle /api/service-state {
              root * /var/lib/homefree-admin
              try_files service-state.json
              file_server
            }

            # Per-service icons for the app launcher. Same source
            # directory and handler shape as admin.<domain>'s
            # /icons block so the two surfaces agree on what an
            # icon URL means.
            handle_path /icons/* {
              root * /run/homefree/admin/icons
              file_server
            }

            # Proxy /api/* and /health to the shared admin-api backend.
            # The backend's TrustedHeaderAuthMiddleware will enforce
            # which paths a non-admin user can hit — admin-only routes
            # still return 403, self-service routes pass through.
            @api {
              path /api/* /health
            }
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

            # Same no-store caching policy as admin: /nix/store mtimes
            # are epoch, ETags collide across rebuilds; no-store forces
            # a fresh fetch each time so refresh actually works.
            @userstatic {
              path *.js *.css *.html *.svg *.png *.woff *.woff2
            }
            header @userstatic {
              Cache-Control "no-store"
              -ETag
              -Last-Modified
            }
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

    # Activation script to copy admin config files
    # This runs during activation but doesn't change the admin-api unit file
    # so it won't trigger a restart when only service configs change
    system.activationScripts.setup-admin-config = {
      text = preStart;
      deps = [];
    };

    ## NOTE: the `reconcile-admin-api` activation script used to live
    ## here. It was a deferred systemd-run that restarted admin-api
    ## ~15-20s after rebuild completed (a small sleep + activation
    ## handoff). Combined with `restartIfChanged = false`, that left
    ## a window where the old admin-api kept serving stale code.
    ##
    ## We've now removed both — admin-api uses NixOS's default
    ## `restartIfChanged = true`, so the unit gets restarted as
    ## part of standard activation. Rebuild safety is preserved by
    ## homefree-rebuild.service (transient, PID 1-owned) decoupling
    ## the rebuild's lifetime from admin-api's. See the comment
    ## above the admin-api systemd.services definition.

  };
}
