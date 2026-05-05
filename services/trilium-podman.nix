{ config, pkgs, ... }:
let
  version = "0.95.0";
  containerDataPath = "/var/lib/trilium-podman";
  port = 8081;

  preStart = ''
    mkdir -p ${containerDataPath}
  '';
in
{
  virtualisation.oci-containers.containers = if config.homefree.services.trilium.enable == true then {
    trilium = {
      image = "triliumnext/notes:v${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:8080"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}:/home/node/trilium-data"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        TRILIUM_DATA_DIR = "/home/node/trilium-data";
      };
    };
  } else {};

  systemd.services.podman-trilium = {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "trilium-prestart" preStart}" ];
    };
  };

  homefree.service-config = if config.homefree.services.trilium.enable == true then [
    {
      label = "trilium";
      name = "Trilium Notes";
      project-name = "TriliumNext Notes";
      systemd-service-names = [
        "podman-trilium"
      ];
      reverse-proxy = {
        enable = true;
        subdomains = [ "notes" "trilium" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = "10.0.0.1";
        port = port;
        public = config.homefree.services.trilium.public;
      };
      backup = {
        paths = [
          containerDataPath
        ];
      };
    }
  ] else [];
}
