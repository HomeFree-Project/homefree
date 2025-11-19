import { LitElement, html, css } from 'lit';
import { getCurrentConfig, validateConfig, previewConfigChanges, applyConfigChanges } from '../../api/client.js';
import './modules/system-module.js';
import './modules/network-module.js';
import './modules/dns-module.js';
import './modules/services-module.js';
import './modules/backups-module.js';
import './modules/status-module.js';
import '../shared/progress-modal.js';
import '../shared/toast-notification.js';

class AdminApp extends LitElement {
  static properties = {
    serverConfig: { type: Object },    // Actual deployed/server state
    pendingConfig: { type: Object },   // User's uncommitted changes
    dirtyModules: { type: Object },    // Track which modules have unsaved changes
    config: { type: Object },          // Computed merged config (for backward compatibility)
    currentModule: { type: String },
    loading: { type: Boolean },
    error: { type: String },
    sidebarCollapsed: { type: Boolean },
    rebuildStatus: { type: Object },
    buildLogs: { type: Array },        // Build output logs
    systemHealth: { type: String },    // System health status for left nav icon
    toasts: { type: Array },           // Toast notifications stack
    statusFlashing: { type: Boolean }, // Status nav item flash animation
    statusNeedsAttention: { type: Boolean } // Persistent flash until user clicks Status
  };

  static styles = css`
    :host {
      display: block;
      width: 100%;
      height: 100vh;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    }

    .admin-container {
      display: flex;
      height: 100%;
    }

    /* Sidebar */
    .sidebar {
      width: 260px;
      background: linear-gradient(180deg, #667eea 0%, #764ba2 100%);
      color: white;
      display: flex;
      flex-direction: column;
      transition: width 0.3s ease;
      overflow-x: hidden;
    }

    .sidebar.collapsed {
      width: 70px;
    }

    .sidebar-header {
      padding: 24px 20px;
      border-bottom: 1px solid rgba(255, 255, 255, 0.1);
      display: flex;
      align-items: center;
      justify-content: space-between;
    }

    .sidebar.collapsed .sidebar-header h1 {
      display: none;
    }

    .sidebar-header h1 {
      margin: 0;
      font-size: 20px;
      font-weight: 600;
      white-space: nowrap;
    }

    .collapse-btn {
      background: rgba(255, 255, 255, 0.1);
      border: none;
      color: white;
      width: 32px;
      height: 32px;
      border-radius: 6px;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
      transition: background 0.2s;
    }

    .collapse-btn:hover {
      background: rgba(255, 255, 255, 0.2);
    }

    .nav-menu {
      flex: 1;
      padding: 16px 0;
      overflow-y: auto;
    }

    .nav-item {
      display: flex;
      align-items: center;
      padding: 12px 20px;
      color: rgba(255, 255, 255, 0.8);
      text-decoration: none;
      cursor: pointer;
      transition: all 0.2s;
      border-left: 3px solid transparent;
      white-space: nowrap;
    }

    .nav-item:hover {
      background: rgba(255, 255, 255, 0.1);
      color: white;
    }

    .nav-item.active {
      background: rgba(255, 255, 255, 0.15);
      color: white;
      border-left-color: white;
    }

    .nav-item-icon {
      width: 20px;
      margin-right: 12px;
      font-size: 18px;
      flex-shrink: 0;
    }

    .sidebar.collapsed .nav-item-text {
      display: none;
    }

    .nav-section-title {
      padding: 20px 20px 8px 20px;
      font-size: 11px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.5px;
      opacity: 0.6;
      white-space: nowrap;
    }

    .sidebar.collapsed .nav-section-title {
      display: none;
    }

    /* Main Content */
    .main-content {
      flex: 1;
      display: flex;
      flex-direction: column;
      background: #f5f5f7;
      overflow: hidden;
    }

    .top-bar {
      height: 64px;
      background: white;
      border-bottom: 1px solid #e5e5e7;
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0 24px;
      box-shadow: 0 1px 3px rgba(0, 0, 0, 0.05);
    }

    .top-bar h2 {
      margin: 0;
      font-size: 24px;
      font-weight: 600;
      color: #1d1d1f;
    }

    .top-bar-actions {
      display: flex;
      gap: 12px;
    }

    .btn {
      padding: 8px 16px;
      border-radius: 8px;
      border: 1px solid #d2d2d7;
      background: white;
      color: #1d1d1f;
      font-size: 14px;
      font-weight: 500;
      cursor: pointer;
      transition: all 0.2s;
    }

    .btn:hover {
      background: #f5f5f7;
    }

    .btn-primary {
      background: #667eea;
      color: white;
      border-color: #667eea;
    }

    .btn-primary:hover {
      background: #5568d3;
    }

    .btn:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }

    .btn:disabled:hover {
      background: #667eea;
    }

    @keyframes spin {
      to { transform: rotate(360deg); }
    }

    .spinner-tiny {
      width: 10px;
      height: 10px;
      border: 2px solid rgba(255, 255, 255, 0.3);
      border-top-color: white;
      border-radius: 50%;
      animation: spin 1s linear infinite;
    }

    .status-badge {
      margin-left: auto;
      width: 10px;
      height: 10px;
      border-radius: 50%;
      flex-shrink: 0;
    }

    .status-badge.healthy {
      background: #10b981;
    }

    .status-badge.unhealthy {
      background: #ef4444;
    }

    .status-badge.warning {
      background: #f59e0b;
    }

    .status-badge.building {
      background: transparent;
      width: auto;
      height: auto;
    }

    .sidebar.collapsed .status-badge {
      display: none;
    }

    /* Status nav item flashing animation */
    @keyframes statusFlash {
      0%, 100% {
        background: rgba(255, 255, 255, 0.15);
        box-shadow: 0 0 0 0 rgba(255, 255, 255, 0.4);
      }
      50% {
        background: rgba(255, 255, 255, 0.25);
        box-shadow: 0 0 10px 2px rgba(255, 255, 255, 0.6);
      }
    }

    .nav-item.flashing {
      animation: statusFlash 1s ease-in-out infinite;
    }

    .content-area {
      flex: 1;
      overflow-y: auto;
      padding: 24px;
    }

    .loading-overlay {
      display: flex;
      align-items: center;
      justify-content: center;
      height: 100%;
      font-size: 18px;
      color: #86868b;
    }

    /* Full-screen loading overlay for initial load */
    .fullscreen-loading {
      position: fixed;
      top: 0;
      left: 0;
      width: 100vw;
      height: 100vh;
      background: #f5f5f7;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      z-index: 9999;
    }

    .loading-spinner {
      width: 48px;
      height: 48px;
      border: 4px solid rgba(102, 126, 234, 0.1);
      border-top-color: #667eea;
      border-radius: 50%;
      animation: spin 1s linear infinite;
      margin-bottom: 16px;
    }

    .loading-text {
      font-size: 16px;
      color: #86868b;
      font-weight: 500;
    }

    .error-message {
      background: #fff3cd;
      color: #856404;
      padding: 16px;
      border-radius: 8px;
      border-left: 4px solid #ffc107;
      margin: 32px;
    }

    .module-content {
      background: white;
      border-radius: 0;
      padding: 24px;
      box-shadow: none;
      min-height: 100%;
    }

    /* Responsive */
    @media (max-width: 768px) {
      .sidebar {
        position: absolute;
        z-index: 100;
        height: 100%;
      }

      .sidebar.collapsed {
        transform: translateX(-100%);
      }
    }
  `;

