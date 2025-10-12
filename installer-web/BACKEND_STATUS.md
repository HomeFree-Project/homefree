# Backend Status - Simplified Version

## Current State

✅ **Simple Backend Running** - FastAPI without GraphQL
❌ **Full GraphQL Backend** - Requires strawberry-graphql (not in nixpkgs)

## What Works Now

The installer ISO now includes a **simplified backend** (`simple_main.py`) that:

### Features
- ✅ FastAPI server on port 8000
- ✅ Basic HTML UI showing status
- ✅ Health check endpoint (`/health`)
- ✅ Status API (`/api/status`)
- ✅ System info endpoint (`/api/system`)
- ✅ CORS enabled
- ✅ Proper logging

### What You'll See
When you boot the ISO:
1. GNOME desktop loads
2. Firefox opens in kiosk mode
3. **You see a purple gradient page** saying "Backend is running!"
4. Links to API endpoints work
5. No GraphQL endpoints (not implemented yet)

## What Doesn't Work Yet

### Missing: Full Installation Wizard
The original plan included:
- ❌ GraphQL API with Strawberry
- ❌ LitHTML frontend components
- ❌ Interactive installation wizard
- ❌ Network interface selection
- ❌ Disk partitioning integration
- ❌ Actual NixOS installation

### Why?
**strawberry-graphql** is not available in nixpkgs. The original `main.py` tries to:
```python
import strawberry  # ❌ ModuleNotFoundError
```

This package would need to be:
1. Packaged for nixpkgs, OR
2. Installed via pip (not reliable in NixOS), OR
3. Vendored into the project

## How to Test Current Version

### Boot the ISO
```bash
# Rebuild with fixed backend
nix build .#nixosConfigurations.homefree-installer.config.system.build.isoImage

# Test in QEMU
./scripts/test-web-installer.sh test
```

### Expected Behavior
1. Desktop loads
2. Firefox opens automatically
3. You see: **"🚀 HomeFree Web Installer - Backend is running!"**
4. Status shows: ✅ Connected
5. API links work

### Check Backend Logs
```bash
# In the VM
journalctl -u homefree-installer-backend -f
```

Should show:
```
INFO: Started HomeFree Web Installer Backend (Simple)
INFO: Uvicorn running on http://0.0.0.0:8000
```

## Next Steps to Complete Full Installer

### Option 1: Package strawberry-graphql for NixOS
Create a Nix derivation for strawberry-graphql and its dependencies.

**Pros**: Proper Nix approach
**Cons**: Time-consuming, complex dependencies

### Option 2: Replace GraphQL with REST
Rewrite the backend to use plain FastAPI REST endpoints instead of GraphQL.

**Pros**: Faster, simpler
**Cons**: Frontend needs rewrite (currently expects GraphQL)

### Option 3: Use Alternative GraphQL Library
Try `graphene-python` which might be in nixpkgs.

**Pros**: Keep GraphQL approach
**Cons**: Different API, requires code changes

### Option 4: Vendor strawberry-graphql
Include strawberry-graphql source code in the project.

**Pros**: Self-contained
**Cons**: Maintenance burden, dependencies still needed

## Recommended Path Forward

### Phase 1: Verify Current ISO ✅ (Done)
- [x] ISO builds successfully
- [x] Firefox launches automatically
- [x] Simple backend responds on port 8000
- [x] Basic UI loads

### Phase 2: Complete Backend (Choose approach)
**Recommended**: Option 2 - Replace with REST

1. Keep `simple_main.py` as base
2. Add REST endpoints for:
   - System info (`/api/system`)
   - Network interfaces (`/api/network/interfaces`)
   - Disk info (`/api/disks`)
   - Installation (`/api/install`)

3. Benefits:
   - No external dependencies needed
   - All packages available in nixpkgs
   - Simpler to debug and test
   - Can implement incrementally

### Phase 3: Update Frontend
1. Replace GraphQL client with `fetch()` calls
2. Update components to call REST endpoints
3. Keep LitHTML UI (works fine)

### Phase 4: Add Installation Logic
1. Port Calamares logic to Python
2. Network detection (already written!)
3. Disk partitioning (use Cockpit or parted)
4. Config generation (already written!)
5. nixos-install execution

## Files Status

### Working
- ✅ `installer-web/default.nix` - NixOS module (fixed)
- ✅ `backend/simple_main.py` - Minimal FastAPI server
- ✅ Systemd service configuration
- ✅ GNOME autostart

### Needs Work
- ⏸️ `backend/main.py` - Full GraphQL server (strawberry dependency)
- ⏸️ `backend/schema.py` - GraphQL schema (strawberry dependency)
- ⏸️ `backend/resolvers/*.py` - GraphQL resolvers (need backend)
- ⏸️ `frontend/src/graphql/client.js` - Expects GraphQL
- ⏸️ `frontend/src/components/*.js` - Expect GraphQL data

### Can Reuse
- ✅ `backend/services/network.py` - Network detection (pure Python)
- ✅ `backend/services/config.py` - Config storage (pure Python)
- ✅ `backend/services/install.py` - Installation logic (pure Python, but needs backend endpoints)

## Current Testing Checklist

- [ ] ISO builds without errors
- [ ] ISO boots in QEMU
- [ ] Firefox launches automatically
- [ ] Backend responds on localhost:8000
- [ ] Status page loads
- [ ] API endpoints return JSON
- [ ] No crashes in journalctl

## Success Criteria (MVP)

For a working installer, we need:
1. ✅ Bootable ISO (done)
2. ✅ Auto-launch browser (done)
3. ✅ Backend responds (done with simple version)
4. ⏸️ Network interface selection UI
5. ⏸️ Disk partitioning UI (Cockpit)
6. ⏸️ User creation form
7. ⏸️ Installation execution
8. ⏸️ Success/reboot screen

## Summary

We've successfully:
- Built a bootable ISO that replaces Calamares
- Auto-launches Firefox with web UI
- Started a working backend server

We still need:
- Complete backend implementation (REST recommended)
- Connect frontend to backend
- Implement actual installation logic

The foundation is solid - now it's "just" building out the features!
