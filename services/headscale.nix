{ config, lib, pkgs, homefree-inputs, ... }:
let
  cfg = config.homefree;
  lan-address = config.homefree.network.lan-address;
  lan-subnet = config.homefree.network.lan-subnet;
  lan-subnet-prefix = lib.head (lib.splitString "/" lan-subnet);  # Extract "10.0.0.0" from "10.0.0.0/24"
  search-domains = [ cfg.system.domain cfg.system.localDomain ] ++ cfg.system.additionalDomains;
  proxiedDomains = config.homefree.proxied-domains;

  # Extract unique base domains from proxied domains (handle wildcards like *.example.com)
  proxiedBaseDomains = lib.unique (lib.map (domain:
    let
      parts = lib.splitString "." domain;
      cleanParts = lib.filter (p: p != "*") parts;
      len = lib.length cleanParts;
    in
      lib.concatStringsSep "." (lib.sublist (if len > 2 then len - 2 else 0) 2 cleanParts)
  ) (lib.flatten (lib.map (dm: dm.domains) proxiedDomains)));

  # All domains that need split DNS: system domains + proxied domains
  all-split-domains = search-domains ++ proxiedBaseDomains;
  ## See: https://headscale.net/stable/ref/acls/
  ## @TODO: Doesn't seem to work, may even block all traffic not explicitly approved.
  policy = pkgs.writeText "headscale-policy.json" ''
    {
      "hosts": {
        "homefree.lan": "${lan-address}/32"
      },
      "autoApprovers": {
        "routes": {
          "${lan-subnet}": [
            "homefree.lan"
          ]
        }
      }
    }
  '';

  headscaleEnabled = config.homefree.service-options.headscale.enable;
  headscaleSecrets = config.homefree.service-options.headscale.secrets;

  headplane-port = 3009;

  ## Per-secret files for SOPS-managed secrets — same pattern as
  ## services/zitadel-podman.nix. The cookie secret is the one
  ## exception: it doesn't *need* to be SOPS-managed because losing it
  ## just invalidates active sessions, so we auto-generate it on first
  ## boot if absent (see headplaneCookiePreStart below). The OIDC creds
  ## and the headscale API key, in contrast, must be set deliberately.
  headplaneSecretsDir = "/var/lib/homefree-secrets/headscale";

  ## OIDC is opt-in. Headplane runs fine without it (falls back to API
  ## key login or unauthenticated, depending on
  ## `oidc.disable_api_key_login`). We only fold the oidc block into
  ## the YAML once all three OIDC-related secrets are populated.
  oidcConfigured =
       (headscaleSecrets.oidc-client-id or null) != null
    && (headscaleSecrets.oidc-client-secret or null) != null
    && (headscaleSecrets.headscale-api-key or null) != null;

  ## Headplane is deployed whenever headscale is enabled. The cookie
  ## secret is auto-generated, so there's no chicken-and-egg problem:
  ## you can use the admin UI immediately to generate the
  ## `headscale apikeys create` value and configure OIDC after.
  deployHeadplane = headscaleEnabled;

  ## The cookie secret is auto-generated on first boot by the
  ## headplane-prepare-secrets.service oneshot defined further down,
  ## ensuring the file exists before LoadCredential reads it. Headplane
  ## requires *some* cookie secret to start; we don't want a fresh
  ## install to be locked out of its own admin UI just because the
  ## sysadmin hasn't visited the SOPS settings page yet.

  ## Secret values are exposed via systemd LoadCredential below; we
  ## point the *_path settings at the resolved paths under
  ## /run/credentials/<unit>/<name> to avoid env-var expansion in YAML.
  headplaneCredsDir = "/run/credentials/headplane.service";

  ## The nixpkgs `services.headscale` module installs a deliberately
  ## minimal /etc/headscale/config.yaml — just the unix-socket path and
  ## the disable-update-check flag — and passes the full settings to
  ## the daemon via `--config <store-path>` instead. Headplane, by
  ## contrast, expects the full config so it can render and validate
  ## it in the UI; pointing it at the stub makes it reject the file
  ## with "database / derp / dns / listen_addr / noise / prefixes /
  ## server_url must be present" errors. We regenerate the same content
  ## using the same YAML formatter and write it next to the stub.
  ##
  ## Headplane's validator additionally rejects explicit null values
  ## where it expects a string/array (e.g. `tls_cert_path: null`,
  ## `policy.path: null`, `dns.extra_records: null`). The headscale
  ## daemon happily accepts these as "unset", but headplane treats
  ## the field as ill-typed. Strip nulls recursively before serialising.
  headscaleSettingsForHeadplane =
    lib.filterAttrsRecursive (_: v: v != null) config.services.headscale.settings;
  headscaleFullConfigFile =
    (pkgs.formats.yaml {}).generate "headscale-full.yaml"
      headscaleSettingsForHeadplane;

  headplaneSettings = {
    server = {
      host = "127.0.0.1";
      port = headplane-port;
      cookie_secret_path = "${headplaneCredsDir}/headplane-cookie-secret";
      cookie_secure = true;
    };
    headscale = {
      url = "http://${lan-address}:${toString config.services.headscale.port}";
      config_path = "/etc/headscale/headplane-view.yaml";
      config_strict = true;
    } // lib.optionalAttrs oidcConfigured {
      ## Only set api_key_path when the API key is actually present —
      ## the headplane module fails activation if the LoadCredential
      ## source file is missing.
      api_key_path = "${headplaneCredsDir}/headscale-api-key";
    };
    integration = {
      proc.enabled = true;
      agent.enabled = false;
    };
  } // lib.optionalAttrs oidcConfigured {
    oidc = {
      issuer = "https://sso.${cfg.system.domain}";
      client_id = headscaleSecrets.oidc-client-id;
      client_secret_path = "${headplaneCredsDir}/oidc-client-secret";
      headscale_api_key_path = "${headplaneCredsDir}/headscale-api-key";
      disable_api_key_login = false;
      token_endpoint_auth_method = "client_secret_post";
    };
  };
