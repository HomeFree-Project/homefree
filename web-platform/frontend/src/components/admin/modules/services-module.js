import { LitElement, html, css } from 'lit';
import { getServices, getServiceOptionsSchema, postServiceAction } from '../../../api/client.js';
import '../../shared/config-section.js';
import '../../shared/app-card.js';
import '../secrets-input.js';
import '../service-option-input.js';
import { confirmDialog } from '../../shared/confirm-dialog.js';
import { actionIcon } from '../../../shared/icons.js';

/**
 * Services configuration module
 * Displays all services with runtime status, enable/disable toggles, and public access settings
 */
class ServicesModule extends LitElement {
  static properties = {
    services: { type: Array },           // Display array (merged view for UI)
    serverConfig: { type: Object },      // Server/deployed state (from parent)
    pendingConfig: { type: Object },     // Pending changes (from parent)
    loading: { type: Boolean },
    error: { type: String },
    searchQuery: { type: String },
    apiUnavailable: { type: Boolean },   // Track if API is temporarily down
    secretsSchema: { type: Object },     // Secrets schema for all services
    secretsStatus: { type: Object },     // Status of which secrets are set
    optionsSchema: { type: Object },     // Service options schema for all services
    hasAuthorizedKeys: { type: Boolean }, // Whether SSH keys are configured (from parent)
    expandedServices: { type: Set, state: true }, // Track which services have secrets expanded
    pendingActions: { type: Object, state: true }, // {label: 'start'|'restart'|'stop'} while in-flight
    actionErrors: { type: Object, state: true } // {label: 'message'} last error per service
  };

