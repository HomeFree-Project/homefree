{ config, lib, pkgs, ... }:

## SKIPPED Phase 3 non-root pass: NetBird's stack is 5 containers
## (management, signal, relay, dashboard, coturn) — four bind
## container-internal port 80, coturn uses --network=host for
## STUN/TURN, and the management container has a complex provisioning
## chain (JSON config, OIDC secrets, relay-secret). Each container
## would need its own UID, group memberships, and CAP_NET_BIND_SERVICE
## audit. Given that NetBird is the secondary VPN (Headscale is the
## daily driver per the project notes), the hardening payoff doesn't
## justify the per-container investigation risk. Each container still
## runs as root inside, but the host firewall + Caddy SSO gate are the
## primary defences here.
##
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
        default = true;
        description = ''
          Make this box the LAN routing peer when NetBird is enabled, and
          auto-provision remote network access for it. Defaults on so
          enabling NetBird "just works" for remote access; set false to run
          the server only (no local routing peer). Has no effect unless the
          NetBird server (enable) is on.
        '';
      };
    };
  };

  cfg = config.homefree;
  netbirdCfg = config.homefree.service-options.netbird;
  lan-address = cfg.network.lan-address;
  domain = cfg.system.domain;
  zitadelDomain = "sso.${domain}";

  ## Split-DNS match domains for the NetBird nameserver group: the public
  ## domains THIS box's resolver is authoritative for (the same split-horizon
  ## `zones` set in services/unbound). Tunneled peers send ONLY these suffixes
  ## to the box's LAN resolver; every other name stays on the peer's own
  ## resolver. Generic — derived from config, never hardcoded. The local
  ## domain (.lan) is intentionally excluded: it's LAN-only and identical
  ## across boxes, so matching it would re-introduce the cross-instance
  ## collision; remote peers reach internal services via the public domain,
  ## which split-horizon already maps to the LAN IP.
  splitDnsMatchDomains = lib.unique ([ cfg.system.domain ] ++ cfg.system.additionalDomains);
  splitDnsMatchDomainsJson = builtins.toJSON splitDnsMatchDomains;

  ## Image tags. Pin all of these together — NetBird ships breaking
  ## changes in the management.json schema across minor versions, so
  ## bumping these should be a deliberate, coordinated update.
  managementTag = "0.72.4";
  signalTag = "0.72.4";
  relayTag = "0.72.4";
  dashboardTag = "v2.39.0";
  coturnTag = "4.12.0";

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
  ## Routing-peer + auto-provisioning are gated on the server being enabled
  ## too — `client.enable` defaults true, so without this gate every box
  ## (even with NetBird off) would start the netbird client daemon.
  deployClient = enabled && netbirdCfg.client.enable;

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
        default = true;
        description = ''
          Make this box the LAN routing peer and auto-provision remote
          network access (the "Networks" model: a network + subnet resource
          + routing-peer router + access policy + LAN nameserver group),
          replacing the dashboard onboarding wizard. Defaults on with the
          NetBird server; set false to run the server only. Gated on the
          server being enabled. Note: running both this and the tailscale
          client (services.tailscale, used by headscale) on the same router
          installs two sets of netfilter rules — test before enabling both.
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
    ## OIDC client descriptor — unconditional per modules/sso-clients.nix.
    homefree.sso.clients = [{
      svc = "netbird";
      internal_name = "homefree-netbird";
      ## NetBird needs to authenticate THREE clients with one OIDC app:
      ##   1. Web dashboard SPA at https://netbird.<domain>/{auth,silent-auth}
      ##   2. NetBird CLI / native client via loopback http://localhost:53000/
      ##   3. Mobile clients via the same loopback flow
      ## NATIVE app type is required for (2)/(3) — USER_AGENT rejects
      ## non-https loopback redirect_uris. NATIVE + AUTH_METHOD_NONE +
      ## PKCE accepts both https web callbacks and http loopback URIs.
      ##
      ## Even the web dashboard's "Sign in" button ends up redirecting
      ## through http://localhost:53000/ because the dashboard reads
      ## the PKCE config from /api/users/.../authorization — and that
      ## endpoint serves the management.json PKCEAuthorizationFlow
      ## (CLI-targeted). Registering localhost as a valid redirect on
      ## the same app fixes the browser flow too.
      app_type = "OIDC_APP_TYPE_NATIVE";
      auth_method = "OIDC_AUTH_METHOD_TYPE_NONE";
      response_types = [ "OIDC_RESPONSE_TYPE_CODE" ];
      ## DEVICE_CODE is required for the NetBird mobile/desktop app's
      ## Device Authorization Flow — without it, Zitadel rejects the
      ## /oauth/v2/device_authorization request and the app shows
      ## "Authentication error — see logs for more info" before any
      ## browser ever opens. AUTHORIZATION_CODE handles the loopback
      ## CLI + web dashboard flows; REFRESH_TOKEN keeps sessions alive.
      grant_types = [
        "OIDC_GRANT_TYPE_AUTHORIZATION_CODE"
        "OIDC_GRANT_TYPE_REFRESH_TOKEN"
        "OIDC_GRANT_TYPE_DEVICE_CODE"
      ];
      redirect_uris = [
        "https://netbird.${domain}/auth"
        "https://netbird.${domain}/silent-auth"
        "http://localhost:53000/"
      ];
      post_logout_uris = [ "https://netbird.${domain}/" ];
      needs_pat = true;        # mgmt machine user for org/group reads
      ## Both containers consume the client_id: management.json on
      ## the management side, and dashboard.env on the dashboard SPA
      ## side. Restart both when the secret rotates — otherwise the
      ## dashboard keeps a stale client_id and login fails with
      ## "Errors.App.NotFound".
      post_restart_units = [
        "podman-netbird-management.service"
        "podman-netbird-dashboard.service"
      ];
    }];

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
    ## All five containers are always rendered when NetBird is enabled,
    ## via the app-platform primitive (modules/app-platform.nix): the
    ## dedicated podman-* dns-ready units and the per-container shell are
    ## generated. Every container runs as root inside (see the SKIPPED
    ## Phase 3 note at the top of this file); none of the bespoke
    ## bootstrap (management.json synthesis, secret anchoring, env files,
    ## ConditionPathExists gates, extra ordering) lives in the primitive
    ## — that stays in the systemd.services.podman-* declarations below.
    ##
    ## Pre-provisioning, the management + dashboard containers refuse to
    ## start (their preStart bails / the unit's condition is unmet), and
    ## the others sit idle. zitadel-provision.service kicks them via
    ## `systemctl restart` once secrets land — single rebuild, no manual
    ## intervention.

    ## management — dataDir=null + caBundle=false: the whole bespoke
    ## preStart (CA-bundle synthesis, TURN/relay secret anchoring,
    ## management.json sed) lives verbatim in preStartInit. The
    ## ConditionPathExists secrets gate + extra ordering (after zitadel)
    ## stay in the systemd override below.
    homefree.containers.netbird-management = lib.mkIf enabled {
      image = "netbirdio/management:${managementTag}";
      runAs = { mode = "root"; reason = "upstream netbird image runs as root; binds container port 80"; };
      dataDir = null;
      caBundle = false;

      ## NetBird 0.70+ runs the REST API + gRPC mux on container
      ## port 80, with a legacy gRPC-only compat server on the
      ## port configured in management.json (33073). All Caddy
      ## traffic — REST /api/* and /management.ManagementService/*
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

      ## Full bespoke preStart (CA bundle + anchored TURN/relay secrets +
      ## management.json sed) — runs verbatim, no generated mkdir/chown.
      preStartInit = managementJsonPreStart;
    };

    ## signal — only a single mkdir of its own data dir; let the
    ## primitive emit that via dataDir (root mode → no chown).
    homefree.containers.netbird-signal = lib.mkIf enabled {
      image = "netbirdio/signal:${signalTag}";
      runAs = { mode = "root"; reason = "upstream netbird image runs as root; binds container port 80"; };
      ## Volume mount target needs to exist before podman binds it in;
      ## the primitive's mkdir covers what the hand-written preStart did.
      dataDir = netbirdSignalDataPath;
      caBundle = false;
      ports = [
        "0.0.0.0:${toString netbirdSignalPort}:80"
      ];
      volumes = [
        "${netbirdSignalDataPath}:/var/lib/netbird"
        "/etc/localtime:/etc/localtime:ro"
      ];
      cmd = [ "--log-file" "console" "--port" "80" ];
    };

    ## relay — dataDir=null + caBundle=false: relay.env synthesis lives
    ## verbatim in preStartInit. The ConditionPathExists relay-secret
    ## gate + after-management ordering stay in the override below.
    homefree.containers.netbird-relay = lib.mkIf enabled {
      image = "netbirdio/relay:${relayTag}";
      runAs = { mode = "root"; reason = "upstream netbird image runs as root"; };
      dataDir = null;
      caBundle = false;
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

      ## Render the relay env file from the generated relay-secret. The
      ## management container's preStart already creates the file under
      ## /var/lib/netbird/relay-secret; we just need to surface it as an
      ## env var via a separate file (kept tiny so it's easy to re-emit).
      preStartInit = ''
        set -eu
        install -m 600 /dev/null ${netbirdDataPath}/relay.env
        echo "NB_AUTH_SECRET=$(cat ${netbirdDataPath}/relay-secret)" \
          > ${netbirdDataPath}/relay.env
      '';
    };

    ## dashboard — dataDir=null + caBundle=false: dashboard.env synthesis
    ## (its own mkdir + set -eu) lives verbatim in preStartInit. The
    ## ConditionPathExists gate + TimeoutStopSec/KillMode shutdown tuning
    ## stay in the systemd override below.
    homefree.containers.netbird-dashboard = lib.mkIf enabled {
      image = "netbirdio/dashboard:${dashboardTag}";
      runAs = { mode = "root"; reason = "upstream netbird dashboard (nginx) image runs as root; binds container port 80"; };
      dataDir = null;
      caBundle = false;
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

      ## Full dashboard.env synthesis (its own set -eu + mkdir).
      preStartInit = dashboardEnvPreStart;
    };

    ## coturn — host networking for STUN/TURN. --network=host stays in
    ## extraOptions (NOT runAs.rootless — that would set the podman
    ## user= field and drift). No data dir / CA bundle / preStart, so
    ## the primitive emits no ExecStartPre for it (matching the
    ## hand-written unit). dns-ready ordering is generated.
    homefree.containers.netbird-coturn = lib.mkIf enabled {
      image = "coturn/coturn:${coturnTag}";
      runAs = { mode = "root"; reason = "coturn uses --network=host for STUN/TURN; runs root inside"; };
      extraOptions = [ "--network=host" ];
      volumes = [
        "${turnserverConfFile}:/etc/turnserver.conf:ro"
      ];
      cmd = [ "-c" "/etc/turnserver.conf" ];
    };

    ## ── systemd unit overrides (escape hatches) ──────────────────────────
    ## These merge with the generated podman-* units from the app-platform
    ## primitive to add the secrets gates + extra ordering the primitive
    ## doesn't know about. The primitive already supplies the dns-ready
    ## after/wants and (where present) the ExecStartPre prestart script.

    ## The management container's preStart bails on missing Zitadel
    ## secrets — see managementJsonPreStart's gate at the top of this
    ## file. The ConditionPathExists below keeps the unit cleanly
    ## inactive (rather than crash-looping) until zitadel-provision
    ## lands the secrets.
    systemd.services.podman-netbird-management = lib.mkIf enabled {
      after = [ "podman-zitadel.service" ];
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
    };

    systemd.services.podman-netbird-relay = lib.mkIf enabled {
      after = [ "podman-netbird-management.service" ];
      ## Relay needs the auth secret that netbird-management generates
      ## in its preStart. Gate on the file being present so we don't
      ## crash-loop pre-provisioning.
      unitConfig.ConditionPathExists = [
        "${netbirdDataPath}/relay-secret"
      ];
    };

    systemd.services.podman-netbird-dashboard = lib.mkIf enabled {
      unitConfig.ConditionPathExists = [
        "${secretsDir}/oidc-client-id"
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
      serviceConfig = {
        TimeoutStopSec = lib.mkForce "5s";
        KillMode = lib.mkForce "mixed";
      };
    };


    ## ── NetBird remote-network-access provisioning (REST) ─────────────
    ## Replaces the dashboard onboarding wizard: idempotently provisions the
    ## "Networks" model (a network + LAN subnet resource + routing-peer
    ## router + access policy), a reusable setup-key, and a LAN nameserver
    ## group, then connects this box as the routing peer — all via the
    ## NetBird REST API.
    ##
    ## Credential: the REST API accepts a PAT (`Authorization: Token`) or a
    ## Zitadel JWT whose `aud` is the netbird client_id. We can't mint such
    ## a JWT for a machine user, and NetBird's `/api/setup` (the only
    ## no-login PAT bootstrap) requires NetBird's *embedded* IDP — which is
    ## incompatible with our external Zitadel IDP and the SSO-only rule. So
    ## we mint a PAT the one way that works with an external IDP: insert a
    ## `personal_access_tokens` row for the owner user, reproducing exactly
    ## the token NetBird itself would issue — `nbp_` + 30 random base62
    ## chars + a 6-char base62 CRC32 checksum of the secret (the checksum IS
    ## verified on use), stored as base64(sha256(full-token)). Everything
    ## else is the supported REST API (no further SQL, no cache restart —
    ## REST writes go live immediately).
    ##
    ## Bootstrap (headless): with an external IDP, NetBird creates the account
    ## only on an interactive SSO login, and no token we can mint headlessly is
    ## accepted (a machine-user token's `aud` is never the netbird client_id —
    ## proven). So when no account exists, step 2 FABRICATES it directly in
    ## store.db (mirroring newAccountWithId) — no SSO login, no wizard, ever.
    ## Runs from a TIMER (never at `nixos-rebuild switch`) so it can't block or
    ## fail a rebuild; exits 0 on any not-ready condition and retries; a
    ## versioned `.netbird-provisioned-vN` sentinel + ConditionPathExists make
    ## it a no-op once complete. Bumping the version (when the provisioning
    ## logic changes) drops the old sentinel match so every box re-runs the
    ## (idempotent) script exactly once to converge to the new desired state.
    ##
    ## Reset/restore: the sentinel lives in netbirdDataPath next to
    ## store.db, so wiping the DB (the documented "reset NetBird" step) also
    ## drops the sentinel and re-provisions from scratch. Every step is
    ## idempotent + self-healing — a stale on-disk PAT/setup-key (kept under
    ## /var/lib/homefree-secrets, which is NOT wiped with the DB) is detected
    ## and re-minted, and pre-existing REST objects are reused. Anchoring is
    ## intentionally skipped: the generate→anchor model does not fit these
    ## DB-coordinated secrets (see docs/agent-notes/secrets-anchoring.md).
    systemd.services.netbird-provision = lib.mkIf deployClient {
      description = "Provision NetBird remote-network-access (Networks model + routing peer) via REST";
      after = [ "podman-netbird-management.service" "netbird.service" ];
      wants = [ "podman-netbird-management.service" "netbird.service" ];
      ## Skip once fully provisioned (sentinel written); the timer keeps
      ## firing but this becomes a cheap no-op. The version suffix is bumped
      ## whenever the provisioning logic changes so already-provisioned boxes
      ## re-run the idempotent script once (here: v1's catch-all DNS group ->
      ## v2's split-DNS group). nixos-rebuild restarts this changed unit, which
      ## re-evaluates the condition and runs immediately; the timer is backup.
      unitConfig.ConditionPathExists = "!${netbirdDataPath}/.netbird-provisioned-v2";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = with pkgs; [ curl jq sqlite coreutils util-linux openssl gzip netbird ];
      script = ''
        set -u
        SECRETS_DIR=${secretsDir}
        DB=${netbirdDataPath}/store.db
        API="http://127.0.0.1:${toString netbirdMgmtPort}"
        HOSTH="Host: netbird.${domain}"
        MGMT_URL="https://netbird.${domain}"
        SUBNET="${cfg.network.lan-subnet}"
        LAN_IP="${lan-address}"
        PAT_FILE="$SECRETS_DIR/netbird-api-pat"
        KEY_FILE="$SECRETS_DIR/setup-key"
        SENTINEL="${netbirdDataPath}/.netbird-provisioned-v2"
        ALPHABET=0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz

        log()    { echo "netbird-provision: $*"; }
        ## Never fail a boot/timer cycle: log and exit 0, leaving the
        ## sentinel unwritten so the timer retries on the next tick.
        giveup() { log "$*"; exit 0; }
        sq()     { sqlite3 -cmd '.timeout 8000' "$DB" "$@"; }

        ## 1. management API readiness (unauthenticated /api/users -> 401
        ##    once the listener is up; 5xx/000 while the backend is warming)
        ready=
        for _ in $(seq 1 30); do
          code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 -H "$HOSTH" "$API/api/users" 2>/dev/null || echo 000)
          case "$code" in 401|200) ready=1; break;; *) sleep 2;; esac
        done
        [ -n "$ready" ] || giveup "management API not ready yet — will retry"

        ## 2. ensure the NetBird account exists — fabricate it if absent.
        ##    NetBird only creates the account on an interactive SSO login, and
        ##    no headless token is accepted, so we write it straight into
        ##    store.db (mirroring newAccountWithId): the wide accounts row +
        ##    owner user + All group + default All->All policy + an
        ##    account_onboardings row with onboarding_flow_pending=0 (which
        ##    suppresses the dashboard wizard). NAMED columns, not positional —
        ##    the accounts column order changes across NetBird versions. Owner =
        ##    the admin's Zitadel user id (written by zitadel-provision), so the
        ##    admin is owner on first login; blank name/email are safe (NetBird
        ##    skips encrypt/decrypt of "" and the IdP cache fills them in).
        if [ -z "$(sq "SELECT id FROM accounts LIMIT 1;" 2>/dev/null || true)" ]; then
          OWNER_ID_FILE="$SECRETS_DIR/owner-user-id"
          [ -s "$OWNER_ID_FILE" ] \
            || giveup "no account and no owner-user-id yet (zitadel-provision pending) — will retry"
          FOWNER=$(cat "$OWNER_ID_FILE")
          gid() { head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-20; }
          ACCT=$(gid); NETID=$(gid); ALLG=$(gid); POL=$(gid)
          NETR=$(( (RANDOM % 64) + 64 ))    # random /16 in 100.64.0.0/10
          NOW=$(date -u +'%Y-%m-%d %H:%M:%S.%N+00:00')
          ## Q expands to an empty SQL string at runtime; emitted as '$Q' so
          ## the surrounding single-quotes are never adjacent in this Nix
          ## indented-string block (adjacent ones would end the string early).
          Q=""
          sq <<SQL
