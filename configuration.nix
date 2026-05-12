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

    ## Admin interface
    ./services/admin-web.nix

    ## System services
    ## @TODO: Evaluate if any can be moved to podman
    ./services/backup.nix
    ./services/caddy.nix
    ./services/ddclient.nix
    ./services/dnsmasq.nix
    ./services/headscale.nix
    ./services/netbird.nix
    ./services/landing-page
    ./services/unbound.nix

    ## Shared services
    ## @TODO: Evaluate if any can be moved to podman
    ./services/mqtt.nix
    ./services/mysql.nix
    ./services/postgres.nix

    ## Podman-based services
    ./services/adguardhome-podman.nix
    ./services/azuracast-podman.nix
    ./services/baikal-podman.nix
    ./services/cryptpad-podman.nix
    ./services/forgejo-podman.nix
    ./services/freshrss-podman.nix
    ./services/frigate-podman.nix
    ./services/grocy-podman.nix
    ./services/home-assistant-podman.nix
    ./services/homebox-podman.nix
    ./services/jellyfin-podman.nix
    ./services/joplin-podman.nix
    ./services/immich-podman.nix
    ./services/linkwarden-podman.nix
    ./services/lidarr-podman.nix
    # ./services/matrix-podman.nix
    ./services/mediawiki-podman.nix
    ./services/minecraft-podman.nix
    # ./services/mongo-podman.nix
    ./services/nextcloud-podman.nix
    ./services/nzbget-podman.nix
    ./services/odoo-podman.nix
    ./services/ollama-podman.nix
    ./services/postgres-vectorchord-podman.nix
    ./services/radicale-podman.nix
    ./services/screeenly-podman.nix
    ./services/snipe-it-podman.nix
    ./services/trilium-podman.nix
    ./services/unifi-podman.nix
    ./services/unifi-os-podman.nix
    ./services/vaultwarden-podman.nix
    ./services/webdav-podman.nix
    ./services/sso.nix
    ./services/zitadel-podman.nix
    ./services/zitadel-provision.nix
    ./services/zitadel-pam-bridge.nix
    # ./services/zitadel-podman-oauth.nix

    ## @TODO: Move to podman
    ## Otherwise entire system needs to be upgraded to upgrade individual app
    # ./services/authentik.nix
    # ./services/matrix.nix
    # ./services/nextcloud.nix
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


