import { LitElement, html, css } from 'lit';
import '../../shared/config-section.js';
import '../../shared/form-field.js';
import { getTimezones } from '../../../api/client.js';

/**
 * System configuration module
 * Handles: hostname, domain, timezone, locale, keyboard, admin user
 */
class SystemModule extends LitElement {
  static properties = {
    config: { type: Object },
    timezones: { type: Array },
    modified: { type: Boolean }
  };

  static styles = css`
    :host {
      display: block;
    }

    .module-container {
      width: 100%;
    }

    .field-row {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 20px;
    }

    @media (max-width: 768px) {
      .field-row {
        grid-template-columns: 1fr;
      }
    }

    .ssh-keys-container {
      margin-top: 16px;
    }

    .ssh-key-item {
      display: flex;
      align-items: center;
      gap: 12px;
      padding: 12px;
      background: #f5f5f7;
      border-radius: 8px;
      margin-bottom: 8px;
    }

    .ssh-key-text {
      flex: 1;
      font-family: monospace;
      font-size: 12px;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .btn-icon {
      background: none;
      border: none;
      color: #ff3b30;
      cursor: pointer;
      padding: 4px;
      font-size: 16px;
    }

    .add-key-btn {
      padding: 10px 16px;
      border-radius: 8px;
      border: 1px solid #667eea;
      background: white;
      color: #667eea;
      font-size: 14px;
      font-weight: 500;
      cursor: pointer;
      transition: all 0.2s;
    }

    .add-key-btn:hover {
      background: #667eea;
      color: white;
    }

    textarea {
      width: 100%;
      padding: 10px 12px;
      font-size: 14px;
      border: 1px solid #d2d2d7;
      border-radius: 8px;
      font-family: monospace;
      resize: vertical;
      min-height: 100px;
    }

    textarea:focus {
      outline: none;
      border-color: #667eea;
    }
  `;

  constructor() {
    super();
    this.config = {
      system: {
        hostName: '',
        domain: '',
        localDomain: 'lan',
        additionalDomains: [],
        timeZone: '',
        defaultLocale: 'en_US.UTF-8',
        keyMap: 'us',
        countryCode: '',
        adminUsername: '',
        adminEmail: '',
        authorizedKeys: []
      }
    };
    this.timezones = [];
    this.modified = false;
    this.newSshKey = '';
  }

  async connectedCallback() {
    super.connectedCallback();
    await this.loadTimezones();
  }

  async loadTimezones() {
    try {
      const tzRegions = await getTimezones();
      // Flatten timezone regions into a single list
      // Note: zones already include the region (e.g., "America/Los_Angeles")
      this.timezones = tzRegions.flatMap(region =>
        region.zones.map(zone => ({
          value: zone,
          label: zone
        }))
      );
    } catch (error) {
      console.error('Failed to load timezones:', error);
    }
  }

