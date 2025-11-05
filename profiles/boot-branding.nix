{ config, lib, pkgs, ... }:

let
  # Check if homefree module is loaded
  hasHomefree = config ? homefree;

  # Enable branding - always true (either homefree module is loaded, or standalone use)
  enableBranding = true;

  # Package the HomeFree Plymouth theme
  homefree-plymouth-theme = pkgs.stdenv.mkDerivation {
    name = "homefree-plymouth-theme";
    src = ../themes/plymouth/homefree;

    buildInputs = [ pkgs.plymouth ];

    installPhase = ''
      mkdir -p $out/share/plymouth/themes/homefree
      cp -r $src/* $out/share/plymouth/themes/homefree/

      # Substitute the theme path placeholder with actual output path
      sed -i "s|@PLYMOUTH_THEME_PATH@|$out/share/plymouth/themes/homefree|g" \
        $out/share/plymouth/themes/homefree/homefree.plymouth

      # Ensure proper permissions
      chmod 644 $out/share/plymouth/themes/homefree/*
    '';
  };

in {
  config = lib.mkIf enableBranding {
    # Override NixOS branding with HomeFree
    system.nixos = {
      distroName = "HomeFree";
      distroId = "homefree";
    };

    # Enable Plymouth boot splash
    boot.plymouth = {
      enable = true;
      theme = "homefree";
      themePackages = [ homefree-plymouth-theme ];

      # Use black background for smoother transitions
      extraConfig = ''
        DeviceScale=1
      '';
    };

    # Reduce boot message verbosity for cleaner splash
    boot.kernelParams = [
      "quiet"
      "splash"
      "udev.log_level=3"
    ];

    # Configure systemd-boot bootloader branding (for EFI systems)
    boot.loader.systemd-boot = lib.mkIf config.boot.loader.systemd-boot.enable {
      # Unfortunately, systemd-boot doesn't support custom themes easily
      # We can only customize through configuration options
      editor = false;  # Disable editor for security
      consoleMode = lib.mkDefault "max";  # Use maximum resolution
    };

    # Add timeout display customization
    boot.loader.timeout = lib.mkDefault 5;

    # GRUB configuration for BIOS systems (with HomeFree branding)
    boot.loader.grub = lib.mkIf config.boot.loader.grub.enable {
      # Use a dark background
      backgroundColor = "#000000";

      # Configure GRUB appearance
      splashImage = null;  # No splash image, clean look

      extraConfig = ''
        # HomeFree GRUB Theme - Dark/Monochrome
        set menu_color_normal=white/black
        set menu_color_highlight=black/white
        set color_normal=white/black
        set color_highlight=black/white

        # Custom menu styling
        set timeout_style=menu

        # Terminal output settings
        terminal_output gfxterm
        set gfxmode=auto
        set gfxpayload=keep
      '';

      # Customize the boot menu order and generation labels
      extraPerEntryConfig = ''
        # This ensures HomeFree branding appears in entries
      '';

      # The distroName set above will automatically be used in menu entries
    };
  };
}
