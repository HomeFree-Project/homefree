/**
 * REST API Client for HomeFree Web Installer
 * Replaces GraphQL client with simple fetch-based API calls
 */

const API_BASE = '';  // Same origin

// Hard ceiling on any single API call. Without this a bare fetch()
// inherits the browser's network-stack timeout, which over HTTP/3 can
// stall ~30s on a QUIC connection whose backend died mid-rebuild: the
// connection isn't dead, just black-holed, so the browser keeps probing
// it instead of opening a fresh one. Aborting after a few seconds lets
// the next poll tick reconnect cleanly.
const DEFAULT_TIMEOUT_MS = 8000;

/**
 * Generic fetch wrapper with error handling
 */
async function fetchAPI(endpoint, options = {}) {
  try {
    // Honour a caller-supplied signal if present; otherwise impose the
    // default timeout. AbortSignal.any keeps both alive when both exist.
    const timeoutSignal = AbortSignal.timeout(options.timeoutMs || DEFAULT_TIMEOUT_MS);
    const signal = options.signal
      ? AbortSignal.any([options.signal, timeoutSignal])
      : timeoutSignal;
    const { timeoutMs, ...fetchOptions } = options;

    const response = await fetch(`${API_BASE}${endpoint}`, {
      headers: {
        'Content-Type': 'application/json',
        ...options.headers,
      },
      ...fetchOptions,
      signal,
    });

    if (!response.ok) {
      const body = await response.json().catch(() => ({ detail: response.statusText }));
      // Attach the HTTP status and full body to the Error so callers
      // can branch on auth errors (401/403) and surface tailored
      // messages instead of a generic "Failed to connect".
      const err = new Error(body.detail || `HTTP ${response.status}: ${response.statusText}`);
      err.status = response.status;
      err.body = body;
      throw err;
    }

    return await response.json();
  } catch (error) {
    console.error(`API Error [${endpoint}]:`, error);
    throw error;
  }
}

/**
 * GET request helper.
 *
 * GETs are idempotent, so we retry a couple times on a TRANSIENT failure
 * — the fetch itself rejecting (a "NetworkError"/"Failed to fetch") or
 * our own timeout firing. Those happen for a beat during an admin-api
 * blue/green flip or on the very first request after a page load, and
 * without a retry they surface as a scary red "NetworkError" box that
 * clears itself a moment later. HTTP error *responses* (err.status set —
 * 401/403/4xx/5xx) are real answers from the backend and are never
 * retried, so auth handling stays immediate.
 */
async function get(endpoint, { retries = 2, retryDelayMs = 300 } = {}) {
  for (let attempt = 0; ; attempt++) {
    try {
      return await fetchAPI(endpoint, { method: 'GET' });
    } catch (error) {
      // No .status === the fetch never got an HTTP response (network
      // drop or timeout) → transient, worth a retry.
      const transient = typeof error.status !== 'number';
      if (!transient || attempt >= retries) throw error;
      await new Promise((resolve) => setTimeout(resolve, retryDelayMs));
    }
  }
}

/**
 * POST request helper
 */
async function post(endpoint, data) {
  return fetchAPI(endpoint, {
    method: 'POST',
    body: JSON.stringify(data),
  });
}

// =============================================================================
// API Functions
// =============================================================================

// Health & Status
export const getHealth = () => get('/health');
export const getStatus = () => get('/api/status');

// System Information
export const getSystemInfo = () => get('/api/system');
export const isVirtualized = () => get('/api/system/is-virtualized');

// Network
export const getNetworkInterfaces = () => get('/api/network/interfaces');
export const configureNetwork = (wanInterface, lanInterface) =>
  post('/api/network/configure', {
    wan_interface: wanInterface,
    lan_interface: lanInterface,
  });

// Storage & NAS — local drive pools (Phase 1).
// `createStoragePool` deliberately uses post() (no retry): it formats disks,
// so it must never be auto-replayed. The status poll uses get() (retryable).
export const getStorageDrives = () => get('/api/storage/drives');
export const getStoragePools = () => get('/api/storage/pools');
export const previewStoragePool = (members, profile) =>
  post('/api/storage/preview', { members, profile });
export const createStoragePool = (payload) =>
  post('/api/storage/pools/create', payload);
// Reformat: put a NEW filesystem on an existing mdadm parity array WITHOUT
// re-running mdadm --create (skips the multi-TB resync at the cost of any
// data currently on the array). Status reported via the same create-status
// endpoint — the in-flight slot is shared.
export const reformatStoragePool = (payload) =>
  post('/api/storage/pools/reformat', payload);
