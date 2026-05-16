{ config, pkgs, lib, modulesPath, ... }:

# HomeFree Web Installer - Installer-Specific Configuration
# Only used when building the installer ISO

let
  # Create a minimal blank image to replace NixOS splash screens
  blankSplash = pkgs.runCommand "blank-splash" {} ''
    mkdir -p $out
    ${pkgs.imagemagick}/bin/convert -size 1x1 xc:black $out/splash.png
  '';

  # HomeFree minimal GRUB theme - clean text-based theme with no NixOS branding
  homefreeGrubTheme = pkgs.stdenv.mkDerivation {
    name = "homefree-grub-theme";
    src = ../themes/grub/homefree;

    nativeBuildInputs = [ pkgs.grub2_efi pkgs.imagemagick ];

    installPhase = ''
      mkdir -p $out

      # Copy theme configuration
      cp $src/theme.txt $out/

      # Copy unicode font from GRUB (always available)
      cp ${pkgs.grub2_efi}/share/grub/unicode.pf2 $out/

      # Generate DejaVu fonts using grub-mkfont
      for font in ${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans.ttf \
                  ${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans-Bold.ttf \
                  ${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSansMono.ttf \
                  ${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSansMono-Bold.ttf; do
        if [ -f "$font" ]; then
          fontname=$(basename "$font" .ttf)
          grub-mkfont -o "$out/$fontname.pf2" "$font" || true
        fi
      done

      # Create simple border images for menu
      # Menu borders (thin white lines on transparent)
      convert -size 1x1 xc:'#666666' $out/menu_n.png
      convert -size 1x1 xc:'#666666' $out/menu_s.png
      convert -size 1x1 xc:'#666666' $out/menu_e.png
      convert -size 1x1 xc:'#666666' $out/menu_w.png
      convert -size 1x1 xc:'#666666' $out/menu_ne.png
      convert -size 1x1 xc:'#666666' $out/menu_nw.png
      convert -size 1x1 xc:'#666666' $out/menu_se.png
      convert -size 1x1 xc:'#666666' $out/menu_sw.png
      convert -size 1x1 xc:'#111111' $out/menu_c.png

      # Selected item background (gray)
      convert -size 1x1 xc:'#444444' $out/select_c.png
      convert -size 1x1 xc:'#444444' $out/select_n.png
      convert -size 1x1 xc:'#444444' $out/select_s.png
      convert -size 1x1 xc:'#444444' $out/select_e.png
      convert -size 1x1 xc:'#444444' $out/select_w.png
      convert -size 1x1 xc:'#444444' $out/select_ne.png
      convert -size 1x1 xc:'#444444' $out/select_nw.png
      convert -size 1x1 xc:'#444444' $out/select_se.png
      convert -size 1x1 xc:'#444444' $out/select_sw.png
    '';
  };

in {
  # Base system configuration - Use GNOME installer WITHOUT Calamares
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-graphical-gnome.nix"
    ../profiles/boot-branding.nix
  ];

  # Install required packages for web installer
  environment.systemPackages = with pkgs; [
    # Browser for installer UI
    firefox

    # Utilities for installer
    gnome-terminal
    libnotify  # For notify-send
    zenity  # For progress dialogs
    xdotool  # For forcing window focus on startup

    # GNOME extensions
    gnomeExtensions.no-overview  # Prevent Activities Overview on startup

    # VM guest tools for proper display resolution
    spice-vdagent  # SPICE guest agent for QXL dynamic resolution
    qemu-utils     # QEMU guest utilities
    bindfs
  ];

  # Enable SPICE guest agent for dynamic resolution with QXL
  services.spice-vdagentd.enable = true;

  # Loading script for installer startup
  environment.etc."homefree-installer/loading.sh" = {
    text = ''
      #!/usr/bin/env bash

      # Create a named pipe for progress updates
      PROGRESS_PIPE=$(mktemp -u)
      mkfifo "$PROGRESS_PIPE"

      # Show progress dialog in background
      DISPLAY=:0 ${pkgs.zenity}/bin/zenity \
        --progress \
        --title="HomeFree Installer" \
        --text="Initializing installer..." \
        --percentage=0 \
        --auto-close \
        --no-cancel \
        --width=400 < "$PROGRESS_PIPE" &

      ZENITY_PID=$!

      # Function to update progress
      update_progress() {
        echo "$1"
        echo "# $2"
      } > "$PROGRESS_PIPE"

      # Initial progress
      update_progress "10" "Starting installer backend..."
      sleep 0.5

      # Wait for backend to be ready (up to 10 seconds)
      update_progress "30" "Waiting for backend to be ready..."
      for i in {1..10}; do
        if ${pkgs.curl}/bin/curl -s http://localhost:8000/health > /dev/null 2>&1; then
          break
        fi
        sleep 1
      done

      # Backend is ready
      update_progress "60" "Backend ready, launching browser..."
      sleep 0.5

      # Launch Firefox in kiosk mode
      DISPLAY=:0 ${pkgs.firefox}/bin/firefox --kiosk --private-window http://localhost:8000 &
      FIREFOX_PID=$!

      # Wait for Firefox window to appear
      update_progress "80" "Waiting for browser window..."
      sleep 1

      DISPLAY=:0 ${pkgs.xdotool}/bin/xdotool search --sync --onlyvisible --class firefox windowactivate 2>/dev/null || true

      # Firefox is visible, close progress dialog
      update_progress "100" "Installer ready!"

      # Close the named pipe and kill zenity
      exec 3>&- 2>/dev/null || true
      rm -f "$PROGRESS_PIPE"
      kill $ZENITY_PID 2>/dev/null || true

      # Keep script running so systemd tracks Firefox
      wait $FIREFOX_PID
    '';
    mode = "0755";
  };

  # Auto-launch web installer in browser using GNOME autostart
  environment.etc."xdg/autostart/homefree-installer.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=HomeFree Installer
    Comment=HomeFree Web-Based Installation Wizard
    Exec=${pkgs.bash}/bin/bash /etc/homefree-installer/loading.sh
    Icon=system-software-install
    Terminal=false
    Categories=System;
    X-GNOME-Autostart-enabled=true
    X-GNOME-Autostart-Delay=0
  '';

  # Disable DPMS and screen blanking at X server level
  environment.etc."xdg/autostart/disable-dpms.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Disable DPMS
    Comment=Disable display power management for installer
    Exec=${pkgs.xorg.xset}/bin/xset s off -dpms
    Terminal=false
    Categories=System;
    X-GNOME-Autostart-enabled=true
    X-GNOME-Autostart-Delay=1
  '';

  # Create desktop shortcut for manual launch
  system.activationScripts.installerDesktop = ''
    mkdir -p /home/nixos/Desktop
    cat > /home/nixos/Desktop/homefree-installer.desktop << 'EOF'
    [Desktop Entry]
    Type=Application
    Name=HomeFree Installer
    Comment=Launch HomeFree Installation Wizard
    Exec=${pkgs.firefox}/bin/firefox --kiosk --private-window http://localhost:8000
    Icon=system-software-install
    Terminal=false
    Categories=System;
    EOF
    chmod +x /home/nixos/Desktop/homefree-installer.desktop || true
    chown nixos:users /home/nixos/Desktop/homefree-installer.desktop || true
  '';

  # Auto-mount shared folder for development mode (virtiofs)
  # Mount virtiofs filesystem to temporary location, then use bindfs to remap ownership
  systemd.mounts = [
    {
      where = "/mnt/homefree-virtiofs";
      what = "mount_homefree_source";
      type = "virtiofs";
      options = "rw";
      wantedBy = [ "multi-user.target" ];
    }
    {
      where = "/home/nixos/homefree";
      what = "/mnt/homefree-virtiofs";
      type = "fuse.bindfs";
      options = "force-user=nixos,force-group=users,chown-ignore,chgrp-ignore";
      wantedBy = [ "multi-user.target" ];
      after = [ "mnt-homefree\\x2dvirtiofs.mount" ];
      requires = [ "mnt-homefree\\x2dvirtiofs.mount" ];
    }
  ];

  # Create mount point directories at boot
  system.activationScripts.createHomefreeMount = ''
    mkdir -p /mnt/homefree-virtiofs
    mkdir -p /home/nixos/homefree
    chown nixos:users /home/nixos/homefree 2>/dev/null || true
  '';

  # Create symlink after mount succeeds
  systemd.services.homefree-symlink = {
    description = "Create /homefree symlink for development mode";
    after = [ "home-nixos-homefree.mount" ];
    requires = [ "home-nixos-homefree.mount" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.bash}/bin/bash -c 'rm -rf /homefree 2>/dev/null || true; ln -sf /home/nixos/homefree /homefree'";
    };
  };

  # ISO customization
  isoImage = {
    isoName = lib.mkForce "homefree-web-installer.iso";
    volumeID = lib.mkForce "HOMEFREE_WEB";
    appendToMenuLabel = " HomeFree Installer";

    # Use custom HomeFree GRUB theme (clean text-based, no NixOS branding)
    grubTheme = homefreeGrubTheme;

    # Use blank splash images instead of NixOS branding
    efiSplashImage = "${blankSplash}/splash.png";
    splashImage = "${blankSplash}/splash.png";
  };

  # Configure boot loader to show menu with proper timeout
  # Use longer timeout and force menu display for QEMU compatibility
  boot.loader.timeout = lib.mkForce 10;
  boot.loader.grub.configurationLimit = 0;  # Don't hide menu

  # Add GRUB configuration to improve QEMU reliability
  boot.loader.grub.extraConfig = ''
    # Ensure graphics mode is initialized before menu
    insmod all_video
    insmod gfxterm
    set gfxmode=auto
    set gfxpayload=keep
  '';

  # HomeFree branding for boot screen
  system.nixos = {
    distroName = "HomeFree";
    distroId = "homefree";
  };

  # Plymouth boot splash configuration
  boot.plymouth = {
    enable = true;
    theme = lib.mkDefault "spinner";  # Use built-in spinner theme for installer
  };

  # Clean boot experience
  boot.kernelParams = [
    "quiet"
    "splash"
    "vt.global_cursor_default=1"  # Enable blinking cursor in text console (0=no blink, 1=blink)
  ];

  # Auto-login for live ISO
  services.displayManager.autoLogin = {
    enable = true;
    user = "nixos";
  };

  # Enable necessary kernel modules for virtualization testing
  boot.kernelModules = [ "kvm-intel" "kvm-amd" ];

  # Ensure GNOME is properly configured
  services.xserver = {
    enable = true;
    desktopManager.gnome.enable = true;
    # Use software rendering fallback for VMs
    videoDrivers = lib.mkDefault [ "modesetting" ];
  };

  # Disable GNOME welcome tour and initial setup
  services.gnome.gnome-initial-setup.enable = lib.mkForce false;

  # Exclude GNOME Tour from packages
  environment.gnome.excludePackages = with pkgs; [
    gnome-tour
  ];

  # GNOME settings for installer - disable screen lock and power management
  programs.dconf.enable = true;
  programs.dconf.profiles.user.databases = [{
    settings = {
      # Disable screen lock
      "org/gnome/desktop/screensaver" = {
        lock-enabled = false;
        lock-delay = lib.gvariant.mkUint32 0;
        idle-activation-enabled = false;
      };

      # Disable automatic screen blank/suspend
      "org/gnome/desktop/session" = {
        idle-delay = lib.gvariant.mkUint32 0;  # Never idle
      };

      # Disable power management - never suspend or turn off screen
      "org/gnome/settings-daemon/plugins/power" = {
        sleep-inactive-ac-timeout = lib.gvariant.mkInt32 0;  # Never sleep when plugged in
        sleep-inactive-ac-type = "nothing";
        sleep-inactive-battery-timeout = lib.gvariant.mkInt32 0;  # Never sleep on battery
        sleep-inactive-battery-type = "nothing";
        idle-dim = false;  # Don't dim screen when idle
        ambient-enabled = false;  # Disable DPMS
      };

      # Start directly to desktop instead of Activities Overview
      # Activities Overview still accessible via Super key for debugging
      "org/gnome/shell" = {
        startup-state = "desktop";
        enabled-extensions = [ "no-overview@fthx" ];
        disable-user-extensions = false;
      };
    };
  }];

  # Reduce GNOME Shell effects in VMs
  environment.variables = {
    # Disable animations and effects that can cause GPU issues in VMs
    CLUTTER_PAINT = "disable-dynamic-max-render-time";
    MUTTER_DEBUG_ENABLE_ATOMIC_KMS = "0";
  };

  # Enable SSH for development/debugging
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "yes";  # Allow root login for installer debugging
      PasswordAuthentication = true;
    };
  };

  # Set password for nixos user for SSH access
  users.users.nixos.password = "nixos";
  users.users.root.password = "root";
}
