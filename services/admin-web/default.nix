{ config, lib, pkgs, options, homefree-inputs, ... }:

with lib;

let
  cfg = config.homefree;

  # web-platform source, consumed via its own flake input rather than a
  # `../../web-platform` relative path import. `.source` is the input's
  # git-clean filtered tree (web-platform/flake.nix drops __pycache__/*.pyc
  # etc.), so what we serve is byte-identical to the old path import but
  # decoupled from this repo's directory layout.
  installerWebPath = homefree-inputs.web-platform.legacyPackages.${pkgs.system}.source;

  # Python environment with required packages. The dependency set is factored
  # into web-platform/backend/python-env.nix so the backend import-all gate
  # (checks/default.nix) builds the SAME closure this service runs under.
  pythonEnv = pkgs.python3.withPackages (import (installerWebPath + "/backend/python-env.nix"));

  # Admin backend service package
  # Uses the same web-platform backend, but in admin mode
  admin-backend = pkgs.writeShellScriptBin "homefree-admin-backend" ''
    #!/usr/bin/env bash
    cd ${installerWebPath}/backend
    exec ${pythonEnv}/bin/python simple_main.py
  '';

  # Dashboard sampler service package. A standalone metrics collector —
  # the sole writer of the dashboard history DB. Runs independently of
  # the admin-api blue/green colour units so the dashboard time-series
  # charts survive admin-api restarts and flips. See
  # web-platform/backend/dashboard_sampler.py.
  dashboard-sampler = pkgs.writeShellScriptBin "homefree-dashboard-sampler" ''
    #!/usr/bin/env bash
    cd ${installerWebPath}/backend
    exec ${pythonEnv}/bin/python dashboard_sampler.py
  '';

  # Drive-temperature sampler package. Same standalone pattern as the
  # dashboard sampler, but runs as root because smartctl needs
  # CAP_SYS_RAWIO to open block devices. PATH augmented with the
  # system profile so `smartctl` and `lsblk` are reachable — the
  # default unit PATH is too restricted to find them.
  drive-temp-sampler = pkgs.writeShellScriptBin "homefree-drive-temp-sampler" ''
    #!/usr/bin/env bash
    export PATH="/run/current-system/sw/bin:$PATH"
    cd ${installerWebPath}/backend
    exec ${pythonEnv}/bin/python drive_temp_sampler.py
  '';

  # App-versions refresher. Walks the container catalog and queries
  # each container image's upstream registry for the latest semver
  # tag. Backs the Advanced -> App Versions page. Outbound-network
  # only (no privileged operations), so the systemd unit is sandboxed
  # but still runs as root to share write access to
  # /var/lib/homefree-admin/app-versions-cache.json with the admin-api
  # (which is the manual-refresh writer for the same file).
  app-versions-refresher = pkgs.writeShellScriptBin "homefree-app-versions-refresher" ''
    #!/usr/bin/env bash
    cd ${installerWebPath}/backend
    exec ${pythonEnv}/bin/python app_versions_refresh.py
  '';

  # SQLite DB shared by the sampler (writer) and admin-api (reader).
  dashboardDbDir = "/var/lib/homefree-dashboard";
  dashboardDbPath = "${dashboardDbDir}/history.db";

  driveTempDbDir = "/var/lib/homefree-drive-temps";
  driveTempDbPath = "${driveTempDbDir}/history.db";

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
  ## version-tracking carries `command`/`update-command` paths; coerce
  ## them to store strings (or null) so the JSON encoder + the backend
  ## resolver get plain strings. The resolver consumes this descriptor to
  ## override its default image-derived version detection per app, and
  ## the upgrade endpoint runs `update-command` in place of the generic
  ## pin rewriter.
  projectVersionTracking = vt: vt // {
    command = if vt.command == null then null else toString vt.command;
    update-command =
      if vt.update-command == null then null else toString vt.update-command;
  };

  ## The version-detection resolver keys enabled rows on the CONTAINER
  ## name, but version-tracking + project-name are declared per service
  ## LABEL — and the two differ for some apps (unifi's container is
  ## `unifi-os`, label `unifi`). So we ALSO alias the metadata under each
  ## container name that shares the entry's PRIMARY (first) container's
  ## image. That single rule covers two cases at once:
  ##   * name != label (unifi-os -> unifi), and
  ##   * blue/green pairs that share one image (oauth2-proxy-blue +
  ##     oauth2-proxy-green both resolve oauth2proxy's descriptor).
  ## Matching on IMAGE (not just "all containers") keeps a genuine sidecar
  ## with a DIFFERENT image (immich-redis, postgres-vectorchord) OUT of the
  ## alias, so it stays on the default strategy instead of inheriting the
  ## app's upstream.
  ociContainers = config.virtualisation.oci-containers.containers or {};
  containerImageOf = cname: (ociContainers.${cname} or {}).image or null;
  entryContainers = sc:
    map (lib.removePrefix "podman-")
      (lib.filter (lib.hasPrefix "podman-") sc.systemd-service-names);
  primaryImageContainers = sc:
    let conts = entryContainers sc;
    in if conts == [] then []
       else let primImg = containerImageOf (lib.head conts);
            in lib.optionals (primImg != null)
                 (lib.filter (c: containerImageOf c == primImg) conts);

  service-config-map = builtins.listToAttrs (
    lib.concatMap (sc:
      let
        value = {
          name = sc.name;
          project-name = sc.project-name;
          version-tracking = projectVersionTracking sc.version-tracking;
        };
        aliases = lib.filter (c: c != sc.label) (primaryImageContainers sc);
      in
        [ { name = sc.label; inherit value; } ]
        ++ map (c: { name = c; inherit value; }) aliases
    ) cfg.service-config
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

  # Host-app catalog for the App Versions page: NON-container apps
  # (headscale/headplane, opensprinkler, ...) that declare a
  # version-tracking strategy but ship no OCI image, so they appear in
  # neither image catalog above and would otherwise be invisible.
  #   * non-container = no `podman-*` systemd unit, AND
  #   * opted in      = a strategy other than the default "image"
  # (an app keeps the default "image" strategy only when it HAS an image,
  # so a non-container app on the default is genuinely untrackable and is
  # deliberately omitted rather than shown as a perpetual "unknown").
  hostAppHasContainer = sc:
    lib.any (n: lib.hasPrefix "podman-" n) sc.systemd-service-names;
  host-apps-list = map (sc: {
    label = sc.label;
    name = sc.name;
    project-name = sc.project-name;
    enabled = sc.enable;
    version-tracking = projectVersionTracking sc.version-tracking;
  }) (lib.filter
        (sc: !(hostAppHasContainer sc)
             && sc.version-tracking.strategy != "image")
        cfg.service-config);
  host-apps-json = (pkgs.formats.json {})
    .generate "host-apps.json" host-apps-list;

  # Provenance for the App Versions page: which containers are declared
  # by THIS repo's tree vs. an external module (a plugin flake, or
  # something dropped into /etc/nixos). External apps' version pins live
  # in their own repository — `scripts/upgrade-apps.py` (the page's
  # Update button) only edits this repo's checkout, so the UI must not
  # offer Update on rows it can never bump, and the pending-rebuild
  # overlay must not match them against this repo's pins.
  #
  # Detection is by definition LOCATION, not heuristics: a container is
  # external when every file that defines it lives outside this repo's
  # source tree. Checked on BOTH declaration surfaces — raw
  # `virtualisation.oci-containers.containers` AND the app-platform
  # registry `homefree.containers` (whose generator would otherwise make
  # every registry app look like it came from modules/app-platform.nix).
  homefreeSourceRoot = toString ../..;
  containerDefLocations =
    (options.virtualisation.oci-containers.containers.definitionsWithLocations or [])
    ++ (options.homefree.containers.definitionsWithLocations or []);
  internallyDefinedContainers = lib.unique (lib.concatMap
    (d: if lib.hasPrefix homefreeSourceRoot (toString d.file)
        then lib.attrNames d.value
        else [])
    containerDefLocations);

  # Container catalog for the Advanced -> App Versions page. Iterates
  # every container declared via virtualisation.oci-containers and
  # emits its name + image string + provenance. Image-string parsing
  # (registry / repo / tag split) is done in Python — keeping this
  # aggregator dumb avoids brittle Nix string surgery and lets the
  # resolver evolve without a rebuild.
  container-images-list = lib.mapAttrsToList (name: c: {
    inherit name;
    image = c.image;
    external = !(lib.elem name internallyDefinedContainers);
  }) (config.virtualisation.oci-containers.containers or {});
  container-images-json = (pkgs.formats.json {})
    .generate "container-images.json" container-images-list;

  # Full app-image catalog for the App Versions page, INCLUDING apps
  # that are currently disabled — those never declare an oci-container,
  # so container-images-json (above) can't see them. Built at BUILD time
  # by scanning every apps/<x>/ and services/<x>/ default.nix for its
  # image pin, using the same parser scripts/upgrade-apps.py relies on
  # (shared in resolvers/app_source_index.py). Emitting it here keeps the
  # /api/apps/versions endpoint a fast, no-filesystem-scan read at
  # request time. Output shape: [{app, image}].
  all-app-images-json = pkgs.runCommand "all-app-images.json" {} ''
    ${pythonEnv}/bin/python \
      ${installerWebPath}/backend/resolvers/app_source_index.py \
      scan ${../../apps} ${../../services} > $out
  '';

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
    ${pkgs.coreutils}/bin/cp ${container-images-json} /run/homefree/admin/container-images.json
    ${pkgs.coreutils}/bin/cp ${all-app-images-json} /run/homefree/admin/all-app-images.json
    ${pkgs.coreutils}/bin/cp ${host-apps-json} /run/homefree/admin/host-apps.json
    ${pkgs.coreutils}/bin/cp ${secrets-schema-json} /run/homefree/admin/service-secrets-schema.json
    ${pkgs.coreutils}/bin/cp ${service-options-schema-json} /run/homefree/admin/service-options-schema.json

    # Icons. rm+ln keeps the live path stable across rebuilds even
    # though the underlying derivation hash changes.
    ${pkgs.coreutils}/bin/rm -rf /run/homefree/admin/icons
    ${pkgs.coreutils}/bin/ln -s ${service-icons-pkg} /run/homefree/admin/icons
  '';

  ## ─── Blue/green admin-api ────────────────────────────────────────
  ##
  ## admin-api runs as TWO permanent units, admin-api-blue (:8000) and
  ## admin-api-green (:8001), built from one shared function. On a
  ## rebuild that changes the backend, the admin-api-flip activation
  ## script starts the standby colour, health-gates it, gracefully
  ## reloads Caddy onto it, then stops the old colour — a red-black
  ## flip with zero noticeable downtime for the Admin/Home UIs.
  ##
  ## Caddy reaches whichever colour is active via an `import`ed
  ## snippet file (see snippetTemplate below); the flip rewrites that
  ## file and `systemctl reload caddy` (graceful, drains in-flight).

  adminApiColours = {
    blue  = 8000;
    green = 8001;
  };

  ## Friendly access-denied page served by Caddy when admin-api's
  ## /api/auth/admin-check returns 403, so a non-admin user lands on a
  ## real page instead of the raw JSON body. Lives here (not in
  ## caddy/default.nix) because it is emitted as part of the admin-api
  ## upstream snippet that the flip rewrites.
  accessDeniedHtml = ''
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Access denied</title>
      <style>
        body { font-family: system-ui, -apple-system, sans-serif;
               background: #f8f9fa; color: #212529; margin: 0;
               min-height: 100vh; display: flex; align-items: center;
               justify-content: center; padding: 1rem; }
        .card { background: white; border-radius: 12px;
                box-shadow: 0 4px 24px rgba(0,0,0,0.08);
                padding: 3rem 2.5rem; max-width: 500px; width: 100%;
                text-align: center; }
        .icon { font-size: 3rem; margin-bottom: 1rem; }
        h1 { margin: 0 0 0.5rem; font-size: 1.5rem; color: #dc3545; }
        p  { margin: 0.5rem 0; line-height: 1.5; color: #495057; }
        .actions { margin-top: 2rem; display: flex; gap: 0.75rem;
                   justify-content: center; flex-wrap: wrap; }
        a  { display: inline-block; padding: 0.6rem 1.2rem;
             border-radius: 6px; text-decoration: none; font-weight: 500;
             transition: background 120ms ease; }
        .primary   { background: #0d6efd; color: white; }
        .primary:hover   { background: #0b5ed7; }
        .secondary { background: #e9ecef; color: #212529; }
        .secondary:hover { background: #dee2e6; }
        .small { color: #6c757d; font-size: 0.875rem; margin-top: 1.5rem; }
      </style>
    </head>
    <body>
      <div class="card">
        <div class="icon">🚫</div>
        <h1>Access denied</h1>
        <p>You are signed in, but this service requires the
           <code>homefree-admin</code> role.</p>
        <p class="small">Ask your HomeFree administrator to grant
           you the role, or sign out to switch users.</p>
        <div class="actions">
          <a class="primary"
             href="https://auth.${cfg.system.domain}/oauth2/sign_out?rd=https%3A%2F%2F${cfg.system.domain}%2F">
            Sign out
          </a>
          <a class="secondary" href="https://${cfg.system.domain}/">
            Home
          </a>
        </div>
      </div>
    </body>
    </html>
  '';

  ## Caddy snippet bodies for admin-api's two upstream uses. `__PORT__`
  ## is substituted at runtime by lib/blue-green.nix's flip with the
  ## active colour's port. `admin_api_admin_check` references the
  ## `@sso_gate` matcher defined by the importing site BEFORE the
  ## `import` — caddy/default.nix must keep that ordering (snippet
  ## expansion is textual).
  adminApiSnippets = [
    {
      snippetName = "admin_api_proxy";
      body = ''
        	reverse_proxy localhost:__PORT__ {
        		@backend_down status 502 503 504
        		handle_response @backend_down {
        			root * /var/lib/homefree-admin
        			rewrite * /service-state.json
        			file_server
        		}
        	}'';
    }
    {
      snippetName = "admin_api_admin_check";
      body = ''
        	forward_auth @sso_gate localhost:__PORT__ {
        		uri /api/auth/admin-check
        		header_up X-Auth-Request-User {http.request.header.X-Auth-Request-User}
        		header_up X-Auth-Request-Preferred-Username {http.request.header.X-Auth-Request-Preferred-Username}
        		header_up X-Auth-Request-Email {http.request.header.X-Auth-Request-Email}
        		header_up X-Auth-Request-Groups {http.request.header.X-Auth-Request-Groups}
        		@admin_denied status 403
        		handle_response @admin_denied {
        			header Content-Type "text/html; charset=utf-8"
        			header Cache-Control "no-store"
        			respond <<HTML
        ${accessDeniedHtml}
        HTML 403
        		}
        	}'';
    }
  ];

  ## Shared builder for the two admin-api colour units. They are
  ## identical except for the port (which also makes the unit hashes
  ## distinct). NOT wantedBy multi-user.target — the boot oneshot
  ## admin-api-active.service starts the active colour only.
  ## NOTE: lib/blue-green.nix forces `restartIfChanged = false` AND
  ## `stopIfChanged = false` on every colour unit — switch-to-
  ## configuration must neither restart nor stop a colour unit; the
  ## flip owns the full lifecycle. We do NOT set them here.
  mkAdminApiUnit = colour: port: {
    description = "HomeFree Admin API Backend (${colour})";
    after = [ "network.target" ];

    serviceConfig = {
      Type = "simple";
      User = "root";
      Group = "root";
      StateDirectory = "homefree-admin";
      WorkingDirectory = "/var/lib/homefree-admin";
      ExecStart = "${admin-backend}/bin/homefree-admin-backend";
      Restart = "always";
      RestartSec = "10s";
      KillMode = "process";
      Environment = [
        "PATH=${lib.makeBinPath [
          pkgs.nixos-rebuild
          pkgs.nix
          pkgs.git
          # `acl` provides setfacl/getfacl. DevelopersService._ensure_writable_for_owner
          # bails with a warning when setfacl is not on PATH, which silently
          # leaves every local-flake `.git` tree without the protective owner-rwX
          # ACL — root then writes loose objects into it during the rebuild,
          # locking the owning user out of subdirs they need to write to on the
          # next `git commit` / `git gc`. See docs/agent-notes/local-flake-acl.md.
          pkgs.acl
          pkgs.systemd
          pkgs.sops
          pkgs.ssh-to-age
          pkgs.coreutils
          pkgs.bash
          pkgs.gnused
          pkgs.gnugrep
          pkgs.findutils
          pkgs.shadow
          pkgs.fail2ban
          pkgs.nftables
          pkgs.iproute2
        ]}"
        "HOMEFREE_FRONTEND_PATH=${installerWebPath}/frontend"
        "HOMEFREE_DEVELOPMENT=${if config.homefree.development then "1" else "0"}"
        # Per-colour listen port. admin-api-blue=8000, admin-api-green=8001.
        "HOMEFREE_ADMIN_API_PORT=${toString port}"
        # Dashboard history DB — admin-api reads it; the standalone
        # homefree-dashboard-sampler service writes it.
        "HOMEFREE_DASHBOARD_DB=${dashboardDbPath}"
        # Optional external elevation-lookup URL template. Empty
        # string when `homefree.privacy.externalServices.elevation.url`
        # is null — admin-api treats empty as "feature disabled" and
        # returns 503 from /api/network/elevation so the UI can show
        # a clear "not configured" message.
        "HOMEFREE_ELEVATION_API_URL=${
          if config.homefree.privacy.externalServices.elevation.url == null
          then ""
          else config.homefree.privacy.externalServices.elevation.url
        }"
        # Box-wide defaults for the alerts module (and future Privacy
        # admin page) — every third-party endpoint the box may call
        # for a feature is surfaced here. The frontend reads these
        # via /api/system/privacy-defaults and uses them as the
        # default for fresh alerts; per-alert overrides remain.
        "HOMEFREE_PRIVACY_PUBLIC_IP_URL=${
          config.homefree.privacy.externalServices.publicIp.url
        }"
        "HOMEFREE_PRIVACY_DOH_URL=${
          config.homefree.privacy.externalServices.doh.url
        }"
      ];
    };
  };

  ## Generic blue/green machinery for admin-api: two colour units, the
  ## boot oneshots, the flip activation script, and the Caddy upstream
  ## snippet. The flip fires whenever the admin-backend store path
  ## changes. See lib/blue-green.nix.
  bg = (import ../../lib/blue-green.nix { inherit lib pkgs; }) {
    name = "admin-api";
    stateDir = "/var/lib/homefree-admin";
    colours = { blue = 8000; green = 8001; };
    workload = { kind = "systemd"; mkUnit = mkAdminApiUnit; };
    healthCheck = { kind = "http"; path = "/health"; };
    closure = { kind = "store-path"; path = "${admin-backend}"; };
    caddySnippets = adminApiSnippets;
    migrateFrom = "admin-api.service";
    migrateRollback = "restart-legacy";
    failureMarker = "admin-api-flip-failed.json";
    ## setup-admin-config writes the /run/homefree/admin config the
    ## backend reads on start — order the flip after it.
    activationDeps = [ "setup-admin-config" ];
    ## Order this flip after the OTHER blue/green service's snippet
    ## writer, so oauth2-proxy's file-scope Caddy `import` target
    ## exists before this flip reloads Caddy. The name is the static
    ## `${name}-bg-snippet` of apps/zitadel/default.nix's oauth2-proxy
    ## blue/green instance.
    snippetActivationDeps = [ "oauth2-proxy-bg-snippet" ];
  };

in
{
  # Admin service is always enabled - no enable check needed
  config = lib.mkMerge [

  ## Blue/green machinery (colour units, boot oneshots, flip script,
  ## Caddy snippet) — all generated by lib/blue-green.nix.
  ##
  ## PATH note (carried into mkAdminApiUnit): coreutils + the standard
  ## userspace tools are needed because the rebuild admin-api spawns
  ## (nixos-rebuild-ng) shells out to bare commands like `test`,
  ## `mkdir`, `cat` without absolute paths.
  bg.config

  {
    ## Register admin-api's runtime snippet for file-scope import in
    ## the generated Caddyfile.
    homefree.internal.caddy-file-scope-imports = [ bg.caddyImportLine ];

    # Admin UI service configuration (served by Caddy)
    homefree.service-config = [
      {
        label = "admin";
        name = "HomeFree Admin";
        project-name = "HomeFree Admin";

        systemd-service-names = [
          # Both colour units — only the active one is running; the
          # standby shows inactive, which is expected.
          "admin-api-blue"
          "admin-api-green"
          "caddy"
        ];

        admin = {
          show = true;
        };

        sso = {
          kind = "caddy_gated";
          ## Dev context (intentionally not surfaced in the admin UI):
          ## HomeFree admin UI itself — Caddy SSO gate enforces
          ## oauth2-proxy + homefree-admin role.
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

          ## Also serve the admin UI on the bare LAN IP. The finish-setup
          ## captive portal redirects to http://<lan-ip>/ — an IP, never a
          ## hostname — because a hostname in a redirect is resolved by
          ## whatever client follows it (which may be on a different network
          ## and resolve admin.<localDomain> to a *different* HomeFree box).
          extra-http-hosts = [ "http://${cfg.network.lan-address}" ];

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
            # Redirect non-LAN requests to the public app. redir fires before
            # forward_auth in Caddy's ordering, so external browsers never hit
            # the SSO gate or get a blank page (which happened when the external
            # IP had no matching vhost and Caddy returned an empty 200).
            @external not remote_ip 10.0.0.0/8 127.0.0.1/32
            redir @external https://app.${cfg.system.domain}/ 302

            # Strip Alt-Svc so browsers never upgrade to HTTP/3 on this site.
            # Chrome QUIC state can get stuck and block the admin UI from loading.
            header -Alt-Svc

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
            # admin_api_proxy is defined in the runtime-rewritten
            # snippet (/run/homefree/admin-api-upstream.caddy); it
            # carries the reverse_proxy to the active blue/green port
            # plus the @backend_down -> service-state.json fallback.
            handle @api {
              import admin_api_proxy
            }

            # NOTE: cache headers (no-store, strip ETag/Last-Modified) are
            # set centrally in services/caddy/default.nix's static-path
            # block — one unmatched `header` for the whole site. Do not add
            # another `header` block here: two unmatched `header` directives
            # in one site is ambiguous in Caddy.
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
          # Both colour units — only the active one is running; the
          # standby shows inactive, which is expected.
          "admin-api-blue"
          "admin-api-green"
          "caddy"
        ];

        admin = {
          show = false;
        };

        sso = {
          kind = "caddy_gated";
          ## Dev context (intentionally not surfaced in the admin UI):
          ## Per-user dashboard — oauth2-proxy gate only, no admin role
          ## required.
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
            # admin_api_proxy: see the admin vhost above — same
            # runtime-rewritten snippet, points at the active colour.
            handle @api {
              import admin_api_proxy
            }

            # NOTE: cache headers are set centrally in
            # services/caddy/default.nix's static-path block. Do not add a
            # `header` block here — see the admin vhost note above.
          '';
        };
      }

      # API backend (separate entry for monitoring)
      {
        label = "admin-api";
        name = "HomeFree Admin API";
        project-name = "HomeFree Admin API";

        systemd-service-names = [
          # Both colour units — only the active one is running; the
          # standby shows inactive, which is expected.
          "admin-api-blue"
          "admin-api-green"
          # Standalone dashboard metrics sampler — writes the history
          # DB the admin-api reads.
          "homefree-dashboard-sampler"
          # Standalone drive-temperature sampler — writes the per-drive
          # temperature history DB the Hardware page reads.
          "homefree-drive-temp-sampler"
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

    ## Dashboard sampler — standalone, minimal-privilege metrics
    ## collector. It is the *sole* writer of the dashboard history DB.
    ## Decoupled from the admin-api blue/green units on purpose: its
    ## lifetime spans admin-api restarts and colour flips, so the
    ## dashboard time-series charts have no gaps and there is exactly
    ## one writer (no last-writer-wins between two colours). admin-api
    ## reads the DB read-only.
    users.users.homefree-dashboard = {
      isSystemUser = true;
      group = "homefree-dashboard";
      description = "HomeFree dashboard metrics sampler";
    };
    users.groups.homefree-dashboard = { };

    systemd.services.homefree-dashboard-sampler = {
      description = "HomeFree Dashboard Metrics Sampler";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        Type = "simple";
        User = "homefree-dashboard";
        Group = "homefree-dashboard";
        ## StateDirectory creates /var/lib/homefree-dashboard owned by
        ## the sampler user. Mode 0755 so the admin-api units (running
        ## as root, which can read regardless) — and any future
        ## non-root reader — can open the DB.
        StateDirectory = "homefree-dashboard";
        StateDirectoryMode = "0755";
        WorkingDirectory = dashboardDbDir;
        ExecStart = "${dashboard-sampler}/bin/homefree-dashboard-sampler";
        Restart = "always";
        RestartSec = "10s";
        Environment = [
          "HOMEFREE_DASHBOARD_DB=${dashboardDbPath}"
        ];
        ## Pure metrics collector — no privileges needed. psutil
        ## counters, net_io_counters and the TCP connectivity probe
        ## all work unprivileged. Lock the unit down.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_NETLINK" ];
        SystemCallFilter = [ "@system-service" ];
      };
    };

    ## Drive-temperature sampler — separate root-privileged unit. Lives
    ## apart from the dashboard sampler so that one stays unprivileged.
    ## smartctl needs CAP_SYS_RAWIO; we keep it as full root rather than
    ## granting a fine-grained capability because the per-tick subprocess
    ## already inherits root and the unit is otherwise locked down.
    systemd.services.homefree-drive-temp-sampler = {
      description = "HomeFree Drive Temperature Sampler";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];

      serviceConfig = {
        Type = "simple";
        ## Root: smartctl needs CAP_SYS_RAWIO to open /dev/sdX.
        User = "root";
        Group = "root";
        StateDirectory = "homefree-drive-temps";
        StateDirectoryMode = "0755";
        WorkingDirectory = driveTempDbDir;
        ExecStart = "${drive-temp-sampler}/bin/homefree-drive-temp-sampler";
        Restart = "always";
        RestartSec = "10s";
        Environment = [
          "HOMEFREE_DRIVE_TEMP_DB=${driveTempDbPath}"
        ];
        ## Locked down despite running as root. smartctl is the only
        ## thing that needs raw device access; everything else is
        ## sqlite and sysfs reads.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
      };
    };

    ## NOTE: the admin-api blue/green flip — colour units, boot
    ## oneshots, the flip activation script, the Caddy upstream
    ## snippet — is now generated by lib/blue-green.nix (the `bg`
    ## binding in the `let` above, merged via `bg.config`). The
    ## hand-written implementation that used to live here has been
    ## replaced by that one reusable mechanism (also used for
    ## oauth2-proxy). The flip's pointer files are unchanged:
    ## /var/lib/homefree-admin/{active-color,active-closure,
    ## admin-api-flip-failed.json}.

    ## App-versions refresher — periodic outbound fetch of each
    ## container image's latest semver tag from its upstream registry.
    ## Backs the Advanced -> App Versions page. Oneshot (no daemon);
    ## the timer runs it daily + the admin-api can kick the same
    ## refresh in-process via POST /api/apps/versions/refresh.
    ##
    ## Runs as root to share write access with the admin-api (also
    ## root) for /var/lib/homefree-admin/app-versions-cache.json. The
    ## work itself is purely network + file write, so the unit is
    ## otherwise locked down via the systemd sandbox directives below.
    systemd.services.homefree-app-versions-refresh = {
      description = "Refresh upstream container image versions";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        StateDirectory = "homefree-admin";
        WorkingDirectory = "/var/lib/homefree-admin";
        ExecStart = "${app-versions-refresher}/bin/homefree-app-versions-refresher";
        ## Sandbox — outbound network + writing one file in
        ## /var/lib/homefree-admin is all this needs.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
        SystemCallFilter = [ "@system-service" ];
      };
    };

    systemd.timers.homefree-app-versions-refresh = {
      description = "Daily refresh of upstream container image versions";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        ## First run shortly after boot so the page has data the first
        ## time it's opened on a freshly-installed box; recur daily.
        OnBootSec = "10min";
        OnUnitActiveSec = "24h";
        Persistent = true;
        RandomizedDelaySec = "30m";
      };
    };
  }
  ];
}
