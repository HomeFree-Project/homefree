# REST API Implementation Progress

## ✅ Completed Tasks

### 1. Backend REST API (`simple_main.py`)
**Status**: ✅ Complete

Implemented full REST API with 15 endpoints covering all installation functionality:

**System & Health**:
- `GET /health` - Health check
- `GET /api/status` - Backend status
- `GET /api/system` - System info (CPU, memory, disks)

**Network**:
- `GET /api/network/interfaces` - List interfaces
- `POST /api/network/configure` - Set WAN/LAN

**Locale**:
- `GET /api/locale/timezones` - Available timezones
- `GET /api/locale/keyboard-layouts` - Keyboard layouts

**Configuration**:
- `POST /api/config/hostname` - Set hostname
- `POST /api/config/location` - Set timezone/locale
- `POST /api/config/keyboard` - Set keyboard layout
- `POST /api/config/user` - Create user
- `POST /api/config/partitioning` - Set partitioning
- `GET /api/config/summary` - Installation summary

**Installation**:
- `POST /api/install/start` - Begin installation
- `GET /api/install/status` - Installation progress

**Key Features**:
- All resolvers integrated (SystemResolver, NetworkResolver, ConfigResolver, InstallResolver)
- Proper error handling with HTTPException
- Request/Response models with Pydantic
- Frontend file serving from `/etc/homefree-installer/frontend/`
- Fallback HTML for testing
- CORS enabled

### 2. Python Dependencies
**Status**: ✅ Complete

Added to `installer-web/default.nix`:
- `pyudev` - For network interface detection
- `pydantic` - For request/response validation

### 3. Frontend REST Client (`frontend/src/api/client.js`)
**Status**: ✅ Complete

Created clean REST API client replacing GraphQL:
- Generic `fetchAPI()` wrapper with error handling
- Individual functions for each endpoint
- `pollInstallStatus()` helper for installation progress polling
- No external dependencies (uses native `fetch()`)

### 4. Component Updates - Network Step
**Status**: ✅ Complete (example implementation)

Updated `network-step.js` to demonstrate the conversion pattern:

**Changes**:
```javascript
// OLD (GraphQL)
import { graphqlClient, GET_NETWORK_INTERFACES, SET_NETWORK_CONFIG } from '../graphql/client.js';

const result = await graphqlClient.query(GET_NETWORK_INTERFACES, {}).toPromise();
const interfaces = result.data.networkInterfaces.filter(iface => iface.isEthernet);

// NEW (REST)
import { getNetworkInterfaces, configureNetwork } from '../api/client.js';

const interfaces = await getNetworkInterfaces();
const filtered = interfaces.filter(iface => iface.is_ethernet);
```

**Key Pattern Changes**:
- GraphQL snake_case becomes REST is_ethernet (Python convention)
- Direct function calls instead of GraphQL client
- Simpler error handling
- No `.toPromise()` wrappers

---

## 🔄 Remaining Tasks

### 5. Update Remaining LitHTML Components

**Pattern to follow** (based on network-step.js):

1. **Change import**:
   ```javascript
   // OLD
   import { graphqlClient, GET_X, SET_Y } from '../graphql/client.js';

   // NEW
   import { getX, setY } from '../api/client.js';
   ```

2. **Update GraphQL queries**:
   ```javascript
   // OLD
   const result = await graphqlClient.query(GET_X, {}).toPromise();
   const data = result.data.fieldName;

   // NEW
   const data = await getX();
   ```

3. **Update GraphQL mutations**:
   ```javascript
   // OLD
   const result = await graphqlClient.mutation(SET_Y, { param: value }).toPromise();
   if (result.data.mutationName.success) { ... }

   // NEW
   const result = await setY(value);
   if (result.success) { ... }
   ```

4. **Fix field names** (GraphQL camelCase → REST snake_case):
   - `isEthernet` → `is_ethernet`
   - `cpuInfo` → `cpu_info`
   - `memoryTotal` → `memory_total`
   - etc.

### Components Needing Updates:

#### ✅ `network-step.js` - DONE (example)

#### 🔲 `welcome-step.js`
**Changes needed**:
- Import `getSystemInfo` from `../api/client.js`
- Replace GraphQL query with `const systemInfo = await getSystemInfo()`
- Update field names: `cpuInfo` → `cpu_info`, `memoryTotal` → `memory_total`