  constructor() {
    super();
    this.serverConfig = null;
    this.pendingConfig = {};
    this.config = {};  // Initialize merged config
    this.dirtyModules = new Set();
    this.currentModule = 'system';
    this.loading = true;
    this.error = null;
    this.sidebarCollapsed = false;
    this.systemHealth = 'healthy';
    this.buildLogs = [];
    this.rebuildStatus = {
      running: false,
      message: '',
      lastUpdate: null
    };
    this.statusPollInterval = null;
    this._pollRebuildActive = false;
    this.toasts = [];
    this.statusFlashing = false;
    this.statusNeedsAttention = false;
    this._toastIdCounter = 0;

    // Navigation modules
    this.modules = [
      {
        id: 'system',
        title: 'System',
        icon: '⚙️',
        section: 'General'
      },
      {
        id: 'network',
        title: 'Network',
        icon: '🌐',
        section: 'General'
      },
      {
        id: 'dns',
        title: 'DNS',
        icon: '🔍',
        section: 'General'
      },
      {
        id: 'services',
        title: 'Services',
        icon: '📦',
        section: 'Applications'
      },
      {
        id: 'backups',
        title: 'Backups',
        icon: '💾',
        section: 'Data'
      },
      {
        id: 'advanced',
        title: 'Advanced',
        icon: '🔧',
        section: 'System'
      },
      {
        id: 'status',
        title: 'Status',
        icon: '📊',
        section: 'System'
      }
    ];
  }

  async connectedCallback() {
    super.connectedCallback();

    // CRITICAL: Stop polling before page unload to prevent connection limit race condition
    // Create AbortController for cancelling in-flight requests
    this.rebuildStatusAbortController = new AbortController();

    this.beforeUnloadHandler = () => {
      // Abort any in-flight requests
      if (this.rebuildStatusAbortController) {
        this.rebuildStatusAbortController.abort();
      }
      // Clear polling interval
      if (this.statusPollInterval) {
        clearInterval(this.statusPollInterval);
      }
    };
    window.addEventListener('beforeunload', this.beforeUnloadHandler);

    // Read initial route from hash
    this.loadRouteFromHash();

    // Listen for hash changes (back/forward buttons)
    window.addEventListener('hashchange', () => {
      this.loadRouteFromHash();
    });

    await this.loadConfig();

    // Check if a rebuild is already in progress
    await this.checkRebuildStatus();

    // Start continuous polling to keep status icon up-to-date
    // This ensures the icon updates even after backend restarts or external rebuilds
    this.statusPollInterval = setInterval(() => this.checkRebuildStatus(), 3000);
  }

