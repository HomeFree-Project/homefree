{ config, lib, pkgs, ... }:
let
  cfg = config.homefree;
  lan-address = config.homefree.network.lan-address;
  lan-subnet = config.homefree.network.lan-subnet;
  lan-subnet-prefix = lib.head (lib.splitString "/" lan-subnet);  # Extract "10.0.0.0" from "${lan-subnet}"
  search-domains = [ cfg.system.domain cfg.system.localDomain ] ++ cfg.system.additionalDomains;
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

  headplane-version = "0.6.0";
  headplane-containerDataPath = "/var/lib/headplane";
  headplane-port = 3009;
  headplane-preStart = ''
    mkdir -p ${headplane-containerDataPath}/data
    mkdir -p ${headplane-containerDataPath}/configs
  '';

  headplane-config = {
    # Configuration for the Headplane server and web application
    server = {
      host = "0.0.0.0";
      port = headplane-port;

      # The secret used to encode and decode web sessions
      # Ensure that this is exactly 32 characters long
      cookie_secret = "<change_me_to_something_secure!>";

      # Should the cookies only work over HTTPS?
      # Set to false if running via HTTP without a proxy
      # (I recommend this is true in production)
      cookie_secure = true;
    };
    # Headscale specific settings to allow Headplane to talk
    # to Headscale and access deep integration features
    headscale = {
      # The URL to your Headscale instance
      # (All API requests are routed through this URL)
      # (THIS IS NOT the gRPC endpoint, but the HTTP endpoint)
      #
      # IMPORTANT: If you are using TLS this MUST be set to `https://`
      url = "http://headscale:5000";

      # If you use the TLS configuration in Headscale, and you are not using
      # Let's Encrypt for your certificate, pass in the path to the certificate.
      # (This has no effect `url` does not start with `https://`)
      # tls_cert_path: "/var/lib/headplane/tls.crt"

      # Optional, public URL if they differ
      # This affects certain parts of the web UI
      # public_url: "https://headscale.example.com"

      # Path to the Headscale configuration file
      # This is optional, but HIGHLY recommended for the best experience
      # If this is read only, Headplane will show your configuration settings
      # in the Web UI, but they cannot be changed.
      config_path = "/etc/headscale/config.yaml";

      # Headplane internally validates the Headscale configuration
      # to ensure that it changes the configuration in a safe way.
      # If you want to disable this validation, set this to false.
      config_strict = true;

      # If you are using `dns.extra_records_path` in your Headscale
      # configuration, you need to set this to the path for Headplane
      # to be able to read the DNS records.
      #
      # Pass it in if using Docker and ensure that the file is both
      # readable and writable to the Headplane process.
      # When using this, Headplane will no longer need to automatically
      # restart Headscale for DNS record changes.
      # dns_records_path: "/var/lib/headplane/extra_records.json"
    };

    # Integration configurations for Headplane to interact with Headscale
    integration = {
      agent = {
        # The Headplane agent allows retrieving information about nodes
        # This allows the UI to display version, OS, and connectivity data
        # You will see the Headplane agent in your Tailnet as a node when
        # it connects.
        enabled = false;
        # To connect to your Tailnet, you need to generate a pre-auth key
        # This can be done via the web UI or through the `headscale` CLI.
        pre_authkey = "<your-preauth-key>";
        # Optionally change the name of the agent in the Tailnet.
        # host_name: "headplane-agent"

        # Configure different caching settings. By default, the agent will store
        # caches in the path below for a maximum of 1 minute. If you want data
        # to update faster, reduce the TTL, but this will increase the frequency
        # of requests to Headscale.
        # cache_ttl: 60
        # cache_path: /var/lib/headplane/agent_cache.json

        # Do not change this unless you are running a custom deployment.
        # The work_dir represents where the agent will store its data to be able
        # to automatically reauthenticate with your Tailnet. It needs to be
        # writable by the user running the Headplane process.
        # work_dir: "/var/lib/headplane/agent"
      };

      # Only one of these should be enabled at a time or you will get errors
      # This does not include the agent integration (above), which can be enabled
      # at the same time as any of these and is recommended for the best experience.
      docker = {
        enabled = false;

        # By default we check for the presence of a container label (see the docs)
        # to determine the container to signal when changes are made to DNS settings.
        container_label = "me.tale.headplane.target=headscale";

        # HOWEVER, you can fallback to a container name if you desire, but this is
        # not recommended as its brittle and doesn't work with orchestrators that
        # automatically assign container names.
        #
        # If `container_name` is set, it will override any label checks.
        # container_name: "headscale"

        # The path to the Docker socket (do not change this if you are unsure)
        # Docker socket paths must start with unix:// or tcp:// and at the moment
        # https connections are not supported.
        socket = "unix:///var/run/docker.sock";
      };

      # Please refer to docs/integration/Kubernetes.md for more information
      # on how to configure the Kubernetes integration. There are requirements in
      # order to allow Headscale to be controlled by Headplane in a cluster.
      kubernetes = {
        enabled = false;
        # Validates the manifest for the Pod to ensure all of the criteria
        # are set correctly. Turn this off if you are having issues with
        # shareProcessNamespace not being validated correctly.
        validate_manifest = true;
        # This should be the name of the Pod running Headscale and Headplane.
        # If this isn't static you should be using the Kubernetes Downward API
        # to set this value (refer to docs/Integrated-Mode.md for more info).
        pod_name = "headscale";
      };
      # Proc is the "Native" integration that only works when Headscale and
      # Headplane are running outside of a container. There is no configuration,
      # but you need to ensure that the Headplane process can terminate the
      # Headscale process.
      #
      # (If they are both running under systemd as sudo, this will work).
      proc = {
        enabled = false
      };
    };

    # OIDC Configuration for simpler authentication
    # (This is optional, but recommended for the best experience)
    oidc = {
      issuer = "https://accounts.google.com";
      client_id = "your-client-id";

      # The client secret for the OIDC client
      # Either this or `client_secret_path` must be set for OIDC to work
      client_secret = "<your-client-secret>";
      # You can alternatively set `client_secret_path` to read the secret from disk.
      # The path specified can resolve environment variables, making integration
      # with systemd's `LoadCredential` straightforward:
      # client_secret_path: "${CREDENTIALS_DIRECTORY}/oidc_client_secret"

      disable_api_key_login = false;
      token_endpoint_auth_method = "client_secret_post";

      # If you are using OIDC, you need to generate an API key
      # that can be used to authenticate other sessions when signing in.
      #
      # This can be done with `headscale apikeys create --expiration 999d`
      headscale_api_key = "<your-headscale-api-key>";

      # Optional, but highly recommended otherwise Headplane
      # will attempt to automatically guess this from the issuer
      #
      # This should point to your publicly accessibly URL
      # for your Headplane instance with /admin/oidc/callback
      redirect_uri = "http://localhost:3000/admin/oidc/callback";

      # Stores the users and their permissions for Headplane
      # This is a path to a JSON file, default is specified below.
      user_storage_file = "/var/lib/headplane/users.json";
    };
  };

  config-yaml = (pkgs.formats.yaml {}).generate "config.yaml" headplane-config;
