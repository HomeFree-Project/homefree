# Calamares Replacement - Implementation Details

## Problem Statement

The initial implementation created a web installer but **didn't actually replace Calamares**. Both would have been present, with Calamares still auto-launching on boot.

## Root Cause

The `installer-web/default.nix` file was importing the Calamares installer module, which would cause Calamares to launch instead of the web UI.

## Solution Implemented

### 1. Changed Base Module Import

**Before:**
```nix
imports = [
  "${pkgs.path}/nixos/modules/installer/cd-dvd/installation-cd-graphical-calamares-gnome.nix"
];
```

**After:**
```nix
imports = [
  "${pkgs.path}/nixos/modules/installer/cd-dvd/installation-cd-graphical-gnome.nix"
];
```

This uses the base GNOME installer **without** Calamares.

### 2. Explicitly Disabled Calamares

Added explicit disable directive:

```nix
# Explicitly disable Calamares if it somehow gets enabled
services.calamares.enable = lib.mkForce false;
```

The `lib.mkForce` ensures this overrides any other module trying to enable it.

### 3. Replaced Systemd Service with GNOME Autostart

**Why the change:**
- Systemd services are not ideal for launching GUI applications
- GNOME has a built-in autostart mechanism that's more reliable
- Better integration with the desktop environment

**Old approach (systemd service):**
```nix
systemd.services.homefree-installer-browser = {
  # ... complex service definition
};
```

**New approach (GNOME autostart):**
```nix
environment.etc."xdg/autostart/homefree-installer.desktop".text = ''
  [Desktop Entry]
  Type=Application
  Name=HomeFree Installer
  Exec=${pkgs.bash}/bin/bash -c "sleep 5 && ${pkgs.firefox}/bin/firefox --kiosk --private-window http://localhost:8000"
  X-GNOME-Autostart-enabled=true
  X-GNOME-Autostart-Delay=5
'';
```

### 4. Added Desktop Shortcut

Created a desktop icon for manual relaunch:

```nix
environment.etc."skel/Desktop/homefree-installer.desktop".text = ''
  [Desktop Entry]
  Type=Application
  Name=HomeFree Installer
  Exec=${pkgs.firefox}/bin/firefox --kiosk --private-window http://localhost:8000
  Icon=system-software-install
'';
```

### 5. Ensured Proper Package Exclusion

Explicitly listed packages, with comments noting Calamares is excluded:

```nix
environment.systemPackages = with pkgs; [
  cockpit
  gparted           # Fallback partition tool
  firefox           # Browser for web UI
  gnome.gnome-terminal  # For debugging
  # NOTE: Calamares is NOT included
];
```

## Boot Sequence Now

1. **System boots** → GRUB → NixOS kernel
2. **GNOME starts** → GDM auto-login as `nixos` user
3. **Desktop loads** → GNOME desktop appears
4. **Backend starts** → `homefree-installer-backend.service` systemd service
5. **5-second delay** → Wait for backend to be ready
6. **Firefox launches** → Kiosk mode, fullscreen
7. **Installer loads** → `http://localhost:8000`

**No Calamares at any point!**

## Testing Verification

To verify Calamares is truly disabled:

```bash
# After booting the ISO:
systemctl status calamares  # Should show "not found" or "inactive"
ps aux | grep calamares      # Should show nothing
which calamares              # Should show "not found"
```

To verify web installer launches:

```bash
# After booting the ISO:
systemctl status homefree-installer-backend  # Should show "active (running)"
ps aux | grep firefox                         # Should show Firefox with kiosk flag
curl http://localhost:8000                    # Should return HTML
```

## User Experience

### What Users See

1. **Boot screen** → HomeFree splash
2. **GNOME login** → Auto-logs in (no password needed)
3. **Desktop appears** → Clean GNOME desktop
4. **Brief pause** → 5 seconds for backend startup
5. **Firefox fullscreen** → Web installer loads automatically
6. **Installation wizard** → Guided step-by-step process

### What Users Don't See

- ❌ Calamares window
- ❌ Manual application launching
- ❌ Configuration prompts
- ❌ Terminal windows (unless debugging)

## Fallback Options

If the auto-launch fails, users can:

1. **Click desktop icon** → "HomeFree Installer" on desktop
2. **Manual Firefox** → Open Firefox and go to `http://localhost:8000`
3. **Check backend** → `systemctl status homefree-installer-backend`
4. **View logs** → `journalctl -u homefree-installer-backend -f`

## Configuration Files Changed

1. **`installer-web/default.nix`** (primary file)
   - Changed base import
   - Disabled Calamares
   - Replaced systemd service with autostart
   - Added desktop shortcut
   - Updated package list

2. **`installer-web/README.md`**
   - Added boot behavior section
   - Clarified Calamares replacement
   - Updated overview

3. **`installer-web/CALAMARES_REPLACEMENT.md`** (this file)
   - Documented the fix

## Key Differences: Old vs New

| Aspect | Old (Broken) | New (Fixed) |
|--------|-------------|-------------|
| **Base module** | calamares-gnome | graphical-gnome |
| **Calamares state** | Would launch | Explicitly disabled |
| **Browser launch** | systemd service | GNOME autostart |
| **Desktop icon** | None | Added |
| **User experience** | Both installers | Only web installer |

## Security Considerations

- **Kiosk mode** prevents users from accidentally closing installer
- **Private window** doesn't save history/cookies
- **Local only** (localhost:8000) - no network exposure
- **Auto-login** is safe (live ISO, ephemeral)

## Future Enhancements

1. **Custom splash screen** showing "Loading installer..."
2. **Better error handling** if backend fails to start
3. **Network connectivity check** before launching
4. **Option to exit kiosk mode** for advanced users
5. **Multi-monitor support** detection

## Configuration Integration

The web installer is now the **default** `homefree-installer` configuration:

**flake.nix structure:**
```nix
nixosConfigurations = {
  # Default installer - Web-based (replaces Calamares)
  homefree-installer = ...uses ./installer-web...

  # Legacy Calamares installer (backup)
  homefree-installer-calamares = ...uses ./installer...
}
```

**Build commands:**
- `./scripts/build-image.sh` → Web installer (default)
- `nix build .#nixosConfigurations.homefree-installer.config.system.build.isoImage` → Web installer
- `nix build .#nixosConfigurations.homefree-installer-calamares.config.system.build.isoImage` → Calamares (backup)

## Conclusion

The web installer now **fully replaces Calamares** as the default installer. When users boot the ISO, they get a modern, browser-based installation experience with no trace of the old Qt-based Calamares installer.

✅ **Calamares is gone** (from default build)
✅ **Web installer auto-launches**
✅ **Clean user experience**
✅ **Fallback options available**
✅ **Build scripts work unchanged** (default to web installer)
✅ **Calamares still accessible** (as homefree-installer-calamares)