  handleFieldChange(field, value) {
    // Update config
    const newConfig = { ...this.config };
    const path = field.split('.');

    let current = newConfig;
    for (let i = 0; i < path.length - 1; i++) {
      current = current[path[i]];
    }
    current[path[path.length - 1]] = value;

    this.config = newConfig;
    this.modified = true;

    // Emit change event to parent
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { config: newConfig },
      bubbles: true,
      composed: true
    }));
  }

  addSshKey() {
    if (!this.newSshKey.trim()) {
      alert('Please enter an SSH key');
      return;
    }

    const keys = [...this.config.system.authorizedKeys, this.newSshKey.trim()];
    this.handleFieldChange('system.authorizedKeys', keys);
    this.newSshKey = '';

    // Notify parent that SSH keys have changed
    this.dispatchEvent(new CustomEvent('ssh-keys-changed', {
      bubbles: true,
      composed: true
    }));
  }

  removeSshKey(index) {
    const keys = this.config.system.authorizedKeys.filter((_, i) => i !== index);
    this.handleFieldChange('system.authorizedKeys', keys);

    // Notify parent that SSH keys have changed
    this.dispatchEvent(new CustomEvent('ssh-keys-changed', {
      bubbles: true,
      composed: true
    }));
  }

  render() {
    const { system } = this.config;

    // Locale options
    const localeOptions = [
      { value: 'en_US.UTF-8', label: 'English (US)' },
      { value: 'en_GB.UTF-8', label: 'English (UK)' },
      { value: 'de_DE.UTF-8', label: 'German' },
      { value: 'fr_FR.UTF-8', label: 'French' },
      { value: 'es_ES.UTF-8', label: 'Spanish' },
      { value: 'it_IT.UTF-8', label: 'Italian' },
      { value: 'ja_JP.UTF-8', label: 'Japanese' },
      { value: 'zh_CN.UTF-8', label: 'Chinese (Simplified)' }
    ];

    // Keyboard layout options
    const keyboardOptions = [
      { value: 'us', label: 'US' },
      { value: 'uk', label: 'UK' },
      { value: 'de', label: 'German' },
      { value: 'fr', label: 'French' },
      { value: 'es', label: 'Spanish' }
    ];

    return html`
      <div class="module-container">
        <!-- System Identity -->
        <config-section
          title="System Identity"
          description="Basic system identification and domain configuration"
        >
          <form-field
            label="Hostname"
            type="text"
            .value=${system.hostName}
            placeholder="homefree"
            help="Name of this system on your network"
            required
            @field-change=${(e) => this.handleFieldChange('system.hostName', e.detail.value)}
          ></form-field>

          <div class="field-row">
            <form-field
              label="Primary Domain"
              type="text"
              .value=${system.domain}
              placeholder="homefree.host"
              help="Public domain for HTTPS services"
              @field-change=${(e) => this.handleFieldChange('system.domain', e.detail.value)}
            ></form-field>

            <form-field
              label="Local Domain"
              type="text"
              .value=${system.localDomain}
              placeholder="lan"
              help="Domain suffix for local network"
              @field-change=${(e) => this.handleFieldChange('system.localDomain', e.detail.value)}
            ></form-field>
          </div>
        </config-section>

        <!-- Location & Language -->
        <config-section
          title="Location & Language"
          description="Timezone, locale, and keyboard configuration"
        >
          <div class="field-row">
            <form-field
              label="Timezone"
              type="select"
              .value=${system.timeZone}
              .options=${this.timezones}
              placeholder="Select timezone..."
              required
              @field-change=${(e) => this.handleFieldChange('system.timeZone', e.detail.value)}
            ></form-field>

            <form-field
              label="Country Code"
              type="text"
              .value=${system.countryCode}
              placeholder="US"
              help="Two-letter ISO country code"
              @field-change=${(e) => this.handleFieldChange('system.countryCode', e.detail.value)}
            ></form-field>
          </div>

          <div class="field-row">
            <form-field
              label="Locale"
              type="select"
              .value=${system.defaultLocale}
              .options=${localeOptions}
              required
              @field-change=${(e) => this.handleFieldChange('system.defaultLocale', e.detail.value)}
            ></form-field>

            <form-field
              label="Keyboard Layout"
              type="select"
              .value=${system.keyMap}
              .options=${keyboardOptions}
              required
              @field-change=${(e) => this.handleFieldChange('system.keyMap', e.detail.value)}
            ></form-field>
          </div>
        </config-section>

        <!-- Admin Account -->
        <config-section
          title="Admin Account"
          description="Administrator user configuration"
        >
          <form-field
            label="Admin Username"
            type="text"
            .value=${system.adminUsername}
            placeholder="admin"
            help="Username for system administrator"
            required
            @field-change=${(e) => this.handleFieldChange('system.adminUsername', e.detail.value)}
          ></form-field>

          <form-field
            label="Admin Email"
            type="email"
            .value=${system.adminEmail}
            placeholder="admin@example.com"
            help="Email for git commits and notifications"
            @field-change=${(e) => this.handleFieldChange('system.adminEmail', e.detail.value)}
          ></form-field>

          <div class="ssh-keys-container">
            <label style="display: block; font-size: 14px; font-weight: 500; margin-bottom: 12px;">
              SSH Authorized Keys
            </label>

            ${system.authorizedKeys && system.authorizedKeys.length > 0 ? html`
              ${system.authorizedKeys.map((key, index) => html`
                <div class="ssh-key-item">
                  <span class="ssh-key-text">${key}</span>
                  <button
                    class="btn-icon"
                    @click=${() => this.removeSshKey(index)}
                    title="Remove"
                  >
                    🗑️
                  </button>
                </div>
              `)}
            ` : html`
              <p style="color: #86868b; font-size: 14px; margin-bottom: 16px;">
                No SSH keys configured. Add one below for secure remote access.
              </p>
            `}

            <textarea
              placeholder="Paste SSH public key here (ssh-rsa ...)"
              .value=${this.newSshKey}
              @input=${(e) => { this.newSshKey = e.target.value; }}
            ></textarea>

            <button
              class="add-key-btn"
              @click=${this.addSshKey}
              style="margin-top: 12px;"
            >
              + Add SSH Key
            </button>
          </div>

          <div style="margin-top: 16px; padding: 12px; background: #e3f2fd; border-left: 4px solid #2196f3; border-radius: 4px; font-size: 13px; color: #1d1d1f;">
            <strong>💡 Tip:</strong> The first SSH key will be used for encrypting service secrets.
            <ul style="margin: 8px 0 0 20px; padding: 0;">
              <li>After adding a key, click "Save & Apply" to activate it</li>
              <li>Secrets fields (on Backups and Services pages) will be enabled after the rebuild completes</li>
              <li>You'll need the corresponding private key to manage secrets through the admin UI</li>
            </ul>
          </div>
        </config-section>
      </div>
    `;
  }
}

customElements.define('system-module', SystemModule);
