{ config, pkgs, lib, modulesPath, ... }:

# HomeFree Web Platform - Shared Configuration
# Used by both installer and admin interface

{
  # Copy installer/admin source files
  environment.etc."homefree-installer/frontend".source = ./frontend;
  environment.etc."homefree-installer/backend".source = ./backend;

  # Privilege escalation wrapper script for installer/admin operations
  environment.etc."homefree-installer/pkexec-wrapper.sh" = {
    text = ''
      #!/usr/bin/env bash
      # Wrapper script for privileged installer/admin operations
      # This script is called via pkexec from the backend

      set -e

      # pkexec resets the environment, so the backend service's PATH is
      # not inherited. Re-establish a PATH that includes the disk tools
      # (parted, btrfs-progs, disko, cryptsetup, tpm2-tools, ...) and the
      # NixOS install tools the privileged commands rely on.
      export PATH="${lib.makeBinPath [
        pkgs.util-linux
        pkgs.coreutils
        pkgs.parted
        pkgs.dosfstools
        pkgs.btrfs-progs
        pkgs.disko
        pkgs.cryptsetup
        pkgs.tpm2-tools
        pkgs.sbctl
        pkgs.nixos-install-tools
        pkgs.nix
        pkgs.git
        pkgs.gnused
        pkgs.gnugrep
      ]}:/run/current-system/sw/bin:$PATH"

      # Special handling for file writes to /mnt
      if [ "$1" = "write-file" ]; then
        # write-file <path> <content from stdin>
        TARGET_FILE="$2"
        cat > "$TARGET_FILE"
        exit 0
      fi

      # Special handling for mkdir on /mnt (install target) and /etc
      # (the live installer's config, e.g. /etc/nixos/secrets).
      if [ "$1" = "mkdir" ] && { [[ "$2" == /mnt/* ]] || [[ "$2" == /etc/* ]]; }; then
        mkdir -p "$2"
        exit 0
      fi

      # Execute the command passed as arguments
      exec "$@"
    '';
    mode = "0755";
  };

  # Systemd service for web platform backend
  systemd.services.homefree-installer-backend = let
    # Create Python environment with available packages
    pythonEnv = pkgs.python3.withPackages (ps: with ps; [
      fastapi
      uvicorn
      psutil
      pyudev
      pydantic
      pyyaml
      babel
      httpx
    ]);
  in {
    description = "HomeFree Web Platform Backend";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    # Add required system packages to PATH for subprocess calls
    path = with pkgs; [
      util-linux      # lsblk, wipefs, mkswap, swapon, mount, umount
      nixos-install-tools  # nixos-generate-config, nixos-install, nixos-enter
      git
      nix             # nixos-version
      parted          # disk partitioning
      dosfstools      # mkfs.vfat for EFI partition
      btrfs-progs     # mkfs.btrfs, btrfs commands
      polkit          # pkexec for privilege escalation
      mkpasswd        # password hashing for user creation
      disko           # declarative disk partitioning (LUKS, RAID, btrfs)
      cryptsetup      # LUKS formatting / systemd-cryptenroll
      tpm2-tools      # TPM2 probing and key sealing
      sbctl           # Secure Boot key management (lanzaboote opt-in)
      coreutils       # dd, cp for keyfile generation
    ];

    serviceConfig = {
      Type = "simple";
      User = "nixos";
      WorkingDirectory = "/etc/homefree-installer/backend";
      ExecStart = "${pythonEnv}/bin/python simple_main.py";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Enable polkit for pkexec
  security.polkit.enable = true;

  # Ensure pkexec has setuid bit (required for privilege escalation)
  security.wrappers.pkexec = {
    setuid = true;
    owner = "root";
    group = "root";
    source = "${pkgs.polkit}/bin/pkexec";
  };

  # Polkit policy to allow nixos user to run installer/admin commands via pkexec
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.policykit.exec" &&
          action.lookup("program") == "/etc/homefree-installer/pkexec-wrapper.sh" &&
          subject.user == "nixos") {
        return polkit.Result.YES;
      }
    });
  '';

  # Enable Cockpit for disk management
  services.cockpit = {
    enable = true;
    port = 9090;
    settings = {
      WebService = {
        AllowUnencrypted = true;
      };
    };
  };

  # Firewall rules for platform services
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 8000 9090 ];  # Backend and Cockpit
  };

  # Install base packages needed for web platform
  environment.systemPackages = with pkgs; [
    # Web server dependencies
    python3
    python3Packages.fastapi
    python3Packages.uvicorn
    python3Packages.psutil
    nodejs

    # Disk management
    cockpit
    gparted
    parted

    # Utilities
    git
    curl  # For backend health checks
  ];
}