  static styles = css`
    :host {
      display: block;
    }

    .module-container {
      width: 100%;
    }

    .info-box {
      background: var(--hf-surface-2);
      border-radius: 8px;
      padding: 16px;
      margin-bottom: 20px;
      font-size: 14px;
      color: var(--hf-text);
      display: flex;
      align-items: center;
      justify-content: space-between;
    }

    .info-text {
      flex: 1;
    }

    /* Unified notification box — grey-tinted bg, colored left edge. */
    .warning-box {
      background: rgba(59, 130, 246, 0.08);
      border-left: 4px solid var(--hf-warn);
      border-radius: 8px;
      padding: 14px 18px;
      margin-bottom: 16px;
      font-size: 13px;
      line-height: 1.5;
      color: var(--hf-text-muted);
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .warning-box::before {
      content: '⚠️';
      font-size: 16px;
    }

    .search-box {
      margin-bottom: 20px;
    }

    .search-box input {
      width: 100%;
      max-width: 500px;
      padding: 12px 16px;
      font-size: 14px;
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      font-family: inherit;
    }

    .search-box input:focus {
      outline: none;
      border-color: var(--hf-accent);
    }

    /* Card grid — auto-fill with a per-card minimum width. The column
       count grows with the viewport (more cards per row on a wide
       monitor) and collapses to one on a phone, with no fixed count
       and no breakpoint. The --hf-card-min floor keeps each card wide
       enough to seat the icon, name, status badge and action buttons
       on one header row without the name clipping. An expanded card
       keeps its column and simply grows taller in place — it must not
       widen or reflow the grid. Default grid align-items:stretch makes
       every card in a row the same height; app-card has height:100% to
       fill the cell. */
    .service-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(var(--hf-card-min), 1fr));
      gap: 12px;
    }

    /* ---- App card: three stacked zones --------------------------------
       The admin app card was a ragged stack of left-aligned rows. It is
       now organised into three deliberate zones inside <app-card>:
         1. header slot  — status badge + lifecycle icon-buttons, pinned
                            to the right of the icon/title row.
         2. .card-meta   — an aligned label/value block (just the URL).
                            A fixed-width label column lines every row up.
         3. .card-footer — the Enable / Expose toggles, fenced off from
                            the meta block by a hairline rule.
       The SSO pill, per-unit systemd list and the deeper config form
       live below, inside the "Details & Config" expander. -------------- */

    /* Zone 1 — header slot content (sits in <app-card>'s .head-aside). */
    .card-head {
      display: flex;
      align-items: center;
      gap: 6px;
    }

    /* Status as a single pill: a coloured dot + word. Replaces the old
       loose dot+text row and the separate monospace systemd line. */
    .status-badge {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 3px 9px 3px 8px;
      border-radius: 999px;
      font-size: 11.5px;
      font-weight: 600;
      letter-spacing: 0.01em;
      white-space: nowrap;
      background: var(--hf-surface-3);
      color: var(--hf-text-muted);
    }
    .status-badge.running  { background: rgba(52,211,153,0.13);  color: var(--hf-ok); }
    .status-badge.failed   { background: rgba(239,68,68,0.13);   color: var(--hf-err); }
    .status-badge.degraded { background: rgba(245,158,11,0.13);  color: var(--hf-warn); }
    .status-badge.starting { background: rgba(245,158,11,0.13);  color: var(--hf-warn); }

    /* Compact square lifecycle buttons (play / restart / stop). They sit
       in the header beside the badge — icon-only, with title tooltips —
       so they cost no vertical space on the card face. */
    .icon-actions {
      display: flex;
      gap: 4px;
    }
    .icon-action {
      width: 26px;
      height: 26px;
      padding: 0;
      display: grid;
      place-items: center;
      background: var(--hf-surface);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      color: var(--hf-text-muted);
      cursor: pointer;
      transition: background 0.15s, border-color 0.15s, color 0.15s;
    }
    .icon-action svg {
      width: 13px;
      height: 13px;
    }
    .icon-action:hover:not(:disabled) {
      background: var(--hf-surface-3);
      border-color: var(--hf-accent);
      color: var(--hf-text);
    }
    .icon-action.danger:hover:not(:disabled) {
      border-color: var(--hf-err);
      color: var(--hf-err);
    }
    .icon-action:disabled {
      opacity: 0.35;
      cursor: not-allowed;
    }
    /* The in-flight button keeps a steady accent tint while its request
       is outstanding (the icon itself doesn't spin — title says why). */
    .icon-action.busy {
      border-color: var(--hf-accent);
      color: var(--hf-accent);
    }

    /* Zone 2 — aligned meta block. Each row is [label | value] on a
       shared two-column grid so every label edge and value edge lines
       up, however many rows a given service has. The value track is
       minmax(0, 1fr) rather than a plain 1fr so it can shrink below its
       content's intrinsic width on a narrow card — a 1fr track has an
       implicit min-width:auto and would let a long URL push the grid
       wider than the card and overflow the right edge. */
    .card-meta {
      display: grid;
      grid-template-columns: auto minmax(0, 1fr);
      gap: 6px 10px;
      align-items: baseline;
      margin-bottom: 2px;
    }
    .meta-label {
      font-size: 11px;
      font-weight: 600;
      letter-spacing: 0.04em;
      text-transform: uppercase;
      color: var(--hf-text-subtle);
      white-space: nowrap;
    }
    .meta-value {
      font-size: 12.5px;
      color: var(--hf-text-muted);
      min-width: 0;
    }
    a.meta-value {
      color: var(--hf-accent);
      text-decoration: none;
      /* break-all lets a long unbroken URL fold inside the value
         column instead of forcing the column (and the card) wider. */
      word-break: break-all;
      display: flex;
      align-items: center;
      gap: 4px;
    }
    a.meta-value:hover { text-decoration: underline; }
    /* The URL text — min-width:0 lets it shrink inside the flex anchor
       so word-break can fold it; without it the text is treated as an
       unshrinkable flex item and overflows. */
    a.meta-value > span {
      min-width: 0;
      overflow-wrap: anywhere;
    }
    a.meta-value svg {
      width: 11px;
      height: 11px;
      flex-shrink: 0;
      opacity: 0.8;
    }
    /* SSO posture as a pill (inside the "Details & Config" expander).
       Mirrors the .status-badge pill so it reads as a badge, not as a
       link — the old inline coloured text was indistinguishable from
       the URL anchor. */
    .sso-pill {
      display: inline-flex;
      align-items: center;
      padding: 3px 9px;
      border-radius: 999px;
      font-size: 11.5px;
      font-weight: 600;
      letter-spacing: 0.01em;
      white-space: nowrap;
      background: var(--hf-surface-3);
      color: var(--hf-text-muted);
    }
    .sso-pill.ok       { background: rgba(52,211,153,0.13); color: var(--hf-ok); }
    .sso-pill.warn     { background: rgba(245,158,11,0.13); color: var(--hf-warn); }
    .sso-pill.disabled { background: var(--hf-surface-3);   color: var(--hf-text-subtle); }

    /* Zone 3 — toggle footer. Fenced from the meta block by a hairline;
       the two toggle rows stack with a tight, even gap. */
    .card-footer {
      margin-top: 12px;
      padding-top: 12px;
      border-top: 1px solid var(--hf-border);
      display: flex;
      flex-direction: column;
      gap: 8px;
    }
    /* A system service (admin/admin-api) has no toggles — show a single
       muted note in the footer's place so the card still has a base. */
    .system-note {
      margin-top: 12px;
      padding-top: 12px;
      border-top: 1px solid var(--hf-border);
      font-size: 12px;
      color: var(--hf-text-subtle);
    }

    .config-expander {
      margin: 12px -18px -18px;
      padding: 12px 18px;
      border-top: 1px solid var(--hf-border);
      background: var(--hf-surface-2);
      cursor: pointer;
      display: flex;
      align-items: center;
      gap: 6px;
      font-size: 13px;
      color: var(--hf-accent);
      transition: all 0.2s;
      user-select: none;
      border-radius: 0 0 11px 11px;
    }

    .config-expander:hover {
      background: var(--hf-surface-3);
      color: var(--hf-accent-hover);
    }

    .config-expander-arrow {
      font-size: 10px;
      transition: transform 0.2s;
    }

    .config-expander.expanded .config-expander-arrow {
      transform: rotate(90deg);
    }

    @keyframes pulse {
      0%, 100% {
        opacity: 1;
      }
      50% {
        opacity: 0.5;
      }
    }

    /* ---- Systemd units list (inside the "Details & Config" expander) --
       The per-unit health that used to crowd the card face now lives
       here: one row per unit, a small status dot + the unit name. */
    .systemd-units {
      display: flex;
      flex-direction: column;
      gap: 6px;
    }
    .systemd-unit {
      display: flex;
      align-items: center;
      gap: 8px;
      font-size: 12px;
      font-family: 'SF Mono', Monaco, 'Courier New', monospace;
      color: var(--hf-text-muted);
    }
    .unit-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      flex-shrink: 0;
      background: var(--hf-border-2);
    }
    .unit-dot.unit-ok       { background: var(--hf-ok); }
    .unit-dot.unit-bad      { background: var(--hf-err); }
    .unit-dot.unit-starting { background: var(--hf-warn); animation: pulse 1.5s ease-in-out infinite; }
    /* A blue/green standby unit being inactive is its expected steady
       state, not an error — render it muted, like an unknown unit. */
    .unit-dot.unit-standby,
    .unit-dot.unit-unknown  { background: var(--hf-text-subtle); }

    /* Each toggle is a row inside the card: label on the left, switch
       pushed to the right edge by margin-left:auto on the switch. The
       label stays glued to the start of the line, so on a very wide
       card the label and switch are not flung to opposite ends —
       margin-left:auto keeps the pairing correct at any card width. */
    .toggle-container {
      display: flex;
      align-items: center;
      gap: 10px;
    }
    .toggle-container .toggle-switch {
      margin-left: auto;
    }

    .toggle-label {
      font-size: 13px;
      color: var(--hf-text-muted);
    }

    .toggle-switch {
      position: relative;
      width: 44px;
      height: 24px;
    }

    .toggle-switch input {
      opacity: 0;
      width: 0;
      height: 0;
    }

    .toggle-slider {
      position: absolute;
      cursor: pointer;
      top: 0;
      left: 0;
      right: 0;
      bottom: 0;
      background-color: var(--hf-border-2);
      transition: 0.3s;
      border-radius: 24px;
    }

    .toggle-slider:before {
      position: absolute;
      content: "";
      height: 18px;
      width: 18px;
      left: 3px;
      bottom: 3px;
      background-color: var(--hf-text);
      transition: 0.3s;
      border-radius: 50%;
    }

    input:checked + .toggle-slider {
      background-color: var(--hf-accent);
    }

    input:checked + .toggle-slider:before {
      transform: translateX(20px);
    }

    input:disabled + .toggle-slider {
      opacity: 0.5;
      cursor: not-allowed;
    }

    .secrets-section {
      padding: 16px;
    }

    .secrets-header {
      font-size: 14px;
      font-weight: 500;
      color: var(--hf-accent);
      margin-bottom: 12px;
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .secrets-content {
      padding-left: 24px;
    }

    .loading-spinner {
      text-align: center;
      padding: 40px;
      color: var(--hf-text-muted);
    }

    .error-box {
      background: rgba(59, 130, 246, 0.08);
      border-left: 4px solid var(--hf-err);
      border-radius: 8px;
      padding: 14px 18px;
      margin-bottom: 20px;
      font-size: 13px;
      line-height: 1.5;
      color: var(--hf-text-muted);
    }
    .error-box strong { color: var(--hf-text); }

    .no-results {
      text-align: center;
      padding: 40px;
      color: var(--hf-text-muted);
    }

    .refresh-button {
      background: var(--hf-accent);
      color: #06281c;
      border: none;
      padding: 8px 16px;
      border-radius: 6px;
      font-size: 13px;
      cursor: pointer;
      margin-left: 12px;
      transition: background 0.2s;
    }

    .refresh-button:hover {
      background: var(--hf-accent-hover);
    }

    .refresh-button:disabled {
      background: var(--hf-border-2);
      cursor: not-allowed;
    }

    /* Child services (instances) — a stack of nested <app-card>s
       inside an expanded parent's config section. */
    .child-services {
      margin-top: 8px;
      padding-left: 16px;
      border-left: 2px solid var(--hf-border);
      display: flex;
      flex-direction: column;
      gap: 8px;
    }

    /* Instance management buttons */
    .add-instance-button {
      background: var(--hf-accent);
      color: #06281c;
      border: none;
      padding: 10px 16px;
      border-radius: 8px;
      font-size: 13px;
      cursor: pointer;
      margin-top: 12px;
      transition: background 0.2s;
      width: 100%;
    }

    .add-instance-button:hover {
      background: var(--hf-accent-hover);
    }

    .delete-instance-button {
      background: var(--hf-err);
      color: var(--hf-text);
      border: none;
      padding: 8px 16px;
      border-radius: 6px;
      font-size: 13px;
      cursor: pointer;
      transition: background 0.2s;
    }

    .delete-instance-button:hover {
      background: #dc2626;
    }

    /* A failed lifecycle action surfaces its error under the toggle
       footer (the icon-buttons themselves are too small to caption). */
    .action-error {
      color: var(--hf-err);
      font-size: 11px;
      margin-top: 8px;
      word-break: break-word;
    }

    /* The card grid is responsive on its own (auto-fill minmax) — it
       collapses to one column on narrow screens with no extra rules. */
  `;