INSERT INTO accounts (id,created_by,created_at,domain,domain_category,is_domain_primary_account,network_identifier,network_net,network_net_v6,network_dns,network_serial,dns_settings_disabled_management_groups,settings_peer_login_expiration_enabled,settings_peer_login_expiration,settings_peer_inactivity_expiration_enabled,settings_peer_inactivity_expiration,settings_regular_users_view_blocked,settings_groups_propagation_enabled,settings_jwt_groups_enabled,settings_jwt_groups_claim_name,settings_jwt_allow_groups,settings_routing_peer_dns_resolution_enabled,settings_dns_domain,settings_network_range,settings_network_range_v6,settings_peer_expose_enabled,settings_peer_expose_groups,settings_extra_peer_approval_enabled,settings_extra_user_approval_required,settings_extra_integrated_validator,settings_extra_integrated_validator_groups,settings_lazy_connection_enabled,settings_auto_update_version,settings_auto_update_always,settings_ipv6_enabled_groups,settings_local_mfa_enabled) VALUES ('$ACCT','$FOWNER','$NOW','netbird.${domain}','private',1,'$NETID','{"IP":"100.$NETR.0.0","Mask":"//8AAA=="}',NULL,'$Q',0,'[]',1,86400000000000,0,600000000000,1,1,0,'$Q','[]',1,'$Q','"100.$NETR.0.0/16"','""',0,NULL,0,1,'$Q',NULL,0,'disabled',0,NULL,0);
INSERT INTO users (id,account_id,role,is_service_user,non_deletable,service_user_name,auto_groups,blocked,pending_approval,created_at,issued,integration_ref_id,integration_ref_integration_type,name,email) VALUES ('$FOWNER','$ACCT','owner',0,0,'$Q','[]',0,0,'$NOW','api',0,'$Q','$Q','$Q');
INSERT INTO "groups" (id,account_id,name,issued,resources,integration_ref_id,integration_ref_integration_type) VALUES ('$ALLG','$ACCT','All','api',NULL,0,'$Q');
INSERT INTO policies (id,account_id,name,description,enabled,source_posture_checks) VALUES ('$POL','$ACCT','Default','This is a default rule that allows connections between all the resources',1,NULL);
INSERT INTO policy_rules (id,policy_id,name,description,enabled,action,destinations,destination_resource,sources,source_resource,bidirectional,protocol,ports,port_ranges,authorized_groups,authorized_user) VALUES ('$POL','$POL','Default','This is a default rule that allows connections between all the resources',1,'accept','["$ALLG"]','{"ID":"","Type":""}','["$ALLG"]','{"ID":"","Type":""}',1,'all','[]','[]','{}','$Q');
INSERT INTO account_onboardings (account_id,onboarding_flow_pending,signup_form_pending,created_at,updated_at) VALUES ('$ACCT',0,0,'$NOW','$NOW');
SQL
          log "fabricated NetBird account ($ACCT, owner $FOWNER, net 100.$NETR.0.0/16)"
          ## Management cached "no account" at startup; restart so it loads the
          ## fabricated account from store.db, then re-probe readiness.
          ${pkgs.systemd}/bin/systemctl restart podman-netbird-management.service || true
          ready=
          for _ in $(seq 1 30); do
            code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 -H "$HOSTH" "$API/api/users" 2>/dev/null || echo 000)
            case "$code" in 401|200) ready=1; break;; *) sleep 2;; esac
          done
          [ -n "$ready" ] || giveup "management not ready after fabrication restart — will retry"
        fi

        ## owner user id — now guaranteed present (fabricated or from a prior login)
        OWNER=$(sq "SELECT id FROM users WHERE role='owner' AND is_service_user=0 LIMIT 1;" 2>/dev/null || true)
        [ -n "$OWNER" ] || giveup "owner user not found after ensure-account — will retry"

        ## 3. API PAT: reuse the on-disk one if it still validates, else
        ##    mint a fresh one (insert a personal_access_tokens row for the
        ##    owner, reproducing NetBird's own token + checksum exactly).
        pat_ok() { [ "$(curl -s -o /dev/null -w '%{http_code}' -H "$HOSTH" -H "Authorization: Token $1" "$API/api/users")" = 200 ]; }
        PAT=
        if [ -s "$PAT_FILE" ] && pat_ok "$(cat "$PAT_FILE")"; then
          PAT=$(cat "$PAT_FILE"); log "reusing API PAT"
        else
          SECRET=$(tr -dc 0-9A-Za-z </dev/urandom | head -c30)
          ## CRC32 (IEEE) of the secret via gzip's trailer (4 bytes, LE)
          set -- $(printf '%s' "$SECRET" | gzip -c | tail -c8 | head -c4 | od -An -tu1)
          CRC=$(( $1 + $2 * 256 + $3 * 65536 + $4 * 16777216 ))
          ## base62-encode the checksum, then left-pad to 6 with '0'
          ENC=; N=$CRC
          [ "$N" -eq 0 ] && ENC=0
          while [ "$N" -gt 0 ]; do
            POS=$(( (N % 62) + 1 ))
            ENC=$(printf '%s' "$ALPHABET" | cut -c"$POS")$ENC
            N=$(( N / 62 ))
          done
          while [ "$(printf '%s' "$ENC" | wc -c)" -lt 6 ]; do ENC=0$ENC; done
          PLAIN=nbp_$SECRET$ENC
          HASH=$(printf '%s' "$PLAIN" | openssl dgst -sha256 -binary | openssl base64 -A)
          PID=$(uuidgen | tr -d -); NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
          sq "DELETE FROM personal_access_tokens WHERE name='homefree-provision';"
          sq "INSERT INTO personal_access_tokens (id,user_id,name,hashed_token,expiration_date,created_by,created_at,last_used) VALUES ('$PID','$OWNER','homefree-provision','$HASH','2099-12-31T23:59:59Z','$OWNER','$NOW','$NOW');"
          pat_ok "$PLAIN" || giveup "freshly minted PAT did not validate — will retry"
          install -m 600 /dev/null "$PAT_FILE"; printf '%s' "$PLAIN" > "$PAT_FILE"
          PAT=$PLAIN; log "minted API PAT"
        fi
        AUTH="Authorization: Token $PAT"

        api() {
          if [ "$#" -ge 3 ]; then
            curl -s -X "$1" -H "$HOSTH" -H "$AUTH" -H 'Content-Type: application/json' -d "$3" "$API$2"
          else
            curl -s -X "$1" -H "$HOSTH" -H "$AUTH" "$API$2"
          fi
        }
        ## first id of a named object in a JSON-array endpoint
        find_id() { api GET "$1" | jq -r --arg n "$2" '.[] | select(.name==$n) | .id' 2>/dev/null | head -1; }

        ## 4. groups: default "All" (find) + "Routing Peers" (ensure)
        ALL_GID=$(find_id /api/groups All)
        [ -n "$ALL_GID" ] || giveup "default 'All' group not present yet — will retry"
        RP_GID=$(find_id /api/groups "Routing Peers")
        if [ -z "$RP_GID" ]; then
          RP_GID=$(api POST /api/groups '{"name":"Routing Peers"}' | jq -r '.id // empty')
          log "created group 'Routing Peers'"
        fi
        [ -n "$RP_GID" ] || giveup "could not ensure 'Routing Peers' group — will retry"

        ## 5. reusable setup-key (auto_groups -> Routing Peers). The plaintext
        ##    is only returned at create, so re-mint if we lack the on-disk copy.
        SK_ID=$(api GET /api/setup-keys | jq -r '.[] | select(.name=="homefree-router" and .revoked==false) | .id' 2>/dev/null | head -1)
        if [ -n "$SK_ID" ] && [ -s "$KEY_FILE" ]; then
          log "reusing setup-key homefree-router"
        else
          [ -n "$SK_ID" ] && api PUT "/api/setup-keys/$SK_ID" "{\"revoked\":true,\"auto_groups\":[\"$RP_GID\"]}" >/dev/null
          SK_PLAIN=$(api POST /api/setup-keys "{\"name\":\"homefree-router\",\"type\":\"reusable\",\"expires_in\":31536000,\"auto_groups\":[\"$RP_GID\"],\"usage_limit\":0}" | jq -r '.key // empty')
          [ -n "$SK_PLAIN" ] || giveup "setup-key creation returned no key — will retry"
          install -m 600 /dev/null "$KEY_FILE"; printf '%s' "$SK_PLAIN" > "$KEY_FILE"
          log "minted setup-key homefree-router"
        fi

        ## 6. network
        NET_ID=$(find_id /api/networks "HomeFree LAN")
        if [ -z "$NET_ID" ]; then
          NET_ID=$(api POST /api/networks '{"name":"HomeFree LAN","description":"Auto-provisioned LAN remote-access network"}' | jq -r '.id // empty')
          log "created network 'HomeFree LAN'"
        fi
        [ -n "$NET_ID" ] || giveup "could not ensure network — will retry"

        ## 7. subnet resource (type is auto-derived from the CIDR address)
        RES_ID=$(api GET "/api/networks/$NET_ID/resources" | jq -r '.[] | select(.name=="HomeFree LAN subnet") | .id' 2>/dev/null | head -1)
        RES_TYPE=$(api GET "/api/networks/$NET_ID/resources" | jq -r '.[] | select(.name=="HomeFree LAN subnet") | .type' 2>/dev/null | head -1)
        if [ -z "$RES_ID" ]; then
          RES_JSON=$(api POST "/api/networks/$NET_ID/resources" "{\"name\":\"HomeFree LAN subnet\",\"description\":\"$SUBNET\",\"address\":\"$SUBNET\",\"enabled\":true,\"groups\":[\"$RP_GID\"]}")
          RES_ID=$(printf '%s' "$RES_JSON" | jq -r '.id // empty')
          RES_TYPE=$(printf '%s' "$RES_JSON" | jq -r '.type // empty')
          log "created resource 'HomeFree LAN subnet'"
        fi
        [ -n "$RES_ID" ] || giveup "could not ensure resource — will retry"
        [ -n "$RES_TYPE" ] || RES_TYPE=subnet

        ## 8. router (peer_groups -> Routing Peers; this box auto-joins that
        ##    group via the setup-key, so no peer-id lookup / DB race)
        HAS_ROUTER=$(api GET "/api/networks/$NET_ID/routers" | jq -r --arg g "$RP_GID" '.[] | select(.peer_groups != null and (.peer_groups | index($g))) | .id' 2>/dev/null | head -1)
        if [ -z "$HAS_ROUTER" ]; then
          api POST "/api/networks/$NET_ID/routers" "{\"peer_groups\":[\"$RP_GID\"],\"metric\":9999,\"masquerade\":true,\"enabled\":true}" >/dev/null
          log "created router (peer_groups=Routing Peers)"
        fi

        ## 9. access policy: All -> the subnet resource (every peer reaches LAN)
        if [ -z "$(find_id /api/policies "HomeFree LAN access")" ]; then
          api POST /api/policies "{\"name\":\"HomeFree LAN access\",\"description\":\"Allow all peers to reach the HomeFree LAN\",\"enabled\":true,\"rules\":[{\"name\":\"HomeFree LAN access\",\"enabled\":true,\"bidirectional\":true,\"protocol\":\"all\",\"action\":\"accept\",\"sources\":[\"$ALL_GID\"],\"destinationResource\":{\"id\":\"$RES_ID\",\"type\":\"$RES_TYPE\"}}]}" >/dev/null
          log "created policy 'HomeFree LAN access'"
        fi

        ## 10. nameserver group (SPLIT-DNS, not catch-all): tunneled peers send
        ##     ONLY this box's own domains (${splitDnsMatchDomainsJson}) to its
        ##     LAN resolver; every other name — other HomeFree boxes' domains,
        ##     public sites — stays on the peer's own resolver.
        ##
        ##     A catch-all group (primary:true, domains:[]) hijacks ALL DNS the
        ##     instant a peer connects, so a phone on box A's LAN + box B's VPN
        ##     resolves A's own names via B's resolver and gets B's WAN IP
        ##     (cert/SSL errors). primary:false + match-domains scopes each box
        ##     to the domains its resolver is actually authoritative for.
        ##
        ##     Converge (PUT existing), don't create-or-skip: boxes provisioned
        ##     under v1 already have the old catch-all group and must be fixed
        ##     in place. jq builds the body so the Nix-rendered domain array
        ##     and the runtime ids/IP are escaped correctly.
        NS_BODY=$(jq -cn \
          --arg ip "$LAN_IP" --arg gid "$ALL_GID" \
          --argjson domains '${splitDnsMatchDomainsJson}' \
          '{name:"homefree-lan-dns",
            description:"HomeFree split-DNS resolver (this instance domains only)",
            nameservers:[{ip:$ip,ns_type:"udp",port:53}],
            enabled:true,groups:[$gid],
            primary:false,domains:$domains,search_domains_enabled:true}')
        NS_ID=$(find_id /api/dns/nameservers "homefree-lan-dns")
        if [ -z "$NS_ID" ]; then
          api POST /api/dns/nameservers "$NS_BODY" >/dev/null \
            && log "created split-DNS nameserver group 'homefree-lan-dns'"
        else
          api PUT "/api/dns/nameservers/$NS_ID" "$NS_BODY" >/dev/null \
            && log "converged split-DNS nameserver group 'homefree-lan-dns' to match-domains"
        fi

        ## 11. connect this box as the routing peer (one-time; the netbird
        ##     daemon persists the config and reconnects by itself after)
        if [ ! -S /run/netbird/sock ]; then
          for _ in $(seq 1 15); do [ -S /run/netbird/sock ] && break; sleep 1; done
        fi
        [ -S /run/netbird/sock ] || giveup "netbird daemon socket not up yet — will retry"
        if netbird --daemon-addr unix:///run/netbird/sock status --json 2>/dev/null | jq -e '.managementState == "Connected"' >/dev/null 2>&1; then
          log "router peer already connected"
        else
          netbird --daemon-addr unix:///run/netbird/sock up --management-url "$MGMT_URL" --setup-key "$(cat "$KEY_FILE")" || giveup "netbird up failed — will retry"
          log "router peer connected"
        fi

        ## done — the sentinel makes ConditionPathExists skip future runs
        : > "$SENTINEL"
        log "provisioning complete"
      '';
    };

    ## Drive netbird-provision from a timer (not wantedBy multi-user.target)
    ## so `nixos-rebuild switch` never blocks on, or fails because of,
    ## pre-login provisioning. It retries every ~2 min until the sentinel is
    ## written, so the operator's single SSO login converges automatically.
    systemd.timers.netbird-provision = lib.mkIf deployClient {
      description = "Retry NetBird remote-access provisioning until complete";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "90s";
        OnActiveSec = "90s";
        OnUnitActiveSec = "2min";
        Unit = "netbird-provision.service";
      };
    };

    ## ── NetBird client (router-as-peer) ────────────────────────────────
    ## Activate the upstream NixOS module's "backwards compatible"
    ## default client. This starts the netbird daemon as
    ## netbird.service with the `netbird` CLI wrapper on PATH.
    services.netbird = lib.mkIf deployClient {
      enable = true;
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
          ## Only the stateful management dir is backed up. The signal
          ## server is a stateless gRPC relay that persists nothing in
          ## netbirdSignalDataPath (/var/lib/netbird-signal), so including
          ## it tripped the backup guard's empty-source abort on every
          ## run — a false positive, not a missing NAS mount.
          paths = [
            netbirdDataPath
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
            default = true;
            description = "Make this box the LAN routing peer and auto-provision remote network access (replaces the dashboard wizard). On by default with the server; set false to run the server only.";
          }
          ## All four secrets are now provisioned automatically by
          ## zitadel-provision.service. They no longer appear here as
          ## user-fillable fields.
        ];
      }
    ];
  };
}