  disconnectedCallback() {
    super.disconnectedCallback();

    // Remove beforeunload listener
    if (this.beforeUnloadHandler) {
      window.removeEventListener('beforeunload', this.beforeUnloadHandler);
    }

    // Clean up polling interval
    if (this.statusPollInterval) {
      clearInterval(this.statusPollInterval);
    }
  }

  loadRouteFromHash() {
    const hash = window.location.hash.slice(2); // Remove '#/'
    if (hash && this.modules.find(m => m.id === hash)) {
      this.currentModule = hash;
    } else if (!hash) {
      // Default to system if no hash
      this.currentModule = 'system';
    }
  }

  async loadConfig() {
    try {
      this.serverConfig = await getCurrentConfig();
      // Initialize pending config as empty on first load
      // Pending changes will be added as user makes modifications
      if (Object.keys(this.pendingConfig).length === 0) {
        this.pendingConfig = {};
      }
      // Update merged config for legacy modules
      this.updateMergedConfig();
      this.loading = false;
    } catch (error) {
      console.error('Failed to load config:', error);
      this.error = `Failed to load configuration: ${error.message}`;
      this.loading = false;
    }
  }

  async checkRebuildStatus() {
    try {
      const response = await fetch('/api/config/rebuild-status', {
        signal: this.rebuildStatusAbortController?.signal
      });

      // Check if response is OK before parsing JSON
      if (!response.ok) {
        console.error('Failed to fetch rebuild status:', response.status);
        return;
      }

      const status = await response.json();
      console.log('[DEBUG] checkRebuildStatus - status:', status);
      console.log('[DEBUG] checkRebuildStatus - output length:', status.output?.length || 0);
      console.log('[DEBUG] checkRebuildStatus - exit_code:', status.exit_code);
      console.log('[DEBUG] checkRebuildStatus - running:', status.running);

      // If rebuild is running, restore state and start polling
      if (status.running) {
        this.systemHealth = 'building';
        this.rebuildStatus = {
          running: true,
          message: 'Rebuild in progress...',
          lastUpdate: null
        };

        // Start polling to show live updates (only if not already active)
        if (!this._pollRebuildActive) {
          this._pollRebuildActive = true;
          this.pollRebuildStatus();
        }
      } else if (status.exit_code !== null && status.exit_code !== undefined) {
        // Build has finished - restore final state
        const success = status.exit_code === 0;
        const partialSuccess = status.partial_success || false;

        // Set systemHealth based on exit code (same logic as status-module)
        if (success) {
          this.systemHealth = 'healthy';
        } else if (partialSuccess) {
          this.systemHealth = 'warning';
        } else {
          this.systemHealth = 'unhealthy';
        }

        this.rebuildStatus = {
          running: false,
          message: success
            ? 'Rebuild completed successfully'
            : partialSuccess
              ? `Rebuild completed with warnings (exit code ${status.exit_code})`
              : `Rebuild failed (exit code ${status.exit_code})`,
          lastUpdate: {
            success: success || partialSuccess,
            warning: partialSuccess
          }
        };

        // Restore build logs from backend's saved output
        // Backend returns full output when build is finished
        if (status.output && status.output.trim()) {
          this.buildLogs = status.output.trim().split('\n').filter(l => l.trim());
          console.log('[DEBUG] checkRebuildStatus - populated buildLogs, length:', this.buildLogs.length);
          // Force Lit to detect the change and re-render
          this.requestUpdate();
        } else {
          console.log('[DEBUG] checkRebuildStatus - NO output to populate buildLogs');
        }
      } else {
        // No exit code and not running - backend doesn't know about rebuild
        // This happens after external rebuilds or backend restarts
        if (status.output && status.output.trim()) {
          // If there's output, it's likely an error
          this.systemHealth = 'unhealthy';
        } else {
          // No output, no rebuild tracked - system is healthy
          this.systemHealth = 'healthy';
        }
      }
    } catch (error) {
      // Ignore abort errors - these are expected when component disconnects
      if (error.name === 'AbortError') {
        return;
      }
      console.error('Error checking rebuild status:', error);
      // Don't throw - just continue with normal loading
    }
  }

  handleModuleClick(moduleId) {
    this.currentModule = moduleId;
    // Update URL hash to maintain state
    window.location.hash = `#/${moduleId}`;

    // If clicking Status nav, clear the needs attention flag
    if (moduleId === 'status') {
      this.statusNeedsAttention = false;
    }
  }