  constructor() {
    super();
    this.services = [];
    this.serverConfig = null;
    this.pendingConfig = {};
    this.loading = true;
    this.error = null;
    this.searchQuery = '';
    this.apiUnavailable = false;
    this.pollInterval = null;
    this.pollIntervalMs = 5000; // Poll every 5 seconds
    this.secretsSchema = {};
    this.secretsStatus = {};
    this.optionsSchema = {};
    this.hasAuthorizedKeys = false;
    this.expandedServices = new Set();
    this.pendingActions = {};
    this.actionErrors = {};
  }

  async connectedCallback() {
    super.connectedCallback();

    // CRITICAL: Stop polling before page unload to prevent connection limit race condition
    this.beforeUnloadHandler = () => {
      this.stopPolling();
    };
    window.addEventListener('beforeunload', this.beforeUnloadHandler);

    await Promise.all([
      this.loadServices(),
      this.loadSecretsData(),
      this.loadOptionsSchema()
    ]);
    this.startPolling();
  }

  disconnectedCallback() {
    super.disconnectedCallback();

    // Remove beforeunload listener
    if (this.beforeUnloadHandler) {
      window.removeEventListener('beforeunload', this.beforeUnloadHandler);
    }

    this.stopPolling();
  }

  startPolling() {
    // Clear any existing interval
    this.stopPolling();

    // Start polling for service status updates
    this.pollInterval = setInterval(async () => {
      await this.loadServices(false); // Don't show loading spinner on polls
    }, this.pollIntervalMs);
  }

  stopPolling() {
    if (this.pollInterval) {
      clearInterval(this.pollInterval);
      this.pollInterval = null;
    }
  }

  async loadServices(showLoadingSpinner = true) {
    // Only show loading spinner on initial load, not on polling updates
    if (showLoadingSpinner && this.services.length === 0) {
      this.loading = true;
    }
    // Don't clear error on retry - let it persist until successful load
    // this.error = null;

    try {
      const services = await getServices();

      // Clear error and API unavailable flag on successful load
      this.error = null;
      this.apiUnavailable = false;

      // Merge server services with pending changes for display
      // Pending changes from parent override server state
      this.services = services.map(service => {
        const pendingService = this.pendingConfig?.services?.[service.label];
        if (pendingService) {
          // Use pending values for enabled/public, but keep runtime status from server
          return {
            ...service,
            enabled: pendingService.enable,
            public: pendingService.public
          };
        }
        // No pending changes for this service, use server data
        return service;
      });
    } catch (error) {
      console.error('Error loading services:', error);
      // Only show error if we have no services to display (first load failed)
      // Otherwise, keep showing stale data during temporary API unavailability
      if (this.services.length === 0) {
        this.error = error.message || 'Failed to load services';
        this.apiUnavailable = false;
      } else {
        // Mark API as temporarily unavailable but keep showing cached data
        this.apiUnavailable = true;
        console.warn('API temporarily unavailable, showing cached service list');
      }
    } finally {
      this.loading = false;
    }
  }