in
{
  environment.systemPackages = [
    pkgs.headscale
    pkgs.tailscale
  ];

  MOVE THIS TO DOCKER
  SEE: https://github.com/tale/headplane/blob/main/docs/Integrated-Mode.md
  services.headscale = {
    enable = config.homefree.services.headscale.enable;
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
        nameservers.global = [
          ## @TODO: It appears that these servers are round-robinned.
          ##        Can ${lan-address} be set as default, and the rest as backups?
          ##        Would be useful to support ad blocking over tailscale.

          ## Internal DNS, has local domain names
          # "${lan-address}"

          ## Backup in case internal DNS not accessible due to connectivity issues
          "9.9.9.10"
          ## Secondary backup
          "1.1.1.1"
        ];
        ## Needed to resolve internal domains
        nameservers.split = lib.listToAttrs (lib.map (domain:
          {
            name = domain;
            value = [
              lan-address
            ];
          }
        ) search-domains);
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
    authKeyParameters = {
      preauthorized = true;
      baseURL = "https://headscale.${config.homefree.system.domain}";
    };
    useRoutingFeatures = "server";
    extraUpFlags = [
      # "--advertise-routes=${lan-subnet},100.64.0.0/24"
      "--advertise-routes=${lan-subnet}"
      "--advertise-exit-node"
      # "--netfilter-mode=nodivert"
    ];
    extraSetFlags = [
      # "--advertise-routes=${lan-subnet},100.64.0.0/24"
      "--advertise-routes=${lan-subnet}"
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
      $HEADSCALE routes enable -r $($HEADSCALE routes list | $GREP homefree | $GREP "${lan-subnet-prefix}" | $AWK '{ print $1 }')
    '';
  };

  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.services.headscale.enable {
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
        "${headplane-containerDataPath}:/var/lib/headplane"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;

        DEBUG = "true";

        HEADSCALE_URL = "https://headscale.${config.homefree.system.domain}";
        # HEADSCALE_URL = "http://localhost:8080";

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
  };

  systemd.services.podman-headplane = lib.optionalAttrs config.homefree.services.headscale.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "headplane-prestart" headplane-preStart}" ];
    };
  };

  homefree.service-config = lib.optionals config.homefree.services.headscale.enable [
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
        host = lan-address;
        port = config.services.headscale.port;
        public = true;
        extraCaddyConfig = ''
          reverse_proxy /admin* http://${lan-address}:3009
        '';
      };
      backup = {
        paths = [
          "/var/lib/headscale"
        ];
      };
    }
  ];
}
