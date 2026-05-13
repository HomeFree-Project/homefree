{ config, pkgs, lib, ... }:
let
  nfs3Options = [ "nfsvers=3" ];
in
{
  ##------------------------------------------------------------------------
  ## Custom config
  ## @TODO: Make this all configurable through "homefree" config
  ##------------------------------------------------------------------------

  ## @TODO: put something like this into homefree itself
  ##        - Can handle no WAN ip
  ##        - How to deal with external IPs? Check if ddclient is configured, then monitor for internal IP ranges?
  ##        - How to deal with ISPs that don't support ipv6 when monitoring LAN for ipv6?
  ##        - Real solution is to diagnose
  ##             1. why wan doesn't always get or loses global IP, and
  ##             2. why lan doesn't always get ipv6
  ##             Generally IPv6 LAN problems are caused by problems with the WAN, so it's probably a single problem
  systemd.services.wan-monitor = {
    wantedBy = [ "multi-user.target" ];
    enable = true;

    serviceConfig = {
      User = "root";
      Group = "root";
    };

    script = ''
      IP=${pkgs.iproute2}/bin/ip
      GREP=${pkgs.gnugrep}/bin/grep
      SED=${pkgs.gnused}/bin/sed
      NETWORKCTL=${pkgs.systemd}/bin/networkctl
      echo "Started WAN health monitor."

      while :
      do
          WAN_IP=$($IP -f inet addr show eno1 | $SED -En -e 's/.*inet ([0-9.]+).*/\1/p')
          if [[ $WAN_IP =~ ^192.168 ]] || [[ -z $WAN_IP ]]; then
             echo "WAN has no global ipv4 address, reloading."
             $NETWORKCTL reconfigure eno1
          elif ! ($IP -f inet6 addr show enp112s0 | $GREP 'scope global' &> /dev/null) then
             echo "LAN has no IPv6 address, reloading WAN."
             $NETWORKCTL reconfigure eno1
          fi
          sleep 20
      done
    '';
  };


  ## See:
  ## https://www.reddit.com/r/Ubuntu/comments/1jc7bzj/install_hangs_after_efi_stub_measured_initrd_data/
  # boot.kernelParams = [
  #   "video=DP-1:d"
  #   "video=DP-2:d"
  #   "video=DP-3:d"
  #   "video=DP-4:d"
  #   "video=Writeback-1:d"
  #   "video=HDMI-A-1:D"
  # ];

  networking = {
    interfaces = {
      wlp4s0 = {
        useDHCP = true;
      };
    };
    wireless = {
      # enable = lib.mkForce true;
      enable = lib.mkForce false;
      networks = {
        rubber-duck = {
          psk = "zhou1zhong888";
        };
      };
    };
  };

  services.rpcbind.enable = true;

  fileSystems."/mnt/ellis" = {
    device = "10.0.0.42:/volume1/ellis";
    fsType = "nfs";
    # mount when share first used rather than at start, and disconnect after timeout
    options = nfs3Options ++ [ "x-systemd.automount" "noauto" "x-systemd.idle-timeout=600" ];
  };

  fileSystems."/mnt/nas-home" = {
    device = "10.0.0.42:/volume1/homes";
    fsType = "nfs";
    # mount when share first used rather than at start, and disconnect after timeout
    options = nfs3Options ++ [ "x-systemd.automount" "noauto" "x-systemd.idle-timeout=600" ];
  };

  ## @TODO: Move to homefree repo
  imports = [
    ./disk-config.nix
    ./secrets/secrets.nix
  ];

  homefree = {
    system = {
      adminUsername = "erahhal";
      adminHashedPassword = "$6$LLDHmTSsd1XWPo5d$J1AsaqW47dV.09I.jqJ5KJB6OLe4AR9pzZKTZQU1HsaDx0GoifYaTxZ1Ylze6gkwSz3k5j0i1h3BNI2vQVxCY1";
      authorizedKeys = [
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDNvmGn1/uFnfgnv5qsec0GC04LeVB1Qy/G7WivvvUZVBBDzp8goe1DsE8M8iqnBSin56gQZDWsd50co2MbFAWuqH2HxY7OGay7P/V2q+SziTYFva85WGl84qWvYMmdB+alAFBT3L4eH5cegC5NhNp+OGsQuq32RdojgXXQt6vyZnaOypuz90k3rqV6Rt+iBTLz6VziasCLcYydwOvi9f1q6YQwGPLKaupDrV6gxvoX9bXLdopqwnXPSE/Eqczxgwc3PefvAJPSd6TOqIXvbtpv/B3Evt5SPe2gq+qASc5K0tzgra8KAe813kkpq4FuKJzHbT+EmO70wiJjru7zMEhd erahhal@nfml-erahhalQFL"
      ];
      additionalDomains = [ "rahh.al" ];
      timeZone = "America/Los_Angeles";
      countryCode = "US";
    };

    network = {
      wan-interface = "eno1";
      wan-bitrate-mbps-down = 1000;
      wan-bitrate-mbps-up = 1000;
      lan-interface = "enp112s0";
      enable-adblock = false;
      static-ips = [
        {
          mac-address = "38:ea:a7:38:f2:6c";
          hostname = "sicmundus";
          ip = "10.0.0.2";
        }
        {
          mac-address = "50:65:f3:f1:7d:36";
          hostname = "ILOUSE5491762";
          ip = "10.0.0.9";
        }
        {
          mac-address = "ec:71:db:5c:11:6e";
          hostname = "reolink-doorbell";
          ip = "10.0.0.10";
        }
        {
          mac-address = "00:0b:86:a6:9e:40";
          hostname = "aruba";
          ip = "10.0.0.11";
        }
        {
          mac-address = "68:d7:9a:29:b1:e3";
          hostname = "NanoHDHallway";
          ip = "10.0.0.12";
        }
        {
          mac-address = "00:c0:b7:53:f2:35";
          hostname = "ap7900";
          ip = "10.0.0.13";
        }
        {
          mac-address = "9c:05:d6:43:67:61";
          hostname = "u7pro";
          ip = "10.0.0.14";
        }
        {
          mac-address = "00:64:40:d5:0f:31";
          hostname = "ipcam-gate";
          ip = "10.0.0.15";
        }
        {
          mac-address = "00:3e:5e:76:36:ab";
          hostname = "ipcam2";
          ip = "10.0.0.16";
        }
        {
          mac-address = "04:17:b6:3e:92:17";
          hostname = "eufy-cam-1";
          ip = "10.0.0.17";
        }
        {
          mac-address = "04:17:b6:2a:3a:2c";
          hostname = "eufy-ptz";
          ip = "10.0.0.18";
        }
        {
          mac-address = "9c:8e:cd:34:b3:bc";
          hostname = "amcrest-ptz-eth";
          ip = "10.0.0.19";
        }
        {
          mac-address = "9c:8e:cd:34:b9:8c";
          hostname = "amcrest-ptz";
          ip = "10.0.0.20";
        }
        {
          mac-address = "00:11:32:fa:ad:31";
          hostname = "nas-1gb";
          ip = "10.0.0.21";
        }
        {
          mac-address = "9c:8e:cd:3b:4b:ad";
          hostname = "amcrest-ip5m";
          ip = "10.0.0.22";
        }
        {
          mac-address = "d8:3a:dd:a2:2a:99";
          hostname = "speakerserver-lan";
          ip = "10.0.0.27";
        }
        {
          mac-address = "d8:3a:dd:a2:2a:9b";
          hostname = "speakerserver";
          ip = "10.0.0.28";
        }
        {
          mac-address = "dc:a6:32:21:21:47";
          hostname = "partymusic";
          ip = "10.0.0.29";
        }
        {
          mac-address = "64:90:c1:06:79:d1";
          hostname = "roborock";
          ip = "10.0.0.30";
        }
        {
          mac-address = "00:c0:b7:98:c4:12";
          hostname = "apc98C412";
          ip = "10.0.0.31";
        }
        {
          mac-address = "dc:a6:32:2e:aa:90";
          hostname = "mediaserver";
          ip = "10.0.0.32";
        }
        {
          mac-address = "dc:a6:32:2e:aa:8f";
          hostname = "mediaserver-lan";
          ip = "10.0.0.33";
        }
        {
          mac-address = "34:99:71:d7:43:b9";
          hostname = "upaya";
          ip = "10.0.0.34";
        }
        {
          mac-address = "a4:4c:c8:c1:50:de";
          hostname = "upaya-dock";
          ip = "10.0.0.35";
        }
        {
          mac-address = "34:7d:f6:81:3e:ef";
          hostname = "upaya-wifi";
          ip = "10.0.0.36";
        }
        {
          mac-address = "d4:12:43:cf:9a:72";
          hostname = "reMarkable";
          ip = "10.0.0.37";
        }
        {
          mac-address = "dc:1b:a1:05:95:2e";
          hostname = "msi-desktop-wifi";
          ip = "10.0.0.38";
        }
        {
          mac-address = "2c:f0:5d:72:ac:ab";
          hostname = "msi-desktop";
          ip = "10.0.0.39";
        }
        {
          mac-address = "b4:b2:91:52:de:df";
          hostname = "LGwebOSTV";
          ip = "10.0.0.40";
        }
        {
          ## Ethernet
          # mac-address = "cc:d4:2e:bd:42:ea";
          ## Wifi
          mac-address = "cc:d4:2e:bd:42:eb";
          hostname = "rxa2a";
          ip = "10.0.0.41";
        }
        {
          mac-address = "00:11:32:fe:84:1e";
          hostname = "nas";
          ip = "10.0.0.42";
        }
        {
          mac-address = "2c:ab:33:c9:97:28";
          hostname = "envoy";
          ip = "10.0.0.43";
        }
        {
          mac-address = "10:b1:df:d0:04:cc";
          hostname = "BRW10B1DFD004CC";
          ip = "10.0.0.44";
        }
        {
          mac-address = "04:7b:cb:16:02:3b";
          hostname = "thinkpad-dock";
          ip = "10.0.0.45";
        }
        {
          mac-address = "38:7c:76:19:57:b0";
          hostname = "antikythera-dock";
          ip = "10.0.0.46";
        }
        {
          mac-address = "cc:08:fa:80:45:9d";
          hostname = "MacBook-Air";
          ip = "10.0.0.47";
        }
        {
          mac-address = "a0:92:08:9a:5b:e7";
          hostname = "petlibro2";
          ip = "10.0.0.48";
        }
        {
          mac-address = "fc:67:1f:9c:4c:ba";
          hostname = "petlibro3";
          ip = "10.0.0.49";
        }
        {
          mac-address = "dc:a6:32:7e:6d:87";
          hostname = "homeassistant-old";
          ip = "10.0.0.50";
        }
        {
          mac-address = "6a:e3:31:74:2b:6f";
          hostname = "Pixel-7-Pro";
          ip = "10.0.0.51";
        }
        {
          mac-address = "84:ea:ed:1b:28:02";
          hostname = "Roku";
          ip = "10.0.0.52";
        }
        {
          mac-address = "14:7d:da:42:9c:a5";
          hostname = "dylan-mbp";
          ip = "10.0.0.53";
        }
        {
          mac-address = "ac:0b:fb:e6:bb:c1";
          hostname = "ESP-E6BBC1";
          ip = "10.0.0.54";
        }
        {
          mac-address = "48:74:12:9d:60:d1";
          hostname = "OnePlus-Nord-N200";
          ip = "10.0.0.55";
        }
        {
          mac-address = "38:b4:d3:76:68:00";
          hostname = "bosch-dishwasher-103120531351018105";
          ip = "10.0.0.56";
        }
        {
          mac-address = "90:65:84:cb:48:46";
          hostname = "nflx-erahhal-x1c";
          ip = "10.0.0.57";
        }
        {
          mac-address = "c4:c6:e6:6e:c1:9c";
          hostname = "antikythera-lan";
          ip = "10.0.0.58";
        }
        {
          mac-address = "8c:3b:4a:51:6c:d4";
          hostname = "antikythera";
          ip = "10.0.0.59";
        }
        {
          mac-address = "58:41:46:35:72:54";
          hostname = "reolink-e1-pro-1";
          ip = "10.0.0.60";
        }
        {
          mac-address = "58:41:46:44:db:ec";
          hostname = "reolink-e1-pro-2";
          ip = "10.0.0.61";
        }
        {
          mac-address = "68:c6:ac:50:fb:bd";
          hostname = "nflx-erahhal-p16";
          ip = "10.0.0.62";
        }
        # {
        #   mac-address = "58:41:46:35:72:54";
        #   hostname = "reolink-e1-pro-2";
        #   ip = "10.0.0.61";
        # }
      ];
    };

    dns = {
      remote = {
        cert-management = {
          dns-01 = {
            provider = "hetzner";
            secrets = {
              api-token = config.sops.secrets."dns/api-token".path;
            };
          };
        };
        dynamic-dns = {
          zones = [
            {
              zone = "homefree.host";
              protocol = "hetzner";
              username = "erahhal";
              passwordFile = config.sops.secrets."ddclient/ddclient-password".path;
            }
            {
              zone = "rahh.al";
              protocol = "hetzner";
              username = "erahhal";
              passwordFile = config.sops.secrets."ddclient/ddclient-password".path;
            }
          ];
        };
      };

      local = {
        overrides = [
          ##------------------------------------------------
          ## Hardware
          ##------------------------------------------------
          {
            hostname = "att";
            domain = "lan";
            ip = "192.168.1.254";
          }
          {
            hostname = "motorolacablemodem";
            domain = "lan";
            ip = "192.168.100.1";
          }
          {
            hostname = "homefree-amt";
            domain = "lan";
            ip = "10.0.0.8";
          }
          {
            hostname = "opensprinkler";
            domain = "lan";
            ip = "10.0.0.54";
          }
          {
            hostname = "homefree";
            domain = "lan";
            ip = "10.0.0.216";
          }

          ##------------------------------------------------
          ## Proxied Services
          ##------------------------------------------------
          # {
          #   hostname = "ha";
          #   domain = "lan";
          #   ip = "10.0.0.1";
          # }
          # {
          #   hostname = "ha";
          #   domain = "rahh.al";
          #   ip = "10.0.0.1";
          # }
          # {
          #   hostname = "xbrowsersync";
          #   domain = "lan";
          #   ip = "10.0.0.1";
          # }
          # {
          #   hostname = "xbrowsersync";
          #   domain = "rahh.al";
          #   ip = "10.0.0.1";
          # }

          ##------------------------------------------------
          ## Local Services
          ##------------------------------------------------
          # {
          #   hostname = "homebox";
          #   domain = "lan";
          #   ip = "10.0.0.60";
          # }
          # {
          #   hostname = "wekan";
          #   domain = "lan";
          #   ip = "10.0.0.61";
          # }
          # {
          #   hostname = "minio";
          #   domain = "lan";
          #   ip = "10.0.0.63";
          # }
          # {
          #   hostname = "vikunja";
          #   domain = "lan";
          #   ip = "10.0.0.64";
          # }
          # {
          #   hostname = "mariadb";
          #   domain = "lan";
          #   ip = "10.0.0.65";
          # }
          # {
          #   hostname = "photoprism";
          #   domain = "lan";
          #   ip = "10.0.0.66";
          # }
          # {
          #   hostname = "librephotos";
          #   domain = "lan";
          #   ip = "10.0.0.67";
          # }
          # {
          #   hostname = "collabora";
          #   domain = "lan";
          #   ip = "10.0.0.69";
          # }
          # {
          #   hostname = "onlyoffice";
          #   domain = "lan";
          #   ip = "10.0.0.70";
          # }
          # {
          #   hostname = "cryptpad";
          #   domain = "lan";
          #   ip = "10.0.0.71";
          # }
          # {
          #   hostname = "cryptpad-sandbox";
          #   domain = "lan";
          #   ip = "10.0.0.71";
          # }
          # {
          #   hostname = "ethercalc";
          #   domain = "lan";
          #   ip = "10.0.0.72";
          # }
          # {
          #   hostname = "redis";
          #   domain = "lan";
          #   ip = "10.0.0.73";
          # }
          # {
          #   hostname = "authentik";
          #   domain = "lan";
          #   ip = "10.0.0.74";
          # }
          # {
          #   hostname = "postgres";
          #   domain = "lan";
          #   ip = "10.0.0.75";
          # }
          # {
          #   hostname = "joplin";
          #   domain = "lan";
          #   ip = "10.0.0.76";
          # }
          # {
          #   hostname = "etherpad";
          #   domain = "lan";
          #   ip = "10.0.0.77";
          # }
          # {
          #   hostname = "grist";
          #   domain = "lan";
          #   ip = "10.0.0.78";
          # }
          # {
          #   hostname = "vaultwarden";
          #   domain = "lan";
          #   ip = "10.0.0.79";
          # }
          # {
          #   hostname = "wiki";
          #   domain = "lan";
          #   ip = "10.0.0.81";
          # }
          # {
          #   hostname = "wikijs";
          #   domain = "lan";
          #   ip = "10.0.0.81";
          # }
          # {
          #   hostname = "gitea";
          #   domain = "lan";
          #   ip = "10.0.0.82";
          # }
          # {
          #   hostname = "drawio";
          #   domain = "lan";
          #   ip = "10.0.0.83";
          # }
          # {
          #   hostname = "minecraft";
          #   domain = "lan";
          #   ip = "10.0.0.84";
          # }
          # {
          #   hostname = "syncthing";
          #   domain = "lan";
          #   ip = "10.0.0.85";
          # }
          # {
          #   hostname = "xbrowsersync";
          #   domain = "lan";
          #   ip = "10.0.0.86";
          # }
          # {
          #   hostname = "jellyfin";
          #   domain = "lan";
          #   ip = "10.0.0.87";
          # }
          # {
          #   hostname = "smokeping";
          #   domain = "lan";
          #   ip = "10.0.0.88";
          # }
          # {
          #   hostname = "nextcloud";
          #   domain = "lan";
          #   ip = "10.0.0.89";
          # }
        ];
      };
    };

    proxied-domains = [
      {
        domains = [ "slacktopia.org" "*.slacktopia.org" ];
        target = {
          # host = "10.0.0.46";  # or hostname
          host = "10.0.0.59";  # or hostname
          http = {
            port = 8080;
          };
          https = {
            port = 8443;
            ignore-self-signed-cert = true;
          };
        };
        public = false;  # accessible from WAN
      }
    ];

    ## @TODO: Rename? e.g. user-services; optional-services? web-services?  There are other services besides these.
    services = {
      adguard = {
        enable = true;
      };

      authentik = {
        enable = false;
        secrets = {
          environment = config.sops.secrets."authentik/authentik-env".path;
          ldap-environment = config.sops.secrets."authentik/authentik-ldap-env".path;
        };
      };

      baikal = {
        enable = true;
      };

      cryptpad = {
        enable = true;
        adminKeys = [
          "[erahhal@docs.homefree.host/P5QOi+XGnpjjH1R0ua5FWXH3CoWG-+fsG-fZFYitvN0=]"
        ];
      };

      freshrss = {
        enable = true;
      };

      forgejo = {
        enable = true;
        public = true;
      };

      frigate = {
        enable = true;
        media-path = "/mnt/ellis/nvr";
        enable-backup-media = false;
        retain = 30;
        cameras = [
          {
            enable = true;
            ## Fix audio delay in recordings
            direct-stream = true;
            name = "doorbell";
            path = "rtsp://admin:h3llb3nt@10.0.0.10:554/Preview_01_main";
            # path = "rtsp://admin:h3llb3nt@10.0.0.10:554/Preview_01_sub";
            # path = "rtsp://admin:h3llb3nt@10.0.0.10:554";
            width = 1920;
            height = 1080;
            ## Full resolution - @TODO try this out
            # width = 2560;
            # height = 1920;
          }
          {
            enable = true;
            name = "gate";
            path = "rtsp://admin:h3llb3nt@10.0.0.15/11";
            width = 1920;
            height = 1080;
          }
          {
            enable = false;
            name = "reolink-fixed";
            path = "rtsp://6nAPdQpfVNmS:07kN6uekoI6e@10.0.0.17:554/live0";
            width = 1920;
            height = 1080;
          }
          {
            enable = false;
            name = "amcrest-ip5m";
            path = "rtsp://admin:h3llb3nt@10.0.0.22:554/cam/realmonitor?channel=1&subtype=0";
            ## Frigate can't seem to handle full resolution
            # width = 2592;
            # height = 1944;
            width = 1600;
            height = 1200;
          }
          {
            enable = false;
            name = "eufy-ptz";
            path = "rtsp://p1mmL82zytvc:6C7qwtpTqFTE@10.0.0.18:554/live0";
            width = 1920;
            height = 1080;
          }
          {
            enable = false;
            name = "reolink-e1-pro-1";
            path = "rtsp://admin:h3llb3nt@10.0.0.60:554/Preview_01_main";
            # path = "rtsp://admin:h3llb3nt@10.0.0.60:554/Preview_01_sub";
            # path = "rtsp://admin:h3llb3nt@10.0.0.60:554";
            width = 1920;
            height = 1080;
          }
          {
            enable = false;
            name = "reolink-e1-pro-2";
            path = "rtsp://admin:h3llb3nt@10.0.0.61:554/Preview_01_main";
            # path = "rtsp://admin:h3llb3nt@10.0.0.61:554/Preview_01_sub";
            # path = "rtsp://admin:h3llb3nt@10.0.0.61:554";
            width = 1920;
            height = 1080;
          }
        ];
      };

      gitea = {
        enable = false;
        public = false;
      };

      grocy = {
        enable = true;
      };

      ## NOTE: `services.headscale` is the legacy option path; a compat shim
      ## in module.nix mirrors it onto the new `service-options.headscale.*`
      ## namespace declared in services/headscale.nix. New configuration
      ## should prefer `homefree.service-options.headscale = { ... }`.
      headscale = {
        enable = true;
        secrets = {
          tailscale-key = config.sops.secrets."tailscale/key".path;
          ## headplane-env is deprecated as of headplane 0.7. Per-secret
          ## fields (headplane-cookie-secret, oidc-client-id,
          ## oidc-client-secret, headscale-api-key) are managed via the
          ## admin UI under homefree.service-options.headscale.secrets.
          headplane-env = config.sops.secrets."headplane/env".path;
        };
      };

      homeassistant = {
        enable = true;
      };

      homebox = {
        enable = true;
        disable-registration = false;
      };

      immich = {
        enable = true;
      };

      jellyfin = {
        enable = true;
        media-path = "/mnt/ellis/Media";
      };

      joplin = {
        enable = true;
      };

      lidarr = {
        enable = true;
        media-path = "/mnt/ellis/Media/Music";
        downloads-path = "/mnt/ellis/Media/Downloads/Music";
        enable-backup-media = false;
      };

      linkwarden = {
        enable = true;
        secrets = {
          environment = config.sops.secrets."linkwarden/env".path;
        };
      };

      matrix = {
        enable = true;
        enable-federation = true;
        admin-account = "erahhal";
        public = true;
        secrets = {
          registration-shared-secret = config.sops.secrets."matrix/registration-shared-secret".path;
          admin-account-password = config.sops.secrets."matrix/admin-account-password".path;
        };
      };

      mediawiki = {
        enable = true;
        sites = [{
          public = true;
          subdomain = "grimoire";
          name = "Magik Voodoo Tantra Grimoire";
          logo-path = ./images/third-eye-cat.png;
          disable-anonymous-editing = true;
          disable-anonymous-viewing = true;
          disable-user-registration = true;
        }];
        secrets = {
          mysql-password = config.sops.secrets."mediawiki/mysql-password".path;
          wgSecretKey = config.sops.secrets."mediawiki/wgSecretKey".path;
          env = config.sops.secrets."mediawiki/env".path;
        };
      };

      minecraft = {
        enable = true;
        instances = [{
          public = true;
          subdomain = "minecraft";
          name = "Rahhal Minecraft Server";
        }
        {
          public = true;
          subdomain = "minecraft-cisco";
          name = "Cisco's Medieval Fantasy RPG";
          memory = "6G";
          type = "AUTO_CURSEFORGE";
          mod-pack = {
            project-slug = "ciscos-adventure-rpg-ultimate";
          };
        }];
        secrets = {
          curseforge-api-key = config.sops.secrets."minecraft/curseforge-api-key".path;
        };
      };

      ## NetBird is a second VPN platform that coexists with Headscale.
      ## All four secrets must be populated via the admin UI's SOPS surface
      ## before the server containers will deploy. See services/netbird.nix
      ## for the Zitadel pre-flight steps (OIDC app + machine user).
      ## Lives under service-options.* (no compat shim — it's a new service).
      # service-options.netbird = {
      #   enable = false;
      #   client.enable = false;  # router-as-peer; defer until tested
      # };

      nextcloud = {
        enable = true;
        secrets = {
          admin-password = config.sops.secrets."nextcloud/admin-password".path;
          env = config.sops.secrets."nextcloud/env".path;
          secret-file = config.sops.secrets."nextcloud/secret-file".path;
        };
      };

      nzbget = {
        enable = true;
        downloads-path = "/mnt/ellis/Media/Downloads/Music";
        enable-backup-media = false;
      };

      oauth2-proxy = {
        secrets = {
          env = config.sops.secrets."oauth2-proxy/oauth2-proxy-env".path;
        };
      };

      ollama = {
        enable = true;
      };

      radicale = {
        enable = true;
      };

      snipe-it = {
        enable = true;
        secrets = {
          mysql-password = config.sops.secrets."snipe-it/mysql-password".path;
          env = config.sops.secrets."snipe-it/env".path;
        };
      };

      unifi = {
        enable = true;
      };

      vaultwarden = {
        enable = true;
      };

      webdav = {
        enable = true;
      };

      zitadel = {
        enable = true;
        secrets = {
          env = config.sops.secrets."zitadel/env".path;
        };
      };
    };

    ## @TODO: Might want to keep service-config internal and rename this to custom-services?
    service-config = [
      ## ------------------------------------------
      ## EXTERNAL
      ## ------------------------------------------
      {
        label = "apc98c412";
        name = "APC Managed Power Strip";
        reverse-proxy = {
          enable = true;
          subdomains = [ "apc98c412" ];
          https-domains = [ "homefree.host" "rahh.al" ];
          host = "apc98c412.${config.homefree.system.localDomain}";
          port = 80;
        };
      }
      {
        label = "att";
        name = "AT&T Fiber Router";
        reverse-proxy = {
          enable = true;
          subdomains = [ "att" ];
          https-domains = [ "homefree.host" "rahh.al" ];
          host = "att.${config.homefree.system.localDomain}";
          port = 80;
        };
      }
      {
        label = "envoy";
        name = "Enphase Solar (Envoy)";
        reverse-proxy = {
          enable = true;
          subdomains = [ "envoy" ];
          https-domains = [ "homefree.host" "rahh.al" ];
          host = "envoy.${config.homefree.system.localDomain}";
          port = 443;
          ssl = true;
          ssl-no-verify = true;
        };
      }
      {
        label = "nas";
        name = "Synology NAS";
        reverse-proxy = {
          enable = true;
          subdomains = [ "nas" ];
          https-domains = [ "homefree.host" "rahh.al" ];
          host = "nas.${config.homefree.system.localDomain}";
          port = 5000;
        };
      }
      {
        label = "opensprinkler";
        name = "OpenSprinkler Admin";
        reverse-proxy = {
          enable = true;
          subdomains = [ "opensprinkler" ];
          https-domains = [ "homefree.host" "rahh.al" ];
          host = "opensprinkler.${config.homefree.system.localDomain}";
          port = 80;
        };
      }

      ## ------------------------------------------
      ## TO DEPRECATE
      ## ------------------------------------------
      {
        label = "homeassitant-old";
        name = "Home Assistant (Old)";
        reverse-proxy = {
          enable = true;
          subdomains = [ "ha" ];
          https-domains = [ "rahh.al" ];
          host = "homeassistant-old.${config.homefree.system.localDomain}";
          port = 8123;
        };
      }
    ];

    docker-io-auth = {
      enable = true;
      username = "erahhal";
      secrets = {
        password = config.sops.secrets."docker-io-auth/password".path;
      };
    };

    ## ------------------------------------------
    ## Backups
    ## ------------------------------------------

    backups = {
      enable = true;
      to-path = "/mnt/ellis/Backups/homefree";
      # Note: /etc/nixos is always backed up automatically
      extra-from-paths = [
        "/mnt/ellis/Code"
        "/mnt/ellis/Companies"
        "/mnt/ellis/Documents"
        "/mnt/ellis/Kat"
        "/mnt/ellis/Private"
        "/mnt/ellis/Projects"
        "/mnt/ellis/Recipes"
        "/mnt/ellis/Backup_nas.hbk"
        "/mnt/ellis/Backups/oneplus7pro-backup-apps"
        "/mnt/ellis/Backups/oneplus7pro-backup-signal"
        "/mnt/nas-home/erahhal/Photos"
        # "/mnt/homeassistant-backups"
      ];
      backblaze = {
        enable = true;
        bucket = "homefree";
      };
      secrets = {
        restic-password = config.sops.secrets."backup/restic-password".path;
        restic-environment = config.sops.secrets."backup/restic-environment".path;
        backblaze-id = config.sops.secrets."backup/backblaze-id".path;
        backblaze-key = config.sops.secrets."backup/backblaze-key".path;
      };
    };

    ## @TODO: Add custom backup paths

    # proxied-hosts = [
    #   {
    #     label = "adguard_server";
    #     hostname = "10.0.0.1";
    #     port = 8083;
    #     description = "adguard";
    #   }
    #   {
    #     label = "ap7900_server";
    #     hostname = "ap7900.${config.homefree.system.localDomain}";
    #     port = 80;
    #     description = "ap7900";
    #   }
    #   {
    #     label = "aruba_server";
    #     hostname = "aruba.${config.homefree.system.localDomain}";
    #     port = 4343;
    #     description = "aruba";
    #   }
    #   {
    #     label = "att_server";
    #     hostname = "att.${config.homefree.system.localDomain}";
    #     port = 80;
    #     description = "att";
    #   }
    #   {
    #     label = "authentik_server";
    #     hostname = "authentik.${config.homefree.system.localDomain}";
    #     port = 9443;
    #     description = "Authentik";
    #   }
    #   {
    #     label = "cablemodem_server";
    #     hostname = "cablemodem.${config.homefree.system.localDomain}";
    #     port = 80;
    #     description = "cablemodem";
    #   }
    #   {
    #     label = "collabora_server";
    #     hostname = "collabora.${config.homefree.system.localDomain}";
    #     port = 9980;
    #     description = "collabora";
    #   }
    #   {
    #     label = "cryptpad_sandbox_server";
    #     hostname = "cryptpad-sandbox.${config.homefree.system.localDomain}";
    #     port = 3000;
    #     description = "cryptpad-sandbox";
    #   }
    #   {
    #     label = "cryptpad_server";
    #     hostname = "cryptpad.${config.homefree.system.localDomain}";
    #     port = 3000;
    #     description = "cryptpad";
    #   }
    #   {
    #     label = "drawio_server";
    #     hostname = "drawio.${config.homefree.system.localDomain}";
    #     port = 80;
    #     description = "drawio";
    #   }
    #   {
    #     label = "ethercalc_server";
    #     hostname = "ethercalc.${config.homefree.system.localDomain}";
    #     port = 80;
    #     description = "ethercalc";
    #   }
    #   {
    #     label = "etherpad_server";
    #     hostname = "etherpad.${config.homefree.system.localDomain}";
    #     port = 80;
    #     description = "etherpad";
    #   }
    #   {
    #     label = "gitea_server";
    #     hostname = "gitea.${config.homefree.system.localDomain}";
    #     port = 80;
    #     description = "gitea";
    #   }
    #   {
    #     label = "grist_server";
    #     hostname = "grist.${config.homefree.system.localDomain}";
    #     port = 80;
    #     description = "grist";
    #   }
    #   {
    #     label = "ha_server";
    #     hostname = "homeassistant.${config.homefree.system.localDomain}";
    #     port = 8123;
    #     description = "ha";
    #   }
    #   {
    #     label = "homebox_server";
    #     hostname = "homebox.${config.homefree.system.localDomain}";
    #     port = 80;
    #     description = "homebox";
    #   }
    #   {
    #     label = "jellyfin_server";
    #     hostname = "jellyfin.${config.homefree.system.localDomain}";
    #     port = 80;
    #     description = "jellyfin";
    #   }
    #   {
    #     label = "joplin_server";
    #     hostname = "joplin.${config.homefree.system.localDomain}";
    #     port = 22300;
    #     description = "Joplin";
    #   }
    #   {
    #     label = "librephotos_server";
    #     hostname = "librephotos.${config.homefree.system.localDomain}";
    #     port = 80;
    #     description = "librephotos";
    #   }
    #   {
    #     label = "minio_server";
    #     hostname = "minio.${config.homefree.system.localDomain}";
    #     port = 9001;
    #     description = "minio";
    #   }
    #   {
    #     label = "nas_server";
    #     hostname = "nas.${config.homefree.system.localDomain}";
    #     port = 5000;
    #     description = "NAS";
    #   }
    #   {
    #     label = "nextcloud_server";
    #     hostname = "nextcloud.${config.homefree.system.localDomain}";
    #     port = 80;
    #     description = "Nextcloud";
    #   }
    #   {
    #     label = "onlyoffice_server";
    #     hostname = "onlyoffice.${config.homefree.system.localDomain}";
    #     port = 80;
    #     description = "onlyoffice";
    #   }
    #   {
    #     label = "opensprinkler_server";
    #     hostname = "opensprinkler.${config.homefree.system.localDomain}";
    #     port = 80;
    #     description = "Opensprinkler";
    #   }
    #   {
    #     label = "opnsense_server";
    #     hostname = "10.0.0.1";
    #     port = 8445;
    #     description = "opnsense";
    #   }
    #   {
    #     label = "photoprism_server";
    #     hostname = "photoprism.${config.homefree.system.localDomain}";
    #     port = 80;
    #     description = "photoprism";
    #   }
    #   {
    #     label = "pinry_server";
    #     hostname = "pinry.${config.homefree.system.localDomain}";
    #     port = 80;
    #     description = "Pinry";
    #   }
    #   {
    #     label = "s3_server";
    #     hostname = "minio.${config.homefree.system.localDomain}";
    #     port = 9000;
    #     description = "s3";
    #   }
    #   {
    #     label = "smokeping_server";
    #     hostname = "smokeping.${config.homefree.system.localDomain}";
    #     port = 80;
    #     description = "smokeping";
    #   }
    #   {
    #     label = "syncthing_server";
    #     hostname = "syncthing.${config.homefree.system.localDomain}";
    #     port = 80;
    #     description = "syncthing";
    #   }
    #   {
    #     label = "unifi_server";
    #     hostname = "10.0.0.1";
    #     port = 8443;
    #     description = "unifi";
    #   }
    #   {
    #     label = "ups_server";
    #     hostname = "10.0.0.232";
    #     port = 80;
    #     description = "ups";
    #   }
    #   {
    #     label = "vaultwarden_server";
    #     hostname = "vaultwarden.${config.homefree.system.localDomain}";
    #     port = 80;
    #     description = "vaultwarden";
    #   }
    #   {
    #     label = "vikunja_server";
    #     hostname = "vikunja.${config.homefree.system.localDomain}";
    #     port = 80;
    #     description = "vikunja";
    #   }
    #   {
    #     label = "wekan_server";
    #     hostname = "wekan.${config.homefree.system.localDomain}";
    #     port = 80;
    #     description = "wekan";
    #   }
    #   {
    #     label = "wikijs_server";
    #     hostname = "wikijs.${config.homefree.system.localDomain}";
    #     port = 80;
    #     description = "wikijs";
    #   }
    #   {
    #     label = "xbrowsersync_server";
    #     hostname = "xbrowsersync.${config.homefree.system.localDomain}";
    #     port = 80;
    #     description = "xbrowsersync";
    #   }
    #   {
    #     label = "zwave_server";
    #     hostname = "zwave.${config.homefree.system.localDomain}";
    #     port = 8091;
    #     description = "zwave";
    #   }
    # ];
  };
}
