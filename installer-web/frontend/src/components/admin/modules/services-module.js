import { LitElement, html, css } from 'lit';
import '../../shared/config-section.js';

/**
 * Services configuration module
 * Handles: Service enable/disable toggles and public access settings
 */
class ServicesModule extends LitElement {
  static properties = {
    config: { type: Object },
    modified: { type: Boolean }
  };

  static styles = css`
    :host {
      display: block;
    }

    .module-container {
      width: 100%;
    }

    .services-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
      gap: 20px;
      margin-top: 20px;
    }

    .service-card {
      background: white;
      border: 1px solid #e5e5e7;
      border-radius: 12px;
      padding: 20px;
      transition: all 0.2s;
    }

    .service-card:hover {
      box-shadow: 0 4px 12px rgba(0, 0, 0, 0.1);
    }

    .service-card.enabled {
      border-color: #667eea;
      background: linear-gradient(135deg, #ffffff 0%, #f8f9ff 100%);
    }

    .service-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 16px;
    }

    .service-name {
      font-size: 16px;
      font-weight: 600;
      color: #1d1d1f;
      text-transform: capitalize;
    }

    .service-card.enabled .service-name {
      color: #667eea;
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

    .service-options {
      margin-top: 12px;
      padding-top: 12px;
      border-top: 1px solid #e5e5e7;
    }

    .service-option {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 8px 0;
    }

    .option-label {
      font-size: 14px;
      color: #86868b;
    }

    .option-toggle {
      position: relative;
      width: 36px;
      height: 20px;
    }

    .option-toggle input {
      opacity: 0;
      width: 0;
      height: 0;
    }

    .option-toggle .toggle-slider {
      border-radius: 20px;
    }

    .option-toggle .toggle-slider:before {
      height: 14px;
      width: 14px;
      left: 3px;
      bottom: 3px;
    }

    .option-toggle input:checked + .toggle-slider:before {
      transform: translateX(16px);
    }

    .info-box {
      background: #f5f5f7;
      border-radius: 8px;
      padding: 16px;
      margin-bottom: 20px;
      font-size: 14px;
      color: #1d1d1f;
    }

    .search-box {
      margin-bottom: 20px;
    }

    .search-box input {
      width: 100%;
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

    @media (max-width: 768px) {
      .services-grid {
        grid-template-columns: 1fr;
      }
    }
  `;

  constructor() {
    super();
    this.config = {
      services: {}
    };
    this.modified = false;
    this.searchQuery = '';

    // List of all available services
    this.servicesList = [
      { id: 'adguard', name: 'AdGuard Home', description: 'Network-wide ad blocker' },
      { id: 'authentik', name: 'Authentik', description: 'Identity provider and SSO' },
      { id: 'baikal', name: 'Baïkal', description: 'CalDAV/CardDAV server' },
      { id: 'cryptpad', name: 'CryptPad', description: 'Encrypted collaborative documents' },
      { id: 'freshrss', name: 'FreshRSS', description: 'RSS feed aggregator' },
      { id: 'forgejo', name: 'Forgejo', description: 'Git hosting service' },
      { id: 'frigate', name: 'Frigate', description: 'Network video recorder with AI' },
      { id: 'grocy', name: 'Grocy', description: 'Groceries & household management' },
      { id: 'headscale', name: 'Headscale', description: 'Self-hosted Tailscale control server' },
      { id: 'homeassistant', name: 'Home Assistant', description: 'Home automation platform' },
      { id: 'homebox', name: 'Homebox', description: 'Home inventory system' },
      { id: 'immich', name: 'Immich', description: 'Photo and video backup' },
      { id: 'jellyfin', name: 'Jellyfin', description: 'Media server' },
      { id: 'joplin', name: 'Joplin', description: 'Note-taking application' },
      { id: 'kanidm', name: 'Kanidm', description: 'Identity management system' },
      { id: 'lidarr', name: 'Lidarr', description: 'Music collection manager' },
      { id: 'logseq', name: 'Logseq', description: 'Knowledge base and note-taking' },
      { id: 'linkwarden', name: 'Linkwarden', description: 'Bookmark manager' },
      { id: 'matrix', name: 'Matrix Synapse', description: 'Decentralized chat server' },
      { id: 'mediawiki', name: 'MediaWiki', description: 'Wiki software' },
      { id: 'minecraft', name: 'Minecraft', description: 'Minecraft server' },
      { id: 'nextcloud', name: 'Nextcloud', description: 'File sync and share' },
      { id: 'nzbget', name: 'NZBGet', description: 'Usenet downloader' },
      { id: 'oauth2-proxy', name: 'OAuth2 Proxy', description: 'Authentication proxy' },
      { id: 'ollama', name: 'Ollama', description: 'Local AI models' },
      { id: 'radicale', name: 'Radicale', description: 'CalDAV/CardDAV server' },
      { id: 'screeenly', name: 'Screeenly', description: 'Screenshot service' },
      { id: 'snipe-it', name: 'Snipe-IT', description: 'IT asset management' },
      { id: 'unifi', name: 'UniFi Controller', description: 'Network management' },
      { id: 'vaultwarden', name: 'Vaultwarden', description: 'Password manager' },
      { id: 'webdav', name: 'WebDAV', description: 'File access protocol' },
      { id: 'zitadel', name: 'Zitadel', description: 'Identity infrastructure' }
    ];
  }

