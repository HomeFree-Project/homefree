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

// Network
export const getNetworkInterfaces = () => get('/api/network/interfaces');
export const configureNetwork = (wanInterface, lanInterface) =>
  post('/api/network/configure', {
    wan_interface: wanInterface,
    lan_interface: lanInterface,
  });

// Locale & Timezone
export const getTimezones = () => get('/api/locale/timezones');
export const getKeyboardLayouts = () => get('/api/locale/keyboard-layouts');

// Configuration
export const setHostname = (hostname) =>
  post('/api/config/hostname', { hostname });

export const setLocation = (timezone, locale) =>
  post('/api/config/location', { timezone, locale });

export const setKeyboard = (layout, vconsole) =>
  post('/api/config/keyboard', { layout, vconsole });

export const setUser = (username, fullname, password) =>
  post('/api/config/user', { username, fullname, password });

export const setPartitioning = (config) =>
  post('/api/config/partitioning', { config });

export const getInstallSummary = () => get('/api/config/summary');

// Installation
export const startInstallation = () => post('/api/install/start', {});
export const getInstallStatus = () => get('/api/install/status');

// System Control
export const rebootSystem = () => post('/api/system/reboot', {});

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
  startInstallation,
  getInstallStatus,
  pollInstallStatus,
  rebootSystem,
};