  async loadSecretsData() {
    try {
      // Load secrets schema
      const schemaResponse = await fetch('/api/secrets/schema');
      if (schemaResponse.ok) {
        const schemaData = await schemaResponse.json();
        this.secretsSchema = schemaData.schema || {};
      }

      // Load secrets status
      const statusResponse = await fetch('/api/secrets/status');
      if (statusResponse.ok) {
        const statusData = await statusResponse.json();
        this.secretsStatus = statusData.secrets || {};
      }

      // Note: hasAuthorizedKeys is now passed from parent (admin-app)
    } catch (error) {
      console.error('Error loading secrets data:', error);
      // Non-fatal - secrets UI will show appropriate disabled state
    }
  }

  async loadOptionsSchema() {
    try {
      const response = await fetch('/api/services/options/schema');
      if (response.ok) {
        const data = await response.json();
        this.optionsSchema = data.schema || {};
      }
    } catch (error) {
      console.error('Error loading service options schema:', error);
      // Non-fatal - options will just not display if schema fails to load
    }
  }

  toggleSecretsExpanded(serviceLabel) {
    const expanded = new Set(this.expandedServices);
    if (expanded.has(serviceLabel)) {
      expanded.delete(serviceLabel);
    } else {
      expanded.add(serviceLabel);
    }
    this.expandedServices = expanded;
  }

  async handleSecretUpdated(event) {
    // Reload secrets status after a secret is updated
    await this.loadSecretsData();
  }

  handleServiceToggle(serviceLabel, enabled) {
    // Update local services array for immediate UI feedback
    this.services = this.services.map(s =>
      s.label === serviceLabel ? { ...s, enabled } : s
    );

    // Emit action event to parent - parent manages state
    this.dispatchEvent(new CustomEvent('service-toggle', {
      detail: { serviceLabel, enabled },
      bubbles: true,
      composed: true
    }));
  }

  handlePublicToggle(serviceLabel, isPublic) {
    // Update local services array for immediate UI feedback
    this.services = this.services.map(s =>
      s.label === serviceLabel ? { ...s, public: isPublic } : s
    );

    // Emit action event to parent - parent manages state
    this.dispatchEvent(new CustomEvent('service-public-toggle', {
      detail: { serviceLabel, isPublic },
      bubbles: true,
      composed: true
    }));
  }

  handleInstanceToggle(parentLabel, instanceLabel, enabled) {
    // Update local services array for immediate UI feedback
    this.services = this.services.map(s =>
      s.label === instanceLabel ? { ...s, enabled } : s
    );

    // Emit action event to parent - parent manages state
    this.dispatchEvent(new CustomEvent('instance-toggle', {
      detail: { parentLabel, instanceLabel, enabled },
      bubbles: true,
      composed: true
    }));
  }

  handleInstancePublicToggle(parentLabel, instanceLabel, isPublic) {
    // Update local services array for immediate UI feedback
    this.services = this.services.map(s =>
      s.label === instanceLabel ? { ...s, public: isPublic } : s
    );

    // Emit action event to parent - parent manages state
    this.dispatchEvent(new CustomEvent('instance-public-toggle', {
      detail: { parentLabel, instanceLabel, isPublic },
      bubbles: true,
      composed: true
    }));
  }

  handleOptionChanged(serviceLabel, optionKey, value) {
    // Emit action event to parent - parent manages all config state
    this.dispatchEvent(new CustomEvent('service-option-changed', {
      detail: { serviceLabel, optionKey, value },
      bubbles: true,
      composed: true
    }));
  }

  handleInstanceFieldChanged(parentLabel, instanceIndex, fieldKey, value) {
    // Emit action event to parent - parent manages all config state
    this.dispatchEvent(new CustomEvent('instance-field-changed', {
      detail: { parentLabel, instanceIndex, fieldKey, value },
      bubbles: true,
      composed: true
    }));
  }

  handleAddInstanceClick(parentLabel) {
    console.log('[handleAddInstanceClick] Called with parentLabel:', parentLabel);
    // Emit action event to parent - parent manages state
    this.dispatchEvent(new CustomEvent('instance-add', {
      detail: { parentLabel },
      bubbles: true,
      composed: true
    }));
    console.log('[handleAddInstanceClick] Event dispatched');
  }

  handleInstanceDeleteClick(parentLabel, instanceIndex) {
    // Emit action event to parent - parent manages state
    this.dispatchEvent(new CustomEvent('instance-delete', {
      detail: { parentLabel, instanceIndex },
      bubbles: true,
      composed: true
    }));
  }

  handleSearch(e) {
    this.searchQuery = e.target.value.toLowerCase();
  }

  async handleRefresh() {
    await this.loadServices();
  }

  async handleServiceAction(label, action) {
    if (action === 'stop') {
      const ok = await confirmDialog({
        title: 'Stop service?',
        message: `Stop ${label}? The service will not auto-restart until you start it manually or rebuild.`,
        confirmText: 'Stop',
        variant: 'danger',
      });
      if (!ok) return;
    }
    this.pendingActions = { ...this.pendingActions, [label]: action };
    this.actionErrors = { ...this.actionErrors, [label]: null };
    try {
      const res = await postServiceAction(label, action);
      if (!res || res.ok === false) {
        const firstErr = (res?.results || []).find(r => r.returncode !== 0);
        throw new Error(firstErr?.stderr || 'systemctl returned non-zero');
      }
      // Kick a status refresh so the UI catches up faster than the poll
      await this.loadServices(false);
    } catch (err) {
      console.error(`[handleServiceAction] ${action} ${label} failed:`, err);
      this.actionErrors = {
        ...this.actionErrors,
        [label]: err.message || `${action} failed`,
      };
    } finally {
      const next = { ...this.pendingActions };
      delete next[label];
      this.pendingActions = next;
    }
  }

  getStatusClass(activeState, subState, partial = false) {
    if (activeState === 'active' && subState === 'running') {
      return 'running';  // Green - includes partial
    } else if (activeState === 'active' && subState === 'degraded') {
      return 'degraded';  // Yellow - some units up, some down
    } else if (activeState === 'failed') {
      return 'failed';  // Red - all-failed case
    } else if (activeState === 'activating' || subState === 'start') {
      return 'starting';  // Orange
    } else if (activeState === 'inactive' || subState === 'dead') {
      return 'stopped';  // Grey
    }
    return 'unknown';  // Grey
  }

