import { LitElement, html, css } from 'lit';
import { getCurrentConfig, validateConfig, previewConfigChanges, applyConfigChanges, getServiceState, saveConfigChanges, getConfigDirty, getAppliedConfig, getClosureId, getCurrentUser, getMode } from '../../api/client.js';
import { handleSignOut } from '../../shared/auth.js';
import { confirmDialog, alertDialog } from '../shared/confirm-dialog.js';
import { themeVars } from '../../shared/theme.js';
import { userMenuStyles, renderUserMenu, profileUrlForCurrentBox } from '../../shared/user-menu.js';
import { surfaceSwitcherStyles, renderSurfaceSwitcher } from '../../shared/surface-switcher.js';
import { shellStyles } from '../../shared/shell.js';
import { navIcon } from '../../shared/icons.js';
import './modules/dashboard-module.js';
import './modules/hardware-module.js';
import './modules/system-module.js';
import './modules/network-module.js';
import './modules/lan-clients-module.js';
import './modules/dns-module.js';
import './modules/mounts-module.js';
import './modules/extra-proxies-module.js';
import './modules/proxied-domains-module.js';
import './modules/services-module.js';
import './modules/backups-module.js';
import './modules/sso-module.js';
import './modules/users-module.js';
import './modules/status-module.js';
import './modules/updates-module.js';
import './modules/abuse-blocking-module.js';
import './modules/developers-module.js';
import '../shared/progress-modal.js';
import '../shared/toast-notification.js';
import './finish-setup-wizard.js';

class AdminApp extends LitElement {
  static properties = {
    serverConfig: { type: Object },    // Actual deployed/server state
    pendingConfig: { type: Object },   // User's uncommitted changes
    dirtyModules: { type: Object },    // Track which modules have unsaved changes
    config: { type: Object },          // Computed merged config (for backward compatibility)
    currentModule: { type: String },
    /**
     * Module-internal route — the part of the hash after the module
     * ID. Example: `#/backups/configuration` → currentModule='backups',
     * currentSubRoute='configuration'. Modules that don't have
     * sub-state ignore this; modules that do (Backups tabs) read it as
     * a prop and emit `sub-route-change` to update it.
     */
    currentSubRoute: { type: String },
    loading: { type: Boolean },
    error: { type: String },
    sidebarCollapsed: { type: Boolean },
    isMobile: { type: Boolean, state: true },
    rebuildStatus: { type: Object },
    buildLogs: { type: Array },        // Build output logs
    systemHealth: { type: String },    // System health status for left nav icon
    toasts: { type: Array },           // Toast notifications stack
    statusFlashing: { type: Boolean }, // Status nav item flash animation
    statusNeedsAttention: { type: Boolean }, // Persistent flash until user clicks Status
    hasAuthorizedKeys: { type: Boolean }, // Whether SSH keys are configured for secrets management
    setupIncomplete: { type: Boolean, state: true }, // Finish-setup wizard not yet completed (authoritative gate)
    pendingSetupItems: { type: Array, state: true }, // Hint: which finish-setup steps remain (for wizard start step)
    // Finish-setup wizard's current step, lifted up here so navigating
    // away from and back to the wizard doesn't reset it to step 0 (the
    // wizard component is destroyed and recreated on each nav change).
    wizardStep: { type: Number, state: true },
    serviceReloading: { type: Boolean }, // Whether admin-api is restarting
    serviceReloadMessage: { type: String }, // Message to show during reload
    saveStatus: { type: String },          // 'idle' | 'saving' | 'saved' | 'error'
    saveError: { type: String },           // First error message from a failed save, if any
    hasUnappliedChanges: { type: Boolean }, // Whether there are unapplied changes on disk
    dirtyReason: { type: String },          // Why the config is dirty (drives the Apply note)
    undeployedPaths: { state: true },       // Set of dotted config paths not yet deployed
    appliedConfig: { state: true },          // Last-DEPLOYED config — baseline for per-row list highlight
    updateAvailable: { type: Boolean },    // System closure changed since page-load — UI is stale
    currentUser: { type: Object },         // {username, is_admin_user, admin_username} from /api/users/me
    userMenuOpen: { type: Boolean, state: true },
    switcherOpen: { type: Boolean, state: true }, // Top-bar surface-switcher popover (narrow widths)
  };