  /**
   * Show a toast notification
   * @param {string} message - The message to display
   * @param {string} type - Type: 'success', 'error', 'warning', 'info'
   * @param {number} duration - Auto-dismiss duration in ms (default: 5000)
   */
  showToast(message, type = 'info', duration = 5000) {
    const id = this._toastIdCounter++;
    const toast = { id, message, type, duration };
    this.toasts = [...this.toasts, toast];
    this.requestUpdate();
  }

  /**
   * Remove a toast notification
   * @param {number} id - Toast ID to remove
   */
  removeToast(id) {
    this.toasts = this.toasts.filter(t => t.id !== id);
    this.requestUpdate();
  }

  /**
   * Flash the Status nav item for a specified duration
   * @param {number} duration - Duration in ms (default: 2000)
   */
  flashStatus(duration = 2000) {
    this.statusFlashing = true;
    setTimeout(() => {
      this.statusFlashing = false;
    }, duration);
  }

  /**
   * Set or clear the persistent attention flag for Status nav
   * @param {boolean} needs - Whether Status needs attention
   */
  setStatusNeedsAttention(needs) {
    this.statusNeedsAttention = needs;
  }

  toggleSidebar() {
    this.sidebarCollapsed = !this.sidebarCollapsed;
  }

  getCurrentModuleTitle() {
    const module = this.modules.find(m => m.id === this.currentModule);
    return module ? module.title : 'HomeFree Admin';
  }

  getStatusBadgeClass() {
    // Use systemHealth directly (same as status-module.js)
    // This ensures left nav badge matches status page title
    if (this.rebuildStatus.running) {
      return 'building';
    }
    return this.systemHealth || 'healthy';
  }

  handleConfigChange(e) {
    // Legacy handler for modules that still use config-change event
    // TODO: Migrate all modules to use specific action events
    const moduleName = e.detail.module || 'unknown';
    this.pendingConfig = { ...this.pendingConfig, ...e.detail.config };
    this.dirtyModules.add(moduleName);
    this.updateMergedConfig();
    this.requestUpdate();
  }

  handleServiceToggle(e) {
    const { serviceLabel, enabled } = e.detail;

    // Initialize services in pending config if not exists
    if (!this.pendingConfig.services) {
      this.pendingConfig = { ...this.pendingConfig, services: {} };
    }

    // Get current service config from server or pending
    const currentConfig = this.pendingConfig.services[serviceLabel] ||
                          this.serverConfig?.services?.[serviceLabel] ||
                          { enable: false, public: false };

    // Update pending config immutably
    this.pendingConfig = {
      ...this.pendingConfig,
      services: {
        ...this.pendingConfig.services,
        [serviceLabel]: {
          ...currentConfig,
          enable: enabled
        }
      }
    };

    // Mark services module as dirty
    this.dirtyModules.add('services');
    this.updateMergedConfig();
    this.requestUpdate();
  }

  handleServicePublicToggle(e) {
    const { serviceLabel, isPublic } = e.detail;

    // Initialize services in pending config if not exists
    if (!this.pendingConfig.services) {
      this.pendingConfig = { ...this.pendingConfig, services: {} };
    }

    // Get current service config from server or pending
    const currentConfig = this.pendingConfig.services[serviceLabel] ||
                          this.serverConfig?.services?.[serviceLabel] ||
                          { enable: false, public: false };

    // Update pending config immutably
    this.pendingConfig = {
      ...this.pendingConfig,
      services: {
        ...this.pendingConfig.services,
        [serviceLabel]: {
          ...currentConfig,
          public: isPublic
        }
      }
    };

    // Mark services module as dirty
    this.dirtyModules.add('services');
    this.updateMergedConfig();
    this.requestUpdate();
  }

  handleServiceOptionChanged(e) {
    const { serviceLabel, optionKey, value } = e.detail;

    // Initialize services in pending config if not exists
    if (!this.pendingConfig.services) {
      this.pendingConfig = { ...this.pendingConfig, services: {} };
    }

    // Get current service config from server or pending
    const currentConfig = this.pendingConfig.services[serviceLabel] ||
                          this.serverConfig?.services?.[serviceLabel] ||
                          { enable: false, public: false };

    // Update pending config immutably with the new option value
    this.pendingConfig = {
      ...this.pendingConfig,
      services: {
        ...this.pendingConfig.services,
        [serviceLabel]: {
          ...currentConfig,
          [optionKey]: value
        }
      }
    };

    // Mark services module as dirty
    this.dirtyModules.add('services');
    this.updateMergedConfig();
    this.requestUpdate();
  }