  getStatusText(activeState, subState, enabled, partial = false) {
    if (!enabled) {
      return 'Disabled';
    }
    if (activeState === 'active' && subState === 'running') {
      return partial ? 'Running (partial)' : 'Running';
    } else if (activeState === 'active' && subState === 'degraded') {
      return 'Degraded';  // Some units up, some not
    } else if (activeState === 'failed') {
      return 'Failed';  // All units failed
    } else if (activeState === 'activating') {
      return 'Starting';
    } else if (activeState === 'inactive' && subState === 'dead') {
      return 'Stopped';
    } else if (activeState === 'reloading') {
      return 'Reloading';
    }
    return `${activeState} (${subState})`;
  }

  getChildServices(parentLabel) {
    // Get child services from backend
    const backendChildren = this.services.filter(s => s.parent === parentLabel);

    // Get instances from pending config, falling back to server config
    const pendingInstances = this.pendingConfig?.services?.[parentLabel]?.instances ||
                            this.serverConfig?.services?.[parentLabel]?.instances ||
                            [];

    if (pendingInstances.length === 0) {
      return backendChildren;
    }

    // Create child service objects for pending instances not yet in backend
    const pendingChildren = pendingInstances.map((inst, index) => {
      const instanceId = `${parentLabel}_${inst.subdomain}`;

      // Check if already exists in backend children
      const existingChild = backendChildren.find(child => child.label === instanceId);
      if (existingChild) {
        // Update existing child with pending config values
        return {
          ...existingChild,
          enabled: inst.enable ?? existingChild.enabled,
          public: inst.public ?? existingChild.public,
          instanceIndex: index  // Add stable instance index
        };
      }

      // Create synthetic child service for pending instance not yet in backend
      return {
        label: instanceId,
        name: `${parentLabel.charAt(0).toUpperCase() + parentLabel.slice(1)} - ${inst.name}`,
        project_name: parentLabel.charAt(0).toUpperCase() + parentLabel.slice(1),
        enabled: inst.enable ?? true,
        public: inst.public ?? false,
        active_state: 'inactive',
        sub_state: 'dead',
        systemd_services: [],
        url: null,
        parent: parentLabel,
        instanceIndex: index  // Add stable instance index
      };
    });

    return pendingChildren;
  }

  renderServiceCard(service) {
    const statusClass = this.getStatusClass(service.active_state, service.sub_state, service.partial);
    const statusText = this.getStatusText(service.active_state, service.sub_state, service.enabled, service.partial);
    const isEnabled = service.enabled;
    const isPublic = service.public;

    // Check if this service has child instances
    const childServices = this.getChildServices(service.label);
    const hasChildren = childServices.length > 0;

    // Admin service can't be disabled (no enable toggle)
    const cannotDisable = service.label === 'admin' || service.label === 'admin-api';
    const isAdminApi = service.label === 'admin-api';

    // Check if service has configuration options (secrets, options)
    const hasSecrets = this.secretsSchema[service.label] && Object.keys(this.secretsSchema[service.label]).length > 0;
    const serviceOptions = this.optionsSchema[service.label] || {};
    // Filter out standard enable/public options, sops-managed options, and instances (handled as child services)
    const extraOptions = Object.keys(serviceOptions).filter(key =>
      key !== 'enable' &&
      key !== 'public' &&
      key !== 'instances' &&
      !serviceOptions[key]['sops-managed']
    );
    const hasExtraOptions = extraOptions.length > 0;
    // The per-unit systemd list now lives inside the expander, so a
    // running multi-unit service with no other options must still be
    // expandable — hasUnits feeds hasConfig for that reason.
    const hasUnits = isEnabled && !service.parent &&
      service.systemd_services && service.systemd_services.length > 0;
    // SSO posture also lives inside the expander; a service with a real
    // SSO row (anything but an 'infra' bridge service) must stay
    // expandable even when it has no other config.
    const hasSso = !service.parent && (service.sso_kind || 'none') !== 'infra';
    let hasConfig = hasSecrets || hasExtraOptions || hasChildren || hasUnits || hasSso;

    // For child services (instances), check if parent has instance configuration
    if (service.parent) {
      const parentOptions = this.optionsSchema[service.parent] || {};
      const instancesOption = parentOptions['instances'];
      if (instancesOption && instancesOption['submodule-fields']) {
        const configFields = instancesOption['submodule-fields'].filter(f =>
          f.path !== 'enable' && f.path !== 'public'
        );
        if (configFields.length > 0) {
          hasConfig = true;
        }
      }
    }

    // Use stable identifier for expand state (instance index for children, label for parents)
    const expandId = service.instanceIndex !== undefined
      ? `${service.parent}:instance:${service.instanceIndex}`
      : service.label;
    const isExpanded = this.expandedServices.has(expandId);

    // The whole service is one <app-card>, organised into three zones:
    //   - header slot: a status badge + lifecycle icon-buttons, pinned
    //     beside the icon/title.
    //   - default slot: an aligned meta block (just the URL) then a
    //     toggle footer, then the expandable details section.
    // The expander (SSO posture + systemd unit list + config form)
    // grows the card taller in its own grid cell — it does not widen
    // the card or reflow the grid.
    const actionErr = this.actionErrors[service.label];

    return html`
      <app-card
        ?enabled=${isEnabled}
        .label=${service.parent || service.label}
        .name=${service.name}
        .subtitle=${service.project_name || ''}
      >
        <div slot="header" class="card-head">
          <span class="status-badge ${statusClass}" title="${statusText}">
            ${statusText}
          </span>
          ${this.renderIconActions(service)}
        </div>

        ${this.renderMetaBlock(service, isEnabled)}

        ${cannotDisable ? html`
          <div class="system-note">
            ${isAdminApi ? 'System service' : 'System service — always enabled'}
          </div>
        ` : html`
          <div class="card-footer">
            <div class="toggle-container">
              <span class="toggle-label">Enable</span>
              <label class="toggle-switch">
                <input
                  type="checkbox"
                  .checked=${isEnabled}
                  @change=${(e) => {
                    if (service.parent) {
                      this.handleInstanceToggle(service.parent, service.label, e.target.checked);
                    } else {
                      this.handleServiceToggle(service.label, e.target.checked);
                    }
                  }}
                />
                <span class="toggle-slider"></span>
              </label>
            </div>

            ${isEnabled ? html`
              <div class="toggle-container">
                <span class="toggle-label">Expose to internet</span>
                <label class="toggle-switch">
                  <input
                    type="checkbox"
                    .checked=${isPublic}
                    @change=${(e) => {
                      if (service.parent) {
                        this.handleInstancePublicToggle(service.parent, service.label, e.target.checked);
                      } else {
                        this.handlePublicToggle(service.label, e.target.checked);
                      }
                    }}
                  />
                  <span class="toggle-slider"></span>
                </label>
              </div>
            ` : ''}
          </div>
        `}

        ${actionErr ? html`<div class="action-error">${actionErr}</div>` : ''}

        ${this.renderConfigSection(service, hasConfig, isExpanded, expandId)}
      </app-card>
    `;
  }

