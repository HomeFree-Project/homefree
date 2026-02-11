{ config, lib, pkgs, ... }:
let
  cfg = config.homefree;
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
        "homefree.lan": "10.0.0.1/32"
      },
      "autoApprovers": {
        "routes": {
          "10.0.0.0/24": [
            "homefree.lan"
          ]
        }
      }
    }
  '';

  headplane-version = "0.3.9";
  headplane-containerDataPath = "/var/lib/headplane";
  headplane-port = 3009;
  headplane-preStart = ''
    mkdir -p ${headplane-containerDataPath}/data
    mkdir -p ${headplane-containerDataPath}/configs
  '';
in
{
  environment.systemPackages = [
    pkgs.headscale
    pkgs.tailscale
  ];

  services.headscale = {
    enable = config.homefree.services.headscale.enable;
    port = 8087;
    address = "10.0.0.1";
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
        nameservers.global = [
          ## @TODO: It appears that these servers are round-robinned.
          ##        Can 10.0.0.1 be set as default, and the rest as backups?
          ##        Would be useful to support ad blocking over tailscale.

          ## Internal DNS, has local domain names
          # "10.0.0.1"

          ## Backup in case internal DNS not accessible due to connectivity issues
          "9.9.9.10"
          ## Secondary backup
          "1.1.1.1"
        ];
        ## Needed to resolve internal domains (includes proxied domains for Headscale VPN access)
        nameservers.split = lib.listToAttrs (lib.map (domain:
          {
            name = domain;
            value = [
              "10.0.0.1"
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
          stun_listen_addr = "0.0.0.0:${toString cfg.services.headscale.stun-port}";
          automatically_add_embedded_derp_region = true;
        };
        ## Disable default DERP pointing at tailscale corporate servers
        urls = [];
        paths = [];
      };
    };
  };

  ## @TODO: Figure out how to automatically approve exit node without using the web UI
  services.tailscale = {
    enable = true;
    authKeyFile = config.homefree.services.headscale.secrets.tailscale-key;
    useRoutingFeatures = "server";
    extraUpFlags = [
      ## Connect directly to local headscale (bypasses Caddy proxy issues)
      "--login-server=http://10.0.0.1:${toString config.services.headscale.port}"
      "--advertise-routes=10.0.0.0/24"
      "--advertise-exit-node"
    ];
    extraSetFlags = [
      # "--advertise-routes=10.0.0.0/24,100.64.0.0/24"
      "--advertise-routes=10.0.0.0/24"
      "--advertise-exit-node"
      # "--netfilter-mode=nodivert"
    ];
  };

  systemd.services.headscale-enable-routes = {
    after = [ "network.target" "network-online.target" "tailscale.service" ];
    requires = [ "network-online.target" "tailscaled.service" "tailscaled-set.service" "tailscaled-autoconnect.service" ];
    enable = true;
    serviceConfig = {
      User = "headscale";
    };
    # script = builtins.readFile ../scripts/tune_router_performance.sh;
    script = ''
      HEADSCALE=${pkgs.headscale}/bin/headscale
      GREP=${pkgs.gnugrep}/bin/grep
      AWK=${pkgs.gawk}/bin/awk
      $HEADSCALE routes enable -r $($HEADSCALE routes list | $GREP homefree | $GREP "10.0.0.0" | $AWK '{ print $1 }')
    '';
  };

  virtualisation.oci-containers.containers = if config.homefree.services.headscale.enable == true then {
    headplane = {
      image = "ghcr.io/tale/headplane:${headplane-version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString headplane-port}:3000"
      ];

      volumes = [
        "/var/lib/headscale:/var/lib/headscale"
        "/etc/headscale:/etc/headscale"
        "/run/headscale:/run/headscale"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;

        DEBUG = "true";

        ## Connect directly to headscale to avoid Caddy routing issues
        HEADSCALE_URL = "http://10.0.0.1:${toString config.services.headscale.port}";
        # HEADSCALE_URL = "https://headscale.${config.homefree.system.domain}";

        ## If headscale iteself is running in docker, set these
        # HEADSCALE_INTEGRATION = "docker";
        # HEADSCALE_CONTAINER = "headscale";

        DISABLE_API_KEY_LOGIN = "true";
        HOST = "0.0.0.0";    # default: 0.0.0.0
        PORT = "3000";       # default: 3000

        ## Only set this to false if you aren't behind a reverse proxy
        COOKIE_SECURE = "true";

        ## Overrides the configuration file values if they are set in config.yaml
        ## If you want to share the same OIDC configuration you do not need this
        # OIDC_CLIENT_ID = "headscale";
        # OIDC_ISSUER = "https://sso.example.com";
      };

      environmentFiles = [
        config.homefree.services.headscale.secrets.headplane-env
      ];
    };
  } else {};

  systemd.services.podman-headplane = {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "headplane-prestart" headplane-preStart}" ];
    };
  };

  homefree.service-config = if config.homefree.services.headscale.enable == true then [
    {
      label = "headscale";
      name = "VPN";
      project-name = "Headscale";
      systemd-service-names = [
        "headscale"
        "podman-headplane"
      ];
      admin = {
        urlPathOverride = "/admin";
      };
      reverse-proxy = {
        enable = true;
        ## @TODO: Use "vpn" as default
        subdomains = [ "vpn" "headscale" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = "10.0.0.1";
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
            reverse_proxy http://10.0.0.1:${toString config.services.headscale.port} {
              header_up Connection {http.request.header.Connection}
              header_up Upgrade {http.request.header.Upgrade}
            }
          }

          # Handle Tailscale control protocol (requires HTTP upgrade)
          @ts2021 {
            path /ts2021
          }
          handle @ts2021 {
            reverse_proxy http://10.0.0.1:${toString config.services.headscale.port} {
              header_up Connection {http.request.header.Connection}
              header_up Upgrade {http.request.header.Upgrade}
            }
          }

          handle /admin* {
            reverse_proxy http://10.0.0.1:3009
          }
        '';
      };
      firewall = {
        open-ports = {
          tcp = [
            ## Allow Headscale DERP connections
            config.homefree.services.headscale.stun-port
          ];
          udp = [
            ## Allow Headscale DERP connections
            config.homefree.services.headscale.stun-port
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
    }
  ] else [];
  # Cache headscale DNS locally to reduce DNS queries from tailscaled DERP retries
  # NOTE: Commented out - this overrides unbound DNS and prevents public resolution
  # networking.hosts = {
  #   "10.0.0.1" = [ "headscale.homefree.host" "vpn.homefree.host" ];
  # };
}