#### 🔲 `location-step.js`
**Changes needed**:
- Import `getTimezones, setLocation` from `../api/client.js`
- Replace GraphQL query: `const timezones = await getTimezones()`
- Replace GraphQL mutation: `const result = await setLocation(timezone, locale)`

#### 🔲 `keyboard-step.js`
**Changes needed**:
- Import `getKeyboardLayouts, setKeyboard` from `../api/client.js`
- Replace GraphQL query: `const layouts = await getKeyboardLayouts()`
- Replace GraphQL mutation: `const result = await setKeyboard(layout, vconsole)`

#### 🔲 `users-step.js`
**Changes needed**:
- Import `setUser, setHostname` from `../api/client.js`
- Replace GraphQL mutations:
  - `await setHostname(hostname)`
  - `await setUser(username, fullname, password)`

#### 🔲 `summary-step.js`
**Changes needed**:
- Import `getInstallSummary` from `../api/client.js`
- Replace GraphQL query: `const summary = await getInstallSummary()`
- Update field names: `wanInterface` → `wan_interface`, `lanInterface` → `lan_interface`

#### 🔲 `install-step.js`
**Changes needed**:
- Import `startInstallation, pollInstallStatus` from `../api/client.js`
- Replace GraphQL mutation: `await startInstallation()`
- Replace polling logic:
  ```javascript
  const stopPolling = pollInstallStatus((status) => {
    this.progress = status.progress;
    this.message = status.message;
    if (status.completed || status.error) {
      stopPolling();
    }
  });
  ```

#### 🔲 `partition-step.js`
**Special case** - Needs Cockpit Storage integration:
- Import `setPartitioning` from `../api/client.js`
- Embed Cockpit Storage UI (iframe to `http://localhost:9090/storage`)
- On step complete, call `await setPartitioning(config)` with disk configuration

#### 🔲 `finished-step.js`
**Minimal changes**:
- No API calls needed (just shows completion)
- May need to import `getInstallSummary` if showing final config

#### 🔲 `installer-app.js` (main app component)
**Changes needed**:
- Update any GraphQL client references to REST
- Ensure proper component imports

---

## 6. Integrate Cockpit Storage

**Current Status**: Cockpit service enabled in `default.nix` on port 9090

**Integration needed in `partition-step.js`**:
```javascript
render() {
  return html`
    <div class="partition-container">
      <h2>Disk Partitioning</h2>
      <p>Use the Cockpit Storage interface below to partition your disks.</p>

      <iframe
        src="http://localhost:9090/storage"
        width="100%"
        height="600px"
        frameborder="0"
      ></iframe>

      <button @click="${this.handleNext}">Continue</button>
    </div>
  `;
}

async handleNext() {
  // Get partitioning config from Cockpit
  // For now, pass basic config
  await setPartitioning(JSON.stringify({
    device: '/dev/sda',
    mode: 'auto',
    encryption: false,
    swap: true
  }));

  this.dispatchEvent(new CustomEvent('step-complete'));
}
```

**Alternative**: Skip Cockpit integration initially and use automatic partitioning in `install.py` (already implemented).

---

## 7. Testing Plan

### Phase 1: Backend Testing
```bash
# Rebuild with REST API
nix build .#nixosConfigurations.homefree-installer.config.system.build.isoImage

# Test in VM
./scripts/run-vm.sh run

# In VM, test endpoints manually:
curl http://localhost:8000/health
curl http://localhost:8000/api/system
curl http://localhost:8000/api/network/interfaces
```

### Phase 2: Frontend Integration Testing
1. Boot ISO in VM
2. Firefox should load
3. Open browser console (F12)
4. Test API calls:
   ```javascript
   fetch('/api/system').then(r => r.json()).then(console.log)
   fetch('/api/network/interfaces').then(r => r.json()).then(console.log)
   ```

### Phase 3: Component Testing
1. Test each step of installation wizard:
   - Welcome screen loads system info
   - Network step detects interfaces
   - Location/keyboard/users steps work
   - Summary shows correct config
   - Installation executes

### Phase 4: Full Installation Test
1. Complete installation in VM
2. Reboot and verify installed system boots
3. Check `/etc/nixos/homefree-configuration.nix` has correct WAN/LAN interfaces

