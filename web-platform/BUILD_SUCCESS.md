# Build Success - Web Installer ISO

## ✅ ISO Built Successfully!

**Date**: November 1, 2025
**Configuration**: `homefree-installer` (web-based, no Calamares)
**ISO Name**: `nixos-gnome-25.05.20251027.daf6dc4-x86_64-linux.iso`
**Size**: ~2.7 GB

## Build Command

```bash
nix build .#nixosConfigurations.homefree-installer.config.system.build.isoImage
```

## Fixes Applied

### 1. Infinite Recursion Issue
**Problem**: Complex derivations in `let` block + `pkgs.path` reference caused circular dependency

**Solution**:
- Removed all complex build logic from module
- Used `modulesPath` instead of `pkgs.path`
- Simplified to direct source directory copying
- Runtime installation of Python dependencies

### 2. Calamares Option Error
**Problem**: Trying to disable `services.calamares` which doesn't exist in GNOME installer

**Solution**: Removed unnecessary disable statement (GNOME installer doesn't include Calamares by default)

### 3. Package Name Change
**Problem**: `gnome.gnome-terminal` moved to top-level

**Solution**: Changed to `gnome-terminal` directly

## Final Working Configuration

**Key characteristics**:
- ✅ No complex Nix derivations in module
- ✅ Source files copied to `/etc/homefree-installer/`
- ✅ Python dependencies installed at runtime via pip
- ✅ Frontend built at runtime (if needed)
- ✅ Systemd service for backend
- ✅ GNOME autostart for Firefox
- ✅ Cockpit enabled for disk management

## What's Included in ISO

**Packages**:
- Python 3 with FastAPI, Uvicorn, psutil
- Node.js (for frontend, if needed)
- Firefox (kiosk mode)
- Cockpit (disk management)
- GParted, parted (fallback tools)
- Git, GNOME Terminal

**Services**:
- `homefree-installer-backend` - GraphQL API server
- `cockpit` - Disk management UI
- GNOME autostart - Firefox launches automatically

**Files**:
- `/etc/homefree-installer/frontend/` - LitHTML web UI source
- `/etc/homefree-installer/backend/` - Python GraphQL API source

## Boot Behavior

1. System boots to GNOME desktop
2. Auto-login as `nixos` user
3. Backend service starts automatically
4. 8-second delay
5. Firefox launches in kiosk mode
6. Web installer loads at `http://localhost:8000`

**Fallback**: Desktop shortcut for manual launch

## Testing

To test the ISO:

```bash
# Using test script
./scripts/run-vm.sh run

# Or manually with QEMU
qemu-system-x86_64 \
  -m 4096 \
  -smp 2 \
  -enable-kvm \
  -cdrom ./result/iso/*.iso \
  -boot d
```

## Known Limitations

1. **Python dependencies** - Installed at runtime, not baked into ISO
   - First boot will run `pip install` which may take a moment
   - Requires internet connection OR dependencies should be pre-fetched

2. **Frontend not pre-built** - Source files copied as-is
   - If Vite build is needed, will happen at runtime
   - Alternatively, frontend could be served directly without build

3. **Cockpit Storage** - May need additional configuration
   - `cockpit-storaged` package might not be available
   - GParted provided as fallback

## Next Steps

### Immediate Testing
- [ ] Boot ISO in VM
- [ ] Verify backend starts
- [ ] Verify Firefox launches
- [ ] Check web UI loads
- [ ] Test installation flow

### Improvements Needed
- [ ] Pre-install Python dependencies in ISO (not runtime)
- [ ] Pre-build frontend assets
- [ ] Verify Cockpit Storage works
- [ ] Test actual NixOS installation
- [ ] Add error handling for missing deps

### Production Ready Checklist
- [ ] All Python deps included in Nix derivation
- [ ] Frontend built and bundled
- [ ] Installation process tested end-to-end
- [ ] Network interface detection verified
- [ ] Disk partitioning tested
- [ ] Config generation validated

## Comparison: Before vs After

| Aspect | Before (Failed Build) | After (Success) |
|--------|----------------------|-----------------|
| **Module complexity** | Complex derivations in `let` | Simple, minimal config |
| **Package builds** | Attempted in module | Runtime or separate |
| **Calamares** | Tried to disable | Not included |
| **Package names** | Old format | Updated |
| **Build result** | Infinite recursion | ✅ 2.7GB ISO |

## Success Metrics

✅ **ISO builds without errors**
✅ **No Calamares included**
✅ **Web installer files present**
✅ **Services configured**
✅ **Auto-launch configured**
✅ **Size reasonable** (2.7GB, similar to Calamares installer)

---

**The web installer now successfully builds and replaces Calamares as the default installer!**
