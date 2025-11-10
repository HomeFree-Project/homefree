{ config, lib, pkgs, ... }:
let
  containerDataPath = "/var/lib/ollama-webui";

  preStart = ''
    mkdir -p ${containerDataPath}
  '';

  port-internal = 8254;
  port = 3014;
in
{
  options.homefree.service-options.ollama = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Ollama service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    label = lib.mkOption {
      type = lib.types.str;
      default = "ollama";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Ollama";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Ollama";
      internal = true;
      description = "Project name";
    };
  };

  config = {
  environment.systemPackages = lib.optionals config.homefree.service-options.ollama.enable [
    pkgs.ollama
  ];

  services.ollama = lib.optionalAttrs config.homefree.service-options.ollama.enable {
    enable = true;
    ## Default: 11434
    port = 11434;
    host = "[::]";
    loadModels = [
      "deepseek-r1:7b"
    ];
  };

  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.ollama.enable {
    ollama-webui = {
      image = "ghcr.io/open-webui/open-webui:main";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
        "--add-host=host.docker.internal:host-gateway"
      ];

      ports = [
        "0.0.0.0:${toString port}:${toString port-internal}"
      ];

      volumes = [
      "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}:/app/backend/data"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        PORT = toString port-internal;
        WEBUI_URL = "https://ollama.${config.homefree.system.domain}";
        OLLAMA_BASE_URL = "http://${config.homefree.network.lan-address}:${toString config.services.ollama.port}";
        ## @TODOS
        # WEBUI_SECRET_KEY
        # DEFAULT_LOCALE
        # DEFAULT_PROMPT_SUGGESTIONS
        # CORS_ALLOW_ORIGIN (defualt is *)
        # USER_AGENT
        ## Single user mode (can't change after first run)
        # WEBUI_AUTH=False
      };
    };
  };

  systemd.services.podman-ollama-webui = lib.optionalAttrs config.homefree.service-options.ollama.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "ollama-webui-prestart" preStart}" ];
    };
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.ollama) label name project-name;
      ## @TODO: Why is this not a list?
      systemd-service-names = [
        "ollama"
        "podman-ollama-webui"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.ollama.enable;
        subdomains = [ "ollama" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.ollama.public;
      };
      backup = {
        paths = [
          containerDataPath
        ];
      };
    }];
  };
}