export const getStoragePoolCreateStatus = () =>
  get('/api/storage/pools/create-status');
export const forgetStoragePool = (name) =>
  post('/api/storage/pools/forget', { name });
// Re-add a pool record verbatim. Used by the Undo Remove flow with the
// appliedConfig record so the post-undo state byte-matches applied (no
// pending diff afterward).
export const restoreStoragePool = (record) =>
  post('/api/storage/pools/restore', { record });
// Reclaim: tear down an in-use array/LVM group and wipe its disks back to
// eligible. post() (no retry) — it wipes disks; the status poll is retryable.
export const reclaimStorageDisks = (members) =>
  post('/api/storage/reclaim', { members });
export const getStorageReclaimStatus = () =>
  get('/api/storage/reclaim-status');
// Import: re-attach an existing on-disk volume (non-destructive).
export const getStorageImportable = () => get('/api/storage/importable');
export const importStoragePool = (payload) =>
  post('/api/storage/pools/import', payload);
// Promote: add an unmanaged btrfs (mounted via homefree.mounts OR currently
// cold, single-drive or md-backed) to homefree.storage.pools. Non-destructive
// — no format, no device-identity change, same fs-uuid. The backend evicts a
// matching homefree.mounts row in the same atomic write so the volume isn't
// double-mounted on Apply.
export const getPromotableBtrfs = () => get('/api/storage/promotable-btrfs');
export const promoteVolume = (fs_uuid, name, mountpoint) =>
  post('/api/storage/pools/promote', { fs_uuid, name, mountpoint });
// Disk mounts: live `homefree.mounts` view (with mounted/used/total runtime)
// + the list of partitions/disks that could be added as a new mount.
export const getMounts = () => get('/api/storage/mounts');
export const getMountableDevices = () => get('/api/storage/mountable-devices');
// System mounts: read-only / mount info for the "System" card in the
// unified Volumes section. Returns a list (length 0 or 1).
export const getSystemVolumes = () => get('/api/storage/system-volumes');

// Storage encryption (master key for data-pool LUKS containers). The master
// key is the LUKS recovery passphrase persisted at
// /etc/nixos/secrets/recovery-passphrase.txt — same value that unlocks the
// system disk's recovery slot. The Storage UI uses these to gate the
// "Encrypt this volume" toggle on first-time setup.
export const getStorageEncryptionStatus = () =>
  get('/api/storage/encryption/status');
// Generate a fresh 6-base36 master passphrase. Returns it ONCE so the UI
// can display it for the admin to save. Backend refuses if one already exists.
export const generateStorageMasterKey = () =>
  post('/api/storage/encryption/master-key/generate', {});
// Persist a user-provided master passphrase (min 20 chars, printable ASCII).
// Backend refuses if one already exists.
export const setStorageMasterKey = (passphrase) =>
  post('/api/storage/encryption/master-key/set', { passphrase });

// Locale & Timezone — cached module-level so the network call only happens
// once per page load. The data is large but immutable for the session, so
// holding the promise eliminates the empty-dropdown flicker when navigating
// back to a module that consumes it.
let _timezonesPromise = null;
let _keyboardLayoutsPromise = null;

export const getTimezones = () => {
  if (!_timezonesPromise) {
    _timezonesPromise = get('/api/locale/timezones').catch((err) => {
      // Don't cache failures — let the next caller retry.
      _timezonesPromise = null;
      throw err;
    });
  }
  return _timezonesPromise;
};

export const getKeyboardLayouts = () => {
  if (!_keyboardLayoutsPromise) {
    _keyboardLayoutsPromise = get('/api/locale/keyboard-layouts').catch((err) => {
      _keyboardLayoutsPromise = null;
      throw err;
    });
  }
  return _keyboardLayoutsPromise;
};

// Locales, countries, currencies, languages — cached the same way as
// timezones since these are large but immutable per session.
let _localesPromise = null;
let _countriesPromise = null;
let _currenciesPromise = null;
let _languagesPromise = null;

const _cachedGet = (path, promiseRef) => {
  if (!promiseRef.p) {
    promiseRef.p = get(path).catch((err) => {
      promiseRef.p = null;
      throw err;
    });
  }
  return promiseRef.p;
};

const _localesRef = { p: null };
const _countriesRef = { p: null };
const _currenciesRef = { p: null };
const _languagesRef = { p: null };

