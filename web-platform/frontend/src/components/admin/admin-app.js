import { LitElement, html, css } from 'lit';
import { getCurrentConfig, validateConfig, previewConfigChanges, applyConfigChanges, getServiceState, saveConfigChanges, getConfigDirty, getClosureId, getCurrentUser } from '../../api/client.js';
import { handleSignOut } from '../../shared/auth.js';
import './modules/system-module.js';
import './modules/network-module.js';
import './modules/dns-module.js';
import './modules/mounts-module.js';
import './modules/extra-proxies-module.js';
import './modules/services-module.js';
import './modules/backups-module.js';
import './modules/sso-module.js';
import './modules/users-module.js';
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
    statusNeedsAttention: { type: Boolean }, // Persistent flash until user clicks Status
    hasAuthorizedKeys: { type: Boolean }, // Whether SSH keys are configured for secrets management
    serviceReloading: { type: Boolean }, // Whether admin-api is restarting
    serviceReloadMessage: { type: String }, // Message to show during reload
    saveStatus: { type: String },          // 'idle' | 'saving' | 'saved' | 'error'
    saveError: { type: String },           // First error message from a failed save, if any
    hasUnappliedChanges: { type: Boolean }, // Whether there are unapplied changes on disk
    updateAvailable: { type: Boolean },    // System closure changed since page-load — UI is stale
    currentUser: { type: Object },         // {username, is_admin_user, admin_username} from /api/users/me
    userMenuOpen: { type: Boolean, state: true },
  };

  static styles = css`
    :host {
      display: block;
      width: 100%;
      height: 100vh;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      color: var(--hf-text);
      background: var(--hf-bg);
      color-scheme: dark;

      --hf-bg:           #0a0a0a;
      --hf-surface:      #111111;
      --hf-surface-2:    #1a1a1a;
      --hf-surface-3:    #242424;
      --hf-border:       #222222;
      --hf-border-2:     #2e2e2e;
      --hf-text:         #ededed;
      --hf-text-muted:   #888888;
      --hf-text-subtle:  #555555;
      --hf-accent:       #6366f1;
      --hf-accent-hover: #5558e0;
      --hf-accent-soft:  rgba(99, 102, 241, 0.15);
      --hf-ok:           #10b981;
      --hf-warn:         #f59e0b;
      --hf-err:          #ef4444;
      --hf-focus-ring:   rgba(99, 102, 241, 0.4);
      --hf-shadow:       0 1px 3px rgba(0, 0, 0, 0.4);
      --hf-shadow-lg:    0 8px 32px rgba(0, 0, 0, 0.6);
    }

    .admin-container {
      display: flex;
      height: 100%;
    }

    /* Sidebar */
    .sidebar {
      width: 260px;
      background: var(--hf-surface);
      border-right: 1px solid var(--hf-border);
      color: var(--hf-text);
      display: flex;
      flex-direction: column;
      transition: width 0.3s ease;
      overflow-x: hidden;
    }

    .sidebar.collapsed {
      width: 70px;
    }

    .sidebar-header {
      height: 64px;
      padding: 0 20px;
      border-bottom: 1px solid var(--hf-border);
      display: flex;
      align-items: center;
      justify-content: space-between;
      flex-shrink: 0;
    }

    .sidebar.collapsed .sidebar-header h1 {
      display: none;
    }

    .sidebar-header h1 {
      margin: 0;
      font-size: 20px;
      font-weight: 600;
      white-space: nowrap;
      color: var(--hf-text);
      letter-spacing: -0.01em;
    }

    .collapse-btn {
      background: var(--hf-surface-2);
      border: 1px solid var(--hf-border);
      color: var(--hf-text-muted);
      width: 32px;
      height: 32px;
      border-radius: 6px;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
      transition: all 0.15s;
    }

    .collapse-btn:hover {
      background: var(--hf-surface-3);
      color: var(--hf-text);
    }

    .nav-menu {
      flex: 1;
      padding: 16px 0;
      overflow-y: auto;
    }

    .nav-item {
      display: flex;
      align-items: center;
      padding: 10px 20px;
      color: var(--hf-text-muted);
      text-decoration: none;
      cursor: pointer;
      transition: all 0.15s;
      border-left: 2px solid transparent;
      white-space: nowrap;
    }

    .nav-item:hover {
      background: var(--hf-surface-2);
      color: var(--hf-text);
    }

    .nav-item.active {
      background: var(--hf-surface-2);
      color: var(--hf-text);
      border-left-color: var(--hf-accent);
    }

    .nav-item-icon {
      width: 20px;
      margin-right: 12px;
      font-size: 16px;
      flex-shrink: 0;
      filter: grayscale(0.4);
    }

    .nav-item.active .nav-item-icon {
      filter: none;
    }

    .sidebar.collapsed .nav-item-text {
      display: none;
    }

    .nav-section-title {
      padding: 20px 20px 8px 20px;
      font-size: 10px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      color: var(--hf-text-subtle);
      white-space: nowrap;
      overflow: hidden;
    }

    /* When the sidebar is collapsed, replace the section title text with
       a divider line so each section's icons stay vertically aligned with
       their expanded position. The container keeps the same vertical
       footprint as the expanded title (20px top + ~14px line + 8px bottom). */
    .sidebar.collapsed .nav-section-title {
      color: transparent;
      padding: 20px 12px 8px 12px;
      position: relative;
    }

    .sidebar.collapsed .nav-section-title::after {
      content: '';
      position: absolute;
      left: 12px;
      right: 12px;
      top: 50%;
      height: 1px;
      background: var(--hf-border);
    }

    /* Main Content */
    .main-content {
      flex: 1;
      display: flex;
      flex-direction: column;
      background: var(--hf-bg);
      overflow: hidden;
    }

    .top-bar {
      height: 64px;
      background: var(--hf-surface);
      border-bottom: 1px solid var(--hf-border);
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0 24px;
    }

    .top-bar-title {
      display: flex;
      align-items: center;
      gap: 16px;
      min-width: 0;
    }

    .top-bar h2 {
      margin: 0;
      font-size: 20px;
      font-weight: 600;
      color: var(--hf-text);
      letter-spacing: -0.01em;
    }

    .top-bar-actions {
      display: flex;
      gap: 8px;
      align-items: center;
    }

    /* Sidebar Apply footer — pinned at the bottom by flex layout.
       Pushes itself down by giving nav a flex: 1 above. */
    .sidebar-footer {
      margin-top: auto;
      padding: 12px;
      border-top: 1px solid var(--hf-border);
      flex-shrink: 0;
    }
    .sidebar.collapsed .sidebar-footer {
      padding: 8px;
    }
    .sidebar-footer .apply-btn {
      width: 100%;
      padding: 10px 14px;
      font-size: 14px;
      font-weight: 500;
      border-radius: 6px;
      border: 1px solid var(--hf-accent);
      background: var(--hf-accent);
      color: white;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
      transition: opacity 0.15s;
    }
    .sidebar-footer .apply-btn:hover:not(:disabled) {
      opacity: 0.9;
    }
    .sidebar-footer .apply-btn:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }
    .sidebar.collapsed .sidebar-footer .apply-btn-text {
      display: none;
    }
    /* When collapsed, the "Applying…" text next to the spinner is
       display:none, but .btn-spinner carries a margin-right: 8px
       (intended to space it from the trailing text). With the text
       hidden, that margin pushes the spinner left of center inside
       the icon-only button. Drop the margin in the collapsed case. */
    .sidebar.collapsed .sidebar-footer .apply-btn .btn-spinner {
      margin-right: 0;
    }

    /* User menu in the top bar */
    .user-menu-wrap {
      position: relative;
    }
    .user-menu-trigger {
      width: 36px;
      height: 36px;
      border-radius: 50%;
      border: 1px solid var(--hf-border-2);
      background: var(--hf-surface);
      color: var(--hf-text);
      font-size: 14px;
      font-weight: 600;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      transition: background 0.15s, border-color 0.15s;
    }
    .user-menu-trigger:hover,
    .user-menu-trigger.open {
      background: var(--hf-surface-2);
      border-color: var(--hf-accent);
    }
    .user-menu-popover {
      position: absolute;
      top: calc(100% + 6px);
      right: 0;
      min-width: 200px;
      background: var(--hf-surface);
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      box-shadow: var(--hf-shadow-lg);
      z-index: 100;
      overflow: hidden;
    }
    .user-menu-header {
      padding: 12px 14px;
      border-bottom: 1px solid var(--hf-border);
      font-size: 13px;
    }
    .user-menu-header .user-name {
      color: var(--hf-text);
      font-weight: 500;
    }
    .user-menu-header .user-role {
      color: var(--hf-text-muted);
      font-size: 11px;
      margin-top: 2px;
    }
    .user-menu-item {
      display: block;
      padding: 10px 14px;
      color: var(--hf-text);
      text-decoration: none;
      font-size: 14px;
      background: none;
      border: none;
      width: 100%;
      text-align: left;
      cursor: pointer;
      font-family: inherit;
    }
    .user-menu-item:hover {
      background: var(--hf-surface-2);
    }

    /* Save status indicator */
    .save-indicator {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      font-size: 12px;
      color: var(--hf-text-muted);
      font-weight: 500;
      padding: 4px 10px;
      border-radius: 999px;
      background: var(--hf-surface-2);
      border: 1px solid var(--hf-border);
      transition: all 0.2s;
      white-space: nowrap;
    }

    .save-indicator.saving {
      color: var(--hf-text);
    }

    .save-indicator.saved {
      color: var(--hf-ok);
    }

    .save-indicator.error {
      color: var(--hf-err);
      border-color: var(--hf-err);
    }

    .save-dot {
      width: 6px;
      height: 6px;
      border-radius: 50%;
      background: currentColor;
      flex-shrink: 0;
    }

    .save-spinner {
      width: 10px;
      height: 10px;
      border: 1.5px solid var(--hf-border-2);
      border-top-color: var(--hf-accent);
      border-radius: 50%;
      animation: spin 0.7s linear infinite;
      flex-shrink: 0;
    }

    .btn {
      padding: 7px 14px;
      border-radius: 6px;
      border: 1px solid var(--hf-border-2);
      background: var(--hf-surface-2);
      color: var(--hf-text);
      font-size: 13px;
      font-weight: 500;
      cursor: pointer;
      transition: all 0.15s;
    }

    .btn:hover {
      background: var(--hf-surface-3);
      border-color: var(--hf-text-subtle);
    }

    .btn-primary {
      background: var(--hf-accent);
      color: white;
      border-color: var(--hf-accent);
    }

    .btn-primary:hover {
      background: var(--hf-accent-hover);
      border-color: var(--hf-accent-hover);
    }

    .btn:disabled,
    .btn:disabled:hover,
    .btn-primary:disabled,
    .btn-primary:disabled:hover {
      opacity: 0.4;
      cursor: not-allowed;
      background: var(--hf-surface-2);
      border-color: var(--hf-border-2);
      color: var(--hf-text-muted);
    }

    @keyframes spin {
      to { transform: rotate(360deg); }
    }

    .spinner-tiny {
      width: 10px;
      height: 10px;
      border: 2px solid var(--hf-border-2);
      border-top-color: var(--hf-accent);
      border-radius: 50%;
      animation: spin 1s linear infinite;
    }

    /* Spinner sized + colored to read inside the primary button. */
    .btn-spinner {
      display: inline-block;
      width: 12px;
      height: 12px;
      border: 2px solid rgba(255, 255, 255, 0.35);
      border-top-color: #fff;
      border-radius: 50%;
      animation: spin 0.8s linear infinite;
      vertical-align: -2px;
      margin-right: 8px;
    }

    .btn:disabled .btn-spinner {
      border-color: var(--hf-text-subtle);
      border-top-color: var(--hf-text-muted);
    }

    .status-badge {
      margin-left: auto;
      width: 8px;
      height: 8px;
      border-radius: 50%;
      flex-shrink: 0;
    }

    .status-badge.healthy {
      background: var(--hf-ok);
      box-shadow: 0 0 6px rgba(16, 185, 129, 0.5);
    }

    .status-badge.unhealthy {
      background: var(--hf-err);
      box-shadow: 0 0 6px rgba(239, 68, 68, 0.6);
    }

    .status-badge.warning {
      background: var(--hf-warn);
      box-shadow: 0 0 6px rgba(245, 158, 11, 0.5);
    }

    .status-badge.building {
      background: transparent;
      width: auto;
      height: auto;
      box-shadow: none;
    }

    .sidebar.collapsed .status-badge {
      display: none;
    }

    /* Status nav item flashing animation */
    @keyframes statusFlash {
      0%, 100% {
        background: var(--hf-surface-2);
        box-shadow: 0 0 0 0 var(--hf-focus-ring);
      }
      50% {
        background: var(--hf-accent-soft);
        box-shadow: 0 0 12px 2px var(--hf-focus-ring);
      }
    }

    .nav-item.flashing {
      animation: statusFlash 1s ease-in-out infinite;
    }

    .content-area {
      flex: 1;
      overflow-y: auto;
      padding: 24px;
      background: var(--hf-bg);
    }

    .loading-overlay {
      display: flex;
      align-items: center;
      justify-content: center;
      height: 100%;
      font-size: 18px;
      color: var(--hf-text-muted);
    }

    /* Full-screen loading overlay for initial load */
    .fullscreen-loading {
      position: fixed;
      top: 0;
      left: 0;
      width: 100vw;
      height: 100vh;
      background: var(--hf-bg);
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      z-index: 9999;
    }

    .loading-spinner {
      width: 48px;
      height: 48px;
      border: 4px solid var(--hf-border);
      border-top-color: var(--hf-accent);
      border-radius: 50%;
      animation: spin 1s linear infinite;
      margin-bottom: 16px;
    }

    .loading-text {
      font-size: 14px;
      color: var(--hf-text-muted);
      font-weight: 500;
    }

    .error-message {
      background: rgba(239, 68, 68, 0.08);
      color: var(--hf-err);
      padding: 16px;
      border-radius: 8px;
      border-left: 3px solid var(--hf-err);
      margin: 32px;
    }

    /* Service reload overlay */
    .service-reload-overlay {
      position: fixed;
      top: 0;
      left: 0;
      width: 100vw;
      height: 100vh;
      background: rgba(0, 0, 0, 0.75);
      display: flex;
      align-items: center;
      justify-content: center;
      z-index: 10000;
      backdrop-filter: blur(6px);
    }

    .service-reload-content {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border);
      border-radius: 12px;
      padding: 32px;
      text-align: center;
      box-shadow: var(--hf-shadow-lg);
      max-width: 400px;
    }

    .service-reload-spinner {
      width: 48px;
      height: 48px;
      border: 4px solid var(--hf-border);
      border-top-color: var(--hf-accent);
      border-radius: 50%;
      animation: spin 1s linear infinite;
      margin: 0 auto 16px;
    }

    .service-reload-title {
      font-size: 18px;
      font-weight: 600;
      color: var(--hf-text);
      margin-bottom: 8px;
    }

    .service-reload-message {
      font-size: 14px;
      color: var(--hf-text-muted);
    }

    .module-content {
      background: var(--hf-bg);
      border-radius: 0;
      padding: 24px;
      box-shadow: none;
      min-height: 100%;
      color: var(--hf-text);
    }

    /* Toast container positioning */
    .toast-container {
      position: fixed;
      bottom: 24px;
      right: 24px;
      z-index: 10001;
      display: flex;
      flex-direction: column;
      gap: 8px;
    }

    /* JSON config viewer (Advanced tab) */
    .config-details {
      margin-top: 20px;
    }

    .config-details > summary {
      cursor: pointer;
      font-weight: 500;
      color: var(--hf-text);
      user-select: none;
      padding: 4px 0;
    }

    .config-details > summary:hover {
      color: var(--hf-accent);
    }

    .config-json {
      background: var(--hf-surface);
      color: var(--hf-text);
      padding: 16px;
      border-radius: 8px;
      overflow-x: auto;
      margin-top: 8px;
      font-size: 12.5px;
      line-height: 1.5;
      border: 1px solid var(--hf-border);
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
      tab-size: 2;
      white-space: pre;
    }

    .config-json .json-key   { color: #93c5fd; }   /* light blue */
    .config-json .json-str   { color: #86efac; }   /* light green */
    .config-json .json-num   { color: #fcd34d; }   /* amber */
    .config-json .json-bool  { color: #f0abfc; }   /* magenta */
    .config-json .json-null  { color: var(--hf-text-muted); font-style: italic; }

    /* Update-available banner: shown when the deployed system closure
       changes underneath an open tab (a rebuild succeeded after this tab
       loaded). Sits above the admin layout. */
    .update-banner {
      height: 40px;
      background: var(--hf-accent);
      color: white;
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 12px;
      font-size: 13px;
      font-weight: 500;
      box-shadow: 0 1px 3px rgba(0, 0, 0, 0.4);
      flex-shrink: 0;
    }

    .update-banner-icon {
      font-size: 14px;
      animation: spin 3s linear infinite;
      animation-play-state: paused;
    }

    .update-banner:hover .update-banner-icon {
      animation-play-state: running;
    }

    .update-banner-btn {
      background: rgba(255, 255, 255, 0.18);
      border: 1px solid rgba(255, 255, 255, 0.3);
      color: white;
      padding: 4px 12px;
      border-radius: 4px;
      font-size: 12px;
      font-weight: 600;
      cursor: pointer;
      transition: background 0.15s;
    }

    .update-banner-btn:hover {
      background: rgba(255, 255, 255, 0.3);
    }

    .admin-container.with-banner {
      height: calc(100% - 40px);
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
    this.hasAuthorizedKeys = false;
    this.serviceReloading = false;
    this.currentUser = null;
    this.userMenuOpen = false;
    this._closeUserMenuOnOutsideClick = null;
    this.serviceReloadMessage = '';
    this.serviceStateCheckInterval = null;

    // Auto-save state
    this.saveStatus = 'idle';        // idle | saving | saved | error
    this.saveError = '';
    this._saveTimer = null;
    this._saveInFlight = false;
    this._savePending = false;       // queue one trailing save while in-flight
    this.SAVE_DEBOUNCE_MS = 800;
    this._savedFlashTimer = null;

    // Apply / dirty state
    this.hasUnappliedChanges = false;
    this.dirtyPollInterval = null;

    // System closure tracking — detects when the deployed code changed
    // out from under us (a rebuild succeeded, the frontend bundle Caddy
    // serves is now newer than what this tab loaded). When that happens,
    // we surface a "Refresh" banner so the user can pick up new code.
    this._initialClosureId = null;
    this.updateAvailable = false;
    this.closureIdPollInterval = null;

    // Navigation modules.
    // Three sections: System (the host + its OS), Applications
    // (services + their backups), Identity (users + SSO). The item
    // formerly titled "System" is renamed "Host" to avoid colliding
    // with the section name.
    this.modules = [
      {
        id: 'system',
        title: 'Host',
        icon: '⚙️',
        section: 'System'
      },
      {
        id: 'network',
        title: 'Network',
        icon: '🌐',
        section: 'System'
      },
      {
        id: 'dns',
        title: 'DNS',
        icon: '🔍',
        section: 'System'
      },
      {
        id: 'mounts',
        title: 'Mounts',
        icon: '🗂️',
        section: 'System'
      },
      {
        id: 'extra-proxies',
        title: 'External Proxies',
        icon: '🔌',
        section: 'System'
      },
      {
        id: 'status',
        title: 'Status',
        icon: '📊',
        section: 'System'
      },
      {
        id: 'advanced',
        title: 'Advanced',
        icon: '🔧',
        section: 'System'
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
        section: 'Applications'
      },
      {
        id: 'users',
        title: 'Users',
        icon: '👥',
        section: 'Identity'
      },
      {
        id: 'sso',
        title: 'SSO',
        icon: '🔐',
        section: 'Identity'
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
      // Clear polling intervals
      if (this.statusPollInterval) {
        clearInterval(this.statusPollInterval);
      }
      if (this.serviceStateCheckInterval) {
        clearTimeout(this.serviceStateCheckInterval);
      }
    };
    window.addEventListener('beforeunload', this.beforeUnloadHandler);

    // Read initial route from hash
    this.loadRouteFromHash();

    // Listen for hash changes (back/forward buttons)
    window.addEventListener('hashchange', () => {
      this.loadRouteFromHash();
    });

    // Check service availability before loading config
    await this.checkServiceAvailability();

    // Load the currently-signed-in user so we can show them in the
    // top-bar user menu. Non-blocking — falls back to a generic avatar.
    getCurrentUser()
      .then((u) => { this.currentUser = u; })
      .catch(() => {});

    await this.loadConfig();

    // Load SSH key status for secrets management
    await this.loadSSHKeyStatus();

    // Check if a rebuild is already in progress
    await this.checkRebuildStatus();

    // Start continuous polling to keep status icon up-to-date
    // This ensures the icon updates even after backend restarts or external rebuilds
    this.statusPollInterval = setInterval(() => this.checkRebuildStatus(), 3000);

    // Initial dirty check + periodic refresh for the Apply button enabled state
    this.checkConfigDirty();
    this.dirtyPollInterval = setInterval(() => this.checkConfigDirty(), 5000);

    // Capture the system closure id at page-load time, then poll for
    // changes. When it shifts, the deployed UI is newer than what this
    // tab has loaded — show a Refresh banner.
    this.initClosureTracking();
    this.closureIdPollInterval = setInterval(() => this.checkClosureId(), 5000);
  }

  disconnectedCallback() {
    super.disconnectedCallback();

    // Remove beforeunload listener
    if (this.beforeUnloadHandler) {
      window.removeEventListener('beforeunload', this.beforeUnloadHandler);
    }

    // Clean up polling intervals
    if (this.statusPollInterval) {
      clearInterval(this.statusPollInterval);
    }
    if (this.serviceStateCheckInterval) {
      clearTimeout(this.serviceStateCheckInterval);
    }
    if (this.dirtyPollInterval) {
      clearInterval(this.dirtyPollInterval);
    }
    if (this.closureIdPollInterval) {
      clearInterval(this.closureIdPollInterval);
    }
    if (this._saveTimer) {
      clearTimeout(this._saveTimer);
    }
    if (this._savedFlashTimer) {
      clearTimeout(this._savedFlashTimer);
    }
    if (this._closeUserMenuOnOutsideClick) {
      document.removeEventListener('mousedown',
        this._closeUserMenuOnOutsideClick, true);
      this._closeUserMenuOnOutsideClick = null;
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

  async loadSSHKeyStatus() {
    try {
      const response = await fetch('/api/secrets/keys/user');
      if (!response.ok) {
        console.error('Failed to load SSH key status:', response.status);
        this.hasAuthorizedKeys = false;
        return;
      }
      const data = await response.json();
      this.hasAuthorizedKeys = data.exists || false;
    } catch (error) {
      console.error('Error loading SSH key status:', error);
      this.hasAuthorizedKeys = false;
    }
  }

  async checkServiceAvailability() {
    /**
     * Check if admin-api service is reloading/restarting
     * Polls /api/service-state and shows overlay if status is 'restarting'
     */
    try {
      const state = await getServiceState();

      if (state.admin_api_status === 'restarting') {
        this.serviceReloading = true;
        this.serviceReloadMessage = state.message || 'Admin API is restarting...';

        // Poll again in 2 seconds
        if (this.serviceStateCheckInterval) {
          clearTimeout(this.serviceStateCheckInterval);
        }
        this.serviceStateCheckInterval = setTimeout(() => {
          this.checkServiceAvailability();
        }, 2000);
      } else {
        // Service is operational
        this.serviceReloading = false;
        this.serviceReloadMessage = '';

        // Clear any polling
        if (this.serviceStateCheckInterval) {
          clearTimeout(this.serviceStateCheckInterval);
          this.serviceStateCheckInterval = null;
        }
      }
    } catch (error) {
      // Backend is completely unavailable - show loading state
      console.warn('Service state check failed:', error);
      this.serviceReloading = true;
      this.serviceReloadMessage = 'Connecting to admin API...';

      // Retry in 2 seconds
      if (this.serviceStateCheckInterval) {
        clearTimeout(this.serviceStateCheckInterval);
      }
      this.serviceStateCheckInterval = setTimeout(() => {
        this.checkServiceAvailability();
      }, 2000);
    }
  }

  async checkRebuildStatus() {
    try {
      // include_history=1 returns the full log on this initial fetch, so a
      // page reload mid-build (or after one finished) hydrates the build
      // logs panel instead of showing empty.
      const response = await fetch('/api/config/rebuild-status?include_history=1', {
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

        // Hydrate logs from the include_history=1 fetch so we don't show
        // an empty pane while reattaching to an in-progress rebuild.
        if (status.output && status.output.trim()) {
          this.buildLogs = status.output.trim().split('\n').filter(l => l.trim());
        }

        // Start polling to show live updates (only if not already active)
        if (!this._pollRebuildActive) {
          this._pollRebuildActive = true;
          this.pollRebuildStatus({ preserveLogs: true });
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

  /**
   * Handle SSH keys changed event from system-module
   * Note: SSH keys are only available for secrets management after Save & Apply
   * So we don't refresh here - it will refresh after successful rebuild
   */
  handleSSHKeysChanged() {
    // No-op: SSH key status will be refreshed after rebuild completes
    // The key must be saved to the system config before it can be used for secrets
  }

  toggleSidebar() {
    this.sidebarCollapsed = !this.sidebarCollapsed;
  }

  /** Toggle the top-bar user menu. Sets up an outside-click handler
   *  so clicking anywhere else dismisses the popover. */
  toggleUserMenu(e) {
    if (e) e.stopPropagation();
    this.userMenuOpen = !this.userMenuOpen;
    if (this.userMenuOpen) {
      this._closeUserMenuOnOutsideClick = (evt) => {
        const path = evt.composedPath();
        const trigger = this.renderRoot?.querySelector('.user-menu-wrap');
        if (trigger && !path.includes(trigger)) {
          this.userMenuOpen = false;
          document.removeEventListener('mousedown',
            this._closeUserMenuOnOutsideClick, true);
          this._closeUserMenuOnOutsideClick = null;
        }
      };
      // Defer registration so the click that opened the menu doesn't
      // immediately close it.
      setTimeout(() => {
        document.addEventListener('mousedown',
          this._closeUserMenuOnOutsideClick, true);
      }, 0);
    } else if (this._closeUserMenuOnOutsideClick) {
      document.removeEventListener('mousedown',
        this._closeUserMenuOnOutsideClick, true);
      this._closeUserMenuOnOutsideClick = null;
    }
  }

  getCurrentModuleTitle() {
    const module = this.modules.find(m => m.id === this.currentModule);
    return module ? module.title : 'HomeFree Admin';
  }

  renderSaveIndicator() {
    switch (this.saveStatus) {
      case 'saving':
        return html`
          <span class="save-indicator saving">
            <span class="save-spinner"></span>
            Saving…
          </span>
        `;
      case 'saved':
        return html`
          <span class="save-indicator saved">
            <span class="save-dot"></span>
            Saved
          </span>
        `;
      case 'error':
        return html`
          <span class="save-indicator error" title="${this.saveError}">
            <span class="save-dot"></span>
            Save error: ${this.saveError || 'unknown'}
          </span>
        `;
      case 'idle':
      default:
        return '';
    }
  }

  /**
   * Lightweight JSON syntax highlighter. Returns HTML with span class
   * markers; pair with .config-json CSS rules for actual coloring. Input
   * MUST already be a stringified JSON value (passed through
   * JSON.stringify) so we can rely on its quoting and escaping.
   */
  highlightJson(jsonStr) {
    const escape = s => s
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;');
    return escape(jsonStr).replace(
      /("(?:\\.|[^"\\])*"(?:\s*:)?|\b(?:true|false|null)\b|-?\d+(?:\.\d+)?(?:[eE][+\-]?\d+)?)/g,
      (match) => {
        let cls = 'json-num';
        if (/^"/.test(match)) {
          cls = /:$/.test(match) ? 'json-key' : 'json-str';
        } else if (/^(?:true|false)$/.test(match)) {
          cls = 'json-bool';
        } else if (/^null$/.test(match)) {
          cls = 'json-null';
        }
        return `<span class="${cls}">${match}</span>`;
      }
    );
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
    this.scheduleAutoSave();
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
    this.scheduleAutoSave();
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
    this.scheduleAutoSave();
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
    this.scheduleAutoSave();
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
    this.scheduleAutoSave();
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
    this.scheduleAutoSave();
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
    this.scheduleAutoSave();
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
    this.scheduleAutoSave();
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
    this.scheduleAutoSave();
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

  /**
   * Schedule a debounced auto-save. Called after every config mutation.
   * If a save is already in flight, queues one trailing save.
   */
  scheduleAutoSave() {
    if (this._saveTimer) {
      clearTimeout(this._saveTimer);
    }
    // Reset "Saved" flash if we're getting more edits
    if (this._savedFlashTimer) {
      clearTimeout(this._savedFlashTimer);
      this._savedFlashTimer = null;
    }
    this._saveTimer = setTimeout(() => this.autoSave(), this.SAVE_DEBOUNCE_MS);
  }

  async autoSave() {
    if (this._saveInFlight) {
      // Coalesce: schedule one trailing save once the current one returns
      this._savePending = true;
      return;
    }
    this._saveInFlight = true;
    this.saveStatus = 'saving';
    this.saveError = '';
    this.requestUpdate();

    try {
      const configToSave = this.getMergedConfig();
      const result = await saveConfigChanges(configToSave);
      if (result.success) {
        this.saveStatus = 'saved';
        this.saveError = '';
        // Mark as having unapplied changes (we just wrote new content to disk)
        this.hasUnappliedChanges = true;
        // Refresh dirty state from server in case other clients are editing
        this.checkConfigDirty();
        // Auto-fade the "Saved" pill back to idle after a moment
        if (this._savedFlashTimer) clearTimeout(this._savedFlashTimer);
        this._savedFlashTimer = setTimeout(() => {
          if (this.saveStatus === 'saved') {
            this.saveStatus = 'idle';
            this.requestUpdate();
          }
        }, 1800);
      } else {
        this.saveStatus = 'error';
        this.saveError = (result.errors && result.errors[0]) || result.message || 'Save failed';
      }
    } catch (error) {
      console.error('Auto-save failed:', error);
      this.saveStatus = 'error';
      this.saveError = error.message || 'Network error';
    } finally {
      this._saveInFlight = false;
      this.requestUpdate();
      // Trailing save if more edits came in while we were saving
      if (this._savePending) {
        this._savePending = false;
        this.scheduleAutoSave();
      }
    }
  }

  async checkConfigDirty() {
    try {
      const result = await getConfigDirty();
      this.hasUnappliedChanges = !!result.dirty;
      this.requestUpdate();
    } catch (error) {
      // Don't spam logs while admin-api is restarting
      if (error.name !== 'AbortError') {
        console.warn('Failed to check config dirty state:', error.message);
      }
    }
  }

  /**
   * Capture the current system closure id at page-load. Subsequent polls
   * compare against this value; if it changes, new code has been deployed
   * and the user should reload.
   */
  async initClosureTracking() {
    try {
      const result = await getClosureId();
      this._initialClosureId = result.closure_id || null;
    } catch (error) {
      // Non-fatal: skip update detection. Older backends without this
      // endpoint will trip this on every poll, which we suppress below.
      this._initialClosureId = null;
    }
  }

  async checkClosureId() {
    if (!this._initialClosureId) return;
    try {
      const result = await getClosureId();
      const current = result.closure_id || null;
      if (current && current !== this._initialClosureId) {
        this.updateAvailable = true;
        // Stop polling once we know — no point re-asking.
        if (this.closureIdPollInterval) {
          clearInterval(this.closureIdPollInterval);
          this.closureIdPollInterval = null;
        }
      }
    } catch (error) {
      // Transient — admin-api restarting, etc. Just skip this tick.
    }
  }

  handleRefreshForUpdate() {
    window.location.reload();
  }

  async handleApplyChanges() {
    if (this.rebuildStatus.running) {
      this.showToast('A rebuild is already in progress.', 'warning', 4000);
      return;
    }
    try {
      // Flush any pending save first so we apply the latest in-memory state
      if (this._saveTimer) {
        clearTimeout(this._saveTimer);
        this._saveTimer = null;
      }
      if (this._saveInFlight || this.saveStatus === 'saving') {
        // Wait briefly for the in-flight save to settle
        await new Promise(resolve => setTimeout(resolve, 100));
      }
      // Force a synchronous save now if we have pending in-memory changes
      if (this.dirtyModules.size > 0 || this.saveStatus === 'error') {
        await this.autoSave();
      }

      const configToApply = this.getMergedConfig();

      const validation = await validateConfig(configToApply);
      if (!validation.valid) {
        const firstError = validation.errors[0] || 'Validation failed';
        this.showToast(`Validation failed: ${firstError}`, 'error', 7000);
        return;
      }

      if (validation.warnings && validation.warnings.length > 0) {
        const firstWarning = validation.warnings[0];
        this.showToast(`Warning: ${firstWarning}`, 'warning', 5000);
      }

      const result = await applyConfigChanges(configToApply);

      if (!result.success) {
        this.showToast(`Failed to apply: ${result.message || 'Unknown error'}`, 'error', 7000);
        return;
      }

      this.showToast('Applying configuration…', 'success', 4000);
      this.flashStatus(2000);

      this.dirtyModules.clear();
      this.updateMergedConfig();

      this.rebuildStatus = {
        running: true,
        message: 'Starting system rebuild...',
        lastUpdate: null
      };

      this.pollRebuildStatus();

    } catch (error) {
      console.error('Error applying changes:', error);
      this.showToast(`Error: ${error.message || 'Unknown error'}`, 'error', 7000);
    }
  }

  async pollRebuildStatus(opts = {}) {
    // Reset build logs ONLY when starting a NEW poll (not on repeated calls from statusPollInterval)
    // The flag ensures we only reset once per build. When reattaching to an
    // in-progress rebuild after a reload, pass {preserveLogs:true} so the
    // history we just fetched isn't wiped before incremental polling starts.
    if (!opts.preserveLogs) {
      this.buildLogs = [];
    }

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
                // Reload SSH key status in case user added keys
                await this.loadSSHKeyStatus();
                // Now that serverConfig is updated, clear optimistic updates
                this.pendingConfig = {};
                this.updateMergedConfig();
                // Refresh applied/dirty state — the backend wrote the
                // applied-config marker, so the Apply button should disable.
                this.checkConfigDirty();
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
                // Reload SSH key status in case user added keys
                await this.loadSSHKeyStatus();
                // Now that serverConfig is updated, clear optimistic updates
                this.pendingConfig = {};
                this.updateMergedConfig();
                this.checkConfigDirty();
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
          } else {
            // Backend says not-running but doesn't know the exit code.
            // Don't leave the spinner stuck — clear it and report
            // an indeterminate completion. Refresh dirty state so the
            // Apply button gets re-enabled if the system is out of sync.
            this.systemHealth = 'warning';
            this.rebuildStatus = {
              running: false,
              message: 'Rebuild completed (status unknown)',
              lastUpdate: { success: null, warning: true }
            };
            this.checkConfigDirty();
          }

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
            @ssh-keys-changed=${this.handleSSHKeysChanged}
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

      case 'mounts':
        return html`
          <mounts-module
            .config=${this.config}
            @config-change=${this.handleConfigChange}
          ></mounts-module>
        `;

      case 'extra-proxies':
        return html`
          <extra-proxies-module
            .config=${this.config}
            @config-change=${this.handleConfigChange}
          ></extra-proxies-module>
        `;

      case 'services':
        return html`
          <services-module
            .serverConfig=${this.serverConfig}
            .pendingConfig=${this.pendingConfig}
            .hasAuthorizedKeys=${this.hasAuthorizedKeys}
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
            .hasAuthorizedKeys=${this.hasAuthorizedKeys}
            @config-change=${this.handleConfigChange}
          ></backups-module>
        `;

      case 'sso':
        return html`
          <sso-module
            .config=${this.config}
            @config-change=${this.handleConfigChange}
          ></sso-module>
        `;

      case 'users':
        return html`
          <users-module></users-module>
        `;

      case 'advanced':
        return html`
          <div class="module-content">
            <h3>Advanced Configuration</h3>
            <p>Advanced configuration options will be available in a future update.</p>

            ${this.config ? html`
              <details open class="config-details">
                <summary>View Current Configuration (Debug)</summary>
                <pre class="config-json"
                     .innerHTML=${this.highlightJson(JSON.stringify(this.config, null, 2))}></pre>
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

  /** Top-right user menu: avatar circle with the signed-in user's
   *  initial, click opens a popover with sign-out. Defensive on
   *  missing currentUser (e.g. /api/users/me failed) — falls back to
   *  a generic "Account" label. */
  _renderUserMenu() {
    const u = this.currentUser;
    const username = u?.username || '';
    const initial = username ? username[0].toUpperCase() : '?';
    const role = u?.is_admin_user ? 'HomeFree admin' : 'Signed in';

    return html`
      <div class="user-menu-wrap">
        <button
          class="user-menu-trigger ${this.userMenuOpen ? 'open' : ''}"
          @click=${this.toggleUserMenu}
          title=${username ? `Signed in as ${username}` : 'Account menu'}
          aria-haspopup="true"
          aria-expanded=${this.userMenuOpen}
        >${initial}</button>

        ${this.userMenuOpen ? html`
          <div class="user-menu-popover">
            <div class="user-menu-header">
              <div class="user-name">${username || 'Account'}</div>
              <div class="user-role">${role}</div>
            </div>
            <a class="user-menu-item" href="#" @click=${handleSignOut}>
              Sign out
            </a>
          </div>
        ` : ''}
      </div>
    `;
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
      ${this.updateAvailable ? html`
        <div class="update-banner" role="status">
          <span class="update-banner-icon">↻</span>
          <span class="update-banner-text">
            New version of HomeFree Admin available
          </span>
          <button class="update-banner-btn" @click=${this.handleRefreshForUpdate}>
            Refresh
          </button>
        </div>
      ` : ''}
      <div class="admin-container ${this.updateAvailable ? 'with-banner' : ''}">
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

          <!-- Apply button pinned to the sidebar bottom. nav-menu has
               flex: 1 so the footer naturally lands here. Title shows
               "Apply" when collapsed since the text is hidden. -->
          <div class="sidebar-footer">
            <button
              class="apply-btn"
              @click=${this.handleApplyChanges}
              ?disabled=${this.rebuildStatus.running}
              title=${this.rebuildStatus.running
                ? 'Rebuild in progress — wait for it to finish before applying again'
                : 'Apply pending configuration'}
            >
              ${this.rebuildStatus.running
                ? html`<span class="btn-spinner"></span><span class="apply-btn-text">Applying…</span>`
                : html`<span class="apply-btn-text">Apply</span>${this.sidebarCollapsed ? html`✓` : ''}`}
            </button>
          </div>
        </div>

        <!-- Main Content -->
        <div class="main-content">
          <div class="top-bar">
            <div class="top-bar-title">
              <h2>${this.getCurrentModuleTitle()}</h2>
              ${this.renderSaveIndicator()}
            </div>

            <div class="top-bar-actions">
              ${this._renderUserMenu()}
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

      <!-- Service Reload Overlay -->
      ${this.serviceReloading ? html`
        <div class="service-reload-overlay">
          <div class="service-reload-content">
            <div class="service-reload-spinner"></div>
            <div class="service-reload-title">Service Restarting</div>
            <div class="service-reload-message">${this.serviceReloadMessage}</div>
          </div>
        </div>
      ` : ''}
    `;
  }
}

customElements.define('admin-app', AdminApp);
