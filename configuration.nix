{ config, homefree-inputs, lib, ... }:
let
  defaultLocale = config.homefree.system.defaultLocale;

  ## Auto-discover every module under `apps/` and `services/`. Each
  ## subdirectory is one self-contained module — its `default.nix`
  ## is the entrypoint. Subdirectories whose name starts with `_`
  ## are skipped, which is the convention for disabling a module
  ## without deleting it (e.g. `_mongo/`, `_goidc-proxy/`).
  ##
  ## Adding a new service requires only creating `apps/<name>/` or
  ## `services/<name>/` with a `default.nix` — no edit here.
  ## Removing one requires only `rm -rf apps/<name>/` (or rename
  ## to `_<name>` to keep it on disk but out of the build).
  discoverModules = dir:
    let
      entries = builtins.readDir dir;
      isEnabledDir = name: type:
        type == "directory" && !(lib.hasPrefix "_" name);
    in
      lib.mapAttrsToList
        (name: _: dir + "/${name}")
        (lib.filterAttrs isEnabledDir entries);
in
{
  imports = [
    ./profiles/acme.nix
    ./profiles/bash.nix
    ./profiles/boot-branding.nix
    ./profiles/common.nix
    ./profiles/git.nix
    ./profiles/hardware-configuration.nix
    ./profiles/router.nix
    ./profiles/secrets.nix
    ./profiles/security-policy.nix
    ./profiles/traffic-control.nix
    ./profiles/virtualisation.nix

    ## Host modules
    ./modules/mounts.nix
    ./modules/storage-pools.nix
    ./modules/storage-shares.nix
    ./modules/media-server.nix
    ./modules/snapshots.nix
    ./modules/service-restart-policy.nix
    ./modules/app-platform.nix
    ./modules/sso-clients.nix
    ./modules/abuse-blocking.nix
    ./modules/geoip.nix
    ./modules/setup-state.nix
    ./modules/instance-managed-docs.nix
    ./modules/finish-setup-console.nix
    ./modules/secrets-recipient-migrate.nix
    ./modules/boot-mirror.nix
    ./modules/auditd.nix
    ./modules/lan-static-ip.nix
  ]
  ## Infrastructure modules (system services shared by apps; not
  ## user-facing). Discovered from services/.
  ++ (discoverModules ./services)
  ## User-facing apps. Discovered from apps/. Each app's
  ## default.nix gates its config on a `homefree.services.<name>.enable`
  ## option so importing a disabled app is cheap.
  ++ (discoverModules ./apps);

  nix = {
    nixPath = [ "nixpkgs=${homefree-inputs.nixpkgs}" ];
  };

  # Only create admin user on installed systems (not in live installer)
  users.users."${config.homefree.system.adminUsername}" = lib.mkIf (config.system.nixos.variant_id or "" != "installer") ({
    isNormalUser  = true;
    home  = "/home/${config.homefree.system.adminUsername}";
    description = config.homefree.system.adminDescription;
    extraGroups = [ "wheel" "docker" ];
    openssh.authorizedKeys.keys = config.homefree.system.authorizedKeys;
  } // (
    ## Set exactly one password option so NixOS doesn't warn about
    ## conflicting precedence. When a hash is configured in
    ## homefree-config.json (system.hashedPassword, wired by
    ## modules/homefree-config-loader.nix) it is the persistent admin
    ## password. Otherwise fall back to an empty initial password,
    ## which is set on first login or via SSH.
    if config.homefree.system.hashedPassword != null then {
      hashedPassword = config.homefree.system.hashedPassword;
    } else {
      initialHashedPassword = "";
    }
  ));

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
  time.timeZone = config.homefree.system.timeZone;

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