export const getLocales = () => _cachedGet('/api/locale/locales', _localesRef);
export const getCountries = () => _cachedGet('/api/locale/countries', _countriesRef);
export const getCurrencies = () => _cachedGet('/api/locale/currencies', _currenciesRef);
export const getLanguages = () => _cachedGet('/api/locale/languages', _languagesRef);

// Geocoding — server-proxied to OpenStreetMap Nominatim. Caller is
// responsible for debouncing input (~600ms is a good default given
// Nominatim's 1-req/sec usage policy).
export const geocodeAddress = (q) =>
  get(`/api/geocode?q=${encodeURIComponent(q)}`);

// IP-based geolocation — direct browser call to ipapi.co (CORS-enabled,
// 1000 req/day free, no key). Returns { latitude, longitude,
// country_code, timezone, city, ... }. Used as a one-click prefill for
// the location form.
export const ipGeolocate = async () => {
  const r = await fetch('https://ipapi.co/json/', { mode: 'cors' });
  if (!r.ok) throw new Error(`IP lookup failed: HTTP ${r.status}`);
  return r.json();
};

// SSO state — provisioning status and per-service sentinels. The admin
// SSO page consumes this. Not cached: we want fresh state every visit
// because the user may have just reprovisioned a service.
export const getSsoState = () => get('/api/sso/state');

export const reprovisionSso = () => post('/api/sso/reprovision', {});

// Zitadel user management. All routes go through the FastAPI backend
// which holds the Zitadel admin PAT — the frontend never sees that
// secret. Errors bubble up as standard HTTP responses.
export const listUsers = () => get('/api/users');
export const createUser = (data) => post('/api/users', data);
export const deleteUser = (id) =>
  fetch(`/api/users/${encodeURIComponent(id)}`, { method: 'DELETE' })
    .then(r => r.ok ? r.json() : r.json().then(j => Promise.reject(j)));
export const setUserAdmin = (id, isAdmin) =>
  post(`/api/users/${encodeURIComponent(id)}/admin`, { is_admin: isAdmin });

export const getCurrentUser = () => get('/api/users/me');

export const updateUser = (id, patch) =>
  fetch(`/api/users/${encodeURIComponent(id)}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(patch),
  }).then(r => r.ok ? r.json() : r.json().then(j => Promise.reject(j)));

export const setUserPassword = (id, newPassword) =>
  post(`/api/users/${encodeURIComponent(id)}/password`,
    { new_password: newPassword });

export const changeOwnPassword = (currentPassword, newPassword) =>
  post('/api/users/me/password',
    { current_password: currentPassword, new_password: newPassword });

// Self-service profile update (per-user dashboard at home.<domain>).
// Backend resolves the target user-id from the auth header — body
// fields are filtered to first/last/display name and email only.
export const updateOwnProfile = (patch) =>
  post('/api/users/me/profile', patch);

// App launcher data for the per-user dashboard. Returns the list of
// services the *authenticated* user can actually open in a browser:
// drops admin-gated services for non-admins, drops admin/manual/etc.
// metaservices, drops services with no resolvable URL.
export const getVisibleServices = () => get('/api/services/visible-to-me');

// Elevation lookup. Open-Meteo first (more reliable, 10k req/day non-
// commercial, no key), Open-Elevation as fallback if Open-Meteo errors.
// Both are CORS-enabled so this stays browser-side — the user's network
// reaches the API directly, no proxy needed. Returns meters above sea
// level as a number, or null if both services fail.
export const lookupElevation = async (latitude, longitude) => {
  if (typeof latitude !== 'number' || typeof longitude !== 'number') {
    throw new Error('Latitude and longitude required');
  }
  // Open-Meteo: returns { elevation: [<meters>] }
  try {
    const url = `https://api.open-meteo.com/v1/elevation?latitude=${latitude}&longitude=${longitude}`;
    const r = await fetch(url, { mode: 'cors' });
    if (r.ok) {
      const d = await r.json();
      if (Array.isArray(d.elevation) && d.elevation.length > 0) {
        return Math.round(d.elevation[0]);
      }
    }
  } catch (e) {
    // fall through to Open-Elevation
  }
  // Open-Elevation: returns { results: [{ elevation: <meters>, ... }] }
  const url = `https://api.open-elevation.com/api/v1/lookup?locations=${latitude},${longitude}`;
  const r = await fetch(url, { mode: 'cors' });
  if (!r.ok) throw new Error(`Elevation lookup failed: HTTP ${r.status}`);
  const d = await r.json();
  if (d.results && d.results[0] && typeof d.results[0].elevation === 'number') {
    return Math.round(d.results[0].elevation);
  }
  throw new Error('Elevation lookup returned no data');
};

