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
  userOptions = {
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
    client = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Run the NetBird client on this host (router as peer). Independent of server.";
      };
    };
  };

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

  ## Anchors auto-generated secrets into encrypted /etc/nixos/secrets
  ## so they survive a restore — see lib/secrets-anchor.nix.
  anchor = import ../../lib/secrets-anchor.nix { inherit lib pkgs; };

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

    ## TURN/relay secrets, anchored into encrypted /etc/nixos/secrets
    ## so they survive a restore (lib/secrets-anchor.nix). Runtime
    ## copies stay in netbirdDataPath where the management.json sed
    ## block below reads them; mkdirMode=null because that dir is
    ## created (and owned) earlier in this preStart.
    ${anchor.preamble}
    ${anchor.anchorSecret {
      service = "netbird";
      key = "turn-secret";
      dir = netbirdDataPath;
      mkdirMode = null;
      generate = "${pkgs.openssl}/bin/openssl rand -hex 32";
    }}
    ${anchor.anchorSecret {
      service = "netbird";
      key = "turn-password";
      dir = netbirdDataPath;
      mkdirMode = null;
      generate = "${pkgs.openssl}/bin/openssl rand -hex 16";
    }}
    ${anchor.anchorSecret {
      service = "netbird";
      key = "relay-secret";
      dir = netbirdDataPath;
      mkdirMode = null;
      generate = "${pkgs.openssl}/bin/openssl rand -hex 32";
    }}

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
      ${./management.json.tmpl} \
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
  ## netbird's user-facing JSON-binding schema. This REPLACES the
  ## legacy compat shim that module.nix declared for
  ## `homefree.services.netbird`. The `service-options.netbird` block
  ## below is the authoritative full schema (a superset) and is left
  ## intact deliberately.
  options.homefree.services.netbird = userOptions;

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

    ## NetBird's secrets (oidc-client-{id,secret}, mgmt-machine-token,
    ## data-store-encryption-key) are filled in automatically by
    ## zitadel-provision.service — OIDC pair + PAT minted via the
    ## Zitadel API, encryption key generated locally. preStart scripts
    ## read the files directly from /var/lib/homefree-secrets/netbird/,
    ## bypassing the Nix-config layer. No option declarations here.
  };

  config = {
    ## Reserve NetBird's host-published ports from the kernel's ephemeral
    ## range (32768–60999). Without this, an outbound TCP connection
    ## (most commonly tailscaled, but anything making outbound TCP) can
    ## randomly grab one of these as its source port — then podman's
    ## `bind(0.0.0.0:<port>)` for the relay/mgmt/dashboard fails with
    ## `address already in use`, the unit goes into a restart loop, and
    ## the box ships with a flaky Apply (rebuild exits 4, UI stays
    ## yellow). Reserving here means the kernel won't auto-assign these
    ## for outbound — listener binds always succeed. Only ports inside
    ## the ephemeral range need this; ones below 32768 (e.g. 10000) are
    ## already safe. ip_local_reserved_ports accepts ranges and
    ## comma-separated lists. Set unconditionally — the cost is zero
    ## when NetBird is disabled (kernel just reserves three numbers).
    boot.kernel.sysctl."net.ipv4.ip_local_reserved_ports" =
      "${toString netbirdMgmtPort},${toString netbirdRelayPort},${toString netbirdDashboardPort}";

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
          ## NetBird 0.70+ runs the REST API + gRPC mux on container
          ## port 80, with a legacy gRPC-only compat server on the
          ## port configured in management.json (33073). All Caddy
          ## traffic — REST `/api/*` and `/management.ManagementService/*`
          ## gRPC — targets host:33073 → container:80. The legacy
          ## gRPC-only socket on container:33073 is unused.
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
      wants = [ "dns-ready.service" ];
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
      wants = [ "dns-ready.service" ];
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
      wants = [ "dns-ready.service" ];
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
      wants = [ "dns-ready.service" ];
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
      wants = [ "dns-ready.service" ];
    };


    ## ── NetBird router-as-peer bootstrap (declarative) ────────────────
    ## NetBird's REST API only accepts Zitadel-issued JWTs whose `aud`
    ## claim includes the netbird OIDC client_id. We can't get such a
    ## token for a machine user — Zitadel's `client_credentials` /
    ## JWT-profile flows produce tokens with aud=[project_id, machine
    ## -user-name], never the netbird app's client_id.
    ##
    ## So we bootstrap via SQL surgery on netbird's own sqlite store
    ## instead. NetBird's SetupKey row layout:
    ##   key        = base64(sha256(plaintext_key))
    ##   key_secret = first5chars + "****"     (HiddenKey display preview)
    ## We generate a UUID-shaped plaintext key, hash + insert it, then
    ## write the plaintext to /var/lib/homefree-secrets/netbird/setup-
    ## key for `netbird up`. Idempotent: re-inserts only if the named
    ## key is absent. We pick up the existing account_id from the
    ## accounts table; netbird's "single account mode" guarantees
    ## exactly one row.
    ##
    ## Route creation follows the same pattern after the local peer
    ## has registered: INSERT a routes row pointing at the peer's id.
    systemd.services.netbird-mint-setup-key = lib.mkIf deployClient {
      description = "Mint a NetBird setup-key for the local router peer (SQL bootstrap)";
      after = [ "podman-netbird-management.service" ];
      requires = [ "podman-netbird-management.service" ];
      wantedBy = [ "netbird.service" ];
      before = [ "netbird.service" ];
      ## Account row is only created after the first user logs in via
      ## SSO. On a fresh install we'll fail until that happens, then
      ## succeed on retry. Restart=on-failure with backoff keeps us
      ## trying without hard-burning the boot.
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "60s";
      };
      startLimitIntervalSec = 3600;
      startLimitBurst = 30;
      path = with pkgs; [ sqlite coreutils util-linux openssl ];
      script = ''
        set -eu
        SECRETS_DIR=${secretsDir}
        DB=${netbirdDataPath}/store.db
        KEY_FILE="$SECRETS_DIR/setup-key"
        KEY_NAME="homefree-router"

        ## Wait for management to have created the DB + first account
        ## (happens on the very first user login, then persists).
        ## Single-account-mode means we always converge on exactly one
        ## account row.
        deadline=$(( $(date +%s) + 60 ))
        while [ ! -s "$DB" ] \
              || [ -z "$(sqlite3 "$DB" 'SELECT id FROM accounts LIMIT 1;' 2>/dev/null)" ]; do
          [ $(date +%s) -ge $deadline ] && \
            { echo "netbird-mint-setup-key: no account row after 60s — has a user logged in?" >&2; exit 1; }
          sleep 2
        done
        ACCT_ID=$(sqlite3 "$DB" 'SELECT id FROM accounts LIMIT 1;')

        ## If a key with our name already exists, reuse the plaintext
        ## from disk (the DB doesn't store plaintext — only its hash).
        EXISTING=$(sqlite3 "$DB" \
          "SELECT id FROM setup_keys WHERE name='$KEY_NAME' AND revoked=0;")
        if [ -n "$EXISTING" ] && [ -s "$KEY_FILE" ]; then
          echo "netbird-mint-setup-key: existing key reused (id=$EXISTING)"
          exit 0
        fi
        ## If a key exists but we lack the plaintext, the only recovery
        ## is to revoke + re-mint. Revoke the orphan rows so the new
        ## key wins; the on-disk file is the source of truth.
        if [ -n "$EXISTING" ]; then
          echo "netbird-mint-setup-key: orphan key (no plaintext on disk) — revoking and re-minting"
          sqlite3 "$DB" "UPDATE setup_keys SET revoked=1 WHERE name='$KEY_NAME';"
        fi

        ## Plaintext follows the same shape as netbird's CLI-generated
        ## keys: uppercase UUID. NetBird's hashed_key = base64(sha256).
        PLAINTEXT=$(uuidgen | tr '[:lower:]' '[:upper:]')
        HASHED=$(printf '%s' "$PLAINTEXT" | openssl dgst -sha256 -binary | openssl base64 -A)
        ## HiddenKey(key, 4) = first 5 chars + 4 asterisks
        PREFIX=$(printf '%s' "$PLAINTEXT" | cut -c1-5)
        SECRET="$PREFIX****"
        KEY_ID=$(uuidgen | tr -d '-' | cut -c1-20)
        NOW=$(date -u +'%Y-%m-%dT%H:%M:%S.%NZ')

        ## Reusable key, no expiry (NetBird interprets expires_at NULL
        ## or far-future as non-expiring; we use a 100y horizon to be
        ## safe across all version checks), unlimited usage.
        EXPIRES="2099-12-31T23:59:59Z"
        sqlite3 "$DB" <<SQL
