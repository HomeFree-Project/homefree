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

  preStart = ''
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

    ## Synthesize combined CA bundle so Node's openid-client (used by
    ## the SSO plugin's protocols/oidc.js) trusts sso.<domain> when
    ## fetching /.well-known/openid-configuration. Same pattern as
    ## Linkwarden / Homebox / etc.
    {
      cat /etc/ssl/certs/ca-certificates.crt
      if [ -r /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt ]; then
        echo
        cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
      fi
    } > ${containerDataPath}/ca-bundle.crt
    chmod 644 ${containerDataPath}/ca-bundle.crt

    ## Synthesize sso.js from zitadel-provision secrets. Empty-ish
    ## (enabled=false) pre-provisioning so the container boots cleanly
    ## with the standard CryptPad sign-up form; flipped to enabled+
    ## enforced once the OIDC secrets land.
    ##
    ## Plugin schema (cryptpad/sso/protocols/oidc.js):
    ##   url            -> issuer URL, /.well-known/openid-configuration
    ##                     auto-discovered
    ##   client_id      -> Zitadel app client_id
    ##   client_secret  -> Zitadel app client_secret
    ##   jwt_alg        -> 'RS256' (Zitadel signs id_tokens with RS256;
    ##                     the plugin defaults to PS256 which Zitadel
    ##                     doesn't advertise — set explicitly for clarity)
    ##   username_claim -> 'preferred_username' (Zitadel emits the bare
    ##                     username here; the default 'name' is the full
    ##                     display name which produces ugly user IDs)
    ##   use_pkce/nonce -> default on (we want both)
    ##
    ## Admin role: not propagated. CryptPad admins are identified by
    ## the public keys listed in homefree.service-options.cryptpad
    ## .adminKeys (rendered into config.js above). SSO authentication
    ## is orthogonal — first-time SSO users get a fresh CryptPad
    ## identity (not pre-admin); they become admin only by adding
    ## their public key to adminKeys.
    if [ -s ${secretsDir}/oidc-client-id ] \
       && [ -s ${secretsDir}/oidc-client-secret ]; then
      CID=$(cat ${secretsDir}/oidc-client-id)
      CSEC=$(cat ${secretsDir}/oidc-client-secret)
      ## enforced=true: SSO replaces classic CryptPad login. Per
      ## HomeFree's SSO-only policy. CryptPad derives the user's
      ## keypair from (OIDC sub → server-stored seed in
      ## /data/data/sso_user/zitadel/<sub>.json) + preferred_username
      ## — so the same Zitadel sub on each login always derives the
      ## same drive. If a Zitadel DB wipe ever rotates subs, the
      ## seed file path goes orphan and CryptPad will create a fresh
      ## empty account; recovery in that case is to rename the
      ## sso_user/zitadel/OLD-SUB.json to NEW-SUB.json so derivation
      ## hits the same seed.
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
    virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.cryptpad.enable {
    cryptpad = {
      image = "cryptpad/cryptpad:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:${toString port}"
        "0.0.0.0:${toString wsPort}:${toString wsPort}"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}/config/config.js:/cryptpad/config/config.js:ro"
        ## sso.js is read by the SSO plugin at startup. Regenerated
        ## by preStart whenever oidc-client-* secrets land or rotate.
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
    };
  };

  systemd.services.podman-cryptpad = lib.mkIf config.homefree.service-options.cryptpad.enable {
    after = [ "dns-ready.service" ];
    wants = [ "dns-ready.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "cryptpad-prestart" preStart}" ];
    };
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
