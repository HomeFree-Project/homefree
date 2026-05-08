# Configuration Fix - Making Web Installer the Default

## Problem Identified

When running `./scripts/build-image.sh`, the build used a cached image and **Calamares still launched** because:

1. **Build script defaults to `homefree-installer`** (line 191 of `build-image.sh`)
2. **`homefree-installer` pointed to Calamares** (in `flake.nix`)
3. **`homefree-web-installer` existed but was never used**
4. **Result**: Cached Calamares build, web installer never built

## Solution Applied

### Renamed Configurations in flake.nix

**Before:**
```nix
nixosConfigurations = {
  homefree-installer = ...Calamares installer...
  homefree-web-installer = ...Web installer...
}
```

**After:**
```nix
nixosConfigurations = {
  # Default installer - Web-based (replaces Calamares)
  homefree-installer = ...Web installer...

  # Legacy Calamares installer (backup)
  homefree-installer-calamares = ...Calamares installer...
}
```

### Key Changes

1. **`homefree-installer`** → Now uses `./installer-web` (web installer)
2. **`homefree-installer-calamares`** → Now uses `./installer` (Calamares, backup)
3. **`homefree-web-installer`** → Removed (redundant)

### Build Behavior Now

**Default build (no arguments):**
```bash
./scripts/build-image.sh
# Builds: homefree-installer (WEB INSTALLER)
```

**Explicit web installer:**
```bash
nix build .#nixosConfigurations.homefree-installer.config.system.build.isoImage
# Builds: WEB INSTALLER
```

**Legacy Calamares (backup):**
```bash
nix build .#nixosConfigurations.homefree-installer-calamares.config.system.build.isoImage
# Builds: CALAMARES INSTALLER
```

## Files Modified

1. **`flake.nix`** (lines 97-123)
   - Swapped configuration contents
   - Added descriptive comments
   - Renamed old installer to `-calamares` suffix

2. **`installer-web/README.md`**
   - Updated build instructions
   - Clarified default vs legacy commands

3. **`installer-web/CALAMARES_REPLACEMENT.md`**
   - Added configuration integration section
   - Updated build command documentation

4. **`scripts/run-vm.sh`** (formerly `scripts/test-web-installer.sh`)
   - Changed from `homefree-web-installer` to `homefree-installer`
   - Updated result symlink name (`result-installer`)
   - Added usage note about configuration change
   - Later consolidated into `run-vm.sh run --user-mode` (see scripts/MIGRATION.md)

## Verification

Check available configurations:
```bash
nix flake show
```

Output should include:
- `nixosConfigurations.homefree-installer` (web installer)
- `nixosConfigurations.homefree-installer-calamares` (Calamares)

## Impact

### ✅ What Works Now

- `./scripts/build-image.sh` → Builds web installer (no cache)
- Default ISO boots to web installer in Firefox
- Calamares is completely disabled by default
- No manual configuration changes needed

### 🔄 Migration Path

Users with existing scripts:
- **No changes needed** if using `./scripts/build-image.sh`
- **Update if using** `homefree-web-installer` → change to `homefree-installer`
- **Calamares still available** as `homefree-installer-calamares`

### 📝 Documentation Updates

All documentation now correctly references:
- `homefree-installer` = web installer (default)
- `homefree-installer-calamares` = Calamares (legacy)

## Testing

To verify the fix:

```bash
# Clean old builds
./scripts/run-vm.sh clean

# Build new web installer
./scripts/build-image.sh

# Check it's NOT using cache
# Should show fresh build, not "cached"

# Verify ISO contents
ls -lh build/
# Should see homefree-installer.iso (NEW timestamp)

# Test in QEMU
./scripts/run-vm.sh run
# Should boot to GNOME → Firefox → Web Installer
# NO Calamares should appear
```

## Rollback (if needed)

To temporarily use Calamares:

```bash
# Build Calamares installer
nix build .#nixosConfigurations.homefree-installer-calamares.config.system.build.isoImage

# Or use build script with explicit config
./scripts/build-image.sh homefree-installer-calamares
```

## Summary

| Aspect | Before | After |
|--------|--------|-------|
| **Default config** | `homefree-installer` (Calamares) | `homefree-installer` (Web) |
| **Build script** | Builds Calamares | Builds Web installer |
| **Cache behavior** | Used cached Calamares | Forces new web build |
| **Calamares access** | Default | Available as `-calamares` |
| **Config name** | `homefree-web-installer` | `homefree-installer` |

✅ **Web installer is now truly the default!**
