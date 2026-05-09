import { LitElement, html, css } from 'lit';
import { getServices, getServiceOptionsSchema } from '../../../api/client.js';
import '../../shared/config-section.js';
import '../secrets-input.js';
import '../service-option-input.js';

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
    expandedServices: { type: Set, state: true } // Track which services have secrets expanded
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
      max-width: 1200px;
      display: flex;
      align-items: center;
      justify-content: space-between;
    }

    .info-text {
      flex: 1;
    }

    .warning-box {
      background: rgba(245, 158, 11, 0.1);
      border: 1px solid var(--hf-warn);
      border-radius: 8px;
      padding: 12px 16px;
      margin-bottom: 16px;
      font-size: 13px;
      color: var(--hf-warn);
      max-width: 1200px;
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
      max-width: 1200px;
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

    .services-list {
      max-width: 1200px;
    }

    .service-row {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border);
      border-radius: 12px;
      padding: 16px;
      margin-bottom: 12px;
      transition: all 0.2s;
    }

    .service-row:hover {
      box-shadow: 0 4px 12px rgba(0, 0, 0, 0.1);
    }

    .service-row.enabled {
      border-color: var(--hf-accent);
    }

    .service-row-main {
      display: flex;
      align-items: center;
      gap: 16px;
    }

    .config-expander {
      padding: 12px 16px;
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

    .status-indicator {
      display: flex;
      align-items: center;
      gap: 8px;
      min-width: 120px;
    }

    .status-dot {
      width: 12px;
      height: 12px;
      border-radius: 50%;
      flex-shrink: 0;
    }

    .status-dot.running {
      background: var(--hf-ok);
      box-shadow: 0 0 8px rgba(16, 185, 129, 0.5);
    }

    .status-dot.stopped {
      background: var(--hf-text-muted);
    }

    .status-dot.failed {
      background: var(--hf-err);
      box-shadow: 0 0 8px rgba(239, 68, 68, 0.5);
    }

    .status-dot.starting {
      background: var(--hf-warn);
      animation: pulse 1.5s ease-in-out infinite;
    }

    .status-dot.unknown {
      background: var(--hf-border-2);
    }

    @keyframes pulse {
      0%, 100% {
        opacity: 1;
      }
      50% {
        opacity: 0.5;
      }
    }

    .status-text {
      font-size: 13px;
      font-weight: 500;
      color: var(--hf-text-muted);
    }

    .status-text.running { color: var(--hf-ok); }
    .status-text.failed { color: var(--hf-err); }
    .status-text.starting { color: var(--hf-warn); }

    .service-info {
      flex: 1;
      min-width: 0;
    }

    .service-name {
      font-size: 16px;
      font-weight: 600;
      color: var(--hf-text);
      margin-bottom: 4px;
    }

    .service-project {
      font-size: 13px;
      color: var(--hf-text-muted);
      margin-bottom: 4px;
    }

    .service-url {
      font-size: 12px;
      color: var(--hf-accent);
      text-decoration: none;
      word-break: break-all;
    }

    .service-url:hover {
      text-decoration: underline;
    }

    .service-systemd {
      font-size: 11px;
      color: var(--hf-text-muted);
      font-family: 'SF Mono', Monaco, 'Courier New', monospace;
      margin-top: 4px;
    }

    .service-controls {
      display: flex;
      flex-direction: column;
      gap: 12px;
      align-items: flex-end;
    }

    .toggle-container {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .toggle-label {
      font-size: 13px;
      color: var(--hf-text-muted);
      min-width: 90px;
      text-align: right;
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
      background: rgba(239, 68, 68, 0.1);
      border: 1px solid var(--hf-err);
      border-radius: 8px;
      padding: 16px;
      margin-bottom: 20px;
      color: var(--hf-err);
      max-width: 1200px;
    }

    .no-results {
      text-align: center;
      padding: 40px;
      color: var(--hf-text-muted);
    }

    .refresh-button {
      background: var(--hf-accent);
      color: var(--hf-text);
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

    /* Child services (instances) styling */
    .child-services {
      margin-top: 8px;
      margin-left: 24px;
      padding-left: 16px;
      border-left: 2px solid var(--hf-border);
    }

    .service-row-child {
      background: var(--hf-surface-2);
      margin-bottom: 8px;
      padding: 12px;
    }

    .service-row-child .service-name {
      font-size: 14px;
    }

    .service-row-child .service-project {
      font-size: 12px;
    }

    /* Instance management buttons */
    .add-instance-button {
      background: var(--hf-accent);
      color: var(--hf-text);
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

    @media (max-width: 768px) {
      .service-row {
        flex-direction: column;
        align-items: flex-start;
        gap: 12px;
      }

      .status-indicator {
        width: 100%;
      }

      .service-controls {
        width: 100%;
        align-items: flex-start;
      }

      .toggle-container {
        width: 100%;
        justify-content: space-between;
      }

      .toggle-label {
        text-align: left;
      }
    }
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

  getStatusClass(activeState, subState, partial = false) {
    if (activeState === 'active' && subState === 'running') {
      return 'running';  // Green - includes partial
    } else if (activeState === 'active' && subState === 'degraded') {
      return 'failed';  // Red - actual degradation/problems
    } else if (activeState === 'failed') {
      return 'failed';  // Red
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
      return 'Degraded';  // Actual problems with enabled instances
    } else if (activeState === 'failed') {
      return 'Degraded';  // Failed = Degraded for consistency
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

  renderServiceRow(service) {
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
    let hasConfig = hasSecrets || hasExtraOptions || hasChildren;

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

    // Add child class if this service has a parent
    const childClass = service.parent ? 'service-row-child' : '';

    return html`
      <div class="service-row ${isEnabled ? 'enabled' : ''} ${childClass}">
        <div class="service-row-main">
          <div class="status-indicator">
            <div class="status-dot ${statusClass}"></div>
            <div class="status-text ${statusClass}">${statusText}</div>
          </div>

          <div class="service-info">
            <div class="service-name">${service.name}</div>
            <div class="service-project">${service.project_name}</div>
            ${service.url && isEnabled ? html`
              <a href="${service.url}" target="_blank" class="service-url">
                ${service.url}
              </a>
            ` : ''}
            ${service.systemd_services && service.systemd_services.length > 0 && isEnabled ? html`
              <div class="service-systemd">
                systemd: ${service.systemd_services.join(', ')}
              </div>
            ` : ''}
          </div>

          <div class="service-controls">
            ${!cannotDisable ? html`
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
            ` : ''}

            ${isEnabled && !isAdminApi ? html`
              <div class="toggle-container">
                <span class="toggle-label">Public (WAN)</span>
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

            ${cannotDisable ? html`
              <div class="toggle-label" style="color: var(--hf-text-muted); font-size: 12px;">
                ${isAdminApi ? 'System service' : 'System service (always enabled)'}
              </div>
            ` : ''}
          </div>
        </div>

        ${this.renderConfigSection(service, hasConfig, isExpanded, expandId)}
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
        <span>${isExpanded ? 'Hide settings' : 'More settings...'}</span>
      </div>

      ${isExpanded ? html`
        ${service.parent ? this.renderInstanceConfig(service) : html`
          ${this.renderChildInstances(service)}
          ${this.renderOptionsSection(service)}
          ${this.renderSecretsSection(service)}
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
          ${childServices.map(child => this.renderServiceRow(child))}

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
            Loading services...
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

    // Filter services based on search query
    const filteredServices = parentServices.filter(service => {
      const searchLower = this.searchQuery.toLowerCase();
      return (
        service.name.toLowerCase().includes(searchLower) ||
        service.project_name.toLowerCase().includes(searchLower) ||
        service.label.toLowerCase().includes(searchLower)
      );
    });

    const enabledCount = this.services.filter(s => s.enabled).length;
    const runningCount = this.services.filter(s =>
      s.active_state === 'active' && s.sub_state === 'running'
    ).length;

    return html`
      <div class="module-container">
        ${this.apiUnavailable ? html`
          <div class="warning-box">
            API temporarily unavailable (possibly due to system rebuild). Showing cached service list. Status updates will resume automatically.
          </div>
        ` : ''}

        <div class="info-box">
          <div class="info-text">
            <strong>${runningCount} running / ${enabledCount} enabled / ${this.services.length} total services</strong>
            <div style="margin-top: 8px; font-size: 13px;">
              Enable/disable services and configure public WAN access. Running services appear at the top.
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
            placeholder="Search services..."
            .value=${this.searchQuery}
            @input=${this.handleSearch}
          />
        </div>

        <div class="services-list">
          ${filteredServices.map(service => this.renderServiceRow(service))}
        </div>

        ${filteredServices.length === 0 ? html`
          <div class="no-results">
            No services found matching "${this.searchQuery}"
          </div>
        ` : ''}
      </div>
    `;
  }
}

customElements.define('services-module', ServicesModule);
