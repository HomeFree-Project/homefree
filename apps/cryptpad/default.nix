{ config, lib, pkgs, ... }:
let
  version = "version-2026.5.1";
  containerDataPath = "/var/lib/cryptpad-podman";
  secretsDir = "/var/lib/homefree-secrets/cryptpad";

  port = config.homefree.allocPort "cryptpad";
  wsPort = 3023;
  dockerUserId = 4001;
  dockerGroupId = 4001;

  domain = config.homefree.system.domain;
  CPAD_MAIN_DOMAIN = "https://docs.${domain}";
  CPAD_SANDBOX_DOMAIN = "https://docs-sandbox.${domain}";

  ## CryptPad's OIDC support lives in a separate plugin repo —
  ## cryptpad/sso — which is pure JS dropped into
  ## /cryptpad/lib/plugins/sso. The openid-client npm package is
  ## already bundled in the official cryptpad image, so no build/
  ## install step is needed; we just mount the plugin source.
  ##
  ## Pinned to a known-good commit. Bump the rev + hash to upgrade.
  cryptpad-sso-plugin = pkgs.fetchFromGitHub {
    owner = "cryptpad";
    repo = "sso";
    rev = "7c44ebba5ba83674cc2d47b8176f4b88f4fc9fd7";
    hash = "sha256-GZ73p15LDXtORaN/tDxpuFwYtdIK/vv/ZLY1Js9UAs8=";
  };

  ssoConfigFile = "${containerDataPath}/config/sso.js";

  ## @TODO: Fix all issues here:
  ## https://docs.homefree.host/checkup/

  cryptpadConfig = pkgs.writeText "cryptpad-config.js" ''
    module.exports = {
      httpUnsafeOrigin: '${CPAD_MAIN_DOMAIN}',
      httpSafeOrigin: "${CPAD_SANDBOX_DOMAIN}",
      httpAddress: '0.0.0.0',
      httpPort: ${toString port},
      /* Local development instance port */
      //httpSafePort: 3001,
      websocketPort: ${toString wsPort},
      /* Default: 4 */
      maxWorkers: 8,
      otpSessionExpiration: 7*24, // hours
      //enforceMFA: false,
      //logIP: false,
      adminKeys: [
        ${lib.concatStringsSep "," (lib.map (key: ''"${key}"'') config.homefree.service-options.cryptpad.adminKeys)}
      ],
      //inactiveTime: 90, // days
      //archiveRetentionTime: 15,
      //accountRetentionTime: 365,
      //disableIntegratedEviction: true,
      maxUploadSize: 200 * 1024 * 1024,
      //premiumUploadSize: 100 * 1024 * 1024,
      filePath: './datastore/',
      archivePath: './data/archive',
      pinPath: './data/pins',
      taskPath: './data/tasks',
      blockPath: './block',
      blobPath: './blob',
      blobStagingPath: './data/blobstage',
      decreePath: './data/decrees',
      logPath: './data/logs',
      logToStdout: true,
      logLevel: 'info',
      logFeedback: false,
      verbose: false,
      installMethod: 'unspecified',
    };
  '';

  enable = config.homefree.service-options.cryptpad.enable;

  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Cryptpad Document service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    adminKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Public keys that have access to admin panel";
    };
  };
