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

  ## Per-secret files written by the admin UI's SOPS-managed secrets
  ## pipeline. Same pattern as services/zitadel-podman.nix: files are
  ## populated out-of-band; nix only declares the option and reads the
  ## paths via systemd LoadCredential at service start.
  headplaneSecretsDir = "/var/lib/homefree-secrets/headscale";

  ## Headplane is only deployed once the four credentials below are set.
  ## Without them the service would fail to start (no cookie secret) or
  ## fail OIDC discovery (no client_id/secret/api_key). Match Zitadel's
  ## deployOauth2Proxy gating: enable + all-secrets-populated.
  headplaneSecretsConfigured =
    (headscaleSecrets.headplane-cookie-secret or null) != null
    && (headscaleSecrets.oidc-client-id or null) != null
    && (headscaleSecrets.oidc-client-secret or null) != null
    && (headscaleSecrets.headscale-api-key or null) != null;
  deployHeadplane = headscaleEnabled && headplaneSecretsConfigured;

  ## Headplane 0.7+ takes a YAML config file. The upstream NixOS module
  ## strips null values from the YAML, so optional fields can be left null.
  ## Secret values are exposed via systemd LoadCredential below; we point
  ## the *_path settings at the resolved paths under
  ## /run/credentials/<unit>/<name> to avoid env-var expansion in YAML.
  headplaneCredsDir = "/run/credentials/headplane.service";

  headplaneSettings = {
    server = {
      host = "127.0.0.1";
      port = headplane-port;
      cookie_secret_path = "${headplaneCredsDir}/headplane-cookie-secret";
      cookie_secure = true;
    };
    headscale = {
      url = "http://${lan-address}:${toString config.services.headscale.port}";
      config_path = "/etc/headscale/config.yaml";
      config_strict = true;
      api_key_path = "${headplaneCredsDir}/headscale-api-key";
    };
    integration = {
      proc.enabled = true;
      agent.enabled = false;
    };
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

  ## LoadCredential bridges the SOPS-managed per-secret files into the
  ## headplane.service mount namespace at /run/credentials/headplane.service/<name>.
  ## The headplaneSettings YAML above points the *_path fields at exactly
  ## those resolved paths.
  systemd.services.headplane = lib.mkIf deployHeadplane {
    after = [ "headscale.service" "dns-ready.service" ];
    requires = [ "headscale.service" "dns-ready.service" ];
    serviceConfig = {
      LoadCredential = [
        "headplane-cookie-secret:${headplaneSecretsDir}/headplane-cookie-secret"
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
          description = "Headplane SSO + API credentials (via Zitadel). All four required for the Headplane admin UI to deploy.";
          sops-managed = true;
          submodule-fields = [
            {
              path = "headplane-cookie-secret";
              type = "str";
              nullable = true;
              default = null;
              description = "32-byte session secret used by Headplane to sign cookies. Generate with: openssl rand -base64 32 | head -c 32";
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
