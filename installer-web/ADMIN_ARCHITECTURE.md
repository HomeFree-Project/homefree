# HomeFree Unified Admin/Installer Architecture

## Overview

The HomeFree web installer has been refactored into a **unified admin and installer system** that shares all infrastructure and components. The same codebase now serves both:

1. **Installer Mode**: Runs on the ISO installer to set up HomeFree on new hardware
2. **Admin Mode**: Runs on installed systems to configure all HomeFree settings

## Architecture

### Mode Detection

The system automatically detects which mode to run in based on whether `/etc/nixos/homefree-configuration.nix` exists:

- **Installer Mode**: File doesn't exist → Show installation wizard
- **Admin Mode**: File exists → Show administration interface

### Backend (Python/FastAPI)

#### New Services

```
backend/services/
├── mode.py              # Mode detection (installer vs admin)
├── config_reader.py     # Parse existing NixOS config
├── config_writer.py     # Update NixOS config files
├── nix_operations.py    # nixos-rebuild, dry-activate
└── validation.py        # Multi-layer validation
```

#### New API Endpoints

**Mode Detection:**
- `GET /api/mode` - Returns current mode (installer | admin)

**Admin Configuration:**
- `GET /api/config/current` - Read current NixOS configuration
- `POST /api/config/validate` - Validate config changes
- `GET /api/config/diff` - Show config diff
- `POST /api/config/preview` - Preview with dry-activate
- `POST /api/config/apply` - Apply changes with rebuild
- `GET /api/config/rebuild-status` - Monitor rebuild progress

### Frontend (LitHTML Web Components)

#### Mode Router (`app.js`)

The main app now detects mode and routes to the appropriate application:

```javascript
// Detects mode via API call
const mode = await getMode();

// Routes to installer or admin app
if (mode === 'installer') {
  return <installer-app>
} else {
  return <admin-app>
}
```

#### Admin App (`components/admin/admin-app.js`)

New administration interface with:

- **Sidebar Navigation**: Module-based navigation
- **Module System**: Each config section is a separate module
- **Save & Apply**: Validate → Preview → Apply workflow
- **Real-time Config Loading**: Reads current system config

#### Shared UI Components

Reusable components for both installer and admin:

```
components/shared/
├── form-field.js      # Text, number, boolean, select inputs
├── config-section.js  # Section container with collapse
└── table-editor.js    # Add/edit/delete for lists
```

#### Admin Modules

Each configuration section is a separate module:

```
components/admin/modules/
├── system-module.js    # ✅ IMPLEMENTED
├── network-module.js   # TODO: Phase 2
├── dns-module.js       # TODO: Phase 2
├── services-module.js  # TODO: Phase 2
└── backups-module.js   # TODO: Phase 2
```

**System Module** (Complete Example):
- Hostname, domain configuration
- Timezone, locale, keyboard
- Admin username
- SSH key management

### Service Configuration

#### Admin Service (`services/admin-web.nix`)

New NixOS service that:

1. **Backend Service**: Runs Python FastAPI on port 8000 (as root for NixOS operations)
2. **Frontend**: Served by Caddy as static files
3. **API Proxy**: Caddy proxies `/api/*` to backend
4. **Access**: Available at `admin.<domain>` (LAN-only by default)

#### Service Configuration

```nix
homefree.admin-page.public = false;  # LAN-only (default)
                                      # Set to true for WAN access
```

## How It Works

### Installation Flow (Unchanged)

1. Boot from ISO
2. Auto-launch installer UI in Firefox kiosk mode
3. 9-step wizard → Install to disk
4. Reboot into installed system

### Administration Flow (New)

1. Access `https://admin.<your-domain>`
2. Navigate to configuration module
3. Make changes in UI
4. Click "Save & Apply"
5. System validates → previews → applies

#### Save & Apply Workflow

```
1. User clicks "Save & Apply"
   ↓
2. Frontend validates config (types, required fields)
   ↓
3. Backend validates config (business logic, safety)
   ↓
4. Show network change warnings (if any)
   ↓
5. Write config to /etc/nixos/homefree-configuration.nix
   ↓
6. Run nixos-rebuild dry-activate
   ↓
7. Show preview of changes to user
   ↓
8. User confirms
   ↓
9. Run nixos-rebuild switch
   ↓
10. Monitor rebuild progress
```

## Configuration Coverage

### Currently Implemented (System Module)

✅ Hostname
✅ Primary domain
✅ Local domain
✅ Timezone
✅ Locale
✅ Keyboard layout
✅ Country code
✅ Admin username
✅ SSH authorized keys

### Phase 2 (Planned)

Network Module:
- WAN/LAN interface selection
- Router enable toggle
- LAN configuration (IP, subnet, DHCP)
- Static IP table
- Ad-blocking toggle

DNS Module:
- Local DNS overrides
- Dynamic DNS zones
- DNS-01 challenge configuration

Services Module:
- Service enable/disable toggles
- Per-service configuration
- Secret management