in
{
  options.homefree.services.cryptpad = userOptions;

  options.homefree.service-options.cryptpad = userOptions // {
    # Metadata - always available, not user-configurable
    label = lib.mkOption {
      type = lib.types.str;
      default = "cryptpad";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Docs/Office Suite";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Cryptpad";
      internal = true;
      description = "Project name";
    };
  };

  config = {
    ## Container via app-platform (modules/app-platform.nix). The dns-ready
    ## ordering and podman unit wiring are generated from this descriptor.
    ## root mode: the official cryptpad image requires root; a manual
    ## chown -R 4001:4001 in preStartInit takes the place of the rootless
    ## chown-marker (4001 is not a HomeFree-range uid so we do not create
    ## a dedicated system user).
    homefree.containers.cryptpad = lib.mkIf enable {
      image = "cryptpad/cryptpad:${version}";

      ## SKIPPED Phase 3 UID-pin: cryptpad uses internal uid 4001 (not in
      ## the HomeFree 800-899 range); the platform cannot create a system
      ## user for it without conflicting with existing uid assignments.
      ## A manual chown -R 4001:4001 runs in preStartInit instead.
      runAs = {
        mode = "root";
        reason = "cryptpad image uses internal uid 4001 (outside HomeFree 800-899 range); manual chown in preStartInit takes the place of the platform chown-marker";
      };

      ## dataDir left null: the preStartInit handles all directory creation
      ## (multiple subdirectories, not a single top-level dir), and
      ## caBundle = false because the CA bundle synthesis is manual
      ## (integrated into preStartInit to preserve the exact output order
      ## required by the golden snapshot).
      dataDir = null;

      ports = [
        "0.0.0.0:${toString port}:${toString port}"
        "0.0.0.0:${toString wsPort}:${toString wsPort}"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}/config/config.js:/cryptpad/config/config.js:ro"
        ## sso.js is read by the SSO plugin at startup. Regenerated
        ## by preStartInit whenever oidc-client-* secrets land or rotate.
        "${ssoConfigFile}:/cryptpad/config/sso.js:ro"
        ## Drop the cryptpad/sso plugin into lib/plugins/sso. Pure-JS
        ## drop-in; openid-client is already bundled in the upstream
        ## image so no npm install is needed.
        "${cryptpad-sso-plugin}:/cryptpad/lib/plugins/sso:ro"
        ## Combined CA bundle (system + Caddy local CA) so Node
        ## trusts sso.<domain> when fetching OIDC discovery.
        "${containerDataPath}/ca-bundle.crt:/etc/ssl/homefree-ca-bundle.crt:ro"
        "${containerDataPath}/data/blob:/cryptpad/blob"
        "${containerDataPath}/data/block:/cryptpad/block"
        "${containerDataPath}/data/data:/cryptpad/data"
        "${containerDataPath}/data/files:/cryptpad/datastore"
        "${containerDataPath}/customize:/cryptpad/customize"
        "${containerDataPath}/onlyoffice-dist:/cryptpad/www/common/onlyoffice/dist"
        "${containerDataPath}/onlyoffice-conf:/cryptpad/onlyoffice-conf"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        ## @TODO: move away from root user
        PUID = "1000";
        PGID = "100";
        CPAD_MAIN_DOMAIN = CPAD_MAIN_DOMAIN;
        CPAD_SANDBOX_DOMAIN = CPAD_SANDBOX_DOMAIN;
        CPAD_INSTALL_ONLYOFFICE = "yes";
        CPAD_CONF = "/cryptpad/config/config.js";
        ## Node honors NODE_EXTRA_CA_CERTS as an append-to-bundled-roots
        ## list. Required so openid-client trusts the Caddy-issued
        ## sso.<domain> cert during OIDC discovery.
        NODE_EXTRA_CA_CERTS = "/etc/ssl/homefree-ca-bundle.crt";
      };

      preStartInit = ''
        mkdir -p ${containerDataPath}/config
        mkdir -p ${containerDataPath}/data/blob
        mkdir -p ${containerDataPath}/data/block
        mkdir -p ${containerDataPath}/data/data
        mkdir -p ${containerDataPath}/data/files
        mkdir -p ${containerDataPath}/customize
        mkdir -p ${containerDataPath}/onlyoffice-dist
        mkdir -p ${containerDataPath}/onlyoffice-conf
        mkdir -p ${secretsDir}

        cp ${cryptpadConfig} ${containerDataPath}/config/config.js

        {
          cat /etc/ssl/certs/ca-certificates.crt
          if [ -r /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt ]; then
            echo
            cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
          fi
        } > ${containerDataPath}/ca-bundle.crt
        chmod 644 ${containerDataPath}/ca-bundle.crt

        if [ -s ${secretsDir}/oidc-client-id ] \
           && [ -s ${secretsDir}/oidc-client-secret ]; then
          CID=$(cat ${secretsDir}/oidc-client-id)
          CSEC=$(cat ${secretsDir}/oidc-client-secret)
          cat > ${ssoConfigFile} <<EOF
        module.exports = {
            enabled: true,
            enforced: true,
            cpPassword: false,
            forceCpPassword: false,
            list: [
                {
                    name: 'zitadel',
                    type: 'oidc',
                    url: 'https://sso.${domain}',
                    client_id: '$CID',
                    client_secret: '$CSEC',
                    jwt_alg: 'RS256',
                    username_claim: 'preferred_username',
                }
            ]
        };
        EOF
        else
          cat > ${ssoConfigFile} <<'EOF'
        module.exports = {
            enabled: false,
            enforced: false,
            cpPassword: false,
            forceCpPassword: false,
            list: []
        };
        EOF
        fi
        chmod 644 ${ssoConfigFile}

        chown -R ${toString dockerUserId}:${toString dockerGroupId} ${containerDataPath}
      '';
    };

    homefree.service-config = [{
      inherit (config.homefree.service-options.cryptpad) label name project-name;
      port-request = null;
      enable = config.homefree.service-options.cryptpad.enable;
      systemd-service-names = [
        "podman-cryptpad"
      ];
      sso = {
        kind = "native_oidc";
        ## Dev context (intentionally not surfaced in the admin UI):
        ## Native OIDC via cryptpad/sso plugin. Admin status is
        ## determined by adminKeys (public keys in config.js), NOT by
        ## OIDC claim — SSO users are equal until promoted manually.
      };
      reverse-proxy = {
        enable = config.homefree.service-options.cryptpad.enable;
        subdomains = [ "docs" "docs-sandbox" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.cryptpad.public;
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
          description = "Enable Cryptpad document collaboration platform";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make service accessible from WAN";
        }
        {
          path = "adminKeys";
          type = "listOf str";
          default = [];
          description = "Public keys that have access to admin panel";
        }
      ];
    }];
  };
}