// Configuration
export const setHostname = (hostname) =>
  post('/api/config/hostname', { hostname });

export const setLocation = (timezone, locale, extras = {}) =>
  post('/api/config/location', { timezone, locale, ...extras });

export const setKeyboard = (layout, vconsole) =>
  post('/api/config/keyboard', { layout, vconsole });

export const setUser = (username, fullname, email, password) =>
  post('/api/config/user', { username, fullname, email, password });

export const setPartitioning = (config) =>
  post('/api/config/partitioning', { config });

export const getInstallSummary = () => get('/api/config/summary');

export const setDevelopmentMode = (enabled) =>
  post('/api/config/development-mode', { enabled });

export const getDevelopmentMode = () => get('/api/config/development-mode');

export const setDomain = (domain) =>
  post('/api/config/domain', { domain });

// Installation
export const startInstallation = () => post('/api/install/start', {});
export const getInstallStatus = () => get('/api/install/status');

// System Control
export const rebootSystem = () => post('/api/system/reboot', {});
export const getClosureId = () => get('/api/system/closure-id');

// Admin Mode
export const getMode = () => get('/api/mode');
export const getServiceState = () => get('/api/service-state');
export const getCurrentConfig = () => get('/api/config/current');
export const validateConfig = (config) => post('/api/config/validate', config);
export const getConfigDiff = () => get('/api/config/diff');
export const previewConfigChanges = (config) => post('/api/config/preview', config);
export const saveConfigChanges = (config) => post('/api/config/save', config);
export const applyConfigChanges = (config) => post('/api/config/apply', config);
export const getConfigDirty = () => get('/api/config/dirty');
export const getAppliedConfig = () => get('/api/config/applied');
export const getRebuildStatus = () => get('/api/config/rebuild-status');
// System updates — check for and pull in a newer homefree-base commit.
export const checkSystemUpdates = () => get('/api/system/updates/check');
export const applySystemUpdate = () => post('/api/system/updates/apply', {});
// Same, but returns the FULL log so far (not just incremental output since
// the last poll). Used when reattaching to a rebuild after a page reload so
// the log history isn't lost.
export const getRebuildStatusWithHistory = () =>
  get('/api/config/rebuild-status?include_history=1');

// Developers — register custom Nix flakes that extend the system. Writing
// a flake rewrites /etc/nixos/flake.nix; the user then clicks Apply.
export const getDeveloperFlakes = () => get('/api/developers/flakes');
export const saveDeveloperFlake = (entry) => post('/api/developers/flakes', entry);
export const deleteDeveloperFlake = (id) =>
  fetchAPI(`/api/developers/flakes/${encodeURIComponent(id)}`, { method: 'DELETE' });
export const validateDeveloperFlake = (probe) =>
  post('/api/developers/flakes/validate', probe);

// Alternate HomeFree base repo — build this system from a fork or a local
// working copy instead of the official homefree-base. Saving rewrites
// /etc/nixos/flake.nix; the user then clicks Apply.
export const getHomefreeBase = () => get('/api/developers/homefree-base');
export const saveHomefreeBase = (entry) => post('/api/developers/homefree-base', entry);
export const validateHomefreeBase = (probe) =>
  post('/api/developers/homefree-base/validate', probe);

// Secrets — used by the finish-setup wizard and the DNS module.
export const getSecretsStatus = () => get('/api/secrets/status');
// Add an SSH authorized key (bootstraps SOPS recipients on a fresh box).
export const addAuthorizedKey = (publicKey) =>
  post('/api/secrets/keys/user', { public_key: publicKey });
// Set a single SOPS-managed secret value (service/key -> value).
export const setSecret = (serviceLabel, secretKey, value) =>
  post(`/api/secrets/${encodeURIComponent(serviceLabel)}/${encodeURIComponent(secretKey)}`,
       { value });
// Mark post-install setup complete — called by the finish-setup wizard's
// final step. Writes the .setup-complete sentinel, closing the auth bypass
// and the captive portal.
export const markFinishSetupComplete = () =>
  post('/api/finish-setup/complete', {});