### Phase 3 (Planned)

- Complete all module.nix coverage
- Advanced services (Frigate cameras, Minecraft servers, MediaWiki sites)
- Backup configuration
- Proxied domains
- Real-time validation improvements

## File Structure

```
installer-web/
├── backend/
│   ├── services/
│   │   ├── mode.py                  # NEW: Mode detection
│   │   ├── config_reader.py         # NEW: Read NixOS config
│   │   ├── config_writer.py         # NEW: Write NixOS config
│   │   ├── nix_operations.py        # NEW: Rebuild operations
│   │   ├── validation.py            # NEW: Validation logic
│   │   ├── config.py                # Installer state
│   │   ├── network.py               # Network detection
│   │   └── install.py               # Installation logic
│   ├── resolvers/                   # API resolvers
│   ├── models.py                    # Data models
│   └── simple_main.py               # FastAPI app (updated)
├── frontend/
│   ├── src/
│   │   ├── app.js                   # REFACTORED: Mode router
│   │   ├── api/client.js            # UPDATED: New endpoints
│   │   ├── components/
│   │   │   ├── installer-app.js     # Existing installer
│   │   │   ├── admin/
│   │   │   │   ├── admin-app.js     # NEW: Admin UI
│   │   │   │   └── modules/
│   │   │   │       └── system-module.js  # NEW: System config
│   │   │   └── shared/              # NEW: Shared components
│   │   │       ├── form-field.js
│   │   │       ├── config-section.js
│   │   │       └── table-editor.js
│   │   └── ...
│   └── ...
└── ADMIN_ARCHITECTURE.md            # This file

services/
└── admin-web.nix                     # NEW: Admin service config
```

## Testing

### Test Installer Mode

1. Boot from ISO (or VM with installer)
2. Navigate to installer UI
3. Verify mode detection shows "installer"
4. Complete installation as normal

### Test Admin Mode

1. On installed HomeFree system
2. Navigate to `https://admin.homefree.lan` (or your domain)
3. Verify mode detection shows "admin"
4. Test System module:
   - Change hostname
   - Change timezone
   - Add SSH key
   - Click "Save & Apply"
   - Verify preview shows changes
   - Confirm and verify rebuild succeeds

### Backend Testing

```bash
# On installed system, check mode detection
curl http://localhost:8000/api/mode

# Read current config
curl http://localhost:8000/api/config/current

# Test validation
curl -X POST http://localhost:8000/api/config/validate \
  -H "Content-Type: application/json" \
  -d '{"system":{"hostName":"test"}}'
```

## Key Features

### 🔒 Security

- Multi-layer validation (frontend, backend, NixOS)
- Network change warnings (connectivity loss prevention)
- Dry-activate preview before applying
- Config backups before changes
- Admin UI LAN-only by default

### 🎨 User Experience

- Shared components ensure consistency
- Preview changes before applying
- Real-time validation
- Collapsible sections
- Responsive design

### 🏗️ Architecture Benefits

- **Single Codebase**: Both installer and admin use same code
- **Modular**: Easy to add new configuration modules
- **Maintainable**: Shared components reduce duplication
- **Extensible**: Clear patterns for new features
- **Type-Safe**: Validation at every layer

## Next Steps

### Phase 2: Core Modules

1. **Network Module**: Interface selection, DHCP, static IPs
2. **DNS Module**: Overrides, dynamic DNS
3. **Services Module**: Enable/disable services grid
4. **Backups Module**: Local & Backblaze configuration

### Phase 3: Advanced Features

1. **Complex Services**: Frigate, Minecraft, MediaWiki configuration
2. **Secret Management**: File upload + path specification
3. **Real-time Rebuild Monitoring**: Stream logs to UI
4. **Diff Viewer**: Side-by-side config comparison
5. **Rollback Support**: Revert to previous configurations

### Phase 4: Polish

1. **Accessibility**: Keyboard navigation, screen reader support
2. **Documentation**: Inline help text, tooltips
3. **Testing**: Unit tests, integration tests
4. **Performance**: Optimize config parsing, caching

## Contributing

When adding new admin modules:

1. Create module in `components/admin/modules/<name>-module.js`
2. Follow system-module.js pattern
3. Use shared components (form-field, config-section, table-editor)
4. Handle config-change events
5. Import in admin-app.js
6. Add to switch statement in renderModule()
7. Add navigation entry to modules array

## Notes

- **Installer Mode**: Completely unchanged, all existing functionality preserved
- **Admin Mode**: New functionality, doesn't affect installation
- **Shared Infrastructure**: Backend services, API client, UI components
- **Backwards Compatible**: Existing installs will see admin UI after rebuild
- **No Breaking Changes**: All existing HomeFree config continues to work

## Questions?

See:
- `/installer-web/backend/` for backend implementation
- `/installer-web/frontend/src/components/admin/` for admin UI
- `/installer-web/frontend/src/components/shared/` for shared components
- `/services/admin-web.nix` for service configuration