INSERT INTO setup_keys (
  id, account_id, key, key_secret, name, type,
  created_at, expires_at, updated_at, revoked, used_times,
  auto_groups, usage_limit, ephemeral, allow_extra_dns_labels
) VALUES (
  '$KEY_ID', '$ACCT_ID', '$HASHED', '$SECRET', '$KEY_NAME', 'reusable',
  '$NOW', '$EXPIRES', '$NOW', 0, 0,
  '[]', 0, 0, 0
);
SQL

        install -m 600 /dev/null "$KEY_FILE"
        printf '%s' "$PLAINTEXT" > "$KEY_FILE"
        echo "netbird-mint-setup-key: minted setup-key (id=$KEY_ID, name=$KEY_NAME)"
      '';
    };

    ## ── NetBird client (router-as-peer) ────────────────────────────────
    ## Activate the upstream NixOS module's "backwards compatible"
    ## default client. This starts the netbird daemon as
    ## netbird.service with the `netbird` CLI wrapper on PATH.
    services.netbird = lib.mkIf deployClient {
      enable = true;
    };

    ## Autoconnect oneshot: once the daemon is running AND the
    ## setup-key file exists AND the management backend is
    ## reachable, run `netbird up` to register this host as a peer
    ## and advertise the LAN subnet. Idempotent: reruns are no-ops
    ## once the local config has the management URL + key recorded.
    ##
    ## We ordered after podman-netbird-management.service plus a
    ## runtime readiness probe (the systemd `after=` only sequences
    ## start-of-unit; the container reports "started" before its
    ## HTTP listener is ready). Without the probe, `netbird up`
    ## races the management container and gets a Caddy 502 in the
    ## brief window before podman publishes the upstream socket.
    systemd.services.netbird-autoconnect = lib.mkIf deployClient {
      description = "Onboard the local netbird client into the tenant";
      after = [
        "netbird.service"
        "netbird-mint-setup-key.service"
        "podman-netbird-management.service"
      ];
      requires = [
        "netbird.service"
        "netbird-mint-setup-key.service"
        "podman-netbird-management.service"
      ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = [
        "${secretsDir}/setup-key"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = with pkgs; [ netbird coreutils jq curl ];
      script = ''
        set -eu
        SECRETS_DIR=${secretsDir}
        MGMT_URL="https://netbird.${domain}"
        KEY=$(cat "$SECRETS_DIR/setup-key")
        ## Upstream NixOS module relocates the CLI socket from
        ## /var/run/netbird.sock → /run/netbird/sock.
        DAEMON_ADDR="unix:///run/netbird/sock"

        deadline=$(( $(date +%s) + 30 ))
        while [ ! -S /run/netbird/sock ]; do
          [ $(date +%s) -ge $deadline ] && \
            { echo "netbird-autoconnect: daemon socket never appeared" >&2; exit 1; }
          sleep 1
        done

        ## Wait for the management HTTP backend to be ready. The
        ## management container's systemd unit reports active as
        ## soon as conmon is up, but the Go process inside takes
        ## a few seconds to bind the listener and Caddy returns
        ## 502 until then. We poll a cheap endpoint (the default
        ## management API root, expected to return 404 once routes
        ## are mounted — anything that isn't a 5xx/connection-
        ## error means the backend is reachable).
        ##
        ## 60s budget — the container's prestart can be slow on a
        ## cold boot. Cert verification via the system trust store
        ## (Caddy's internal CA is mounted into other clients via
        ## per-service plumbing; for this CLI probe we just trust
        ## whatever the system trusts).
        deadline=$(( $(date +%s) + 60 ))
        while :; do
          code=$(curl -sk -o /dev/null -w '%{http_code}' \
            --max-time 3 "$MGMT_URL/" || echo 000)
          case "$code" in
            5*|000) ;;          ## not ready — 5xx or connect error
            *) break ;;         ## any non-5xx response = listener up
          esac
          [ $(date +%s) -ge $deadline ] && \
            { echo "netbird-autoconnect: management backend never became reachable (last HTTP $code)" >&2; exit 1; }
          sleep 2
        done

        if netbird --daemon-addr "$DAEMON_ADDR" status --json 2>/dev/null \
           | jq -e '.managementState == "Connected"' >/dev/null 2>&1; then
          echo "netbird-autoconnect: already connected"
          exit 0
        fi

        netbird --daemon-addr "$DAEMON_ADDR" up \
          --management-url "$MGMT_URL" \
          --setup-key "$KEY"
        echo "netbird-autoconnect: onboarded"
      '';
    };

    ## After our local peer has registered with management, ensure a
    ## route exists routing the LAN subnet through this peer. Same
    ## SQL-surgery pattern as setup-key minting: idempotent INSERT
    ## guarded by a name lookup.
    systemd.services.netbird-ensure-route = lib.mkIf deployClient {
      description = "Ensure NetBird LAN subnet route exists for the router peer";
      after = [ "netbird-autoconnect.service" ];
      requires = [ "netbird-autoconnect.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = with pkgs; [ sqlite coreutils nettools util-linux ];
      script = ''
        set -eu
        DB=${netbirdDataPath}/store.db
        SUBNET="${cfg.network.lan-subnet}"
        ROUTE_NAME="homefree-lan"
        HOSTNAME=$(hostname)

        ## Wait up to 60s for our peer (registered by netbird up via
        ## the setup key) to appear in the DB.
        deadline=$(( $(date +%s) + 60 ))
        PEER_ID=""
        while [ -z "$PEER_ID" ]; do
          PEER_ID=$(sqlite3 "$DB" \
            "SELECT id FROM peers WHERE dns_label='$HOSTNAME' OR meta_hostname='$HOSTNAME' LIMIT 1;" \
            2>/dev/null || true)
          [ -n "$PEER_ID" ] && break
          [ $(date +%s) -ge $deadline ] && \
            { echo "netbird-ensure-route: peer for $HOSTNAME never registered" >&2; exit 1; }
          sleep 3
        done

        ACCT_ID=$(sqlite3 "$DB" 'SELECT id FROM accounts LIMIT 1;')
        ## "All" group is the default group every peer belongs to;
        ## using it on the route makes the LAN reachable to all peers.
        ALL_GROUP=$(sqlite3 "$DB" "SELECT id FROM groups WHERE name='All' AND account_id='$ACCT_ID';")
        if [ -z "$ALL_GROUP" ]; then
          echo "netbird-ensure-route: 'All' group not found" >&2
          exit 1
        fi

        ## Idempotency: skip if a route for this peer+subnet+name exists.
        EXISTING=$(sqlite3 "$DB" \
          "SELECT id FROM routes WHERE peer='$PEER_ID' AND network='\"$SUBNET\"' AND net_id='$ROUTE_NAME';")
        if [ -n "$EXISTING" ]; then
          echo "netbird-ensure-route: existing route reused (id=$EXISTING)"
          exit 0
        fi

        ROUTE_ID=$(uuidgen | tr -d '-' | cut -c1-20)
        ## `network` and `groups` columns are stored as JSON-serialized
        ## by NetBird (GORM `serializer:json`). We pass JSON-quoted
        ## values so the row round-trips through NetBird's deserializer
        ## correctly.
        GROUPS_JSON="[\"$ALL_GROUP\"]"
        NETWORK_JSON="\"$SUBNET\""

        sqlite3 "$DB" <<SQL
INSERT INTO routes (
  id, account_id, network, domains, keep_route, net_id, description,
  peer, peer_groups, network_type, masquerade, metric, enabled,
  groups, access_control_groups, skip_auto_apply
) VALUES (
  '$ROUTE_ID', '$ACCT_ID', '$NETWORK_JSON', '[]', 0, '$ROUTE_NAME',
  'HomeFree LAN subnet auto-route',
  '$PEER_ID', '[]', 1, 1, 9999, 1,
  '$GROUPS_JSON', '[]', 0
);
SQL
        echo "netbird-ensure-route: route created (id=$ROUTE_ID, peer=$PEER_ID, network=$SUBNET)"

        ## Force netbird-management to reload its in-memory account
        ## cache so peers see the new route on their next sync. A
        ## graceful container restart triggers a fresh load from
        ## the SQLite store.
        ${pkgs.systemd}/bin/systemctl --no-block restart podman-netbird-management.service || true
      '';
    };

    ## After the route is in place, register a primary nameserver
    ## group pointing at the LAN AdGuard resolver. Without this,
    ## peers route LAN traffic through the tunnel but still resolve
    ## DNS via their carrier's resolver, so `photos.<domain>` etc.
    ## come back with the public WAN IP instead of the LAN address.
    ##
    ## Same SQL-bootstrap pattern as the route — INSERT a
    ## name_server_groups row pointed at the "All" group, primary=1,
    ## so the resolver is consulted for every DNS query.
    ##
    ## NameServerType enum: 1 = UDP (iota+1 in netbird's dns
    ## package).  NameServers list is JSON-serialized — netbird's
    ## GORM serializer marshals NSType as the int form.
    systemd.services.netbird-ensure-nameserver = lib.mkIf deployClient {
      description = "Ensure NetBird primary nameserver group exists for LAN resolution";
      after = [ "netbird-ensure-route.service" ];
      requires = [ "netbird-ensure-route.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = with pkgs; [ sqlite coreutils util-linux ];
      script = ''
        set -eu
        DB=${netbirdDataPath}/store.db
        NS_NAME="homefree-lan-dns"
        LAN_IP="${lan-address}"

        ACCT_ID=$(sqlite3 "$DB" 'SELECT id FROM accounts LIMIT 1;')
        ALL_GROUP=$(sqlite3 "$DB" "SELECT id FROM groups WHERE name='All' AND account_id='$ACCT_ID';")
        if [ -z "$ALL_GROUP" ]; then
          echo "netbird-ensure-nameserver: 'All' group not found" >&2
          exit 1
        fi

        EXISTING=$(sqlite3 "$DB" \
          "SELECT id FROM name_server_groups WHERE name='$NS_NAME' AND account_id='$ACCT_ID';")
        if [ -n "$EXISTING" ]; then
          echo "netbird-ensure-nameserver: existing group reused (id=$EXISTING)"
          exit 0
        fi

        NS_ID=$(uuidgen | tr -d '-' | cut -c1-20)
        ## NameServers JSON: [{"IP":"10.0.0.1","NSType":1,"Port":53}]
        NS_LIST="[{\"IP\":\"$LAN_IP\",\"NSType\":1,\"Port\":53}]"
        GROUPS_JSON="[\"$ALL_GROUP\"]"

        ## `primary` is a SQL reserved keyword — quote with backticks
        ## (matches the column definition in netbird's schema).
        sqlite3 "$DB" <<SQL
INSERT INTO name_server_groups (
  id, account_id, name, description,
  name_servers, groups, \`primary\`,
  domains, enabled, search_domains_enabled
) VALUES (
  '$NS_ID', '$ACCT_ID', '$NS_NAME', 'HomeFree LAN DNS resolver',
  '$NS_LIST', '$GROUPS_JSON', 1,
  '[]', 1, 0
);
SQL
        echo "netbird-ensure-nameserver: created (id=$NS_ID, ip=$LAN_IP:53)"

        ${pkgs.systemd}/bin/systemctl --no-block restart podman-netbird-management.service || true
      '';
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
        sso = {
          kind = "native_oidc";
          ## Dev context (intentionally not surfaced in the admin UI):
          ## Native OIDC; uses a Zitadel machine-user PAT for
          ## backchannel user enumeration.
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
