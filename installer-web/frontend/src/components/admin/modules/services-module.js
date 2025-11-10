import { LitElement, html, css } from 'lit';
import { getServices } from '../../../api/client.js';
import '../../shared/config-section.js';

/**
 * Services configuration module
 * Displays all services with runtime status, enable/disable toggles, and public access settings
 */
class ServicesModule extends LitElement {
  static properties = {
    services: { type: Array },
    config: { type: Object },
    loading: { type: Boolean },
    error: { type: String },
    searchQuery: { type: String },
    modified: { type: Boolean }
  };

  static styles = css`
    :host {
      display: block;
    }

    .module-container {
      width: 100%;
    }

    .info-box {
      background: #f5f5f7;
      border-radius: 8px;
      padding: 16px;
      margin-bottom: 20px;
      font-size: 14px;
      color: #1d1d1f;
      max-width: 1200px;
      display: flex;
      align-items: center;
      justify-content: space-between;
    }

    .info-text {
      flex: 1;
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
      border: 1px solid #d2d2d7;
      border-radius: 8px;
      font-family: inherit;
    }

    .search-box input:focus {
      outline: none;
      border-color: #667eea;
    }

    .services-list {
      max-width: 1200px;
    }

    .service-row {
      background: white;
      border: 1px solid #e5e5e7;
      border-radius: 12px;
      padding: 20px;
      margin-bottom: 12px;
      display: flex;
      align-items: center;
      gap: 20px;
      transition: all 0.2s;
    }

    .service-row:hover {
      box-shadow: 0 4px 12px rgba(0, 0, 0, 0.1);
    }

    .service-row.enabled {
      border-color: #667eea;
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
      background: #34c759;
      box-shadow: 0 0 8px rgba(52, 199, 89, 0.5);
    }

    .status-dot.stopped {
      background: #8e8e93;
    }

    .status-dot.failed {
      background: #ff3b30;
      box-shadow: 0 0 8px rgba(255, 59, 48, 0.5);
    }

    .status-dot.starting {
      background: #ff9500;
      animation: pulse 1.5s ease-in-out infinite;
    }

    .status-dot.unknown {
      background: #d1d1d6;
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
      color: #86868b;
    }

    .status-text.running { color: #34c759; }
    .status-text.failed { color: #ff3b30; }
    .status-text.starting { color: #ff9500; }

    .service-info {
      flex: 1;
      min-width: 0;
    }

    .service-name {
      font-size: 16px;
      font-weight: 600;
      color: #1d1d1f;
      margin-bottom: 4px;
    }

    .service-project {
      font-size: 13px;
      color: #86868b;
      margin-bottom: 4px;
    }

    .service-url {
      font-size: 12px;
      color: #667eea;
      text-decoration: none;
      word-break: break-all;
    }

    .service-url:hover {
      text-decoration: underline;
    }

    .service-systemd {
      font-size: 11px;
      color: #8e8e93;
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
      color: #86868b;
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
      background-color: #ccc;
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
      background-color: white;
      transition: 0.3s;
      border-radius: 50%;
    }

    input:checked + .toggle-slider {
      background-color: #667eea;
    }

    input:checked + .toggle-slider:before {
      transform: translateX(20px);
    }

    input:disabled + .toggle-slider {
      opacity: 0.5;
      cursor: not-allowed;
    }

    .loading-spinner {
      text-align: center;
      padding: 40px;
      color: #86868b;
    }

    .error-box {
      background: #fff3f3;
      border: 1px solid #ffccc7;
      border-radius: 8px;
      padding: 16px;
      margin-bottom: 20px;
      color: #d32f2f;
      max-width: 1200px;
    }

    .no-results {
      text-align: center;
      padding: 40px;
      color: #86868b;
    }

    .refresh-button {
      background: #667eea;
      color: white;
      border: none;
      padding: 8px 16px;
      border-radius: 6px;
      font-size: 13px;
      cursor: pointer;
      margin-left: 12px;
      transition: background 0.2s;
    }

    .refresh-button:hover {
      background: #5568d3;
    }

    .refresh-button:disabled {
      background: #d2d2d7;
      cursor: not-allowed;
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
    this.config = { services: {} };
    this.loading = true;
    this.error = null;
    this.searchQuery = '';
    this.modified = false;
    this.pollInterval = null;
    this.pollIntervalMs = 5000; // Poll every 5 seconds
  }

  async connectedCallback() {
    super.connectedCallback();
    await this.loadServices();
    this.startPolling();
  }

  disconnectedCallback() {
    super.disconnectedCallback();
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
    this.error = null;

    try {
      const services = await getServices();
      this.services = services;

      // Initialize config from loaded services
      if (!this.config.services) {
        this.config = { services: {} };
      }

      // Populate config with current service states
      // But don't overwrite user's pending changes
      services.forEach(service => {
        if (!this.config.services[service.label]) {
          this.config.services[service.label] = {
            enable: service.enabled,
            public: service.public
          };
        }
      });
    } catch (error) {
      console.error('Error loading services:', error);
      this.error = error.message || 'Failed to load services';
    } finally {
      this.loading = false;
    }
  }

  handleServiceToggle(serviceLabel, enabled) {
    const newConfig = { ...this.config };
    if (!newConfig.services[serviceLabel]) {
      newConfig.services[serviceLabel] = { enable: false, public: false };
    }
    newConfig.services[serviceLabel].enable = enabled;

    this.config = newConfig;
    this.modified = true;

    // Update local services array for immediate UI feedback
    this.services = this.services.map(s =>
      s.label === serviceLabel ? { ...s, enabled } : s
    );

    // Emit change event to parent
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { config: newConfig },
      bubbles: true,
      composed: true
    }));
  }

  handlePublicToggle(serviceLabel, isPublic) {
    const newConfig = { ...this.config };
    if (!newConfig.services[serviceLabel]) {
      newConfig.services[serviceLabel] = { enable: false, public: false };
    }
    newConfig.services[serviceLabel].public = isPublic;

    this.config = newConfig;
    this.modified = true;

    // Update local services array for immediate UI feedback
    this.services = this.services.map(s =>
      s.label === serviceLabel ? { ...s, public: isPublic } : s
    );

    // Emit change event to parent
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { config: newConfig },
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

  getStatusClass(activeState, subState) {
    if (activeState === 'active' && subState === 'running') {
      return 'running';
    } else if (activeState === 'failed') {
      return 'failed';
    } else if (activeState === 'activating' || subState === 'start') {
      return 'starting';
    } else if (activeState === 'inactive' || subState === 'dead') {
      return 'stopped';
    }
    return 'unknown';
  }

  getStatusText(activeState, subState, enabled) {
    if (!enabled) {
      return 'Disabled';
    }
    if (activeState === 'active' && subState === 'running') {
      return 'Running';
    } else if (activeState === 'failed') {
      return 'Failed';
    } else if (activeState === 'activating') {
      return 'Starting';
    } else if (activeState === 'inactive' && subState === 'dead') {
      return 'Stopped';
    } else if (activeState === 'reloading') {
      return 'Reloading';
    }
    return `${activeState} (${subState})`;
  }

  renderServiceRow(service) {
    const statusClass = this.getStatusClass(service.active_state, service.sub_state);
    const statusText = this.getStatusText(service.active_state, service.sub_state, service.enabled);
    const isEnabled = service.enabled;
    const isPublic = service.public;

    // Admin service can't be disabled (no enable toggle)
    const cannotDisable = service.label === 'admin' || service.label === 'admin-api';
    const isAdminApi = service.label === 'admin-api';

    return html`
      <div class="service-row ${isEnabled ? 'enabled' : ''}">
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
                  @change=${(e) => this.handleServiceToggle(service.label, e.target.checked)}
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
                  @change=${(e) => this.handlePublicToggle(service.label, e.target.checked)}
                />
                <span class="toggle-slider"></span>
              </label>
            </div>
          ` : ''}

          ${cannotDisable ? html`
            <div class="toggle-label" style="color: #86868b; font-size: 12px;">
              ${isAdminApi ? 'System service' : 'System service (always enabled)'}
            </div>
          ` : ''}
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

    // Filter services based on search query
    const filteredServices = this.services.filter(service => {
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