  handleInstanceFieldChanged(e) {
    const { parentLabel, instanceIndex, fieldKey, value } = e.detail;

    // Initialize services in pending config if not exists
    if (!this.pendingConfig.services) {
      this.pendingConfig = { ...this.pendingConfig, services: {} };
    }

    // Get current parent service config
    const currentParentConfig = this.pendingConfig.services[parentLabel] ||
                                this.serverConfig?.services?.[parentLabel] ||
                                { enable: false, public: false, instances: [] };

    // Get current instances array
    const currentInstances = currentParentConfig.instances || [];

    // Update the specific instance's field
    const updatedInstances = [...currentInstances];
    if (instanceIndex >= 0 && instanceIndex < updatedInstances.length) {
      updatedInstances[instanceIndex] = {
        ...updatedInstances[instanceIndex],
        [fieldKey]: value
      };
    }

    // Update pending config immutably
    this.pendingConfig = {
      ...this.pendingConfig,
      services: {
        ...this.pendingConfig.services,
        [parentLabel]: {
          ...currentParentConfig,
          instances: updatedInstances
        }
      }
    };

    // Mark services module as dirty
    this.dirtyModules.add('services');
    this.updateMergedConfig();
    this.requestUpdate();
  }

  handleInstanceAdd(e) {
    console.log('[handleInstanceAdd] Event received:', e.detail);
    const { parentLabel } = e.detail;

    // Initialize services in pending config if not exists
    if (!this.pendingConfig.services) {
      this.pendingConfig = { ...this.pendingConfig, services: {} };
    }

    // Get current parent service config
    const currentParentConfig = this.pendingConfig.services[parentLabel] ||
                                this.serverConfig?.services?.[parentLabel] ||
                                { enable: false, public: false, instances: [] };

    // Get current instances array
    const currentInstances = currentParentConfig.instances || [];

    // Create a new instance with default values
    // Generate unique subdomain (e.g., "instance-1", "instance-2")
    const instanceNumber = currentInstances.length + 1;
    const newInstance = {
      enable: true,
      public: false,
      subdomain: `instance-${instanceNumber}`,
      name: `Instance ${instanceNumber}`,
      // Additional fields will get their defaults from the schema
      // For minecraft: memory (null), type (null), mod-pack (null), mods ([])
    };

    // Add new instance to array
    const updatedInstances = [...currentInstances, newInstance];

    // Update pending config immutably
    this.pendingConfig = {
      ...this.pendingConfig,
      services: {
        ...this.pendingConfig.services,
        [parentLabel]: {
          ...currentParentConfig,
          instances: updatedInstances
        }
      }
    };

    // Mark services module as dirty
    this.dirtyModules.add('services');
    this.updateMergedConfig();
    this.requestUpdate();
    console.log('[handleInstanceAdd] Instance added, config updated:', {
      parentLabel,
      newInstance,
      updatedInstances,
      pendingConfig: this.pendingConfig
    });
  }

  handleInstanceDelete(e) {
    const { parentLabel, instanceIndex } = e.detail;

    // Confirm deletion
    if (!confirm('Are you sure you want to delete this instance? This action cannot be undone after applying changes.')) {
      return;
    }

    // Initialize services in pending config if not exists
    if (!this.pendingConfig.services) {
      this.pendingConfig = { ...this.pendingConfig, services: {} };
    }

    // Get current parent service config
    const currentParentConfig = this.pendingConfig.services[parentLabel] ||
                                this.serverConfig?.services?.[parentLabel] ||
                                { enable: false, public: false, instances: [] };

    // Get current instances array
    const currentInstances = currentParentConfig.instances || [];

    // Remove instance at index
    const updatedInstances = currentInstances.filter((_, idx) => idx !== instanceIndex);

    // Update pending config immutably
    this.pendingConfig = {
      ...this.pendingConfig,
      services: {
        ...this.pendingConfig.services,
        [parentLabel]: {
          ...currentParentConfig,
          instances: updatedInstances
        }
      }
    };

    // Mark services module as dirty
    this.dirtyModules.add('services');
    this.updateMergedConfig();
    this.requestUpdate();
  }

  handleInstanceToggle(e) {
    const { parentLabel, instanceLabel, enabled } = e.detail;

    // Initialize services in pending config if not exists
    if (!this.pendingConfig.services) {
      this.pendingConfig = { ...this.pendingConfig, services: {} };
    }

    // Get current parent service config
    const currentParentConfig = this.pendingConfig.services[parentLabel] ||
                                this.serverConfig?.services?.[parentLabel] ||
                                { enable: false, public: false, instances: [] };

    // Get current instances array
    const currentInstances = currentParentConfig.instances || [];

    // Find instance index by matching label
    // Instance label format: parentLabel_subdomain (e.g., "minecraft_minecraft-cisco")
    const instanceIndex = currentInstances.findIndex(inst => {
      const instanceId = `${parentLabel}_${inst.subdomain}`;
      return instanceId === instanceLabel;
    });

    if (instanceIndex === -1) {
      console.error('[handleInstanceToggle] Instance not found:', instanceLabel);
      return;
    }

    // Update the specific instance's enable field
    const updatedInstances = [...currentInstances];
    updatedInstances[instanceIndex] = {
      ...updatedInstances[instanceIndex],
      enable: enabled
    };

    // Update pending config immutably
    this.pendingConfig = {
      ...this.pendingConfig,
      services: {
        ...this.pendingConfig.services,
        [parentLabel]: {
          ...currentParentConfig,
          instances: updatedInstances
        }
      }
    };

    // Mark services module as dirty
    this.dirtyModules.add('services');
    this.updateMergedConfig();
    this.requestUpdate();
  }