  /* The aligned meta block: a [label | value] grid carrying just the
     service URL. SSO posture lives inside the "Details & Config"
     expander instead (see renderSsoSection). Returns '' when there is
     nothing to show (e.g. a disabled service, or an infra service with
     no URL), so the card collapses to just header + footer. */
  renderMetaBlock(service, isEnabled) {
    if (!(service.url && isEnabled)) return '';

    return html`
      <div class="card-meta">
        <span class="meta-label">URL</span>
        <a class="meta-value" href="${service.url}" target="_blank" rel="noopener">
          <span>${service.url.replace(/^https?:\/\//, '')}</span>
          ${actionIcon('external-link')}
        </a>
      </div>
    `;
  }

  /* The SSO posture as a section inside the "Details & Config"
     expander. It used to sit on the always-visible card face as
     coloured text that read like the URL link; rendering it here as a
     pill — beside the systemd unit list — keeps it distinct and groups
     all of a service's status in one place.
     Backend (resolvers/services.py) supplies sso_kind, sso_provisioned
     and sso_applicable. Returns '' for 'infra' services (Zitadel,
     oauth2-proxy) — they are the bridge itself, not a consumer. */
  renderSsoSection(service) {
    const kind = service.sso_kind || 'none';
    if (kind === 'infra') return '';

    const typeLabel = ({
      native_oidc: 'Native OIDC',
      caddy_gated: 'Caddy oauth2-proxy',
      basic_auth: 'Caddy + Basic-Auth bridge',
    })[kind];

    let pill;
    if (kind === 'none') {
      // sso_applicable distinguishes a deliberate "not applicable"
      // posture (false) from an integration that is simply pending
      // (true). The reasoning lives in a code comment beside each
      // service's sso block, not in the UI.
      pill = service.sso_applicable === false
        ? html`<span class="sso-pill disabled">Not applicable</span>`
        : html`<span class="sso-pill disabled">Not yet implemented</span>`;
    } else {
      pill = service.sso_provisioned
        ? html`<span class="sso-pill ok">${typeLabel}</span>`
        : html`<span class="sso-pill warn">${typeLabel} (pending)</span>`;
    }

    return html`
      <div class="secrets-section">
        <div class="secrets-header">
          <span>Single sign-on</span>
        </div>
        <div class="secrets-content">${pill}</div>
      </div>
    `;
  }

  /* Compact play / restart / stop icon-buttons for the card header.
     Returns '' (no buttons) for:
     - the admin-api / admin services themselves (acting on them would
       cut the request that issued the action; backend also refuses)
     - services with no backing systemd units (admin parent rows,
       synthetic pending instances not yet realized)
     - a disabled service — enable it via the toggle + rebuild first;
       showing buttons would lie about what they do (the unit may not
       even exist while disabled). */
  renderIconActions(service) {
    if (service.label === 'admin' || service.label === 'admin-api') return '';
    if (!service.systemd_services || service.systemd_services.length === 0) return '';
    if (!service.enabled) return '';

    const pending = this.pendingActions[service.label];
    const cls = this.getStatusClass(service.active_state, service.sub_state, service.partial);
    const isRunning = cls === 'running' || cls === 'degraded';
    const isStopped = cls === 'stopped' || cls === 'failed';

    const btn = (action, glyph, danger, disabled, verb) => html`
      <button
        class="icon-action ${danger ? 'danger' : ''} ${pending === action ? 'busy' : ''}"
        ?disabled=${!!pending || disabled}
        title="${pending === action ? `${verb}…` : verb}"
        aria-label="${verb}"
        @click=${() => this.handleServiceAction(service.label, action)}
      >
        ${actionIcon(glyph)}
      </button>
    `;

    return html`
      <div class="icon-actions">
        ${btn('start', 'play', false, isRunning, 'Start')}
        ${btn('restart', 'restart', false, isStopped, 'Restart')}
        ${btn('stop', 'stop', true, isStopped, 'Stop')}
      </div>
    `;
  }

  /* The per-unit systemd health list — one row per unit, a small status
     dot + the unit name. Lives inside the "Details & Config" expander; it
     used to crowd the card face as a monospace comma list. */
  renderSystemdSection(service) {
    if (service.parent) return '';
    if (!service.enabled) return '';
    if (!service.systemd_services || service.systemd_services.length === 0) return '';

    const units = (service.unit_states && service.unit_states.length > 0)
      ? service.unit_states
      : service.systemd_services.map(n => ({
          name: n,
          active_state: 'unknown',
          sub_state: 'unknown',
        }));

    return html`
      <div class="secrets-section">
        <div class="secrets-header">
          <span>Systemd units (${units.length})</span>
        </div>
        <div class="secrets-content">
          <div class="systemd-units">
            ${units.map(u => {
              const healthy  = u.active_state === 'active' && u.sub_state === 'running';
              // A blue/green standby unit being inactive is its expected
              // steady state, so it is NOT an error.
              const standby  = u.bg_role === 'standby';
              const unknown  = u.active_state === 'unknown';
              const starting = u.active_state === 'activating'
                            || u.active_state === 'reloading'
                            || u.sub_state === 'start';
              const cls = healthy  ? 'unit-ok'
                        : standby  ? 'unit-standby'
                        : unknown  ? 'unit-unknown'
                        : starting ? 'unit-starting'
                        :            'unit-bad';
              const tip = healthy
                ? `${u.active_state} (${u.sub_state})`
                : standby
                  ? `${u.active_state} (${u.sub_state}) — standby (blue/green)`
                  : unknown
                    ? 'status unknown'
                    : starting
                      ? `${u.active_state} (${u.sub_state}) — starting`
                      : `${u.active_state} (${u.sub_state}) — not healthy`;
              return html`
                <div class="systemd-unit" title="${tip}">
                  <span class="unit-dot ${cls}"></span>
                  <span>${u.name}</span>
                </div>
              `;
            })}
          </div>
        </div>
      </div>
    `;
  }