  static styles = [themeVars, userMenuStyles, surfaceSwitcherStyles, shellStyles, css`
    :host {
      display: block;
      width: 100%;
      /* See user-app.js for the 100dvh rationale (mobile browser
         chrome). 100vh fallback first for older browsers. */
      height: 100vh;
      height: 100dvh;
    }

    /* Shell layout (.app-container / sidebar / top-bar / nav-item /
       hamburger / backdrop / mobile media query) lives in
       shared/shell.js and is imported via shellStyles above.
       admin-specific extensions follow. */

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
    /* Small note above the Apply button naming WHY there are undeployed
       changes. Hidden when the sidebar is collapsed (no room for text). */
    /* Clickable note above the Apply button — links to Build & Logs, which
       lists the pending changes. Bare link-button styling. */
    .sidebar-footer .apply-note {
      display: flex;
      align-items: center;
      gap: 6px;
      width: 100%;
      font-size: 12px;
      font-weight: 500;
      font-family: inherit;
      color: var(--hf-warn);
      background: none;
      border: none;
      text-align: left;
      cursor: pointer;
      margin-bottom: 8px;
      padding: 2px;
      line-height: 1.3;
    }
    .sidebar-footer .apply-note:hover .apply-note-text {
      text-decoration: underline;
    }
    .sidebar-footer .apply-note-text {
      flex: 1;
      min-width: 0;
    }
    .sidebar-footer .apply-note-chevron {
      flex-shrink: 0;
      opacity: 0.8;
    }
    .sidebar-footer .apply-note-dot {
      width: 7px;
      height: 7px;
      border-radius: 50%;
      background: currentColor;
      flex-shrink: 0;
    }
    /* The button itself stays the accent CTA; emphasis is modulated by
       opacity + a glow ring so the spinner/contrast context is unchanged.
       Resting (nothing to deploy) is de-emphasized; has-changes lights up. */
    .sidebar-footer .apply-btn {
      width: 100%;
      padding: 10px 14px;
      font-size: 14px;
      font-weight: 500;
      border-radius: 6px;
      border: 1px solid var(--hf-accent);
      background: var(--hf-accent);
      color: #06281c;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
      opacity: 0.6;
      transition: opacity 0.15s, box-shadow 0.15s;
    }
    .sidebar-footer .apply-btn.has-changes {
      opacity: 1;
      box-shadow: 0 0 0 3px var(--hf-accent-glow);
    }
    .sidebar-footer .apply-btn:hover:not(:disabled) {
      opacity: 1;
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

    /* User-menu styles live in src/shared/user-menu.js and are
       imported via userMenuStyles in the static styles array. */

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

    /* Amber dot on a nav item / section header whose page has undeployed
       changes — the per-page rollup of the field/row highlights. */
    .nav-change-dot {
      width: 7px;
      height: 7px;
      border-radius: 50%;
      background: var(--hf-warn);
      flex-shrink: 0;
      margin-left: auto;
    }
    .nav-section-title .nav-change-dot {
      display: inline-block;
      margin-left: 6px;
      vertical-align: middle;
    }
    .sidebar.collapsed .nav-item {
      position: relative;
    }
    .sidebar.collapsed .nav-item .nav-change-dot {
      position: absolute;
      top: 8px;
      right: 8px;
      margin-left: 0;
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

    /* Canonical admin button — 9px 16px / 13px / radius 6px, the
       shared form-button size. Primary / danger variants below keep
       the same metrics, only colours change. */
    .btn {
      padding: 9px 16px;
      border-radius: 6px;
      border: 1px solid var(--hf-border-2);
      background: var(--hf-surface-2);
      color: var(--hf-text);
      font-size: 13px;
      font-weight: 500;
      font-family: inherit;
      cursor: pointer;
      transition: all 0.15s;
    }

    .btn:hover {
      background: var(--hf-surface-3);
      border-color: var(--hf-text-subtle);
    }

    .btn-primary {
      background: var(--hf-accent);
      color: #06281c;
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
      /* Top padding lives on .content-area > * (the module), NOT on
         the scroll container. CSS sticky pins to the container's
         padding-edge — with padding-top here, a child using
         position:sticky; top:0 would pin BELOW the padding strip, and
         scrolled content would slide visibly into that strip above the
         sticky bar. Putting the top gutter on the child keeps the
         visual identical at scroll-top and lets sticky elements pin
         flush against the top of the scroll viewport. */
      padding: 0 24px 24px;
      background: var(--hf-bg);
    }
    /* Single content-width cap + viewport-centering for every admin
       page. The module element renderModule() mounts is the direct
       child of .content-area, so capping/centering that child caps
       every page uniformly.

       .content-area is a flex child to the RIGHT of the in-flow
       desktop sidebar, so plain margin-inline:auto would centre the
       box in the POST-sidebar space — it would visibly shift when
       the sidebar collapses (260->70px). Instead we centre on the
       full viewport: the box's left edge must sit at (100vw - C)/2
       from the viewport's left, which is (100vw - C)/2 - S from
       .content-area's left edge, where S = --hf-sidebar-w (the live
       sidebar width, set inline on .app-container: 260/70 on
       desktop, 0 on the mobile overlay). margin-right:auto absorbs
       the remainder.

       max(0px, ...) clamps the left margin to zero: on wide
       monitors the calc wins and the box is centred on the monitor
       and does NOT move when the sidebar toggles; on narrower
       viewports the 0 floor wins and the box just fills the content
       area, sitting flush against .content-area's own 24px (or 16px
       on mobile) padding on both sides — symmetric gutters with no
       extra margin stacked on the left. The box may move on toggle
       in this regime; that is acceptable since there is no monitor
       margin left to centre within. On mobile S is 0px so the same
       formula resolves to margin-left:0 with no special case.

       100vw is the true viewport width here because the root
       document never scrolls (scrolling is on .content-area); if
       that ever changes, revisit this. */
    .content-area > * {
      /* Top gutter moved off the scroll container so position:sticky
         children can pin flush against the scrollport top. See the
         .content-area block above. Sides + bottom stay on the
         container so the gutters remain symmetric. */
      padding-top: 24px;
      max-width: var(--hf-content-max);
      /* Floor is 0, not the gutter width. .content-area already
         provides a symmetric 24px (16px on mobile) of padding on
         each side; a non-zero margin-left floor would stack on top
         of that, making the left gap visibly larger than the right
         (where margin-right:auto collapses to 0 in the narrow
         regime). In the wide regime the calc value far exceeds 0
         and wins anyway. */
      margin-left: max(
        0px,
        calc(
          (100vw - var(--hf-content-max)) / 2
          - var(--hf-sidebar-w, var(--hf-sidebar-w-expanded))
        )
      );
      margin-right: auto;
      /* The sidebar transitions its width property over 0.3s ease;
         the inline --hf-sidebar-w on .app-container, by contrast,
         snaps instantly when sidebarCollapsed flips. Without a
         matching transition here, our calc()'d margin-left jumps to
         its new value on frame one (e.g. 860->1050 at 3840px) while
         .content-area's left edge is still mid-animation — the box
         briefly shifts ~190px right and slides back as the sidebar
         finishes animating. Matching transition duration + easing
         keeps the box's margin-left and .content-area's left edge
         moving in lockstep, so they cancel continuously and the box
         stays put across the full 0.3s. Inert in the narrow regime
         (margin-left is the constant 24px floor — nothing to
         animate). */
      transition: margin-left 0.3s ease;
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

    /* Unified notification box — grey-tinted bg, colored left edge. */
    .error-message {
      background: rgba(59, 130, 246, 0.08);
      color: var(--hf-text-muted);
      padding: 14px 18px;
      border-radius: 8px;
      border-left: 4px solid var(--hf-err);
      font-size: 13px;
      line-height: 1.5;
      margin: 32px;
    }
    .error-message strong { color: var(--hf-text); }

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
      /* Near-black on the emerald bar — same text-on-accent colour the
         primary button uses. White was unreadable here. */
      color: #06281c;
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
      background: rgba(0, 0, 0, 0.12);
      border: 1px solid rgba(0, 0, 0, 0.28);
      color: #06281c;
      padding: 4px 12px;
      border-radius: 4px;
      font-size: 12px;
      font-weight: 600;
      cursor: pointer;
      transition: background 0.15s;
    }

    .update-banner-btn:hover {
      background: rgba(0, 0, 0, 0.2);
    }

    /* Setup-incomplete warning banner. Same geometry as .update-banner
       so .with-banner's height math (100% - 40px) holds for either. */
    .setup-banner {
      height: 40px;
      background: #b7791f;
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

    .setup-banner-icon { font-size: 15px; }

    .setup-banner-btn {
      background: rgba(255, 255, 255, 0.18);
      border: 1px solid rgba(255, 255, 255, 0.35);
      color: white;
      padding: 4px 12px;
      border-radius: 4px;
      font-size: 12px;
      font-weight: 600;
      cursor: pointer;
      transition: background 0.15s;
    }

    .setup-banner-btn:hover {
      background: rgba(255, 255, 255, 0.32);
    }

    .app-container.with-banner {
      height: calc(100% - 40px);
    }

    /* Hamburger, sidebar-backdrop, and the standard 768px mobile
       overlay treatment live in shared/shell.js. Only admin-
       specific mobile rules remain below (sidebar-footer hide
       fix-up + with-banner offset). */
    @media (max-width: 768px) {
      .sidebar.collapsed .sidebar-footer .apply-btn-text {
        display: initial;
      }
      .app-container.with-banner .sidebar {
        top: 40px;
        height: calc(100% - 40px);
      }
    }
  `];