  handleInstancePublicToggle(e) {
    const { parentLabel, instanceLabel, isPublic } = e.detail;

    // Initialize services in pending config if not exists
    if (!this.pendingConfig.services) {
      this.pendingConfig = { ...this.pendingConfig, services: {} };
    }

    // Get current parent service config
    const currentParentConfig = this.pendingConfig.services[parentLabel] ||
                                this.serverConfig?.services?.[parentLabel] ||
                                { enable: false, public: false, instances: [] };

    // Get current instances array
    const currentInstances = currentParentConfig.instances || [];

    // Find instance index by matching label
    const instanceIndex = currentInstances.findIndex(inst => {
      const instanceId = `${parentLabel}_${inst.subdomain}`;
      return instanceId === instanceLabel;
    });

    if (instanceIndex === -1) {
      console.error('[handleInstancePublicToggle] Instance not found:', instanceLabel);
      return;
    }

    // Update the specific instance's public field
    const updatedInstances = [...currentInstances];
    updatedInstances[instanceIndex] = {
      ...updatedInstances[instanceIndex],
      public: isPublic
    };

    // Update pending config immutably
    this.pendingConfig = {
      ...this.pendingConfig,
      services: {
        ...this.pendingConfig.services,
        [parentLabel]: {
          ...currentParentConfig,
          instances: updatedInstances
        }
      }
    };

    // Mark services module as dirty
    this.dirtyModules.add('services');
    this.updateMergedConfig();
    this.requestUpdate();
  }

  /**
   * Merge server config with pending changes to get the config to save
   * Pending changes override server config
   */
  getMergedConfig() {
    if (!this.serverConfig) {
      return this.pendingConfig;
    }

    // Deep merge: pending changes override server config
    const merged = { ...this.serverConfig };

    // Merge services section
    if (this.pendingConfig.services) {
      // Remove flat instance keys from server config before merging
      // Flat keys like "minecraft_minecraft-cisco" are from old buggy saves
      // and should not be carried forward
      const serverServices = {};
      if (this.serverConfig.services) {
        for (const [name, value] of Object.entries(this.serverConfig.services)) {
          // Skip flat instance keys (format: parent_subdomain)
          if (name.includes('_')) {
            const parentName = name.split('_')[0];
            // Check if parent exists with instances - if so, skip this flat key
            if (this.serverConfig.services[parentName]?.instances) {
              continue;
            }
          }
          serverServices[name] = value;
        }
      }

      merged.services = {
        ...serverServices,
        ...this.pendingConfig.services
      };
    }

    // Merge other sections as they're added
    // TODO: Add other config sections as modules are migrated

    return merged;
  }

  /**
   * Update the merged config property for backward compatibility
   * Call this whenever serverConfig or pendingConfig changes
   */
  updateMergedConfig() {
    this.config = this.getMergedConfig();
  }

  async handleSaveChanges() {
    try {
      // Merge server config with pending changes for validation and submission
      const configToSave = this.getMergedConfig();

      // Validate configuration
      const validation = await validateConfig(configToSave);

      if (!validation.valid) {
        // Show error toast with first error
        const firstError = validation.errors[0] || 'Validation failed';
        this.showToast(`Validation failed: ${firstError}`, 'error', 7000);
        return;
      }

      // Show warnings if any
      if (validation.warnings && validation.warnings.length > 0) {
        // Show warning toast but continue
        const firstWarning = validation.warnings[0];
        this.showToast(`Warning: ${firstWarning}`, 'warning', 5000);
      }

      // Apply changes (skip preview/dry-activate step)
      const result = await applyConfigChanges(configToSave);

      if (!result.success) {
        this.showToast(`Failed to apply configuration: ${result.message || 'Unknown error'}`, 'error', 7000);
        return;
      }

      // Show success toast
      this.showToast('Configuration saved successfully', 'success', 5000);

      // Flash Status nav item for 2 seconds
      this.flashStatus(2000);

      // Keep pendingConfig during rebuild for optimistic updates
      // Will be cleared after serverConfig is reloaded when rebuild completes
      // this.pendingConfig = {};  // Don't clear yet - prevents flicker during rebuild
      this.dirtyModules.clear();
      this.updateMergedConfig();

      // Set rebuild status
      this.rebuildStatus = {
        running: true,
        message: 'Starting system rebuild...',
        lastUpdate: null
      };

      // Start background polling
      this.pollRebuildStatus();

    } catch (error) {
      console.error('Error saving changes:', error);
      this.showToast(`Error: ${error.message || 'Unknown error'}`, 'error', 7000);
    }
  }