  renderConfigSection(service, hasConfig, isExpanded, expandId) {
    if (!hasConfig) {
      return ''; // No config options for this service
    }

    return html`
      <div
        class="config-expander ${isExpanded ? 'expanded' : ''}"
        @click=${() => this.toggleSecretsExpanded(expandId)}
      >
        <span class="config-expander-arrow">▶</span>
        <span>${isExpanded ? 'Hide details & config' : 'Details & Config'}</span>
      </div>

      ${isExpanded ? html`
        ${service.parent ? this.renderInstanceConfig(service) : html`
          ${this.renderChildInstances(service)}
          ${this.renderOptionsSection(service)}
          ${this.renderSecretsSection(service)}
          ${this.renderSsoSection(service)}
          ${this.renderSystemdSection(service)}
        `}
      ` : ''}
    `;
  }

  renderChildInstances(service) {
    const childServices = this.getChildServices(service.label);

    // Check if this service supports instances
    const serviceOptions = this.optionsSchema[service.label] || {};
    const instancesOption = serviceOptions['instances'];
    const hasInstancesOption = instancesOption &&
      (instancesOption.type === 'listOf submodule' ||
       instancesOption.type?.includes('listOf'));

    if (!hasInstancesOption && childServices.length === 0) {
      return '';
    }

    return html`
      <div class="secrets-section">
        <div class="secrets-header">
          <span>Instances ${childServices.length > 0 ? `(${childServices.length})` : ''}</span>
        </div>

        <div class="child-services">
          ${childServices.map(child => this.renderServiceCard(child))}

          ${hasInstancesOption ? html`
            <button
              class="add-instance-button"
              @click=${(e) => { e.stopPropagation(); this.handleAddInstanceClick(service.label); }}
            >
              + Add Instance
            </button>
          ` : ''}
        </div>
      </div>
    `;
  }

  renderInstanceConfig(instance) {
    // Get parent service label and instance index
    const parentLabel = instance.parent;
    const instanceIndex = instance.instanceIndex;

    if (!parentLabel || instanceIndex === undefined) return '';

    // Get parent service options schema to access instances submodule definition
    const parentOptions = this.optionsSchema[parentLabel] || {};
    const instancesOption = parentOptions['instances'];
    if (!instancesOption || !instancesOption.type?.includes('listOf')) {
      console.warn('[renderInstanceConfig] No instances option found for parent:', parentLabel, instancesOption);
      return ''; // No instances configuration available
    }

    // Get the submodule fields that define instance configuration
    const instanceFields = instancesOption['submodule-fields'] || [];

    // Get current instances array from config
    const currentInstances = this.pendingConfig.services?.[parentLabel]?.instances ||
                            this.serverConfig?.services?.[parentLabel]?.instances ||
                            [];

    const currentInstance = currentInstances[instanceIndex];

    if (!currentInstance) {
      console.warn('[renderInstanceConfig] Instance not found at index:', instanceIndex);
      return '';
    }

    return html`
      <div class="secrets-section">
        <div class="secrets-header">
          <span>Instance Configuration</span>
        </div>

        <div class="secrets-content">
          ${instanceFields.map(field => {
            // Skip enable and public - they're handled by toggles
            if (field.path === 'enable' || field.path === 'public') {
              return '';
            }

            const currentValue = currentInstance?.[field.path];
            const label = field.path
              .split('-')
              .map(word => word.charAt(0).toUpperCase() + word.slice(1))
              .join(' ');

            return html`
              <service-option-input
                .optionKey=${field.path}
                .label=${label}
                .description=${field.description || ''}
                .type=${field.type}
                .defaultValue=${field.default}
                .currentValue=${currentValue}
                .submoduleFields=${field['submodule-fields'] || []}
                .enumValues=${field['enum-values'] || []}
                .uiHint=${field['ui-hint'] || null}
                .nullable=${field.nullable || false}
                .required=${field.required || false}
                @option-changed=${(e) => this.handleInstanceFieldChanged(parentLabel, instanceIndex, e.detail.optionKey, e.detail.value)}
              ></service-option-input>
            `;
          })}

          <div style="margin-top: 16px; padding-top: 16px; border-top: 1px solid var(--hf-border);">
            <button
              class="delete-instance-button"
              @click=${() => this.handleInstanceDeleteClick(parentLabel, instanceIndex)}
            >
              Delete Instance
            </button>
          </div>
        </div>
      </div>
    `;
  }

  renderOptionsSection(service) {
    const serviceOptions = this.optionsSchema[service.label] || {};
    // Filter out standard enable/public options, sops-managed options, and instances (handled as child services)
    const extraOptions = Object.keys(serviceOptions).filter(key =>
      key !== 'enable' &&
      key !== 'public' &&
      key !== 'instances' &&
      !serviceOptions[key]['sops-managed']
    );

    if (extraOptions.length === 0) {
      return ''; // No extra options for this service
    }

    return html`
      <div class="secrets-section">
        <div class="secrets-header">
          <span>Configuration Options</span>
        </div>

        <div class="secrets-content">
          ${extraOptions.map(optionKey => {
            const optionDef = serviceOptions[optionKey];
            const currentValue = this.pendingConfig.services?.[service.label]?.[optionKey]
              ?? this.serverConfig?.services?.[service.label]?.[optionKey];
            const label = optionKey
              .split('-')
              .map(word => word.charAt(0).toUpperCase() + word.slice(1))
              .join(' ');

            return html`
              <service-option-input
                .optionKey=${optionKey}
                .label=${label}
                .description=${optionDef.description || ''}
                .type=${optionDef.type}
                .defaultValue=${optionDef.default}
                .currentValue=${currentValue}
                .submoduleFields=${optionDef['submodule-fields'] || []}
                .enumValues=${optionDef['enum-values'] || []}
                .uiHint=${optionDef['ui-hint'] || null}
                @option-changed=${(e) => this.handleOptionChanged(service.label, e.detail.optionKey, e.detail.value)}
              ></service-option-input>
            `;
          })}
        </div>
      </div>
    `;
  }