in
{
  ## nixpkgs ships its own headplane module (services/networking/headplane.nix)
  ## but it's pinned to nixpkgs's headplane version (0.6.x). Disable it so
  ## the upstream flake module — which tracks 0.7+ and adds option fields the
  ## nixpkgs version doesn't — wins without colliding.
  disabledModules = [ "services/networking/headplane.nix" ];
  imports = [
    homefree-inputs.headplane.nixosModules.headplane
  ];

  options.homefree.service-options.headscale = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Headscale VPN service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "UI open to public on WAN port";
    };

    label = lib.mkOption {
      type = lib.types.str;
      default = "headscale";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "VPN (Headscale)";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Headscale";
      internal = true;
      description = "Project name";
    };

    stun-port = lib.mkOption {
      type = lib.types.int;
      description = "DERP STUN relay port";
      default = 3478;
    };

    enable-public-derp-fallback = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Include Tailscale's public DERP relay servers as fallback.

        When enabled, clients can relay traffic through Tailscale's
        infrastructure if the embedded DERP server on this machine is
        unreachable (e.g. after a network switch causes a DNS circular
        dependency where MagicDNS needs the tunnel to resolve the
        headscale server, but the tunnel needs DERP to recover).
        The embedded DERP is always preferred when reachable; public
        servers are only used as a last resort.

        NOTE: This creates a dependency on Tailscale's infrastructure
        (controlplane.tailscale.com). Disable this if you require
        complete independence from Tailscale's services.
      '';
    };

    secrets = {
      tailscale-key = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Location of Tailscale client key for server. Should not be a file included in your source repo.";
      };

      ## Deprecated. Headplane 0.6 (the previous version) consumed an env
      ## file with COOKIE_SECRET, ROOT_API_KEY, OIDC_CLIENT_SECRET. From
      ## 0.7 onward those secrets come from per-secret files via
      ## LoadCredential — see the four fields below. Kept here so existing
      ## configurations evaluate during the migration cycle.
      headplane-env = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "(Deprecated) Location of Headplane env file. No longer used; see headplane-cookie-secret/oidc-* below.";
      };

      ## SOPS-managed secrets used by the headplane native module.
      ## The actual secret values live as files under
      ## /var/lib/homefree-secrets/headscale/<name>, written out of band
      ## by the admin UI's secret manager. The string options below are
      ## just markers so the admin UI knows the secret exists; they are
      ## not read directly. Compare services/zitadel-podman.nix.
      headplane-cookie-secret = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "32-byte session secret used by Headplane to sign cookies. Generate with: openssl rand -base64 32 | head -c 32";
      };
      oidc-client-id = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "OIDC Client ID for the Headplane application in Zitadel.";
      };
      oidc-client-secret = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "OIDC client secret paired with the client ID above.";
      };
      headscale-api-key = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Headscale API key. Create with: headscale apikeys create --expiration 999d";
      };
    };
  };

  config = {
  ## Pull pkgs.headplane (and pkgs.headplane-agent) from the upstream
  ## flake — newer than nixpkgs. Applying unconditionally is harmless;
  ## the package is only referenced when headscale is enabled.
  nixpkgs.overlays = [ homefree-inputs.headplane.overlays.default ];

  environment.systemPackages = lib.optionals headscaleEnabled [
    pkgs.headscale
    pkgs.tailscale
  ];

  ## Expose the full headscale config to Headplane at a separate path,
  ## leaving the nixpkgs-managed /etc/headscale/config.yaml stub alone
  ## (some headscale CLI invocations depend on its minimal shape).
  environment.etc."headscale/headplane-view.yaml" = lib.mkIf deployHeadplane {
    source = headscaleFullConfigFile;
    ## Headplane runs as the headscale user (per the upstream module),
    ## so make this readable by that group.
    mode = "0440";
    user = "headscale";
    group = "headscale";
  };

  services.headscale = lib.optionalAttrs headscaleEnabled {
    enable = true ;
    port = 8087;
    address = lan-address;
    settings = {
      server_url = "https://headscale.${cfg.system.domain}:443";
      # policy.path = policy;
      dns = {
        magic_dns = true;
        # override_local_dns = true;
        ## Must be different from server domain
        base_domain = "homefree.vpn";
        # search_domains = search-domains;
        ## Add
        ## Order matters in headscale 0.26+: the first reachable resolver is
        ## preferred, so put the LAN resolver first to get split-horizon and
        ## ad-blocking; the public resolvers are fallbacks for when the LAN
        ## resolver is unreachable.
        nameservers.global = [
          ## Internal DNS — has local domain names + ad-blocking via unbound
          lan-address
          ## Backup if LAN resolver is unreachable (e.g. before tunnel is up)
          "9.9.9.10"
          ## Secondary backup
          "1.1.1.1"
        ];
        ## Needed to resolve internal domains (includes proxied domains for Headscale VPN access)
        nameservers.split = lib.listToAttrs (lib.map (domain:
          {
            name = domain;
            value = [
              lan-address
            ];
          }
        ) all-split-domains);
      };
      prefixes = {
        ## Some VPNs use addresses that overlap. Reduce the size of the network
        ## from 10.64.0.0/10
        v4 = "100.64.0.0/24";
        v6 = "fd7a:115c:a1e0::/48";
      };
      derp = {
        ## Frequency to update DERP maps
        auto_update_enable = true;
        update_frequency = "5m";
        server = {
          enabled = true;
          region_id = 999;
          region_code = "headscale";
          region_name = "headscale Embedded DERP";
          stun_listen_addr = "0.0.0.0:${toString cfg.service-options.headscale.stun-port}";
          automatically_add_embedded_derp_region = true;
        };
        urls = if cfg.service-options.headscale.enable-public-derp-fallback
          then [ "https://controlplane.tailscale.com/derpmap/default" ]
          else [];
        paths = [];
      };
    };
  };

  ## @TODO: Figure out how to automatically approve exit node without using the web UI
  services.tailscale = lib.optionalAttrs headscaleEnabled {
    enable = true;
    authKeyFile = headscaleSecrets.tailscale-key;
    useRoutingFeatures = "server";
    extraUpFlags = [
      ## Connect directly to local headscale (bypasses Caddy proxy issues)
      "--login-server=http://${lan-address}:${toString config.services.headscale.port}"
      # "--advertise-routes=${lan-subnet},100.64.0.0/24"
      "--advertise-routes=${lan-subnet}"
      "--advertise-exit-node"
    ];
    extraSetFlags = [
      # "--advertise-routes=${lan-subnet},100.64.0.0/24"
      "--advertise-routes=${lan-subnet}"
      "--advertise-exit-node"
      # "--netfilter-mode=nodivert"
    ];
  };

  ## Auto-approve the LAN subnet route advertised by the local tailscale
  ## client (the router host itself).
  ##
  ## Headscale 0.27+ removed `headscale routes list/enable`. The new API is
  ## `headscale nodes list-routes` (per-node view of advertised + approved
  ## routes) and `headscale nodes approve-routes -i <ID> -r <CIDRs>` which
  ## takes a node identifier and the comma-separated list of approved CIDRs.
  ## We find the node by hostname (the router advertises homefree.lan via
  ## tailscale up) and approve our LAN subnet on that node.
  systemd.services.headscale-enable-routes = lib.optionalAttrs headscaleEnabled {
    after = [ "network.target" "network-online.target" "tailscale.service" ];
    requires = [ "network-online.target" "tailscaled.service" "tailscaled-set.service" "tailscaled-autoconnect.service" ];
    enable = true;
    serviceConfig = {
      User = "headscale";
    };
    script = ''
      HEADSCALE=${pkgs.headscale}/bin/headscale
      JQ=${pkgs.jq}/bin/jq

      ## Look up the router node ID by hostname. Match `homefree` and an
      ## advertised route inside our LAN subnet prefix to be safe even if
      ## additional nodes happen to share the hostname.
      NODE_ID=$($HEADSCALE nodes list-routes -o json \
        | $JQ -r --arg prefix "${lan-subnet-prefix}" \
            '.[] | select(.given_name | test("homefree"))
                 | select((.advertised_routes // []) | map(startswith($prefix)) | any)
                 | .id' \
        | head -n1)

      if [ -z "$NODE_ID" ]; then
        echo "headscale-enable-routes: no node advertising ${lan-subnet} found yet"
        exit 0
      fi

      $HEADSCALE nodes approve-routes -i "$NODE_ID" -r "${lan-subnet}"
    '';
  };

  ## Headplane is the Headscale admin UI. From 0.7 it ships a NixOS
  ## module (imported above) and runs as a native systemd service rather
  ## than a podman container. It picks up its YAML config from
  ## /etc/headplane/config.yaml (written by the upstream module from the
  ## settings attrset below) and reads four runtime secrets from systemd
  ## credentials populated via LoadCredential.
  services.headplane = lib.mkIf deployHeadplane {
    enable = true;
    settings = headplaneSettings;
  };

  ## Standalone oneshot that auto-generates the cookie secret before
  ## headplane.service starts. LoadCredential= is processed by PID 1
  ## *before* ExecStartPre runs, so we can't generate the file from
  ## within headplane.service itself — by the time ExecStartPre would
  ## run, LoadCredential has already failed with status 243.
  systemd.services.headplane-prepare-secrets = lib.mkIf deployHeadplane {
    description = "Prepare Headplane runtime secrets (cookie secret)";
    wantedBy = [ "headplane.service" ];
    before = [ "headplane.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      mkdir -p ${headplaneSecretsDir}
      if [ ! -s "${headplaneSecretsDir}/headplane-cookie-secret" ]; then
        ${pkgs.openssl}/bin/openssl rand -base64 32 | head -c 32 \
          > "${headplaneSecretsDir}/headplane-cookie-secret"
      fi
      chmod 600 "${headplaneSecretsDir}/headplane-cookie-secret"
    '';
  };

  ## LoadCredential bridges the SOPS-managed per-secret files into the
  ## headplane.service mount namespace at /run/credentials/headplane.service/<name>.
  ## The headplaneSettings YAML above points the *_path fields at exactly
  ## those resolved paths. We only load OIDC-related credentials when
  ## OIDC is actually configured — LoadCredential of a non-existent
  ## file is fatal at unit start.
  systemd.services.headplane = lib.mkIf deployHeadplane {
    after = [ "headscale.service" "dns-ready.service" "headplane-prepare-secrets.service" ];
    requires = [ "headscale.service" "dns-ready.service" "headplane-prepare-secrets.service" ];
    ## Headplane reads the headscale config file at startup; if we
    ## regenerate that file but the unit definition is otherwise
    ## unchanged, NixOS won't restart the unit on rebuild and the new
    ## config goes unread. Tie restarts to the file's store path.
    restartTriggers = [ headscaleFullConfigFile ];
    serviceConfig = {
      LoadCredential = [
        "headplane-cookie-secret:${headplaneSecretsDir}/headplane-cookie-secret"
      ] ++ lib.optionals oidcConfigured [
        "oidc-client-secret:${headplaneSecretsDir}/oidc-client-secret"
        "headscale-api-key:${headplaneSecretsDir}/headscale-api-key"
      ];
    };
  };

  homefree.service-config = lib.optionals headscaleEnabled [
    {
      inherit (cfg.service-options.headscale) label name project-name;
      systemd-service-names = [ "headscale" ]
        ++ lib.optional deployHeadplane "headplane";
      admin = {
        urlPathOverride = "/admin";
      };
      reverse-proxy = {
        enable = true;
        ## @TODO: Use "vpn" as default
        subdomains = [ "vpn" "headscale" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = lan-address;
        port = config.services.headscale.port;
        public = true;
        extraCaddyConfig = ''
          # Fake DERP latency check (headscale doesn't implement this endpoint)
          handle /derp/latency-check {
            respond 200
          }

          # Handle DERP relay connections (requires HTTP upgrade)
          @derp {
            path /derp /derp/*
          }
          handle @derp {
            reverse_proxy http://${lan-address}:${toString config.services.headscale.port} {
              header_up Connection {http.request.header.Connection}
              header_up Upgrade {http.request.header.Upgrade}
            }
          }

          # Handle Tailscale control protocol (requires HTTP upgrade)
          @ts2021 {
            path /ts2021
          }
          handle @ts2021 {
            reverse_proxy http://${lan-address}:${toString config.services.headscale.port} {
              header_up Connection {http.request.header.Connection}
              header_up Upgrade {http.request.header.Upgrade}
            }
          }

          handle /admin* {
            reverse_proxy http://${lan-address}:3009
          }

          ## Land users at the Headplane admin UI when they visit
          ## https://vpn.<domain>/ in a browser. Headplane is hard-coded
          ## to its /admin basename (see vite/react-router config in the
          ## upstream package), so this is a cosmetic redirect rather than
          ## a path remount. We match `/` exactly so headscale's other
          ## endpoints (/key, /derp/*, /ts2021, /machine/*, etc.) still
          ## reach the headscale daemon below.
          @root_only path /
          redir @root_only /admin/ 302
        '';
      };
      firewall = {
        open-ports = {
          tcp = [
            ## Allow Headscale DERP connections
            cfg.service-options.headscale.stun-port
          ];
          udp = [
            ## Allow Headscale DERP connections
            cfg.service-options.headscale.stun-port
            # Headscale connections
            41641
          ];
        };
      };
      backup = {
        paths = [
          "/var/lib/headscale"
        ];
      };
      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable Headscale VPN service";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make service accessible from WAN";
        }
        {
          path = "stun-port";
          type = "int";
          default = 3478;
          description = "DERP STUN relay port";
        }
        {
          path = "enable-public-derp-fallback";
          type = "bool";
          default = false;
          description = "Fall back to Tailscale public DERP if embedded relay is unreachable";
        }
        {
          path = "secrets";
          type = "submodule";
          description = "Headplane Zitadel SSO + API credentials. Optional — when all three OIDC fields are set the admin UI is locked behind Zitadel login; when empty, the admin UI is open behind Caddy/oauth2-proxy.";
          sops-managed = true;
          submodule-fields = [
            {
              path = "headplane-cookie-secret";
              type = "str";
              nullable = true;
              default = null;
              description = "32-byte session secret used by Headplane to sign cookies. Auto-generated on first boot if not set; setting it here just lets you carry the same value across re-installs.";
              sops-managed = true;
            }
            {
              path = "oidc-client-id";
              type = "str";
              nullable = true;
              default = null;
              description = "OIDC Client ID for the Headplane application in Zitadel.";
              sops-managed = true;
            }
            {
              path = "oidc-client-secret";
              type = "str";
              nullable = true;
              default = null;
              description = "OIDC client secret paired with the client ID above.";
              sops-managed = true;
            }
            {
              path = "headscale-api-key";
              type = "str";
              nullable = true;
              default = null;
              description = "Headscale API key for Headplane to query the gRPC API. Create with: headscale apikeys create --expiration 999d";
              sops-managed = true;
            }
          ];
        }
      ];
    }
  ];
  # Cache headscale DNS locally to reduce DNS queries from tailscaled DERP retries
  # NOTE: Commented out - this overrides unbound DNS and prevents public resolution
  # networking.hosts = {
  #   "${lan-address}" = [ "headscale.homefree.host" "vpn.homefree.host" ];
  # };
  };
}
