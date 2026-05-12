{ config, lib, pkgs, ... }:

## NetBird is a second VPN platform offered alongside Headscale. They
## coexist on the same router: different ports, different subdomains,
## different OIDC client in Zitadel. Clients pick one or the other.
##
## NetBird's self-hosted server is split across four containers
## (dashboard, signal, relay, management) plus an optional coturn TURN
## server. We run all five with TLS terminated by Caddy on the host —
## the containers themselves listen on plain HTTP / h2c, which avoids
## hand-rolling cert plumbing for each service.
##
## Authentication is delegated to Zitadel via OIDC. Three credentials
## need to be created in Zitadel before this module can deploy:
##
##   1. OIDC application "netbird" (Native/SPA, PKCE, with grants for
##      Authorization Code, Device Code, Refresh Token). Yields the
##      client_id (and optionally a secret if confidential).
##   2. A machine user "netbird-mgmt" with role Org Owner. Generate a
##      personal access token (PAT) — that's mgmt-machine-token.
##   3. A 32-byte random key for at-rest encryption of the management
##      datastore — generate locally with `openssl rand -base64 32`.
##
## Until all four secrets (OIDC client id/secret + PAT + datastore
## encryption key) are populated via the admin UI, the NetBird stack
## is not deployed. This mirrors the Zitadel/oauth2-proxy pattern in
## services/zitadel-podman.nix.