  renderSecretsSection(service) {
    const secrets = this.secretsSchema[service.label];
    if (!secrets || Object.keys(secrets).length === 0) {
      return ''; // No secrets for this service
    }

    const secretsCount = Object.keys(secrets).length;
    const statusObj = this.secretsStatus[service.label] || {};
    const setCount = Object.values(statusObj).filter(v => v).length;

    return html`
      <div class="secrets-section">
        <div class="secrets-header">
          <span>Secrets (${setCount}/${secretsCount} configured)</span>
          ${!this.hasAuthorizedKeys ? html`
            <span style="color: var(--hf-err); font-size: 12px;">⚠️ SSH key required</span>
          ` : ''}
        </div>

        <div class="secrets-content">
          ${Object.entries(secrets).map(([secretKey, secretInfo]) => {
            const exists = statusObj[secretKey] || false;
            return html`
              <secrets-input
                .serviceLabel=${service.label}
                .secretKey=${secretKey}
                .label=${secretKey.replace(/([A-Z])/g, ' $1').replace(/^./, str => str.toUpperCase())}
                .description=${secretInfo.description || ''}
                .required=${secretInfo.required || false}
                .disabled=${!this.hasAuthorizedKeys}
                .exists=${exists}
                @secret-updated=${this.handleSecretUpdated}
              ></secrets-input>
            `;
          })}
        </div>
      </div>
    `;
  }

  render() {
    if (this.loading) {
      return html`
        <div class="module-container">
          <div class="loading-spinner">
            Loading apps...
          </div>
        </div>
      `;
    }

    if (this.error) {
      return html`
        <div class="module-container">
          <div class="error-box">
            <strong>Error loading services:</strong> ${this.error}
            <button class="refresh-button" @click=${this.handleRefresh}>
              Retry
            </button>
          </div>
        </div>
      `;
    }

    // Filter out child services (those with parent field) - they'll be rendered inside parent
    const parentServices = this.services.filter(service => !service.parent);

    // Sort by status severity: services that need attention float to the
    // top so they're visible without scrolling. Within a status bucket,
    // fall back to the service display name for stable ordering.
    const statusPriority = {
      failed: 0,
      degraded: 1,
      stopped: 2,
      starting: 3,
      running: 4,
      unknown: 5,
      disabled: 6,
    };
    const sortKey = (service) => {
      if (!service.enabled) return statusPriority.disabled;
      const cls = this.getStatusClass(service.active_state, service.sub_state, service.partial);
      return statusPriority[cls] ?? statusPriority.unknown;
    };
    const sortedParents = [...parentServices].sort((a, b) => {
      const pa = sortKey(a), pb = sortKey(b);
      if (pa !== pb) return pa - pb;
      return (a.name || a.label).localeCompare(b.name || b.label);
    });

    // Filter services based on search query
    const filteredServices = sortedParents.filter(service => {
      const searchLower = this.searchQuery.toLowerCase();
      return (
        service.name.toLowerCase().includes(searchLower) ||
        service.project_name.toLowerCase().includes(searchLower) ||
        service.label.toLowerCase().includes(searchLower)
      );
    });

    // Header counts must describe the cards actually on screen, i.e.
    // top-level parents (`parentServices`) — child instances render
    // nested inside their parent and must not be counted separately.
    //
    // A parent with no backing systemd units AND no child instances is
    // an "external" entry: a reverse-proxy / static-path vhost that
    // points off-box (or has no local process). It has no run-state to
    // report, so it can never be "running" — it gets its own bucket
    // instead of silently dragging down the running count.
    let runningCount = 0;
    let disabledCount = 0;
    let externalCount = 0;
    for (const service of parentServices) {
      if (service.enabled) {
        const hasUnits = service.systemd_services && service.systemd_services.length > 0;
        const hasChildren = this.getChildServices(service.label).length > 0;
        if (!hasUnits && !hasChildren) {
          externalCount++;
        } else if (service.active_state === 'active' && service.sub_state === 'running') {
          runningCount++;
        }
      } else {
        disabledCount++;
      }
    }
    const totalCount = parentServices.length;

    return html`
      <div class="module-container">
        ${this.apiUnavailable ? html`
          <div class="warning-box">
            API temporarily unavailable (possibly due to system rebuild). Showing cached service list. Status updates will resume automatically.
          </div>
        ` : ''}

        <div class="info-box">
          <div class="info-text">
            <strong>${runningCount} running${externalCount > 0 ? html` / ${externalCount} external` : ''}${disabledCount > 0 ? html` / ${disabledCount} disabled` : ''} / ${totalCount} total apps</strong>
            <div style="margin-top: 8px; font-size: 13px;">
              Enable/disable apps and configure public WAN access. Running apps appear at the top.
            </div>
          </div>
          <button
            class="refresh-button"
            @click=${this.handleRefresh}
            ?disabled=${this.loading}
          >
            Refresh
          </button>
        </div>

        <div class="search-box">
          <input
            type="text"
            placeholder="Search apps..."
            .value=${this.searchQuery}
            @input=${this.handleSearch}
          />
        </div>

        <div class="service-grid">
          ${filteredServices.map(service => this.renderServiceCard(service))}
        </div>

        ${filteredServices.length === 0 ? html`
          <div class="no-results">
            No apps found matching "${this.searchQuery}"
          </div>
        ` : ''}
      </div>
    `;
  }
}

customElements.define('services-module', ServicesModule);