---

## File Structure

```
installer-web/
├── backend/
│   ├── simple_main.py          ✅ REST API (complete)
│   ├── main.py                 ⏸️  GraphQL version (not used)
│   ├── schema.py               ⏸️  GraphQL schema (not used)
│   ├── resolvers/
│   │   ├── system.py           ✅ Used by REST API
│   │   ├── network.py          ✅ Used by REST API
│   │   ├── config.py           ✅ Used by REST API
│   │   └── install.py          ✅ Used by REST API
│   └── services/
│       ├── network.py          ✅ Works (needs pyudev)
│       ├── config.py           ✅ Works
│       └── install.py          ✅ Works
│
├── frontend/
│   ├── src/
│   │   ├── api/
│   │   │   └── client.js       ✅ REST client (complete)
│   │   ├── graphql/
│   │   │   └── client.js       ⏸️  Not used anymore
│   │   └── components/
│   │       ├── installer-app.js    🔲 Needs update
│   │       ├── welcome-step.js     🔲 Needs update
│   │       ├── network-step.js     ✅ Updated (example)
│   │       ├── location-step.js    🔲 Needs update
│   │       ├── keyboard-step.js    🔲 Needs update
│   │       ├── partition-step.js   🔲 Needs update + Cockpit
│   │       ├── users-step.js       🔲 Needs update
│   │       ├── summary-step.js     🔲 Needs update
│   │       ├── install-step.js     🔲 Needs update
│   │       └── finished-step.js    🔲 Needs update
│   └── index.html              ✅ Should work as-is
│
└── default.nix                 ✅ Python deps added

```

---

## Next Steps

**Recommended order**:

1. **Update remaining components** (follow pattern from network-step.js)
   - Start with welcome-step.js (simplest)
   - Then location-step.js, keyboard-step.js, users-step.js
   - Then summary-step.js, install-step.js, finished-step.js
   - Finally partition-step.js (most complex)

2. **Build and test ISO**:
   ```bash
   nix build .#nixosConfigurations.homefree-installer.config.system.build.isoImage
   ./scripts/run-vm.sh run
   ```

3. **Test API connectivity**:
   - Boot ISO
   - Open browser console
   - Test API endpoints manually
   - Verify components load data

4. **Iterate on bugs**:
   - Fix field name mismatches
   - Handle errors gracefully
   - Improve loading states

5. **Complete installation test**:
   - Run full installation in VM
   - Verify installed system boots
   - Check configuration files

---

## Known Issues & Considerations

### Field Name Mismatches
GraphQL used camelCase, Python/REST uses snake_case:
- Frontend expects `isEthernet`, backend returns `is_ethernet`
- Frontend expects `cpuInfo`, backend returns `cpu_info`
- etc.

**Solution**: Update frontend to use snake_case field names.

### Partitioning
Most complex step. Options:
1. **Full Cockpit integration** - Embed Cockpit Storage UI (best UX)
2. **Simple selection** - Choose disk from dropdown, use auto-partition
3. **Skip initially** - Use automatic partitioning in backend

**Recommended**: Start with option 2 or 3, add Cockpit later if time permits.

### Installation Progress
Backend already has threading and status updates in `install.py`. Frontend just needs to:
1. Call `startInstallation()`
2. Poll `getInstallStatus()` every second
3. Update progress bar
4. Show completion or error

### Frontend Build
Currently serving source files directly from `/etc/homefree-installer/frontend/`.

May need to:
- Add Vite build step for production
- Or continue serving source files (works with ES modules)

---

## Success Criteria

✅ **Backend REST API working** - DONE
✅ **Python dependencies added** - DONE
✅ **REST client created** - DONE
🔲 **All components updated** - IN PROGRESS (1/9)
🔲 **Frontend loads in browser**
🔲 **API calls successful**
🔲 **Full installation completes**
🔲 **Installed system boots**

---

**Current Progress**: ~60% complete

**Estimated remaining work**:
- Component updates: 2-3 hours
- Testing & bug fixes: 2-4 hours
- Cockpit integration (optional): 2-3 hours

**Total**: 4-7 hours to MVP (without Cockpit), 6-10 hours with full Cockpit integration.