let
  cfg = config.homefree;
  netbirdCfg = config.homefree.service-options.netbird;
  lan-address = cfg.network.lan-address;
  domain = cfg.system.domain;
  zitadelDomain = "sso.${domain}";

  ## Image tags. Pin all of these together — NetBird ships breaking
  ## changes in the management.json schema across minor versions, so
  ## bumping these should be a deliberate, coordinated update.
  managementTag = "0.70.5";
  signalTag = "0.70.5";
  relayTag = "0.70.5";
  dashboardTag = "v2.16.0";
  coturnTag = "4.6.2";

  ## Port allocations. Headscale's embedded DERP claims 3478/udp for
  ## STUN, so NetBird's coturn moves to 3479/udp to dodge the conflict.
  netbirdSignalPort     = 10000;   # signal HTTP (Caddy terminates TLS)
  netbirdMgmtPort       = 33073;   # management HTTP (Caddy terminates TLS)
  netbirdRelayPort      = 33080;   # relay TCP (Caddy terminates TLS)
  netbirdDashboardPort  = 33000;   # dashboard nginx (HTTP)
  netbirdStunPort       = 3479;    # coturn UDP (avoid headscale's 3478)
  netbirdTurnTLSPort    = 5349;    # coturn TLS

  netbirdDataPath = "/var/lib/netbird";
  netbirdSignalDataPath = "/var/lib/netbird-signal";

  enabled = netbirdCfg.enable;
  secretsDir = "/var/lib/homefree-secrets/netbird";

  ## Gating switched from "user filled in 4 nullable string options"
  ## to "the secrets exist on disk", since zitadel-provision.service
  ## now writes all four files for us. Same evaluation-time
  ## pathExists trick as services/zitadel-podman.nix used previously
  ## — but the management.json preStart will refuse to start if
  ## any are missing anyway, so a partial-state deploy still fails
  ## cleanly.
  oidcConfigured =
       builtins.pathExists "${secretsDir}/oidc-client-id"
    && builtins.pathExists "${secretsDir}/oidc-client-secret"
    && builtins.pathExists "${secretsDir}/mgmt-machine-token"
    && builtins.pathExists "${secretsDir}/data-store-encryption-key";
  deployServer = enabled && oidcConfigured;
  deployClient = netbirdCfg.client.enable;

  ## Synthesize /var/lib/netbird/management.json at preStart by sed-ing
  ## the four placeholders against the on-disk secrets. Also generate
  ## a random TURN secret and password if they don't exist (coturn
  ## needs them but they're not user-visible — the management server
  ## hands them out to clients).
  ##
  ## Also gates the entire NetBird stack on the four Zitadel-provided
  ## secrets being present — refuses to start (exit 1) if anything
  ## is missing, which keeps the management container in a clean
  ## "inactive" state pre-provisioning rather than crash-looping.
  ## zitadel-provision.service `systemctl restart`s the unit once
  ## the secrets land.
  managementJsonPreStart = ''
    set -eu

    ## Secrets are guaranteed present at this point: the unit gates on
    ## `ConditionPathExists=` for all four files, so systemd will skip
    ## start (no failure, no restart-counter burn) if any are missing.
    ## zitadel-provision.service `try-restart`s the unit once the files
    ## land, at which point the conditions pass and we run.

    mkdir -p ${netbirdDataPath}

    ## Build a CA bundle the container can mount over its own
    ## /etc/ssl/certs/ca-certificates.crt. Caddy issues internal certs
    ## for sso.${domain} from a runtime-generated local CA, which the
    ## stock alpine bundle inside the container doesn't trust — that's
    ## what produced the "x509: certificate signed by unknown
    ## authority" failure on OIDC discovery. We concatenate the host
    ## system bundle plus Caddy's local root (if it exists yet) so the
    ## container has the same trust set as the host.
    {
      cat /etc/ssl/certs/ca-certificates.crt
      if [ -r /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt ]; then
        echo
        cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
      fi
    } > ${netbirdDataPath}/ca-bundle.crt
    chmod 644 ${netbirdDataPath}/ca-bundle.crt
    cd ${netbirdDataPath}

    if [ ! -s turn-secret ]; then
      ${pkgs.openssl}/bin/openssl rand -hex 32 > turn-secret
      chmod 600 turn-secret
    fi
    if [ ! -s turn-password ]; then
      ${pkgs.openssl}/bin/openssl rand -hex 16 > turn-password
      chmod 600 turn-password
    fi
    if [ ! -s relay-secret ]; then
      ${pkgs.openssl}/bin/openssl rand -hex 32 > relay-secret
      chmod 600 relay-secret
    fi

    install -m 600 /dev/null ${netbirdDataPath}/management.json
    ${pkgs.gnused}/bin/sed \
      -e "s|@@OIDC_CLIENT_ID@@|$(cat ${secretsDir}/oidc-client-id)|g" \
      -e "s|@@OIDC_CLIENT_SECRET@@|$(cat ${secretsDir}/oidc-client-secret)|g" \
      -e "s|@@MGMT_MACHINE_TOKEN@@|$(cat ${secretsDir}/mgmt-machine-token)|g" \
      -e "s|@@DATA_STORE_ENC_KEY@@|$(cat ${secretsDir}/data-store-encryption-key)|g" \
      -e "s|@@TURN_SECRET@@|$(cat ${netbirdDataPath}/turn-secret)|g" \
      -e "s|@@TURN_PASSWORD@@|$(cat ${netbirdDataPath}/turn-password)|g" \
      -e "s|@@RELAY_SECRET@@|$(cat ${netbirdDataPath}/relay-secret)|g" \
      -e "s|@@NETBIRD_DOMAIN@@|netbird.${domain}|g" \
      -e "s|@@NETBIRD_STUN_PORT@@|${toString netbirdStunPort}|g" \
      -e "s|@@NETBIRD_RELAY_PORT@@|${toString netbirdRelayPort}|g" \
      -e "s|@@ZITADEL_DOMAIN@@|${zitadelDomain}|g" \
      ${./netbird/management.json.tmpl} \
      > ${netbirdDataPath}/management.json
  '';

  ## Synthesise /var/lib/netbird/dashboard.env from on-disk secrets
  ## at preStart, so the dashboard container's auth-related env vars
  ## come from runtime files (not Nix-time string substitution).
  ## Same secrets gate as the management preStart.
  dashboardEnvPreStart = ''
    set -eu
    ## Same `ConditionPathExists=` gate as netbird-management — see
    ## the systemd.services.podman-netbird-dashboard block below.
    mkdir -p ${netbirdDataPath}
    install -m 600 /dev/null ${netbirdDataPath}/dashboard.env
    {
      CLIENT_ID=$(cat ${secretsDir}/oidc-client-id)
      echo "AUTH_AUDIENCE=$CLIENT_ID"
      echo "AUTH_CLIENT_ID=$CLIENT_ID"
    } > ${netbirdDataPath}/dashboard.env
  '';

  ## coturn config — minimal; uses host networking so the listening
  ## address is the LAN interface, not a container internal one. The
  ## creds come from /var/lib/netbird/turn-{secret,password}.
  turnserverConfFile = pkgs.writeText "turnserver.conf" ''
    listening-port=${toString netbirdStunPort}
    tls-listening-port=${toString netbirdTurnTLSPort}
    listening-ip=${lan-address}
    relay-ip=${lan-address}
    fingerprint
    lt-cred-mech
    realm=netbird.${domain}
    no-tls
    no-dtls
    no-cli
    log-file=stdout
    no-software-attribute
  '';