  handleServiceToggle(serviceId, enabled) {
    const newConfig = { ...this.config };
    if (!newConfig.services[serviceId]) {
      newConfig.services[serviceId] = { enable: false, public: false };
    }
    newConfig.services[serviceId].enable = enabled;

    this.config = newConfig;
    this.modified = true;

    // Emit change event to parent
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { config: newConfig },
      bubbles: true,
      composed: true
    }));
  }

  handlePublicToggle(serviceId, isPublic) {
    const newConfig = { ...this.config };
    if (!newConfig.services[serviceId]) {
      newConfig.services[serviceId] = { enable: false, public: false };
    }
    newConfig.services[serviceId].public = isPublic;

    this.config = newConfig;
    this.modified = true;

    // Emit change event to parent
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { config: newConfig },
      bubbles: true,
      composed: true
    }));
  }

  handleSearch(e) {
    this.searchQuery = e.target.value.toLowerCase();
    this.requestUpdate();
  }

  renderServiceCard(service) {
    const serviceConfig = this.config.services[service.id] || { enable: false, public: false };
    const isEnabled = serviceConfig.enable;
    const isPublic = serviceConfig.public;

    return html`
      <div class="service-card ${isEnabled ? 'enabled' : ''}">
        <div class="service-header">
          <div>
            <div class="service-name">${service.name}</div>
            <div style="font-size: 12px; color: #86868b; margin-top: 4px;">
              ${service.description}
            </div>
          </div>
          <label class="toggle-switch">
            <input
              type="checkbox"
              .checked=${isEnabled}
              @change=${(e) => this.handleServiceToggle(service.id, e.target.checked)}
            />
            <span class="toggle-slider"></span>
          </label>
        </div>

        ${isEnabled ? html`
          <div class="service-options">
            <div class="service-option">
              <span class="option-label">Public Access (WAN)</span>
              <label class="option-toggle">
                <input
                  type="checkbox"
                  .checked=${isPublic}
                  @change=${(e) => this.handlePublicToggle(service.id, e.target.checked)}
                />
                <span class="toggle-slider"></span>
              </label>
            </div>
          </div>
        ` : ''}
      </div>
    `;
  }

  render() {
    // Filter services based on search query
    const filteredServices = this.servicesList.filter(service =>
      service.name.toLowerCase().includes(this.searchQuery) ||
      service.description.toLowerCase().includes(this.searchQuery)
    );

    const enabledCount = this.servicesList.filter(s =>
      this.config.services[s.id]?.enable
    ).length;

    return html`
      <div class="module-container">
        <div class="info-box">
          <strong>${enabledCount} of ${this.servicesList.length} services enabled</strong>
          <div style="margin-top: 8px; font-size: 13px;">
            Enable the services you want to run on your HomeFree system. Services marked as "Public Access" will be accessible from the internet.
          </div>
        </div>

        <div class="search-box">
          <input
            type="text"
            placeholder="Search services..."
            @input=${this.handleSearch}
          />
        </div>

        <div class="services-grid">
          ${filteredServices.map(service => this.renderServiceCard(service))}
        </div>

        ${filteredServices.length === 0 ? html`
          <div style="text-align: center; padding: 40px; color: #86868b;">
            No services found matching "${this.searchQuery}"
          </div>
        ` : ''}
      </div>
    `;
  }
}

customElements.define('services-module', ServicesModule);
