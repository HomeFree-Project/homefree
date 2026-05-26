## HomeFree per-instance config loader (SHARED, versioned).
##
## This module is the single source of truth for the
## homefree-config.json → homefree.* mapping. It used to live as a
## string-literal template (HOMEFREE_CONFIG_TEMPLATE) inside
## web-platform/backend/services/install.py, rendered into a *generated*
## /etc/nixos/homefree-configuration.nix by scripts/sync-template.py on
## "proper" rebuilds only. That generated file went stale on a bare
## `nixos-rebuild switch` (the sync only ran via the project build script
## / admin UI Apply), and duplicated mapping logic that belongs with the
## code. See docs/agent-notes/homefree-configuration-nix-is-generated.md.
##
## The instance's flake.nix now reads homefree-config.json and passes the
## parsed data (`homefreeConfigJson`) and the instance directory
## (`homefreeInstanceDir`, the path containing flake.nix, normally
## /etc/nixos) into this module via specialArgs. There is no generated
## file on disk anymore; the mapping is always the current shared code.
##
## Two specialArgs are required:
##   - homefreeConfigJson : the parsed homefree-config.json (an attrset).
##   - homefreeInstanceDir : a Nix *path* to the directory containing the
##       instance flake.nix (i.e. `./.` in flake.nix). Needed so the
##       mediawiki logo-path string→path transform can import user assets
##       that live under /etc/nixos/images/ — see the mediawiki block.
##
## All `or`-default tolerance from the old template is preserved verbatim
## so an older homefree-config.json (pre-storage, pre-localization, etc.)
## still evaluates cleanly.

{ config, lib, pkgs, options, homefreeConfigJson, homefreeInstanceDir, ... }:

let
  jsonData = homefreeConfigJson;