in
{
  options.homefree.service-options.netbird = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable NetBird VPN server";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Dashboard accessible from WAN";
    };

    label = lib.mkOption {
      type = lib.types.str;
      default = "netbird";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "VPN (NetBird)";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "NetBird";
      internal = true;
      description = "Project name";
    };

    client = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Run the NetBird client on this host (router as gateway).
          Independent of the server.enable flag — you can run server-only,
          client-only, or both. Note that running both this and the
          tailscale client (services.tailscale, used by headscale) on the
          same router will install two sets of netfilter rules; do not
          enable simultaneously without testing.
        '';
      };
    };

    ## All four secrets are now auto-provisioned by
    ## zitadel-provision.service (oidc-client-{id,secret} +
    ## mgmt-machine-token via Zitadel API; data-store-encryption-key
    ## locally generated). Marked internal so they no longer appear
    ## as user-fillable fields in the admin UI.
    secrets = {
      oidc-client-id = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        internal = true;
        description = "(internal) written by zitadel-provision.service.";
      };
      oidc-client-secret = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        internal = true;
        description = "(internal) written by zitadel-provision.service.";
      };
      mgmt-machine-token = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        internal = true;
        description = "(internal) PAT for the netbird-mgmt machine user, minted by zitadel-provision.service.";
      };
      data-store-encryption-key = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        internal = true;
        description = "(internal) 32-byte base64 key for at-rest encryption of the management datastore — locally generated by zitadel-provision.service.";
      };
    };
  };

  config = {
    ## ── NetBird server containers ──────────────────────────────────────
    ## All five containers are always rendered when NetBird is
    ## enabled. Pre-provisioning, the management + dashboard
    ## containers refuse to start (their preStart bails on missing
    ## secrets), and the others sit idle. zitadel-provision.service
    ## kicks them via `systemctl restart` once secrets land — single
    ## rebuild, no manual intervention.
    virtualisation.oci-containers.containers = lib.mkMerge [
      (lib.optionalAttrs enabled {
        netbird-management = {
          image = "netbirdio/management:${managementTag}";
          autoStart = true;
          ports = [
            "0.0.0.0:${toString netbirdMgmtPort}:80"
          ];
          volumes = [
            "${netbirdDataPath}:/var/lib/netbird"
            "${netbirdDataPath}/management.json:/etc/netbird/management.json:ro"
            ## Trust Caddy's local CA so OIDC discovery against
            ## https://sso.${domain} succeeds. See ca-bundle synthesis
            ## in managementJsonPreStart.
            "${netbirdDataPath}/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro"
            "/etc/localtime:/etc/localtime:ro"
          ];
          cmd = [
            "--port" "80"
            "--log-file" "console"
            "--log-level" "info"
            "--disable-anonymous-metrics=true"
            "--single-account-mode-domain=netbird.${domain}"
            "--dns-domain=netbird.${domain}"
          ];
        };

        netbird-signal = {
          image = "netbirdio/signal:${signalTag}";
          autoStart = true;
          ports = [
            "0.0.0.0:${toString netbirdSignalPort}:80"
          ];
          volumes = [
            "${netbirdSignalDataPath}:/var/lib/netbird"
            "/etc/localtime:/etc/localtime:ro"
          ];
          cmd = [ "--log-file" "console" "--port" "80" ];
        };

        netbird-relay = {
          image = "netbirdio/relay:${relayTag}";
          autoStart = true;
          ports = [
            "0.0.0.0:${toString netbirdRelayPort}:${toString netbirdRelayPort}"
          ];
          environment = {
            NB_LOG_LEVEL = "info";
            NB_LISTEN_ADDRESS = ":${toString netbirdRelayPort}";
            NB_EXPOSED_ADDRESS = "netbird.${domain}:${toString netbirdRelayPort}";
            ## Auth secret loaded from env file populated at preStart
          };
          environmentFiles = [ "${netbirdDataPath}/relay.env" ];
        };

        netbird-dashboard = {
          image = "netbirdio/dashboard:${dashboardTag}";
          autoStart = true;
          ports = [
            "0.0.0.0:${toString netbirdDashboardPort}:80"
          ];
          environment = {
            NETBIRD_MGMT_API_ENDPOINT = "https://netbird.${domain}";
            NETBIRD_MGMT_GRPC_API_ENDPOINT = "https://netbird.${domain}";
            ## AUTH_AUDIENCE + AUTH_CLIENT_ID are synthesised from the
            ## on-disk client_id at preStart (see dashboard.env). We
            ## can't bake them inline because the file may not exist
            ## at Nix-eval time on a fresh install — that would force
            ## a double-rebuild after provisioning.
            AUTH_CLIENT_SECRET = "";  # Native PKCE app — no secret in browser
            AUTH_AUTHORITY = "https://${zitadelDomain}";
            USE_AUTH0 = "false";
            ## Include Zitadel's project-role scope so the dashboard's
            ## access token carries the user's homefree-* roles. The
            ## management server's IdP integration queries Zitadel
            ## directly by PAT to determine user roles, but having
            ## roles in the token is needed for any future client-
            ## side admin/user distinction.
            AUTH_SUPPORTED_SCOPES = "openid profile email offline_access api urn:zitadel:iam:org:project:roles";
            AUTH_REDIRECT_URI = "/auth";
            AUTH_SILENT_REDIRECT_URI = "/silent-auth";
            NETBIRD_TOKEN_SOURCE = "idToken";
            NGINX_SSL_PORT = "443";
            ## Caddy terminates TLS — disable letsencrypt inside the container
            LETSENCRYPT_DOMAIN = "";
            LETSENCRYPT_EMAIL = "";
          };
          environmentFiles = [ "${netbirdDataPath}/dashboard.env" ];
        };

        netbird-coturn = {
          image = "coturn/coturn:${coturnTag}";
          autoStart = true;
          extraOptions = [ "--network=host" ];
          volumes = [
            "${turnserverConfFile}:/etc/turnserver.conf:ro"
          ];
          cmd = [ "-c" "/etc/turnserver.conf" ];
        };
      })
    ];

    ## Render the relay env file from the generated relay-secret. The
    ## management container's preStart already creates the file under
    ## /var/lib/netbird/relay-secret; we just need to surface it as an
    ## env var via a separate file (kept tiny so it's easy to re-emit).
    ##
    ## The management container's preStart bails on missing Zitadel
    ## secrets — see managementJsonPreStart's gate at the top of this
    ## file. That's what keeps the unit cleanly inactive (rather than
    ## crash-looping) until zitadel-provision lands the secrets.
    systemd.services.podman-netbird-management = lib.mkIf enabled {
      after = [ "dns-ready.service" "podman-zitadel.service" ];
      requires = [ "dns-ready.service" ];
      partOf = [ "nftables.service" ];
      ## Unit is silently skipped (ConditionResult=no) until all four
      ## Zitadel-provided secrets land on disk. zitadel-provision
      ## `try-restart`s us once they do — no crash-loop, no restart
      ## counter burn.
      unitConfig.ConditionPathExists = [
        "${secretsDir}/oidc-client-id"
        "${secretsDir}/oidc-client-secret"
        "${secretsDir}/mgmt-machine-token"
        "${secretsDir}/data-store-encryption-key"
      ];
      serviceConfig.ExecStartPre = [
        "!${pkgs.writeShellScript "netbird-management-prestart" managementJsonPreStart}"
      ];
    };

    systemd.services.podman-netbird-signal = lib.mkIf enabled {
      after = [ "dns-ready.service" ];
      requires = [ "dns-ready.service" ];
      partOf = [ "nftables.service" ];
      ## Volume mount target needs to exist before podman tries to bind
      ## it in. Independent of the OIDC secrets gate.
      serviceConfig.ExecStartPre = [
        "!${pkgs.writeShellScript "netbird-signal-prestart" ''
          mkdir -p ${netbirdSignalDataPath}
        ''}"
      ];
    };

    systemd.services.podman-netbird-relay = lib.mkIf enabled {
      after = [ "dns-ready.service" "podman-netbird-management.service" ];
      requires = [ "dns-ready.service" ];
      partOf = [ "nftables.service" ];
      ## Relay needs the auth secret that netbird-management generates
      ## in its preStart. Gate on the file being present so we don't
      ## crash-loop pre-provisioning.
      unitConfig.ConditionPathExists = [
        "${netbirdDataPath}/relay-secret"
      ];
      serviceConfig.ExecStartPre = [
        "!${pkgs.writeShellScript "netbird-relay-env" ''
          set -eu
          install -m 600 /dev/null ${netbirdDataPath}/relay.env
          echo "NB_AUTH_SECRET=$(cat ${netbirdDataPath}/relay-secret)" \
            > ${netbirdDataPath}/relay.env
        ''}"
      ];
    };

    systemd.services.podman-netbird-dashboard = lib.mkIf enabled {
      after = [ "dns-ready.service" ];
      requires = [ "dns-ready.service" ];
      partOf = [ "nftables.service" ];
      unitConfig.ConditionPathExists = [
        "${secretsDir}/oidc-client-id"
      ];
      serviceConfig = {
        ExecStartPre = [
          "!${pkgs.writeShellScript "netbird-dashboard-prestart" dashboardEnvPreStart}"
        ];
        ## The netbirdio/dashboard container ignores SIGTERM cleanly:
        ## its entrypoint loops a "substitute env vars + exec nginx"
        ## script that absorbs the signal but never propagates a
        ## graceful shutdown. The default 2-minute TimeoutStopSec
        ## means every `systemctl restart` of the dashboard takes 2
        ## minutes — painful during rebuilds, even with `--no-block`
        ## from zitadel-provision, because other units (caddy, the
        ## dashboard itself's auto-restart) end up waiting on it.
        ##
        ## Shorten the grace window to 5s and follow with SIGKILL.
        ## Nothing in the dashboard does writeable I/O on shutdown
        ## (it's a static nginx serving the SPA bundle), so an
        ## abrupt kill is safe.
        TimeoutStopSec = lib.mkForce "5s";
        KillMode = lib.mkForce "mixed";
      };
    };

    systemd.services.podman-netbird-coturn = lib.mkIf enabled {
      after = [ "dns-ready.service" ];
      requires = [ "dns-ready.service" ];
      partOf = [ "nftables.service" ];
    };

    ## ── NetBird client (router-as-peer) ────────────────────────────────
    services.netbird = lib.mkIf deployClient {
      enable = true;
      ## Setup-key based onboarding is handled out-of-band — the router
      ## host needs to `netbird up --management-url ... --setup-key ...`
      ## once after first deploy. See the plan for details.
    };

    ## ── service-config (admin UI surface) ──────────────────────────────
    ## All five server containers are always listed (and rendered) when
    ## NetBird is enabled. Pre-provisioning the management + dashboard
    ## containers will be inactive (their preStart bails on missing
    ## secrets) and the admin UI's health check will reflect that —
    ## NetBird shows as "needs SSO bootstrap" rather than "broken".
    homefree.service-config = lib.optionals enabled [
      {
        inherit (netbirdCfg) label name project-name;
        systemd-service-names = [
          "podman-netbird-management"
          "podman-netbird-signal"
          "podman-netbird-relay"
          "podman-netbird-dashboard"
          "podman-netbird-coturn"
        ] ++ lib.optional deployClient "netbird";
        admin = {
          urlPathOverride = "/";
        };
        reverse-proxy = {
          enable = enabled;
          subdomains = [ "netbird" ];
          http-domains = [ "homefree.lan" cfg.system.localDomain ];
          https-domains = [ domain ];
          host = lan-address;
          port = netbirdDashboardPort;
          public = netbirdCfg.public;
          ## NetBird's API and signal speak HTTP/2 (gRPC). Caddy needs
          ## h2c upstreams for these paths. Everything else (the dashboard
          ## SPA + nginx) is plain HTTP/1.
          extraCaddyConfig = ''
            ## Management HTTP API (REST)
            handle /api/* {
              reverse_proxy http://${lan-address}:${toString netbirdMgmtPort}
            }
            ## Management gRPC
            handle /management.ManagementService/* {
              reverse_proxy h2c://${lan-address}:${toString netbirdMgmtPort}
            }
            ## Signal gRPC
            handle /signalexchange.SignalExchange/* {
              reverse_proxy h2c://${lan-address}:${toString netbirdSignalPort}
            }
          '';
        };
        firewall = {
          open-ports = {
            tcp = [
              netbirdMgmtPort
              netbirdSignalPort
              netbirdRelayPort
            ];
            udp = [
              netbirdStunPort
            ];
          };
        };
        backup = {
          paths = [
            netbirdDataPath
            netbirdSignalDataPath
          ];
        };
        options-metadata = [
          {
            path = "enable";
            type = "bool";
            default = false;
            description = "Enable NetBird VPN server";
          }
          {
            path = "public";
            type = "bool";
            default = false;
            description = "Dashboard accessible from WAN";
          }
          {
            path = "client.enable";
            type = "bool";
            default = false;
            description = "Also run the NetBird client on this host (router as peer). Independent of server.";
          }
          ## All four secrets are now provisioned automatically by
          ## zitadel-provision.service. They no longer appear here as
          ## user-fillable fields.
        ];
      }
    ];
  };
}
