/**
 * REST API Client for HomeFree Web Installer
 * Replaces GraphQL client with simple fetch-based API calls
 */

const API_BASE = '';  // Same origin

/**
 * Generic fetch wrapper with error handling
 */
async function fetchAPI(endpoint, options = {}) {
  try {
    const response = await fetch(`${API_BASE}${endpoint}`, {
      headers: {
        'Content-Type': 'application/json',
        ...options.headers,
      },
      ...options,
    });

    if (!response.ok) {
      const error = await response.json().catch(() => ({ detail: response.statusText }));
      throw new Error(error.detail || `HTTP ${response.status}: ${response.statusText}`);
    }

    return await response.json();
  } catch (error) {
    console.error(`API Error [${endpoint}]:`, error);
    throw error;
  }
}

/**
 * GET request helper
 */
async function get(endpoint) {
  return fetchAPI(endpoint, { method: 'GET' });
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

// Configuration
export const setHostname = (hostname) =>
  post('/api/config/hostname', { hostname });

export const setLocation = (timezone, locale) =>
  post('/api/config/location', { timezone, locale });

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
export const getRebuildStatus = () => get('/api/config/rebuild-status');

// Services
export const getServices = () => get('/api/services');
export const getServiceOptionsSchema = () => get('/api/services/options/schema');

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
};