  constructor() {
    super();
    this.serverConfig = null;
    this.pendingConfig = {};
    this.config = {};  // Initialize merged config
    this.dirtyModules = new Set();
    this.currentModule = 'dashboard';
    this.currentSubRoute = '';
    this.loading = true;
    this.error = null;
    /* On mobile (≤768px) the sidebar is an overlay and should start
       hidden so the user sees the content first; on desktop it stays
       open as a permanent sibling. matchMedia keeps these in sync if
       the viewport crosses the breakpoint (rotation, devtools resize,
       etc.). */
    this._mobileMQ = window.matchMedia('(max-width: 768px)');
    this.isMobile = this._mobileMQ.matches;
    this.sidebarCollapsed = this.isMobile;
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
    this.setupIncomplete = false;
    this.pendingSetupItems = [];
    this.wizardStep = -1;  // -1 = not yet initialised; wizard picks its start step
    this.serviceReloading = false;
    this.currentUser = null;
    this.userMenuOpen = false;
    this.switcherOpen = false;
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
    this.dirtyReason = '';
    // Paths (dotted) whose on-disk value differs from the last DEPLOYED
    // (built) config — from /api/config/dirty. Union'd with local unsaved
    // edits into `undeployedPaths`, which drives the per-field highlight.
    this.deployedChangedPaths = new Set();
    this.undeployedPaths = new Set();
    // Last-deployed (built) config snapshot — the baseline list editors diff
    // their rows against to mark added/changed entries. Refreshed on load and
    // after each rebuild (it only changes when a rebuild succeeds).
    this.appliedConfig = null;
    // True while the on-disk config is unparseable; gates the parse-error
    // modal (show once) and blocks auto-save from writing onto a broken base.
    this._configParseError = false;
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
    // Per-item icons are resolved from `id` via navIcon() (see
    // shared/icons.js) — no `icon` key is stored here.
    this.modules = [
      {
        id: 'dashboard',
        title: 'Dashboard',
        section: 'System'
      },
      {
        // Post-install finish-setup. Listed in the nav ONLY while setup is
        // incomplete (filtered by getVisibleModules); the warning banner
        // also links here. Renders the finish-setup-wizard component.
        id: 'finish-setup',
        title: 'Finish Setup',
        section: 'System'
      },
      {
        id: 'system',
        title: 'Host',
        section: 'System'
      },
      {
        id: 'hardware',
        title: 'Hardware',
        section: 'System'
      },
      {
        id: 'network',
        title: 'Network',
        section: 'System'
      },
      {
        id: 'lan-clients',
        title: 'LAN Clients',
        section: 'System'
      },
      {
        id: 'dns',
        title: 'DNS',
        section: 'System'
      },
      {
        id: 'mounts',
        title: 'Mounts',
        section: 'System'
      },
      {
        id: 'extra-proxies',
        title: 'External Proxies',
        section: 'System'
      },
      {
        id: 'proxied-domains',
        title: 'Proxied Domains',
        section: 'System'
      },
      {
        id: 'abuse-blocking',
        title: 'Network Traffic',
        section: 'System'
      },
      {
        id: 'updates',
        title: 'Updates',
        section: 'System'
      },
      {
        id: 'apps',
        title: 'App Configuration',
        section: 'Applications'
      },
      {
        id: 'backups',
        title: 'Backups',
        section: 'Applications'
      },
      {
        id: 'users',
        title: 'Users',
        section: 'Identity'
      },
      {
        id: 'sso',
        title: 'SSO',
        section: 'Identity'
      },
      {
        // Build status + rebuild log viewer + the pending-changes list.
        // Grouped with the other power-user / Developers tools.
        id: 'build-logs',
        title: 'Build & Logs',
        section: 'Developers'
      },
      {
        // Raw homefree-config.json viewer — a power-user / debugging
        // surface, grouped with the other Developers tools.
        id: 'json-config',
        title: 'JSON Config',
        section: 'Developers'
      },
      {
        // Register custom Nix flakes that extend the system with the
        // user's own apps/modules. Last section — a power-user feature.
        id: 'developers',
        title: 'Custom Flakes',
        section: 'Developers'
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

    // Track viewport crossing the mobile breakpoint so the sidebar's
    // default state stays sensible after rotation / resize. We only
    // auto-collapse on transitions into mobile (and auto-expand on
    // transitions out) — within either regime the user's explicit
    // toggle wins, so we don't fight them on every hamburger tap.
    this._mobileMQListener = (e) => {
      const wasMobile = this.isMobile;
      this.isMobile = e.matches;
      if (this.isMobile !== wasMobile) {
        this.sidebarCollapsed = this.isMobile;
      }
    };
    this._mobileMQ.addEventListener('change', this._mobileMQListener);

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

    // Check whether post-install setup is still incomplete. A fresh box
    // installed from the ISO ships without an SSH key / DNS-01 provider; the
    // finish-setup wizard overlay handles those before the dashboard is used.
    //
    // `setupIncomplete` is the AUTHORITATIVE gate — it comes from the backend's
    // .setup-complete marker, which only flips when the wizard explicitly
    // finishes. `pendingSetupItems` is just a hint for which step the wizard
    // opens on; it must NOT gate wizard-vs-dashboard because it empties out
    // mid-wizard (the wizard writes the SSH key / DNS-01 on its early pages).
    try {
      const mode = await getMode();
      this.setupIncomplete = !!mode.setup_incomplete;
      this.pendingSetupItems = mode.pending_setup_items || [];
    } catch (e) {
      this.setupIncomplete = false;
      this.pendingSetupItems = [];
    }

    // On a fresh load with no explicit route in the URL, land on the
    // Finish Setup page while setup is incomplete — that is the thing the
    // user needs to do next, not the dashboard. loadRouteFromHash() ran
    // earlier (before setup status was known) and defaulted to
    // 'dashboard'; correct it here. An explicit hash (the user navigated
    // somewhere on purpose) is always respected.
    if (this.setupIncomplete && !window.location.hash.slice(2)) {
      this.currentModule = 'finish-setup';
    }

    // The rebuild-status poller ALWAYS runs — including during finish-setup.
    // The Status page must show the wizard's rebuild just as it shows a
    // normal Apply: same backend path (/api/config/apply ->
    // homefree-rebuild.service), same /api/config/rebuild-status endpoint.
    // The endpoint is stateless and returns the full log, so the Status
    // page and the finish-setup wizard can both watch the same rebuild
    // with no interference.
    await this.checkRebuildStatus();
    this.statusPollInterval = setInterval(() => this.checkRebuildStatus(), 3000);

    // The remaining pollers are dashboard-only (Apply-button dirty state,
    // closure-id refresh banner) and pointless while the wizard is the
    // active surface — skip them until setup is complete.
    if (this.setupIncomplete) {
      return;
    }

    // Initial dirty check + periodic refresh for the Apply button enabled
    // state. The same tick also re-reads the on-disk config so external edits
    // (a hand-edit to /etc/nixos/homefree-config.json, or another admin tab)
    // flow back INTO the UI — disk is the source of truth, both directions.
    this.refreshConfigFromDisk();
    this.checkConfigDirty();
    this.dirtyPollInterval = setInterval(() => {
      this.refreshConfigFromDisk();
      this.checkConfigDirty();
    }, 5000);

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

    // Detach the mobile-breakpoint listener so it doesn't leak when
    // this component is reconnected.
    if (this._mobileMQ && this._mobileMQListener) {
      this._mobileMQ.removeEventListener('change', this._mobileMQListener);
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
    // Split into module id + module-internal sub-route. Example:
    //   #/backups/configuration → ['backups', 'configuration']
    // The module ID is always the first segment; everything after is
    // passed to the module as currentSubRoute. Unknown module IDs are
    // ignored (the existing behavior — fall through to default).
    const [moduleId, ...rest] = hash.split('/');
    const subRoute = rest.join('/');
    if (moduleId && this.modules.find(m => m.id === moduleId)) {
      this.currentModule = moduleId;
      this.currentSubRoute = subRoute;
    } else if (!moduleId) {
      // Default to the dashboard landing page if no hash
      this.currentModule = 'dashboard';
      this.currentSubRoute = '';
    }
  }

  async loadConfig() {
    try {
      this.serverConfig = await getCurrentConfig();
      // Deployed baseline for per-row list highlighting. Best-effort: keep the
      // previous value on failure rather than dropping highlights.
      try {
        this.appliedConfig = await getAppliedConfig();
      } catch (e) {
        if (e && e.name !== 'AbortError') {
          console.warn('Failed to load applied config:', e.message);
        }
      }
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
     * Polls /api/service-state and shows overlay if status is 'restarting'.
     *
     * While the overlay is up we retry fast (500ms) so it clears the
     * instant the API is back. A rebuild restarts admin-api in ~2s; a
     * flat 2s cadence made the overlay linger up to a full extra tick
     * after the service was already serving.
     */
    const RETRY_MS = 500;
    const scheduleRetry = () => {
      if (this.serviceStateCheckInterval) {
        clearTimeout(this.serviceStateCheckInterval);
      }
      this.serviceStateCheckInterval = setTimeout(() => {
        this.checkServiceAvailability();
      }, RETRY_MS);
    };

    try {
      const state = await getServiceState();

      if (state.admin_api_status === 'restarting') {
        this.serviceReloading = true;
        this.serviceReloadMessage = state.message || 'Admin API is restarting...';
        scheduleRetry();
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
      scheduleRetry();
    }
  }

  async checkRebuildStatus() {
    try {
      // include_history=1 returns the full log on this initial fetch, so a
      // page reload mid-build (or after one finished) hydrates the build
      // logs panel instead of showing empty.
      const signals = [AbortSignal.timeout(8000)];
      if (this.rebuildStatusAbortController?.signal) {
        signals.push(this.rebuildStatusAbortController.signal);
      }
      const response = await fetch('/api/config/rebuild-status?include_history=1', {
        signal: AbortSignal.any(signals)
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
    // Sidebar nav is an intentional jump — drop any sub-route so the
    // landing tab is restored. A module that wants the sub-route to
    // survive can opt out by intercepting this click.
    this.currentSubRoute = '';
    // Update URL hash to maintain state
    window.location.hash = `#/${moduleId}`;

    // If clicking the Build & Logs nav, clear the needs-attention flag
    if (moduleId === 'build-logs') {
      this.statusNeedsAttention = false;
    }

    // On mobile the sidebar covers the content, so close it after
    // navigation. On desktop leave the user's collapsed/expanded
    // preference alone.
    if (this.isMobile) {
      this.sidebarCollapsed = true;
    }
  }

  /**
   * Sub-route change from inside a module (e.g. the Backups module
   * switching tabs). Updates the hash without triggering a hashchange
   * round-trip — replaceState skips it, so we don't run
   * loadRouteFromHash recursively.
   */
  handleSubRouteChange(e) {
    const sub = (e.detail && e.detail.subRoute) || '';
    this.currentSubRoute = sub;
    const moduleId = this.currentModule;
    const newHash = sub ? `#/${moduleId}/${sub}` : `#/${moduleId}`;
    if (window.location.hash !== newHash) {
      window.history.replaceState(null, '', newHash);
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

  /** Toggle the top-bar surface switcher popover (narrow widths).
   *  Mirrors toggleUserMenu() — outside-click dismisses it. */
  toggleSwitcher(e) {
    if (e) e.stopPropagation();
    this.switcherOpen = !this.switcherOpen;
    if (this.switcherOpen) {
      this._closeSwitcherOnOutsideClick = (evt) => {
        const path = evt.composedPath();
        const trigger = this.renderRoot?.querySelector('.surface-switcher-wrap');
        if (trigger && !path.includes(trigger)) {
          this.switcherOpen = false;
          document.removeEventListener('mousedown',
            this._closeSwitcherOnOutsideClick, true);
          this._closeSwitcherOnOutsideClick = null;
        }
      };
      setTimeout(() => {
        document.addEventListener('mousedown',
          this._closeSwitcherOnOutsideClick, true);
      }, 0);
    } else if (this._closeSwitcherOnOutsideClick) {
      document.removeEventListener('mousedown',
        this._closeSwitcherOnOutsideClick, true);
      this._closeSwitcherOnOutsideClick = null;
    }
  }

  getCurrentModuleTitle() {
    const module = this.modules.find(m => m.id === this.currentModule);
    return module ? module.title : 'HomeFree Admin';
  }

  // Modules shown in the nav. The 'finish-setup' module only appears while
  // post-install setup is incomplete; once done it drops out of the nav.
  getVisibleModules() {
    return this.modules.filter(
      m => m.id !== 'finish-setup' || this.setupIncomplete
    );
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
      // 'error' deliberately renders nothing here — a failed save is
      // surfaced as a dismissable modal (see _showSaveError), not in the
      // top-bar pill, which only ever shows progress (saving/saved).
      case 'idle':
      case 'error':
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

  // Enable/public for an EXTERNAL-proxy service lives in its service-config
  // entry (the single source of truth — Caddy/DNS read reverse-proxy.enable,
  // the catalog reads reverse-proxy.public), NOT services.<label>. So route
  // the App Configuration toggle to update the matching service-config row,
  // keeping it minimal (default-stripped) to match the External Proxies form.
  handleExternalProxyToggle(e) {
    const { label, field, value } = e.detail;  // field: 'enable' | 'public'
    const list = (this.getMergedConfig()['service-config'] || []).map(entry => {
      if (!entry || entry.label !== label) return entry;
      const next = { ...entry };
      const isDefault = field === 'enable' ? value === true : value === false;
      if (isDefault) {
        delete next[field];
      } else {
        next[field] = value;
      }
      return next;
    });
    this.pendingConfig = { ...this.pendingConfig, 'service-config': list };
    this.dirtyModules.add('extra-proxies');
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

  async handleInstanceDelete(e) {
    const { parentLabel, instanceIndex } = e.detail;

    // Confirm deletion
    const ok = await confirmDialog({
      title: 'Delete instance?',
      message: 'Are you sure you want to delete this instance? This action cannot be undone after applying changes.',
      confirmText: 'Delete',
      variant: 'danger',
    });
    if (!ok) {
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

    // Merge the network section. The abuse-blocking module edits
    // network.abuseBlockCidrs via the config-change event; without
    // this merge those edits live only in pendingConfig and are
    // dropped on save (getMergedConfig is what save/Apply submit).
    // Shallow per-key override is enough — modules replace whole
    // network.* keys, they don't deep-patch nested objects.
    if (this.pendingConfig.network) {
      merged.network = {
        ...(this.serverConfig.network || {}),
        ...this.pendingConfig.network,
      };
    }

    // The External Proxies module edits `service-config`; without
    // this merge the edit lives only in pendingConfig and is dropped
    // both from the displayed config (so a deleted row reappears) and
    // from save. Whole-array replace — the module rebuilds the list.
    if (this.pendingConfig['service-config'] !== undefined) {
      merged['service-config'] = this.pendingConfig['service-config'];
    }

    // Mounts and Proxied Domains edit their whole array via config-change and
    // (unlike System/DNS/Backups) do NOT mutate serverConfig in place, so
    // without an explicit merge here their edits live only in pendingConfig
    // and never reach the rendered config — a newly-added row silently
    // vanishes on save. Whole-array replace, same as `service-config`.
    if (this.pendingConfig.mounts !== undefined) {
      merged.mounts = this.pendingConfig.mounts;
    }
    if (this.pendingConfig['proxied-domains'] !== undefined) {
      merged['proxied-domains'] = this.pendingConfig['proxied-domains'];
    }

    // Merge other sections as they're added
    // TODO: Add other config sections as modules are migrated

    // The `developers` section (registered custom flakes) is owned
    // solely by the Developers module via its own /api/developers/*
    // endpoints — it is NOT part of the config blob the global Apply
    // submits. Strip it so a stale page-load snapshot can't resurrect
    // a flake the user removed on the Custom Flakes page. The backend
    // also ignores `developers` on this path; this is defence in depth.
    delete merged.developers;

    return merged;
  }

  /**
   * Update the merged config property for backward compatibility
   * Call this whenever serverConfig or pendingConfig changes
   */
  updateMergedConfig() {
    this.config = this.getMergedConfig();
    this.recomputeUndeployedPaths();
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

  // Drive the top-bar pill from a module that persisted out of band (its
  // own endpoint, not the merged-config auto-save). Mirrors autoSave's
  // pill behaviour, including the 1800ms "Saved" fade. The emitting side
  // is a small inline `emitSaveStatus` in each such module (e.g.
  // developers-module, users-module) that dispatches a bubbling,
  // composed `save-status` event.
  // A failed auto-save is shown as a dismissable modal (the canonical
  // single-button alert), not in the top-bar pill. The pending in-memory
  // changes are kept (saveStatus stays 'error', so Apply force-saves
  // first), so dismissing the modal loses nothing.
  _showSaveError(message) {
    alertDialog({
      title: 'Save failed',
      message: message || 'Your change could not be saved. It is still pending — editing again will retry.',
      confirmText: 'Dismiss',
      variant: 'danger',
    });
  }

  handleSaveStatus(e) {
    const { status } = e.detail || {};
    // The pill only ever shows progress. Out-of-band modules surface
    // their OWN inline error on failure, so an 'error' status just clears
    // the pill here — it neither shows in the pill nor pops the global
    // save-error modal (that modal is the auto-save path's feedback).
    this.saveStatus = (status === 'saving' || status === 'saved') ? status : 'idle';
    if (this._savedFlashTimer) {
      clearTimeout(this._savedFlashTimer);
      this._savedFlashTimer = null;
    }
    if (status === 'saved') {
      // A real out-of-band write means new content on disk → Apply enabled.
      this.hasUnappliedChanges = true;
      this._savedFlashTimer = setTimeout(() => {
        if (this.saveStatus === 'saved') {
          this.saveStatus = 'idle';
          this.requestUpdate();
        }
      }, 1800);
    }
    this.requestUpdate();
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
        this._showSaveError(this.saveError);
      }
    } catch (error) {
      console.error('Auto-save failed:', error);
      this.saveStatus = 'error';
      this.saveError = error.message || 'Network error';
      this._showSaveError(this.saveError);
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

  // Re-read the on-disk config and reflect external edits back into the UI
  // (disk is the source of truth, both directions). A malformed file surfaces
  // a modal ONCE and keeps the last-good config — the admin UI is the recovery
  // surface and must never blank.
  async refreshConfigFromDisk() {
    // Do NOT pull disk over the UI while the user has unsaved edits. The
    // legacy config modules (System/Network/DNS/Backups) store their in-flight
    // edit by mutating `serverConfig`'s nested objects in place (their merge
    // path relies on it), so replacing serverConfig here would silently revert
    // the field the user is editing. Disk→UI sync resumes once edits are
    // applied (dirtyModules cleared). The intended case — hand-editing the
    // file while NOT editing in the UI — is unaffected (the UI is clean then).
    if (this.dirtyModules.size > 0 || this._saveInFlight
        || this.saveStatus === 'saving' || this._saveTimer != null) {
      return;
    }
    try {
      const fresh = await getCurrentConfig();
      this._configParseError = false;  // good read clears the latch
      if (JSON.stringify(fresh) !== JSON.stringify(this.serverConfig)) {
        this.serverConfig = fresh;
        this.updateMergedConfig();
        this.requestUpdate();
      }
    } catch (error) {
      if (error && error.status === 422) {
        if (!this._configParseError) {
          this._configParseError = true;
          alertDialog({
            title: 'Config file has a syntax error',
            message: (error.body && error.body.detail)
              ? error.body.detail
              : 'The on-disk homefree-config.json is not valid JSON. Your current view is unchanged — fix the file (or edit via the admin pages) to continue.',
            confirmText: 'Dismiss',
            variant: 'danger',
          });
        }
      } else if (error.name !== 'AbortError') {
        console.warn('Failed to refresh config from disk:', error.message);
      }
    }
  }

  async checkConfigDirty() {
    try {
      const result = await getConfigDirty();
      // These are reactive (or, for undeployedPaths, only reassigned on a real
      // change) so Lit re-renders only when something actually changed — no
      // unconditional requestUpdate that would churn focused inputs every 5s.
      this.hasUnappliedChanges = !!result.dirty;
      this.dirtyReason = result.reason || '';
      this.deployedChangedPaths = new Set(result.changedPaths || []);
      this.recomputeUndeployedPaths();
    } catch (error) {
      // Don't spam logs while admin-api is restarting
      if (error.name !== 'AbortError') {
        console.warn('Failed to check config dirty state:', error.message);
      }
    }
  }

  // Union the deployed-vs-disk changed paths (backend) with the user's local
  // unsaved edits (disk-vs-UI) so a field lights up the instant it's edited,
  // before the debounced save + next poll catch up. Both mean "not deployed".
  recomputeUndeployedPaths() {
    const merged = this.getMergedConfig() || {};
    // `developers` (custom flakes + alternate-base repo) is stripped from the
    // merged/save config on purpose — the Custom Flakes page owns it via its
    // own /api/developers/* endpoints, so the global Apply must never submit a
    // stale page-load snapshot. But its ON-DISK value still differs from the
    // deployed snapshot until the next rebuild, and we DO want to flag that
    // (per-control amber, nav badge, pending-changes list). Re-add it for
    // INDICATION ONLY, sourced from serverConfig (the live disk value the 5s
    // poll refreshes) — never the stale pending snapshot.
    const current = { ...merged };
    if (this.serverConfig && this.serverConfig.developers !== undefined) {
      current.developers = this.serverConfig.developers;
    }
    let paths;
    if (this.appliedConfig && Object.keys(this.appliedConfig).length) {
      // Authoritative AND immediate: diff the current UI state against the
      // DEPLOYED config. No backend round-trip, so reverting a field to its
      // deployed value clears the highlight at once — not after the next 5s
      // poll (which is why a revert used to stay yellow until reload).
      paths = new Set(this._diffPaths(this.appliedConfig, current));
    } else {
      // No deployed baseline yet (fresh box) — fall back to the backend's
      // changedPaths unioned with the local disk-vs-UI diff. (developers is
      // equal on both sides here, so it contributes nothing — the backend's
      // changedPaths already carries it.)
      paths = new Set(this.deployedChangedPaths);
      for (const p of this._diffPaths(this.serverConfig || {}, current)) paths.add(p);
    }
    // Only reassign when the set actually changed. Otherwise the 5s dirty poll
    // would hand every child a brand-new Set each tick — forcing needless
    // re-renders that can disrupt a focused text input.
    const cur = this.undeployedPaths;
    if (!cur || cur.size !== paths.size || [...paths].some(p => !cur.has(p))) {
      this.undeployedPaths = paths;
    }
  }

  // Dotted leaf paths where `b` differs from `a`. Mirrors the backend's
  // compute_changed_paths: objects recurse; arrays/scalars compare
  // whole-value (an array is one path, so a reorder isn't N changes).
  _diffPaths(a, b) {
    const out = [];
    const isObj = (v) => v && typeof v === 'object' && !Array.isArray(v);
    const walk = (x, y, prefix) => {
      if (isObj(x) && isObj(y)) {
        const keys = new Set([...Object.keys(x), ...Object.keys(y)]);
        for (const k of keys) {
          walk(x[k], y[k], prefix ? `${prefix}.${k}` : k);
        }
      } else if (JSON.stringify(x) !== JSON.stringify(y) && prefix) {
        out.push(prefix);
      }
    };
    walk(a || {}, b || {}, '');
    return out;
  }

  // Map the backend dirty `reason` to a short, friendly label for the Apply
  // note + tooltip.
  _dirtyReasonLabel() {
    switch (this.dirtyReason) {
      case 'differs': return 'Configuration changed';
      case 'flake source changed': return 'Flake source changed';
      case 'build inputs changed': return 'System inputs changed';
      case 'local code changed': return 'Local code changed';
      case 'last rebuild failed': return 'Last rebuild failed — retry';
      case 'system update pending': return 'System update pending';
      case 'config parse error': return 'Config file has a syntax error';
      case 'no applied marker': return 'Not yet deployed';
      default: return 'Undeployed changes';
    }
  }

  // Map a dotted config path to the nav module that owns it. Sub-path aware:
  // several pages share a top-level section — network.* is split across
  // Network / LAN Clients / Network Traffic, and services.* across App
  // Configuration / Backups (the backup self-test). Keep in sync with the
  // modules' edited paths.
  pathOwnerModuleId(path) {
    if (!path) return null;
    const seg = path.split('.');
    switch (seg[0]) {
      case 'system': return 'system';
      case 'dns': return 'dns';
      case 'mounts': return 'mounts';
      case 'service-config': return 'extra-proxies';
      case 'proxied-domains': return 'proxied-domains';
      case 'backups': return 'backups';
      case 'sso': return 'sso';
      case 'developers': return 'developers';
      case 'network':
        if (seg[1] === 'static-ips') return 'lan-clients';
        if (seg[1] === 'abuseBlockCidrs') return 'abuse-blocking';
        return 'network';
      case 'services':
        return seg[1] === 'backup-canary' ? 'backups' : 'apps';
      default: return null;
    }
  }

  // Set of nav module ids with undeployed changes — drives the left-nav dots.
  changedModuleIds() {
    const ids = new Set();
    for (const p of (this.undeployedPaths || [])) {
      const id = this.pathOwnerModuleId(p);
      if (id) ids.add(id);
    }
    // Flake-source / build-input divergence isn't a config path; attribute it
    // to the Custom Flakes page.
    if (this.dirtyReason === 'flake source changed' ||
        this.dirtyReason === 'build inputs changed' ||
        this.dirtyReason === 'local code changed') {
      ids.add('developers');
    }
    return ids;
  }

  // Structured list of everything that will deploy on the next Apply: the
  // config paths that differ from the deployed config, each tagged with the
  // page that owns it, plus any code/flake/update reason that isn't a config
  // path. Rendered on the Build & Logs page (linked from the Apply note).
  pendingChanges() {
    const titleOf = (id) =>
      (this.modules.find(m => m.id === id) || {}).title || id || 'Configuration';
    const items = [];
    for (const p of [...(this.undeployedPaths || [])].sort()) {
      const id = this.pathOwnerModuleId(p);
      items.push({ page: id ? titleOf(id) : 'Configuration', detail: p });
    }
    const r = this.dirtyReason;
    if (r === 'flake source changed' || r === 'build inputs changed'
        || r === 'local code changed') {
      items.push({ page: titleOf('developers'), detail: this._dirtyReasonLabel() });
    } else if (r === 'system update pending') {
      items.push({ page: titleOf('updates'), detail: 'System update pending' });
    } else if (r === 'last rebuild failed') {
      items.push({ page: 'Build & Logs', detail: 'Last rebuild failed — retry' });
    }
    return items;
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
    // Show the spinner on the same tick as the click. The validate/apply
    // network round-trips below would otherwise delay it visibly. Every
    // failure/early-return path below resets this so the button recovers.
    this.rebuildStatus = {
      running: true,
      message: 'Applying configuration…',
      lastUpdate: null
    };
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

      // Build-only: Apply rebuilds whatever is on disk (the flush above put our
      // edits there). If the on-disk file is broken or the flush failed, disk
      // won't match the UI — bail clearly instead of building a stale/broken
      // config (the backend would reject it anyway).
      if (this._configParseError) {
        this.showToast('Fix the configuration file syntax error before applying.', 'error', 7000);
        this.rebuildStatus = { running: false, message: '', lastUpdate: null };
        return;
      }
      if (this.saveStatus === 'error') {
        this.showToast('Could not save your changes to disk — not applying.', 'error', 7000);
        this.rebuildStatus = { running: false, message: '', lastUpdate: null };
        return;
      }

      // Validate what we're about to build (after the flush, the merged config
      // equals what's on disk). Warnings are surfaced but don't block.
      const configToApply = this.getMergedConfig();

      const validation = await validateConfig(configToApply);
      if (!validation.valid) {
        const firstError = validation.errors[0] || 'Validation failed';
        this.showToast(`Validation failed: ${firstError}`, 'error', 7000);
        this.rebuildStatus = { running: false, message: '', lastUpdate: null };
        return;
      }

      if (validation.warnings && validation.warnings.length > 0) {
        const firstWarning = validation.warnings[0];
        this.showToast(`Warning: ${firstWarning}`, 'warning', 5000);
      }

      // Send an empty object — the backend rebuilds the on-disk config (single
      // source of truth) and ignores any payload. This is what makes Apply
      // unable to revert an out-of-band hand-edit to the file. ({} avoids any
      // empty-body ambiguity with the JSON Content-Type the client sets.)
      const result = await applyConfigChanges({});

      if (!result.success) {
        this.showToast(`Failed to apply: ${result.message || 'Unknown error'}`, 'error', 7000);
        this.rebuildStatus = { running: false, message: '', lastUpdate: null };
        return;
      }

      this.showToast('Applying configuration…', 'success', 4000);
      this.flashStatus(2000);

      this.dirtyModules.clear();
      this.updateMergedConfig();

      // Spinner is already showing (set on click). Just refine the message;
      // pollRebuildStatus() owns rebuildStatus from here on.
      this.rebuildStatus = {
        running: true,
        message: 'Starting system rebuild...',
        lastUpdate: null
      };

      this.pollRebuildStatus();

    } catch (error) {
      console.error('Error applying changes:', error);
      this.showToast(`Error: ${error.message || 'Unknown error'}`, 'error', 7000);
      this.rebuildStatus = { running: false, message: '', lastUpdate: null };
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
        // Cap each poll at 8s. A bare fetch over HTTP/3 can otherwise
        // stall ~30s on a QUIC connection whose backend restarted
        // mid-rebuild; aborting lets the next tick reconnect cleanly.
        const signals = [AbortSignal.timeout(8000)];
        if (this.rebuildStatusAbortController?.signal) {
          signals.push(this.rebuildStatusAbortController.signal);
        }
        const response = await fetch('/api/config/rebuild-status', {
          signal: AbortSignal.any(signals)
        });

        // Check if response is OK before parsing JSON
        if (!response.ok) {
          throw new Error(`HTTP error! status: ${response.status}`);
        }

        const status = await response.json();

        if (status.output) {
          // The backend returns the COMPLETE log every poll, so REPLACE
          // the buffer wholesale — never append. This is what makes the
          // log gapless across an admin-api/Caddy restart: the first
          // successful poll after a reconnect carries the entire log so
          // far, with nothing missed in the disconnected window.
          const newLines = status.output.trim().split('\n').filter(l => l.trim());
          this.buildLogs = newLines;

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
        this._rebuildPollFailures = 0;
        setTimeout(checkStatus, 2000);
      } catch (error) {
        // Ignore abort errors - these are expected when component disconnects
        if (error.name === 'AbortError') {
          return;
        }

        // A connection drop mid-rebuild is EXPECTED: a rebuild routinely
        // restarts admin-api (the very process serving this status), so
        // the fetch fails for a couple of seconds. Don't kill the poll
        // loop — retry fast (admin-api is back in ~2s) so the page picks
        // the build back up the instant the API returns. Only give up
        // after a sustained outage that a normal restart can't explain.
        this._rebuildPollFailures = (this._rebuildPollFailures || 0) + 1;
        const MAX_TRANSIENT_FAILURES = 15; // ~7.5s at 500ms cadence

        if (this._rebuildPollFailures <= MAX_TRANSIENT_FAILURES) {
          // Keep the spinner up — the build is still considered running.
          this.rebuildStatus = {
            running: true,
            message: 'Reconnecting to rebuild process…',
            lastUpdate: { success: null }
          };
          setTimeout(checkStatus, 500);
          return;
        }

        console.error('Error polling rebuild status:', error);
        // Sustained outage — give up and surface it.
        this._pollRebuildActive = false;
        if (this.systemHealth === 'building') {
          this.systemHealth = 'warning';
        }
        this.rebuildStatus = {
          running: false,
          message: 'Lost connection to rebuild process',
          lastUpdate: { success: false }
        };
        return;
      }
    };

    // Start polling
    this._rebuildPollFailures = 0;
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
      case 'dashboard':
        return html`
          <dashboard-module></dashboard-module>
        `;

      case 'finish-setup':
        return html`
          <finish-setup-wizard
            .pendingItems=${this.pendingSetupItems}
            .initialStep=${this.wizardStep}
            @wizard-step-change=${(e) => { this.wizardStep = e.detail.step; }}
          ></finish-setup-wizard>
        `;

      case 'lan-clients':
        return html`
          <lan-clients-module
            .serverConfig=${this.serverConfig}
            .pendingConfig=${this.pendingConfig}
            .appliedConfig=${this.appliedConfig}
            @config-change=${this.handleConfigChange}
          ></lan-clients-module>
        `;

      case 'system':
        return html`
          <system-module
            .config=${this.config}
            .undeployedPaths=${this.undeployedPaths}
            .appliedConfig=${this.appliedConfig}
            @config-change=${this.handleConfigChange}
            @ssh-keys-changed=${this.handleSSHKeysChanged}
          ></system-module>
        `;

      case 'hardware':
        return html`
          <hardware-module></hardware-module>
        `;

      case 'network':
        return html`
          <network-module
            .config=${this.config}
            .undeployedPaths=${this.undeployedPaths}
            @config-change=${this.handleConfigChange}
          ></network-module>
        `;

      case 'dns':
        return html`
          <dns-module
            .config=${this.config}
            .hasAuthorizedKeys=${this.hasAuthorizedKeys}
            .undeployedPaths=${this.undeployedPaths}
            .appliedConfig=${this.appliedConfig}
            @config-change=${this.handleConfigChange}
          ></dns-module>
        `;

      case 'mounts':
        return html`
          <mounts-module
            .config=${this.config}
            .appliedConfig=${this.appliedConfig}
            @config-change=${this.handleConfigChange}
          ></mounts-module>
        `;

      case 'extra-proxies':
        return html`
          <extra-proxies-module
            .config=${this.config}
            .appliedConfig=${this.appliedConfig}
            @config-change=${this.handleConfigChange}
          ></extra-proxies-module>
        `;

      case 'proxied-domains':
        return html`
          <proxied-domains-module
            .config=${this.config}
            .appliedConfig=${this.appliedConfig}
            @config-change=${this.handleConfigChange}
          ></proxied-domains-module>
        `;

      case 'apps':
        return html`
          <services-module
            .serverConfig=${this.serverConfig}
            .pendingConfig=${this.pendingConfig}
            .appliedConfig=${this.appliedConfig}
            .undeployedPaths=${this.undeployedPaths}
            .hasAuthorizedKeys=${this.hasAuthorizedKeys}
            @service-toggle=${this.handleServiceToggle}
            @service-public-toggle=${this.handleServicePublicToggle}
            @external-proxy-toggle=${this.handleExternalProxyToggle}
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
            .subRoute=${this.currentSubRoute}
            .undeployedPaths=${this.undeployedPaths}
            .appliedConfig=${this.appliedConfig}
            @config-change=${this.handleConfigChange}
            @service-toggle=${this.handleServiceToggle}
            @service-option-changed=${this.handleServiceOptionChanged}
            @sub-route-change=${this.handleSubRouteChange}
          ></backups-module>
        `;

      case 'sso':
        return html`
          <sso-module
            .config=${this.config}
            .undeployedPaths=${this.undeployedPaths}
            @config-change=${this.handleConfigChange}
          ></sso-module>
        `;

      case 'users':
        return html`
          <users-module></users-module>
        `;

      case 'json-config':
        return html`
          <div class="module-content">
            <h3>JSON Config</h3>
            <p>The raw <code>homefree-config.json</code> for this box, exactly
               as the system reads it. Read-only — use the other admin pages
               to make changes.</p>

            ${this.config ? html`
              <details open class="config-details">
                <summary>View Current Configuration</summary>
                <pre class="config-json"
                     .innerHTML=${this.highlightJson(JSON.stringify(this.config, null, 2))}></pre>
              </details>
            ` : ''}
          </div>
        `;

      case 'build-logs':
        return html`
          <status-module
            .rebuildStatus=${this.rebuildStatus}
            .systemHealth=${this.systemHealth}
            .buildLogs=${this.buildLogs}
            .pendingChanges=${this.pendingChanges()}
            .hasUnappliedChanges=${this.hasUnappliedChanges}
          ></status-module>
        `;

      case 'updates':
        return html`
          <updates-module
            @updates-applied=${this.checkConfigDirty}
          ></updates-module>
        `;

      case 'developers':
        return html`
          <developers-module
            .undeployedPaths=${this.undeployedPaths}
            .appliedConfig=${this.appliedConfig}
            @updates-applied=${this.checkConfigDirty}
          ></developers-module>
        `;

      case 'abuse-blocking':
        return html`
          <abuse-blocking-module
            .serverConfig=${this.serverConfig}
            .pendingConfig=${this.pendingConfig}
            .appliedConfig=${this.appliedConfig}
            @config-change=${this.handleConfigChange}
          ></abuse-blocking-module>
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

  /** Top-right user menu. Delegates to the shared renderer so
   *  admin.<domain> and home.<domain> show the same shape.
   *  Account-only now (Profile & password, Sign out) — cross-site
   *  links live in the left nav. Profile & password routes to
   *  home.<domain>/#/profile (the single source of truth for
   *  self-service settings). */
  _renderUserMenu() {
    return renderUserMenu({
      currentUser: this.currentUser,
      open: this.userMenuOpen,
      onToggle: () => this.toggleUserMenu(),
      profileUrl: profileUrlForCurrentBox(),
    });
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

    // Post-install: the finish-setup wizard is NOT a blocking takeover.
    // The admin dashboard is always reachable; while setup is incomplete a
    // warning banner links to the "Finish setup" page (a normal nav module).
    // `setupIncomplete` is the backend .setup-complete marker.

    // Group modules by section. The finish-setup module is pinned at the
    // TOP of the nav as its own highlighted item (not inside a section), so
    // it is excluded from the section grouping here.
    const changedIds = this.changedModuleIds();
    const sections = {};
    this.getVisibleModules()
      .filter(module => module.id !== 'finish-setup')
      .forEach(module => {
        if (!sections[module.section]) {
          sections[module.section] = [];
        }
        sections[module.section].push(module);
      });
    const finishSetupModule = this.setupIncomplete
      ? this.modules.find(m => m.id === 'finish-setup')
      : null;

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
      ${this.setupIncomplete ? html`
        <div class="setup-banner" role="status">
          <span class="setup-banner-icon">⚠</span>
          <span class="setup-banner-text">
            HomeFree isn't fully set up yet — finish setup to secure the box
            and enable HTTPS.
          </span>
          <button
            class="setup-banner-btn"
            @click=${() => this.handleModuleClick('finish-setup')}
          >
            Finish setup
          </button>
        </div>
      ` : ''}
      <div
        class="app-container ${this.updateAvailable || this.setupIncomplete ? 'with-banner' : ''}"
        style="--hf-sidebar-w: ${this.isMobile
          ? '0px'
          : (this.sidebarCollapsed
              ? 'var(--hf-sidebar-w-collapsed)'
              : 'var(--hf-sidebar-w-expanded)')}"
      >
        <!-- Sidebar -->
        <div class="sidebar ${this.sidebarCollapsed ? 'collapsed' : ''}">
          <div class="sidebar-header">
            <h1 @click=${this.toggleSidebar} title="Collapse sidebar">HomeFree</h1>
            <button class="collapse-btn" @click=${this.toggleSidebar}>
              ${this.sidebarCollapsed ? '→' : '←'}
            </button>
          </div>

          <nav class="nav-menu">
           <div class="nav-menu-inner">
            ${finishSetupModule ? html`
              <div
                class="nav-item nav-item-finish-setup ${this.currentModule === 'finish-setup' ? 'active' : ''}"
                @click=${() => this.handleModuleClick('finish-setup')}
              >
                <span class="nav-item-icon">${navIcon('finish-setup')}</span>
                <span class="nav-item-text">${finishSetupModule.title}</span>
              </div>
            ` : ''}
            ${Object.entries(sections).map(([section, modules]) => html`
              <div class="nav-section-title">
                ${section}
                ${modules.some(m => changedIds.has(m.id)) ? html`<span class="nav-change-dot"></span>` : ''}
              </div>
              ${modules.map(module => html`
                <div
                  class="nav-item ${this.currentModule === module.id ? 'active' : ''} ${module.id === 'build-logs' && (this.statusFlashing || this.statusNeedsAttention) ? 'flashing' : ''}"
                  @click=${() => this.handleModuleClick(module.id)}
                >
                  <span class="nav-item-icon">${navIcon(module.id)}</span>
                  <span class="nav-item-text">${module.title}</span>
                  ${changedIds.has(module.id) ? html`<span class="nav-change-dot" title="Undeployed changes"></span>` : ''}
                  ${module.id === 'build-logs' ? html`
                    <span class="status-badge ${this.getStatusBadgeClass()}">
                      ${this.rebuildStatus.running ? html`<div class="spinner-tiny"></div>` : ''}
                    </span>
                  ` : ''}
                </div>
              `)}
            `)}
           </div>
          </nav>

          <!-- Apply button pinned to the sidebar bottom. nav-menu has
               flex: 1 so the footer naturally lands here. Title shows
               "Apply" when collapsed since the text is hidden. -->
          <div class="sidebar-footer">
            ${this.hasUnappliedChanges && !this.rebuildStatus.running && !this.sidebarCollapsed ? html`
              <button
                class="apply-note"
                @click=${() => this.handleModuleClick('build-logs')}
                title="View pending changes"
              >
                <span class="apply-note-dot"></span>
                <span class="apply-note-text">${this._dirtyReasonLabel()}</span>
                <span class="apply-note-chevron">›</span>
              </button>
            ` : ''}
            <button
              class="apply-btn ${this.hasUnappliedChanges ? 'has-changes' : ''}"
              @click=${this.handleApplyChanges}
              ?disabled=${this.rebuildStatus.running}
              title=${this.rebuildStatus.running
                ? 'Rebuild in progress — wait for it to finish before applying again'
                : (this.hasUnappliedChanges
                    ? `Undeployed changes: ${this._dirtyReasonLabel()}`
                    : 'Rebuild the current on-disk configuration')}
            >
              ${this.rebuildStatus.running
                ? html`<span class="btn-spinner"></span><span class="apply-btn-text">Applying…</span>`
                : html`<span class="apply-btn-text">Apply</span>${this.sidebarCollapsed ? html`✓` : ''}`}
            </button>
          </div>
        </div>

        <!-- Backdrop behind the slide-out sidebar on mobile. CSS only
             shows it when .sidebar is NOT collapsed (adjacent-sibling
             selector against .sidebar). Tap closes the nav. -->
        <div class="sidebar-backdrop" @click=${this.toggleSidebar}></div>

        <!-- Main Content -->
        <div class="main-content">
          <div class="top-bar">
            <div class="top-bar-title">
              <!-- Hamburger: hidden on desktop via CSS, shown on mobile.
                   Always toggles the sidebar regardless of viewport. -->
              <button
                class="hamburger-btn"
                @click=${this.toggleSidebar}
                aria-label="Toggle navigation"
              >☰</button>
              <h2>${this.getCurrentModuleTitle()}</h2>
              ${this.renderSaveIndicator()}
            </div>

            <div class="top-bar-actions">
              ${renderSurfaceSwitcher({
                currentSurface: 'admin',
                isAdmin: true,
                isMobile: this.isMobile,
                open: this.switcherOpen,
                onToggle: () => this.toggleSwitcher(),
              })}
              ${this._renderUserMenu()}
            </div>
          </div>

          <div class="content-area" @save-status=${this.handleSaveStatus}>
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