// Services
export const getServices = () => get('/api/services');
export const getServiceOptionsSchema = () => get('/api/services/options/schema');
export const postServiceAction = (label, action) =>
  post(`/api/services/${encodeURIComponent(label)}/action`, { action });

// Abuse blocking (fail2ban + nftables observability)
export const getAbuseBlockingStatus = () => get('/api/abuse-blocking/status');
export const getAbuseBlockingBanned = () => get('/api/abuse-blocking/banned');
export const getAbuseBlockingCounters = () => get('/api/abuse-blocking/counters');
export const getAbuseBlockingTopTrafficSources = (window = 3600, filter = 'all', limit = 20, includeInternal = false) =>
  get(`/api/abuse-blocking/top-traffic-sources?window=${window}&filter=${encodeURIComponent(filter)}&limit=${limit}&include_internal=${includeInternal}`);
export const postAbuseBlockingUnban = (jail, ip) =>
  post('/api/abuse-blocking/unban', { jail, ip });

// Dashboard — system overview, time-series history, LAN clients.
// None are cached: the dashboard polls them for live data.
export const getDashboardOverview = () => get('/api/dashboard/overview');
export const getDashboardHistory = () => get('/api/dashboard/history');
export const getLanClients = () => get('/api/dashboard/lan-clients');

// Hardware — per-drive SMART + sensor snapshot, plus drive-temperature
// history. Backs the Hardware admin page.
export const getHardwareOverview = () => get('/api/hardware/overview');
export const getDriveTempHistory = () => get('/api/hardware/drive-temp-history');
export const getSensorTempHistory = () => get('/api/hardware/sensor-temp-history');

// Firmware — fwupd. Read state lives inside getHardwareOverview() under
// the `firmware` key; these endpoints are the action surface.
export const refreshFirmwareMetadata = () => post('/api/firmware/refresh', {});
export const updateFirmware = (deviceIds) =>
  post('/api/firmware/update', { device_ids: deviceIds });
export const getFirmwareUpdateStatus = () => get('/api/firmware/update-status');

// Power off — confirmation-gated by the caller (see confirmDialog).
// rebootSystem is already exported above in the "System Control"
// section (used by the installer's "reboot after install" button).
export const powerOffSystem = () => post('/api/system/poweroff', {});

// Filesystem
export const browsePath = (path) => get(`/api/filesystem/browse?path=${encodeURIComponent(path)}`);
export const createFolder = (path) => post('/api/filesystem/mkdir', { path });

// =============================================================================
// Polling Helper for Installation Progress
// =============================================================================

/**
 * Poll installation status every second until completed or error
 * @param {Function} onProgress - Callback with status updates
 * @param {number} interval - Polling interval in ms (default 1000)
 * @returns {Function} Stop polling function
 */
export function pollInstallStatus(onProgress, interval = 1000) {
  let stopped = false;

  async function poll() {
    if (stopped) return;

    try {
      const status = await getInstallStatus();
      onProgress(status);

      // Continue polling if not completed and no error
      if (!status.completed && !status.error) {
        setTimeout(poll, interval);
      }
    } catch (error) {
      onProgress({ error: error.message, completed: false });
    }
  }

  poll();

  // Return stop function
  return () => {
    stopped = true;
  };
}

// =============================================================================
// Export all as default object for convenience
// =============================================================================

export default {
  getHealth,
  getStatus,
  getSystemInfo,
  isVirtualized,
  getNetworkInterfaces,
  configureNetwork,
  getTimezones,
  getKeyboardLayouts,
  getLocales,
  getCountries,
  getCurrencies,
  getLanguages,
  geocodeAddress,
  ipGeolocate,
  lookupElevation,
  getSsoState,
  reprovisionSso,
  listUsers,
  createUser,
  deleteUser,
  setUserAdmin,
  getCurrentUser,
  updateUser,
  setUserPassword,
  changeOwnPassword,
  updateOwnProfile,
  getVisibleServices,
  getDeveloperFlakes,
  saveDeveloperFlake,
  deleteDeveloperFlake,
  validateDeveloperFlake,
  setHostname,
  setLocation,
  setKeyboard,
  setUser,
  setPartitioning,
  getInstallSummary,
  setDevelopmentMode,
  getDevelopmentMode,
  startInstallation,
  getInstallStatus,
  pollInstallStatus,
  rebootSystem,
  getSecretsStatus,
  addAuthorizedKey,
  setSecret,
  markFinishSetupComplete,
};
