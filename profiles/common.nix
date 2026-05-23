{ pkgs, system, ...}:
let
  # Disable SCSI block-device runtime PM for a disk so the kernel does not
  # runtime-suspend it and issue a STOP UNIT (idle spindown). Invoked from a
  # udev RUN+= rule with the disk's sysfs path ($1, e.g. /sys/devices/.../sda).
  disableDiskRuntimePM = pkgs.writeShellScript "disable-disk-runtime-pm" ''
    dev="$1"
    [ -w "$dev/device/power/control" ] && echo on > "$dev/device/power/control"
    for f in "$dev"/device/scsi_disk/*/manage_runtime_start_stop; do
      [ -w "$f" ] && echo 0 > "$f"
    done
  '';
in
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
  # Note: powertop autotuning is intentionally disabled. On a server its
  # autotuning enables SATA link power management (ALPM) and disk APM, which
  # spins HDDs down while idle. The next smartd VERIFY poll then times out
  # ("qc timeout ... VERIFY failed"), forcing a SATA link reset roughly every
  # 10 minutes — that hang/reset cycle corrupts or drops long disk copies.
  # Idle disk spindown is the wrong default for an always-on server anyway.
  powerManagement = {
    enable = true;
    powertop.enable = false;
  };

  # Disable USB autosuspend for HID devices (keyboards, mice, etc.).
  # Why: powertop's autotuning enables USB autosuspend system-wide, which
  # causes the first few keystrokes after an idle period to be dropped while
  # the device negotiates resume. HID devices save no meaningful power from
  # suspending. Two layers, both class-level (no per-device hardware IDs):
  #   1. Kernel param sets the default control=on for all USB devices.
  #   2. udev rule pins HID devices to control=on, defending against any
  #      later runtime tool (powertop CLI, tlp, etc.) flipping the default.
  # The previous udev rule used `ATTR{bInterfaceClass}` (single S) — that
  # only matches when bInterfaceClass and power/control live on the same
  # sysfs node, but bInterfaceClass is on the interface child and
  # power/control is on the parent USB device, so the match never fired.
  # `ATTRS{...}` walks parents and matches correctly.
  boot.kernelParams = [ "usbcore.autosuspend=-1" ];

  # Keep storage drives spun up. An always-on server should never idle-spin
  # its disks: spindown causes VERIFY-poll timeouts, SATA link resets, and
  # needless head load-cycle wear. Three independent layers, because the
  # kernel has three separate disk power-down paths:
  #   1. SATA host link power management -> pin to max_performance (ALPM off).
  #   2. SCSI block-device runtime PM -> the kernel runtime-suspends an idle
  #      disk after power/autosuspend_delay_ms and, with manage_runtime_start_
  #      stop=1, issues a SCSI STOP UNIT that physically spins the drive down.
  #      This is the path that actually bit us: the ST28000NT000 was suspended
  #      ~96% of uptime, and each wake raced a VERIFY poll into a 10s timeout.
  #      Fix: pin power/control=on and clear manage_runtime_start_stop.
  #   3. Drive standby timer -> hdparm -S 0 disables it on rotational HDDs.
  # ATTR{queue/rotational}=="1" scopes the disk rules to spinning disks so
  # SSDs/NVMe are left untouched. APM (-B) is intentionally not set: not all
  # drives support it (the ST28000NT000 reports APM not supported).
  # The runtime-PM settings are applied via a RUN+= helper script rather than
  # ATTR{}: manage_runtime_start_stop lives under scsi_disk/<h:c:t:l>/, whose
  # node name is dynamic, and udev's ATTR{} does not expand path wildcards.
  # The script takes the disk's sysfs path (%S%p) as its argument.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTRS{bInterfaceClass}=="03", ATTR{power/control}="on"
    ACTION=="add|change", SUBSYSTEM=="scsi_host", KERNEL=="host*", TEST=="link_power_management_policy", ATTR{link_power_management_policy}="max_performance"
    ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd*", ENV{DEVTYPE}=="disk", ATTR{queue/rotational}=="1", RUN+="${disableDiskRuntimePM} %S%p"
    ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd*", ENV{DEVTYPE}=="disk", ATTR{queue/rotational}=="1", RUN+="${pkgs.hdparm}/bin/hdparm -S 0 /dev/%k"
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

  # Monthly btrfs scrub of the OS root. HomeFree's root is always btrfs
  # (disko_builder), so this regularly checksum-verifies the system, /home and
  # /nix subvolumes — detecting bitrot, and repairing it when root is a btrfs
  # mirror. Storage volumes append their own mountpoints to
  # services.btrfs.autoScrub.fileSystems in modules/storage-pools.nix; the
  # in-use Synology import (/mnt/storage) is deliberately left out (a monthly
  # multi-hour scrub of a 22TB array being copied off would be a lot of I/O).
  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/" ];
  };

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
    hdparm
    htop
    hwinfo
    iftop
    inetutils
    iotop
    iperf3
    jq
    jujutsu          # jj — Git-compatible VCS; preferred for parallel workspaces
    mdadm            # Linux md tooling; the Storage module needs it to CREATE a
                     # parity (raid5/raid6) volume before boot.swraid is on
                     # (storage-pools.nix enables swraid once one exists)
    gptfdisk         # sgdisk — zap partition tables when the Storage module
                     # reclaims (wipes) an in-use disk back to eligible
    lvm2             # vgchange/pvs — tear down LVM on a disk being reclaimed,
                     # even on a box with no pre-existing LVM
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
    smartmontools
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