in
{
  homefree = {
    system = {
      domain = jsonData.system.domain;
      hostName = jsonData.system.hostName;
      timeZone = jsonData.system.timeZone;
      defaultLocale = jsonData.system.defaultLocale;
      countryCode = jsonData.system.countryCode;
      ## Localization extras — `or null`/default so an older JSON
      ## file (pre-2026-05) without these keys evals cleanly.
      elevation = jsonData.system.elevation or null;
      latitude = jsonData.system.latitude or null;
      longitude = jsonData.system.longitude or null;
      unitSystem = jsonData.system.unitSystem or "metric";
      currency = jsonData.system.currency or null;
      language = jsonData.system.language or null;
      keyMap = jsonData.system.keyMap;
      adminUsername = jsonData.system.adminUsername;
      adminDescription = jsonData.system.adminDescription;
      adminEmail = jsonData.system.adminEmail;
      localDomain = jsonData.system.localDomain;
      additionalDomains = jsonData.system.additionalDomains;
      authorizedKeys = jsonData.system.authorizedKeys;
      ## Whether this box is the upstream homefree.host marketing
      ## instance. Default false — a real personal deployment shows
      ## the per-user dashboard at apex. Override in the JSON by
      ## setting `system.project-mode: true`.
      project-mode = jsonData.system.project-mode or false;
      ## Admin user's pre-hashed password. Lives in homefree-config.json
      ## under system.hashedPassword (it is already a crypt hash, not a
      ## plaintext password — same security posture as the world-private
      ## /etc/nixos files that previously carried it). `or null` so an
      ## older JSON file that predates this key still evaluates; when
      ## null, profiles/.../configuration.nix leaves the account's
      ## initialHashedPassword in place (see hashedPassword consumer).
      hashedPassword = jsonData.system.hashedPassword or null;
      ## Boot mirror toggle. The installer writes `true` when the
      ## install chose raid1 (which provisions an ESP on disk 2 at
      ## /boot2 via disko_builder). `or false` so older JSON files
      ## that predate this key still evaluate cleanly. Consumed by
      ## modules/boot-mirror.nix.
      bootMirror = jsonData.system.bootMirror or false;
    };

    network = {
      wan-interface = jsonData.network.wan-interface;
      lan-interface = jsonData.network.lan-interface;
      router.enable = jsonData.network.router-enable;
      lan-address = jsonData.network.lan-address;
      lan-subnet = jsonData.network.lan-subnet;
      dhcp-range-start = jsonData.network.dhcp-range-start;
      dhcp-range-end = jsonData.network.dhcp-range-end;
      enable-unbound-adblock = jsonData.network.enable-unbound-adblock;
      wan-bitrate-mbps-down = jsonData.network.wan-bitrate-mbps-down;
      wan-bitrate-mbps-up = jsonData.network.wan-bitrate-mbps-up;

      # Static IPs conversion
      static-ips = map (ip: {
        mac-address = ip.mac-address;
        hostname = ip.hostname;
        ip = ip.ip;
        wan-access = ip.wan-access or true;
      }) jsonData.network.static-ips;

      ## Abuse-block CIDR list — each entry { cidr, enabled, comment }.
      ## `cidr` may be IPv4 or IPv6. `or []` so a JSON file predating
      ## this key still evaluates; the seed step in modules/abuse-
      ## blocking.nix populates it on first run, and the admin UI
      ## manages it thereafter. Consumed by profiles/router.nix to
      ## build the abusive_nets4 / abusive_nets6 nftables sets.
      ## Per-field `or` defaults tolerate partial entries.
      abuseBlockCidrs = map (e: {
        cidr = e.cidr;
        enabled = e.enabled or true;
        comment = e.comment or "";
      }) (jsonData.network.abuseBlockCidrs or []);
    };

    dns = {
      local = {
        overrides = map (override: {
          hostname = override.hostname;
          domain = override.domain;
          ip = override.ip;
        }) jsonData.dns.overrides;
      };

      ## Remote DNS / dynamic-dns / wildcard cert acquisition. The
      ## JSON carries non-secret metadata (zone names, protocol,
      ## username, etc.) plus a *secret key* per zone — never the
      ## password itself. The actual secret file lives at
      ## /var/lib/homefree-secrets/ddclient/<key> (zone passwords)
      ## and /var/lib/homefree-secrets/dns/api-token (DNS-01 API
      ## token). Users either copy these in from the existing
      ## SOPS-managed source on the previous host or populate them
      ## via the secrets UI.
      remote = {
        cert-management.dns-01 = {
          provider = jsonData.dns.cert-management.provider or null;
          resolvers = jsonData.dns.cert-management.resolvers or [ "1.1.1.1" ];
          secrets.api-token =
            if (jsonData.dns.cert-management.provider or null) == null
            then null
            else /var/lib/homefree-secrets/dns/api-token;
        };
        dynamic-dns = {
          interval = jsonData.dns.dynamic-dns.interval or "10m";
          usev4    = jsonData.dns.dynamic-dns.usev4 or "webv4, webv4=ipinfo.io/ip";
          usev6    = jsonData.dns.dynamic-dns.usev6 or "webv6, webv6=v6.ipinfo.io/ip";
          zones = map (z: {
            disable  = z.disable or false;
            zone     = z.zone;
            protocol = z.protocol or "hetzner";
            username = z.username;
            domains  = z.domains or [ "@" "*" ];
            passwordFile =
              ## Allow callers to skip the path-existence check on
              ## the schema side by emitting a /run/keys-style
              ## non-existent stub when the secret hasn't been
              ## dropped yet. Once the file is in place at
              ## /var/lib/homefree-secrets/ddclient/<key>, ddclient
              ## will pick it up.
              /var/lib/homefree-secrets/ddclient + ("/" + (z.password-secret-key or "password"));
          }) (jsonData.dns.dynamic-dns.zones or []);
        };
      };
    };

    mounts = map (m: {
      mount-point   = m.mount-point;
      device        = m.device;
      fs-type       = m.fs-type or "nfs";
      nfs-version   = m.nfs-version or "3";
      automount     = m.automount or true;
      idle-timeout  = m.idle-timeout or "600";
      extra-options = m.extra-options or [];
      enabled       = m.enabled or true;
    }) (jsonData.mounts or []);

    ## Local btrfs data pools (Storage admin module). Created imperatively
    ## by the admin backend; this block only records their identity so
    ## modules/storage-pools.nix can mount them. The chained `or []`
    ## tolerates an older homefree-config.json that predates the storage
    ## key, and per-field `or` defaults tolerate partial entries.
    storage = {
      pools = map (p: {
        enabled        = p.enabled or true;
        name           = p.name;
        mountpoint     = p.mountpoint;
        profile        = p.profile;
        members        = p.members or [];
        fs-uuid        = p.fs-uuid;
        md-uuid        = p.md-uuid or "";
        md-device      = p.md-device or "";
        encrypted      = p.encrypted or false;
        luks-mappers   = p.luks-mappers or [];
        mount-options  = p.mount-options or [ "compress=zstd" "noatime" ];
        device-timeout = p.device-timeout or "15s";
        snapshots      = p.snapshots or false;
      }) (jsonData.storage.pools or []);
      shares = map (s: {
        enabled   = s.enabled or true;
        name      = s.name;
        path      = s.path;
        allowed   = s.allowed or "";
        read-only = s.read-only or false;
      }) (jsonData.storage.shares or []);
    };

    ## System-disk LUKS + TPM2 first-boot enrollment. Flipped to true by
    ## the installer (services/install.py) when the user opts into LUKS at
    ## install time. Scoped to SYSTEM disks (root + swap) only — data
    ## pools are encrypted independently per-pool via homefree.storage.
    ## The `or false` keeps older homefree-config.json files evaluating
    ## cleanly — boxes installed before this module landed keep their
    ## locally-imported homefree-encryption.nix doing the work until they
    ## migrate the JSON key and drop the stale import.
    system-disk-encryption = {
      enable = jsonData.system-disk-encryption.enable or false;
    };

    ## Local btrfs timeline snapshots (snapper). Off by default; the chained
    ## `or` tolerates older JSON without the key, and the retention defaults
    ## match module.nix's homefree.snapshots.retention.
    snapshots = {
      system.enable = jsonData.snapshots.system.enable or false;
      retention = {
        hourly  = jsonData.snapshots.retention.hourly  or 24;
        daily   = jsonData.snapshots.retention.daily   or 7;
        weekly  = jsonData.snapshots.retention.weekly  or 4;
        monthly = jsonData.snapshots.retention.monthly or 6;
      };
    };

    ## Per-service SSO opt-out toggles. The JSON stores
    ##   { "per-service": { "adguard": { "enable": false }, ... } }
    ## We map it 1:1 to homefree.sso.per-service. Missing entries fall
    ## through to the option's default (enable = true) defined in
    ## services/sso.nix, so a missing key means "SSO on" rather than
    ## a build error.
    sso = {
      allowUserRegistration = jsonData.sso.allowUserRegistration or false;
      per-service = lib.mapAttrs (_: v: {
        enable = v.enable or true;
      }) (jsonData.sso.per-service or {});
    };

    ## Generic pass-through of `jsonData.services` into `homefree.services`.
    ##
    ## The JSON↔Nix mapping is identity now: every JSON key matches its
    ## corresponding Nix attribute name verbatim. Submodule defaults in
    ## module.nix fill in missing keys (e.g. `enable = false` when JSON
    ## only sets `public`), and the type system rejects unknown keys, so
    ## the per-service whitelist is no longer needed.
    ##
    ## Orphaned-key filtering: a custom-flake app (registered via
    ## Developers → Custom Flakes) declares its own
    ## `homefree.services.<name>` option. When such a flake is removed,
    ## its `services.<name>` block can linger in homefree-config.json
    ## after the module that declared the option is gone — an
    ## "orphaned" key. Passing it straight through would abort the whole
    ## build with `error: The option 'homefree.services.<name>' does not
    ## exist`. So we filter `jsonData.services` to keys that are
    ## actually declared options under `homefree.services`; orphaned
    ## keys are silently dropped (their settings stay inert in the JSON,
    ## so re-adding the flake restores them).
    ##
    ## Only mediawiki's instances need a real transform: `logo-path` is
    ## a *string* in JSON (filesystem path like
    ## "/etc/nixos/images/logo.png") but the option type is `nullOr path`
    ## because favicon-generation and image-resizing run as derivations
    ## that need to read the file at build time — that means it has to
    ## be a Nix path literal so Nix imports it into the store.
    ##
    ## Resolving the user's logo files: the conversion needs the path to
    ## resolve against the instance flake source root (normally
    ## /etc/nixos/), because the user's logo files live under
    ## /etc/nixos/images/. The instance flake.nix passes that directory
    ## in as `homefreeInstanceDir` (its own `./.`), so the path import
    ## targets a file inside the instance flake's source tree — exactly
    ## what the old generated /etc/nixos/homefree-configuration.nix did
    ## implicitly with its `./.`. (We cannot use this module's own `./.`:
    ## that resolves to the shared homefree /nix/store path, and the
    ## user's logos are outside it, so pure eval would reject the import.)
    services =
      let
        ## Only keys with a declared `homefree.services.<name>` option
        ## survive — drops orphaned keys left by a removed custom flake
        ## so the build doesn't abort. See the comment block above.
        declared = lib.filterAttrs
          (name: _: options.homefree.services ? ${name})
          (jsonData.services or {});
      in
      ## mediawiki's instances need the logo-path string→path transform
      ## (see comment above). Only rewrite mediawiki when it is actually
      ## present in the config.
      declared // (lib.optionalAttrs (declared ? mediawiki) {
        mediawiki = declared.mediawiki // {
          instances = map (instance: instance // {
            logo-path =
              let raw = instance.logo-path or null; in
              if raw == null || raw == "" then null
              else
                let
                  stripped =
                    if lib.strings.hasPrefix "/etc/nixos/" raw
                    then lib.strings.removePrefix "/etc/nixos/" raw
                    else raw;
                in (homefreeInstanceDir + ("/" + stripped));
          }) (declared.mediawiki.instances or []);
        };
      });

    backups = {
      enable = jsonData.backups.enable;
      to-path = if jsonData.backups.to-path == "" then null else jsonData.backups.to-path;
      ## Each extra-from-paths entry is { path = ...; enabled = ...; }.
      ## A bare string is normalized to { path = <str>; enabled = true; }
      ## so older homefree-config.json files (pre-schema-change) keep
      ## evaluating without a separate migration step.
      extra-from-paths = map (entry:
        if builtins.isString entry
          then { path = entry; enabled = true; }
          else { path = entry.path; enabled = entry.enabled or true; }
      ) (jsonData.backups.extra-from-paths or []);
      backblaze = {
        enable = jsonData.backups.backblaze-enable;
        bucket = if jsonData.backups.backblaze-bucket == "" then null else jsonData.backups.backblaze-bucket;
      };
    };

    ## Extra reverse-proxy entries for non-HomeFree hardware (NAS UI,
    ## solar inverter admin, smart-plug PSU, router admin, etc.).
    ## Each entry contributes one item to homefree.service-config; the
    ## existing Caddy generator iterates that list and adds a route.
    ## In-tree HomeFree services have their own service-config entries
    ## emitted by their respective .nix files — those entries are
    ## merged with these via NixOS list-merge semantics.
    service-config = map (e: {
      ## One "enabled" drives both flags: the top-level enable (catalog +
      ## restart-policy) and reverse-proxy.enable (Caddy routing + DNS).
      enable = e.enable or true;
      label = e.label;
      name = e.name or e.label;
      reverse-proxy = {
        enable    = e.enable or true;
        subdomains = e.subdomains or [ e.label ];
        ## https-domains is the user's public domains. When empty,
        ## services/caddy.nix falls back to system.domain +
        ## additionalDomains. Same default behavior in-tree services
        ## use, so external entries get the same coverage automatically.
        https-domains = e.https-domains or [];
        host      = e.host;
        port      = e.port or 80;
        ssl       = e.ssl or false;
        ssl-no-verify = e.ssl-no-verify or false;
        disable-keepalive = e.disable-keepalive or false;
        public    = e.public or false;
        oauth2    = e.oauth2 or false;
        basic-auth = e.basic-auth or false;
        require-admin-role = e.require-admin-role or false;
      };
    }) (jsonData.service-config or []);

    ## Whole-domain transparent proxies (e.g. slacktopia.org →
    ## internal dev box). Each entry forwards all matching domains
    ## to one backend host. http_port / https_port = null (or
    ## absent) disables that protocol leg.
    proxied-domains = map (e: {
      domains = e.domains or [];
      target = {
        host = e.host;
        http  = if (e.http-port  or null) == null then null else { port = e.http-port; };
        https = if (e.https-port or null) == null then null else {
          port = e.https-port;
          ignore-self-signed-cert = e.ignore-self-signed or false;
        };
      };
      public = e.public or false;
    }) (jsonData.proxied-domains or []);
  };
}