  async pollRebuildStatus() {
    // Reset build logs ONLY when starting a NEW poll (not on repeated calls from statusPollInterval)
    // The flag ensures we only reset once per build
    this.buildLogs = [];

    const checkStatus = async () => {
      try {
        const response = await fetch('/api/config/rebuild-status', {
          signal: this.rebuildStatusAbortController?.signal
        });

        // Check if response is OK before parsing JSON
        if (!response.ok) {
          throw new Error(`HTTP error! status: ${response.status}`);
        }

        const status = await response.json();

        if (status.output) {
          // Accumulate output (trim to remove leading/trailing whitespace)
          const newLines = status.output.trim().split('\n').filter(l => l.trim());
          this.buildLogs = [...this.buildLogs, ...newLines];

          // Update header status with last line
          const lastLine = newLines[newLines.length - 1] || 'Building...';
          this.systemHealth = 'building';
          this.rebuildStatus = {
            running: true,
            message: lastLine.substring(0, 50) + (lastLine.length > 50 ? '...' : ''),
            lastUpdate: { success: null }
          };
        }

        if (!status.running) {
          // Rebuild finished - mark polling as inactive
          this._pollRebuildActive = false;

          // Only update systemHealth if we have actual exit code
          // If exit_code is null, backend doesn't know about the rebuild (external rebuild)
          if (status.exit_code !== null && status.exit_code !== undefined) {
            const success = status.exit_code === 0;
            const partialSuccess = status.partial_success || false;

            if (success) {
              this.systemHealth = 'healthy';
              this.rebuildStatus = {
                running: false,
                message: 'Rebuild completed successfully',
                lastUpdate: { success: true }
              };

              // Flash Status nav for 2 seconds on success
              this.flashStatus(2000);

              // Reload config after success, then clear pending changes
              setTimeout(async () => {
                await this.loadConfig();
                // Now that serverConfig is updated, clear optimistic updates
                this.pendingConfig = {};
                this.updateMergedConfig();
                this.requestUpdate();
              }, 2000);
            } else if (partialSuccess) {
              this.systemHealth = 'warning';
              // Partial success: generation activated but services failed
              this.rebuildStatus = {
                running: false,
                message: `Rebuild completed with warnings (exit code ${status.exit_code}) - Click to view logs`,
                lastUpdate: { success: true, warning: true }
              };

              // Flash Status nav for 2 seconds on partial success
              this.flashStatus(2000);

              // Reload config after partial success, then clear pending changes
              setTimeout(async () => {
                await this.loadConfig();
                // Now that serverConfig is updated, clear optimistic updates
                this.pendingConfig = {};
                this.updateMergedConfig();
                this.requestUpdate();
              }, 2000);
            } else {
              this.systemHealth = 'unhealthy';
              // Show error status - logs are already in this.buildLogs
              this.rebuildStatus = {
                running: false,
                message: `Rebuild failed (exit code ${status.exit_code}) - Click to view logs`,
                lastUpdate: { success: false }
              };

              // Set persistent flash on failure - will continue until user clicks Status
              this.setStatusNeedsAttention(true);
            }
          }
          // If exit_code is null, keep previous systemHealth (don't change it)

          // Stop polling - build is complete
          return;
        }

        // Continue polling every 2 seconds
        setTimeout(checkStatus, 2000);
      } catch (error) {
        // Ignore abort errors - these are expected when component disconnects
        if (error.name === 'AbortError') {
          return;
        }

        console.error('Error polling rebuild status:', error);
        // Reset polling flag on error
        this._pollRebuildActive = false;

        // Reset systemHealth to last known good state or warning
        // Don't leave it as 'building' since we lost connection
        if (this.systemHealth === 'building') {
          this.systemHealth = 'warning';
        }
        this.rebuildStatus = {
          running: false,
          message: 'Lost connection to rebuild process',
          lastUpdate: { success: false }
        };
        // Don't continue polling on error - stop the loop
        return;
      }
    };

    // Start polling
    checkStatus();
  }

