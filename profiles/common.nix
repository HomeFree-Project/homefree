{ pkgs, system, ...}:
{
  # --------------------------------------------------------------------------------------
  # Overlays
  # --------------------------------------------------------------------------------------

  nixpkgs.overlays = [
    (import ../overlays/backblaze-b2.nix)
  ];

  # --------------------------------------------------------------------------------------
  # Base Nix config
  # --------------------------------------------------------------------------------------

  # @TODO: Could this be useful for auto-upgrading systems out there?
  # system.autoUpgrade = {
  #   enable = true;
  #   allowReboot = true;
  #   flake = "github:erahhal/nixcfg";
  #   flags = [
  #     "--recreate-lock-file"
  #     "-no-write-lock-file"
  #     "-L" # print build logs
  #   ];
  #   dates = "daily";
  # };

  nix = {
    # Which package collection to use system-wide.
    package = pkgs.nixVersions.stable;
    # package = pkgs.nixFlakes;

    settings = {
      # sets up an isolated environment for each build process to improve reproducibility.
      # Disallow network callsoutside of fetch* and files outside of the Nix store.
      sandbox = true;
      # Automatically clean out old entries from nix store by detecting duplicates and creating hard links.
      # Only starts with new derivations, so run "nix-store --optimise" to clear out older cruft.
      # optimise.automatic = true below should handle this.
      auto-optimise-store = true;
      # Users with additional Nix daemon rights.
      # Can specify additional binary caches, import unsigned NARs (Nix Archives).
      trusted-users = [ "@wheel" "root" ];
      # Users allowed to connect to Nix daemon
      allowed-users = [ "@wheel" ];
      substituters = [
        "https://cache.nixos.org"
        "https://hydra.nixos.org"
        "https://nix-community.cachix.org"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "hydra.nixos.org-1:CNHJZBh9K4tP3EKF6FkkgeVYsS3ohTl+oS0Qa8bezVs="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
    };
    # Additional text appended to nix.conf
    extraOptions =
      let empty_registry = builtins.toFile "empty-flake-registry.json" ''{"flakes":[],"version":2}''; in
      ''
        # Enable flakes
        experimental-features = nix-command flakes recursive-nix
        flake-registry = ${empty_registry}

        builders-use-substitutes = true

        # Prevents garbage collector from deleting derivations.
        # Useful for querying and tracing options and dependencies for a store path.
        # https://ianthehenry.com/posts/how-to-learn-nix/saving-your-shell/
        keep-derivations = true

        # Prevents garbage collector from deleting outputs of derivations.
        keep-outputs = true
      '';

    # Garbage collection - deletes all unreachable paths in Nix store.
    gc = {
      # Run garbage collection automatically
      automatic = true;
      # Run once a week
      dates = "weekly";
      # Delete older than 7 days, stopping after "max-freed" bytes
      options = "--delete-older-than 7d --max-freed $((64 * 1024**3))";
    };
    # Optimiser settings
    # It seems that this is a scheduled job, as opposed to "autoOptimiseStore", which runs just in time.
    optimise = {
      automatic = true;
      dates = [ "weekly" ];
    };
  };

  # --------------------------------------------------------------------------------------
  # User config
  # --------------------------------------------------------------------------------------

  users.users.www-data = {
    uid = 33;
    group = "www-data";
    isSystemUser = true;
    shell = pkgs.shadow;  # or pkgs.bash if you need shell access
  };

  users.groups.www-data = {
    gid = 33;
  };

  security.sudo.extraRules = [
    {
      groups = [ "wheel" ];
      commands = [ { command = "ALL"; options = [ "NOPASSWD" ]; } ];
    }
  ];

  # --------------------------------------------------------------------------------------
  # Package config
  # --------------------------------------------------------------------------------------

  nixpkgs = {
    hostPlatform = system;
    config = {
      # Allow proprietary packages.
      allowUnfree = true;
    };
  };

  # --------------------------------------------------------------------------------------
  # Boot / Kernel
  # --------------------------------------------------------------------------------------

  # Disables writing to Nix store by mounting read-only. "false" should only be used as a last resort.
  # Nix mounts read-write automatically when it needs to write to it.
  boot.nixStoreMountOpts = [ "ro" ];

  # boot.kernelPackages = pkgs.linuxPackages_latest;

  boot.kernel.sysctl = {
    "fs.inotify.max_user_watches" = 1048577; # defau
    "fs.inotify.max_user_instances" = 1024; # default: 128
    "fs.inotify.max_queued_events" = 32768; # default: 16384
  };

  # --------------------------------------------------------------------------------------
  # Hardware
  # --------------------------------------------------------------------------------------

  hardware.enableRedistributableFirmware = true;
  hardware.enableAllFirmware = true;

  # --------------------------------------------------------------------------------------
  # System
  # --------------------------------------------------------------------------------------

  ## Needed to avoid "too many file open" errors when building containers
  systemd.settings.Manager.DefaultLimitNOFILE = 4096;
  security.pam.loginLimits = [
    { domain = "*"; item = "nofile"; type = "-"; value = "65536"; }
  ];

  # --------------------------------------------------------------------------------------
  # Services
  # --------------------------------------------------------------------------------------

  # Firmware/BIOS updates
  services.fwupd.enable = true;

  # Setting to true will kill things like tmux on logout
  services.logind.settings.Login.KillUserProcesses = false;

  services.gvfs.enable = true; # SMB mounts, trash, and other functionality
  services.tumbler.enable = true; # Thumbnail support for images

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # @TODO: Move to "environment"?
  services.printing.drivers = [ pkgs.brlaser ];

  # Enable the OpenSSH daemon.
  services.openssh = {
    enable = true;
  };

  # This will save you money and possibly your life!
  services.thermald.enable = true;

  services.upower.enable = true;

  # Enable power management
  powerManagement = {
    enable = true;
    powertop.enable = true;
  };

  # Disable USB autosuspend for HID devices (keyboards, mice, etc.).
  # Why: powertop's autotuning enables USB autosuspend globally, which causes
  # the first few keystrokes after an idle period to be dropped while the
  # device wakes up. HID devices barely save any power from suspending, so
  # exempt them entirely.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="03", TEST=="power/control", ATTR{power/control}="on"
    ACTION=="add", SUBSYSTEM=="usb", DRIVERS=="usbhid", TEST=="power/control", ATTR{power/control}="on"
  '';

  # Eternal Terminal
  services.eternal-terminal.enable = true;
  # et port
  networking.firewall.allowedTCPPorts = [ 2022 ];
  environment.variables = {
    ET_NO_TELEMETRY = "1";
  };

  # --------------------------------------------------------------------------------------
  # Base Packages
  # --------------------------------------------------------------------------------------

  programs.nix-ld.enable = true;

  programs.mosh.enable = true;

  environment.systemPackages = with pkgs; [
    (python3.withPackages (python-pkgs: with python-pkgs; [
      pandas
      requests
    ]))
    at-spi2-core
    backblaze-b2
    bashmount
    bfg-repo-cleaner
    bind
    btop
    ccze             # readable parsed system logs
    claude-code
    cpufrequtils
    distrobox
    dmidecode
    dos2unix
    exfat
    exiftool
    ffmpeg
    file
    fio
    fx                # Terminal-based JSON viewer and processor
    gcc
    git
    git-lfs
    gnumake
    gnupg
    htop
    hwinfo
    iftop
    inetutils
    iotop
    iperf3
    jq
    lemonade
    luarocks
    lshw
    lsof
    lxqt.lxqt-policykit # For GVFS
    iw
    iwd
    jhead
    memtest86plus
    minicom
    ncdu
    fastfetch
    nil
    nix-index
    nodejs
    openssl
    # openjdk16-bootstrap
    p7zip
    pciutils
    podman-tui
    powertop
    sops
    sqlite
    ssh-to-age
    sshpass
    steampipe
    tmux
    usbutils
    util-linux
    vulnix
    wireguard-tools
    wget
    xz
    zip
    zsh
  ];
}
