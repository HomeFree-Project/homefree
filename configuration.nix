{ config, homefree-inputs, lib, ... }:
let
  defaultLocale = config.homefree.system.defaultLocale;
in
{
  imports = [
    ./profiles/acme.nix
    ./profiles/bash.nix
    ./profiles/boot-branding.nix
    ./profiles/common.nix
    # ./profiles/config-editor.nix
    ./profiles/git.nix
    ./profiles/hardware-configuration.nix
    ./profiles/router.nix
    ./profiles/secrets.nix
    ./profiles/traffic-control.nix
    ./profiles/virtualisation.nix

    ## Host modules
    ./modules/mounts.nix

    ## ─── Infrastructure (services/) ───
    ## System services shared by apps; not user-facing.
    ./services/admin-web
    ./services/backup
    ./services/caddy
    ./services/ddclient
    ./services/dnsmasq
    ./services/goidc-proxy
    ./services/landing-page
    # ./services/mongo
    ./services/mqtt
    ./services/mysql
    ./services/netavark-reload
    ./services/postgres
    ./services/postgres-vectorchord
    ./services/service-config-json
    ./services/sso
    ./services/unbound

    ## ─── User-facing apps (apps/) ───
    ## Each app is self-contained: default.nix + icon.svg + manual.md
    ## live in apps/<name>/. Order doesn't matter — modules merge.
    ## Inside each one's default.nix the `enable` toggle is gated on
    ## the user's homefree-config.json so importing is cheap when
    ## the app is disabled.
    ./apps/adguard
    ./apps/azuracast
    ./apps/baikal
    ./apps/cryptpad
    ./apps/forgejo
    ./apps/freshrss
    ./apps/frigate
    ./apps/grocy
    ./apps/headscale
    ./apps/home-assistant
    ./apps/homebox
    ./apps/immich
    ./apps/jellyfin
    ./apps/joplin
    ./apps/lidarr
    ./apps/linkwarden
    ./apps/matrix
    ./apps/mediawiki
    ./apps/minecraft
    ./apps/netbird
    ./apps/nextcloud
    ./apps/nzbget
    ./apps/odoo
    ./apps/ollama
    ./apps/radicale
    ./apps/screeenly
    ./apps/snipe-it
    ./apps/trilium
    ./apps/unifi
    ./apps/unifi-os
    ./apps/vaultwarden
    ./apps/webdav

    ## Zitadel is the SSO identity provider. Its three operational
    ## helpers (provision/pam-bridge/password-shim) live alongside
    ## the main module so everything Zitadel ships in one folder.
    ./apps/zitadel
    ./apps/zitadel/provision.nix
    ./apps/zitadel/pam-bridge.nix
    ./apps/zitadel/password-shim.nix

    ## @TODO: Move to podman so apps can be upgraded independently
    ## of the rest of the system.
    # ./apps/authentik
  ];

  nix = {
    nixPath = [ "nixpkgs=${homefree-inputs.nixpkgs}" ];
  };

  # Only create admin user on installed systems (not in live installer)
  users.users."${config.homefree.system.adminUsername}" = lib.mkIf (config.system.nixos.variant_id or "" != "installer") {
    isNormalUser  = true;
    home  = "/home/${config.homefree.system.adminUsername}";
    description = config.homefree.system.adminDescription;
    extraGroups = [ "wheel" "docker" ];
    openssh.authorizedKeys.keys = config.homefree.system.authorizedKeys;
    initialHashedPassword = "";  # Empty password - should be set on first login or via SSH
  };

  # --------------------------------------------------------------------------------------
  # i18n
  # --------------------------------------------------------------------------------------

  # @TODO: Make this UI configurable
  i18n.defaultLocale = defaultLocale;

  i18n.extraLocaleSettings = {
    LC_ADDRESS = defaultLocale;
    LC_IDENTIFICATION = defaultLocale;
    LC_MEASUREMENT = defaultLocale;
    LC_MONETARY = defaultLocale;
    LC_NAME = defaultLocale;
    LC_NUMERIC = defaultLocale;
    LC_PAPER = defaultLocale;
    LC_TELEPHONE = defaultLocale;
    LC_TIME = defaultLocale;
  };

  console.keyMap = config.homefree.system.keyMap;

  # --------------------------------------------------------------------------------------
  # Boot
  # --------------------------------------------------------------------------------------

  # boot.loader = {
  #   systemd-boot = {
  #     enable = true;
  #     configurationLimit = 10;
  #     # Use maximum resolution in systemd-boot for hidpi
  #     consoleMode = "max";
  #   };
  #   efi = {
  #     canTouchEfiVariables = true;
  #   };
  # };

  # --------------------------------------------------------------------------------------
  # Network
  # --------------------------------------------------------------------------------------

  # Prevent hanging when waiting for network to be up
  systemd.network.wait-online.anyInterface = true;

  networking.search = [ config.homefree.system.localDomain ];

  # --------------------------------------------------------------------------------------
  # Base Packages
  # --------------------------------------------------------------------------------------

  nixvim-config = {
    enable = true;
    startify-header = let header-space = "   "; in [
     ''${header-space}  ___ ___                      ___________''
     ''${header-space} /   |   \  ____   _____   ____\_   _____/______   ____   ____''
     ''${header-space}/    ~    \/  _ \ /     \_/ __ \|    __) \_  __ \_/ __ \_/ __ \''
     ''${header-space}\    Y    (  <_> )  Y Y  \  ___/|     \   |  | \/\  ___/\  ___/''
     ''${header-space} \___|_  / \____/|__|_|  /\___  >___  /   |__|    \___  >\___  >''
     ''${header-space}       \/              \/     \/    \/                \/     \/''
    ];
  };

  # --------------------------------------------------------------------------------------
  # Device specific
  # --------------------------------------------------------------------------------------

  # @TODO: Make this UI configurable
  ## Must be forced due to Authentik hard coding a value of UTC
  time.timeZone = lib.mkForce config.homefree.system.timeZone;

  networking = {
    # @TODO: Make this UI configurable
    hostName = config.homefree.system.hostName;
    ## NetworkManager disabled in favor of networkd
    useNetworkd = true;
    # wireless = {
    #   # Disable wpa_supplicant
    #   enable = false;
    # };
  };

  # services.openssh.hostKeys = [
  #   {
  #     bits = 4096;
  #     openSSHFormat = true;
  #     path = "/etc/ssh/ssh_host_rsa_key";
  #     rounds = 100;
  #     type = "rsa";
  #   }
  # ];

  # --------------------------------------------------------------------------------------
  # Hardware specific
  # --------------------------------------------------------------------------------------
}