  renderModule() {
    if (this.error) {
      return html`
        <div class="error-message">
          <strong>Error:</strong> ${this.error}
        </div>
      `;
    }

    // Render appropriate module based on currentModule
    switch (this.currentModule) {
      case 'system':
        return html`
          <system-module
            .config=${this.config}
            @config-change=${this.handleConfigChange}
          ></system-module>
        `;

      case 'network':
        return html`
          <network-module
            .config=${this.config}
            @config-change=${this.handleConfigChange}
          ></network-module>
        `;

      case 'dns':
        return html`
          <dns-module
            .config=${this.config}
            @config-change=${this.handleConfigChange}
          ></dns-module>
        `;

      case 'services':
        return html`
          <services-module
            .serverConfig=${this.serverConfig}
            .pendingConfig=${this.pendingConfig}
            @service-toggle=${this.handleServiceToggle}
            @service-public-toggle=${this.handleServicePublicToggle}
            @service-option-changed=${this.handleServiceOptionChanged}
            @instance-toggle=${this.handleInstanceToggle}
            @instance-public-toggle=${this.handleInstancePublicToggle}
            @instance-field-changed=${this.handleInstanceFieldChanged}
            @instance-add=${this.handleInstanceAdd}
            @instance-delete=${this.handleInstanceDelete}
          ></services-module>
        `;

      case 'backups':
        return html`
          <backups-module
            .config=${this.config}
            @config-change=${this.handleConfigChange}
          ></backups-module>
        `;

      case 'advanced':
        return html`
          <div class="module-content">
            <h3>Advanced Configuration</h3>
            <p>Advanced configuration options will be available in a future update.</p>

            ${this.config ? html`
              <details style="margin-top: 20px;">
                <summary style="cursor: pointer; font-weight: 500;">
                  View Current Configuration (Debug)
                </summary>
                <pre style="background: #f5f5f7; padding: 16px; border-radius: 8px; overflow-x: auto; margin-top: 8px; font-size: 12px;">
${JSON.stringify(this.config, null, 2)}
                </pre>
              </details>
            ` : ''}
          </div>
        `;

      case 'status':
        return html`
          <status-module
            .rebuildStatus=${this.rebuildStatus}
            .systemHealth=${this.systemHealth}
            .buildLogs=${this.buildLogs}
          ></status-module>
        `;

      default:
        return html`
          <div class="module-content">
            <h3>${this.getCurrentModuleTitle()} Configuration</h3>
            <p>This module is under construction.</p>
          </div>
        `;
    }
  }

  render() {
    // Show full-screen loading spinner on initial load
    if (this.loading) {
      return html`
        <div class="fullscreen-loading">
          <div class="loading-spinner"></div>
          <div class="loading-text">Loading configuration...</div>
        </div>
      `;
    }

    // Group modules by section
    const sections = {};
    this.modules.forEach(module => {
      if (!sections[module.section]) {
        sections[module.section] = [];
      }
      sections[module.section].push(module);
    });

    return html`
      <div class="admin-container">
        <!-- Sidebar -->
        <div class="sidebar ${this.sidebarCollapsed ? 'collapsed' : ''}">
          <div class="sidebar-header">
            <h1>HomeFree</h1>
            <button class="collapse-btn" @click=${this.toggleSidebar}>
              ${this.sidebarCollapsed ? '→' : '←'}
            </button>
          </div>

          <nav class="nav-menu">
            ${Object.entries(sections).map(([section, modules]) => html`
              <div class="nav-section-title">${section}</div>
              ${modules.map(module => html`
                <div
                  class="nav-item ${this.currentModule === module.id ? 'active' : ''} ${module.id === 'status' && (this.statusFlashing || this.statusNeedsAttention) ? 'flashing' : ''}"
                  @click=${() => this.handleModuleClick(module.id)}
                >
                  <span class="nav-item-icon">${module.icon}</span>
                  <span class="nav-item-text">${module.title}</span>
                  ${module.id === 'status' ? html`
                    <span class="status-badge ${this.getStatusBadgeClass()}">
                      ${this.rebuildStatus.running ? html`<div class="spinner-tiny"></div>` : ''}
                    </span>
                  ` : ''}
                </div>
              `)}
            `)}
          </nav>
        </div>

        <!-- Main Content -->
        <div class="main-content">
          <div class="top-bar">
            <h2>${this.getCurrentModuleTitle()}</h2>

            <div class="top-bar-actions">
              <button class="btn" @click=${this.loadConfig}>
                Refresh
              </button>
              <button
                class="btn btn-primary"
                @click=${this.handleSaveChanges}
                ?disabled=${this.rebuildStatus.running}
              >
                Save & Apply
              </button>
            </div>
          </div>

          <div class="content-area">
            ${this.renderModule()}
          </div>
        </div>
      </div>

      <!-- Progress Modal -->
      <progress-modal></progress-modal>

      <!-- Toast Notifications Container -->
      <div class="toast-container">
        ${this.toasts.map(toast => html`
          <toast-notification
            .message=${toast.message}
            .type=${toast.type}
            .duration=${toast.duration}
            @toast-close=${() => this.removeToast(toast.id)}
          ></toast-notification>
        `)}
      </div>
    `;
  }
}

customElements.define('admin-app', AdminApp);
