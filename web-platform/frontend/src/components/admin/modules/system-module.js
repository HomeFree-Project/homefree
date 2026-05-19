import { LitElement, html, css } from 'lit';
import '../../shared/config-section.js';
import '../../shared/form-field.js';
import '../../shared/lat-lng-picker.js';
import '../../shared/table-editor.js';
import { alertDialog } from '../../shared/confirm-dialog.js';
import {
  getTimezones, getLocales, getCountries, getCurrencies, getLanguages,
  lookupElevation,
} from '../../../api/client.js';

/**
 * System configuration module
 * Handles: hostname, domain, timezone, locale, country, language,
 * currency, unit system, GPS, elevation, keyboard, admin user.
 */
class SystemModule extends LitElement {
  static properties = {
    config: { type: Object },
    timezones: { type: Array },
    locales: { type: Array },
    countries: { type: Array },
    currencies: { type: Array },
    languages: { type: Array },
    modified: { type: Boolean },
    elevationLookupBusy: { type: Boolean, state: true },
    elevationLookupError: { type: String, state: true },
  };

  static styles = css`
    :host {
      display: block;
    }

    /* Width cap + centering is applied once, app-wide, on
       admin-app.js's .content-area > * — no per-module max-width. */
    .module-container {
      width: 100%;
    }

    /* minmax(0, 1fr) — not 1fr — so a column can shrink below its
       content's min-content width. Plain 1fr keeps an implicit
       min-width:auto and the field overflows / clips on the right. */
    .field-row {
      display: grid;
      grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
      gap: 20px;
    }

    @media (max-width: 768px) {
      .field-row {
        grid-template-columns: minmax(0, 1fr);
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
      background: var(--hf-surface-2);
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
      color: var(--hf-err);
      cursor: pointer;
      padding: 4px;
      font-size: 16px;
    }

    /* Textarea + button stacked; button left-aligned with the
       textarea and sized to its own content (align-items: flex-start
       keeps it from stretching to the textarea's full width). */
    .add-key-row {
      display: flex;
      flex-direction: column;
      align-items: flex-start;
      gap: 12px;
    }

    /* Canonical admin button — 9px 16px / 13px / radius 6px,
       bordered surface (matches admin-app / table-editor / etc). */
    .add-key-btn {
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

    .add-key-btn:hover {
      background: var(--hf-surface-3);
      border-color: var(--hf-text-subtle);
    }

    textarea {
      width: 100%;
      box-sizing: border-box;
      padding: 10px 12px;
      font-size: 14px;
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      background: var(--hf-bg);
      color: var(--hf-text);
      font-family: monospace;
      resize: vertical;
      min-height: 100px;
    }

    textarea:focus {
      outline: none;
      border-color: var(--hf-accent);
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
        elevation: null,
        latitude: null,
        longitude: null,
        unitSystem: 'metric',
        currency: '',
        language: '',
        adminUsername: '',
        adminEmail: '',
        authorizedKeys: []
      }
    };
    this.timezones = [];
    this.locales = [];
    this.countries = [];
    this.currencies = [];
    this.languages = [];
    this.modified = false;
    this.newSshKey = '';
    this.elevationLookupBusy = false;
    this.elevationLookupError = '';
  }

  async _lookupElevation() {
    const lat = this.config?.system?.latitude;
    const lon = this.config?.system?.longitude;
    if (typeof lat !== 'number' || typeof lon !== 'number') {
      this.elevationLookupError = 'Set latitude and longitude first.';
      return;
    }
    this.elevationLookupError = '';
    this.elevationLookupBusy = true;
    try {
      const elevation = await lookupElevation(lat, lon);
      this.handleFieldChange('system.elevation', elevation);
    } catch (e) {
      this.elevationLookupError = `Lookup failed: ${e.message || e}`;
    } finally {
      this.elevationLookupBusy = false;
    }
  }

  async connectedCallback() {
    super.connectedCallback();
    await this.loadLists();
  }

  async loadLists() {
    // Load all dropdown data in parallel. Each failure is logged
    // and leaves its dropdown empty rather than blocking the others.
    const [tzRegions, locales, countries, currencies, languages] =
      await Promise.allSettled([
        getTimezones(), getLocales(), getCountries(),
        getCurrencies(), getLanguages(),
      ]);

    if (tzRegions.status === 'fulfilled') {
      this.timezones = tzRegions.value.flatMap(region =>
        region.zones.map(zone => ({ value: zone, label: zone }))
      );
    } else {
      console.error('Failed to load timezones:', tzRegions.reason);
    }

    if (locales.status === 'fulfilled') {
      this.locales = locales.value;
    } else {
      console.error('Failed to load locales:', locales.reason);
    }

    if (countries.status === 'fulfilled') {
      this.countries = countries.value;
    } else {
      console.error('Failed to load countries:', countries.reason);
    }

    if (currencies.status === 'fulfilled') {
      this.currencies = currencies.value;
    } else {
      console.error('Failed to load currencies:', currencies.reason);
    }

    if (languages.status === 'fulfilled') {
      this.languages = languages.value;
    } else {
      console.error('Failed to load languages:', languages.reason);
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

  async addSshKey() {
    if (!this.newSshKey.trim()) {
      await alertDialog({ message: 'Please enter an SSH key.' });
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

  // table-editor passes back the full row-object array; the JSON
  // schema stores additionalDomains as a flat string array, so we
  // unpack the `domain` field on the way out. Empty/whitespace
  // entries are dropped so a stray "Add Domain" click with no input
  // doesn't pollute the config.
  handleAdditionalDomainsChange(e) {
    const domains = (e.detail.data || [])
      .map(r => (r.domain || '').trim())
      .filter(d => d.length > 0);
    this.handleFieldChange('system.additionalDomains', domains);
  }

  render() {
    const { system } = this.config;

    // Keyboard layout options — small fixed list since these mirror the
    // X11/console keymaps we explicitly support. The other dropdowns
    // (locale, country, currency, language) come from the API.
    const keyboardOptions = [
      { value: 'us', label: 'US' },
      { value: 'uk', label: 'UK' },
      { value: 'de', label: 'German' },
      { value: 'fr', label: 'French' },
      { value: 'es', label: 'Spanish' }
    ];

    // Single-column table-editor for additional domains (flat string
    // array in JSON, modeled as { domain } rows for the table).
    const additionalDomainsColumns = [
      { key: 'domain', label: 'Domain', type: 'text', placeholder: 'example.com' }
    ];

    const unitSystemOptions = [
      { value: 'metric', label: 'Metric' },
      { value: 'us_customary', label: 'US Customary (Imperial)' }
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

          <!--
            Additional domains. The JSON shape is a flat array of strings
            (e.g. ["rahh.al", "slacktopia.org"]). table-editor works in
            terms of row objects, so we translate on the way in and out
            via handleAdditionalDomainsChange below. table-editor has no
            title/help of its own, so the heading + description are
            rendered here.
          -->
          <h4 style="font-size: 14px; color: var(--hf-text); margin: 20px 0 4px;">
            Additional Domains
          </h4>
          <p style="font-size: 12px; color: var(--hf-text-muted); margin: 0 0 12px;">
            Extra public domains served alongside the primary domain. Caddy
            will issue certificates and Unbound will resolve them. Each
            service's reverse-proxy gets ${'${subdomain}.${domain}'} for
            every domain listed (primary + additional).
          </p>
          <table-editor
            .columns=${additionalDomainsColumns}
            .data=${(system.additionalDomains || []).map(d => ({ domain: d }))}
            addLabel="Add Domain"
            @data-change=${this.handleAdditionalDomainsChange}
          ></table-editor>
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
              label="Country"
              type="select"
              .value=${system.countryCode || ''}
              .options=${this.countries}
              placeholder="Select country..."
              help="ISO 3166-1 alpha-2 country code"
              @field-change=${(e) => this.handleFieldChange('system.countryCode', e.detail.value)}
            ></form-field>
          </div>

          <div class="field-row">
            <form-field
              label="Locale"
              type="select"
              .value=${system.defaultLocale || 'en_US.UTF-8'}
              .options=${this.locales}
              placeholder="Select locale..."
              help="POSIX system locale (formatting, sorting)"
              required
              @field-change=${(e) => this.handleFieldChange('system.defaultLocale', e.detail.value)}
            ></form-field>

            <form-field
              label="Language"
              type="select"
              .value=${system.language || ''}
              .options=${this.languages}
              placeholder="Select language..."
              help="UI language for apps that have their own (BCP 47)"
              @field-change=${(e) => this.handleFieldChange('system.language', e.detail.value)}
            ></form-field>
          </div>

          <div class="field-row">
            <form-field
              label="Keyboard Layout"
              type="select"
              .value=${system.keyMap}
              .options=${keyboardOptions}
              required
              @field-change=${(e) => this.handleFieldChange('system.keyMap', e.detail.value)}
            ></form-field>

            <form-field
              label="Currency"
              type="select"
              .value=${system.currency || ''}
              .options=${this.currencies}
              placeholder="Select currency..."
              help="ISO 4217 currency code"
              @field-change=${(e) => this.handleFieldChange('system.currency', e.detail.value)}
            ></form-field>
          </div>
        </config-section>

        <!-- Location coordinates -->
        <config-section
          title="Geographic Location"
          description="Used by Home Assistant for location-aware automations (sun, weather, etc.) and similar services. Optional."
        >
          <lat-lng-picker
            .latitude=${system.latitude}
            .longitude=${system.longitude}
            @change=${(e) => {
              this.handleFieldChange('system.latitude', e.detail.latitude);
              this.handleFieldChange('system.longitude', e.detail.longitude);
            }}
          ></lat-lng-picker>

          <div class="field-row" style="margin-top: 16px;">
            <div>
              <form-field
                label="Elevation above sea level (meters)"
                type="number"
                .value=${system.elevation == null ? '' : String(system.elevation)}
                placeholder="0"
                @field-change=${(e) => {
                  const v = e.detail.value;
                  this.handleFieldChange('system.elevation', v === '' || v == null ? null : parseInt(v, 10));
                }}
              ></form-field>
              <button
                type="button"
                style="margin-top: 6px; padding: 6px 12px; font-size: 12px; border: 1px solid var(--hf-border-2); background: var(--hf-surface); color: var(--hf-text); border-radius: 6px; cursor: pointer;"
                ?disabled=${this.elevationLookupBusy ||
                            typeof system.latitude !== 'number' ||
                            typeof system.longitude !== 'number'}
                @click=${this._lookupElevation}
              >${this.elevationLookupBusy ? 'Looking up…' : 'Look up from coords'}</button>
              ${this.elevationLookupError
                ? html`<div style="color: var(--hf-err); font-size: 12px; margin-top: 6px;">${this.elevationLookupError}</div>`
                : ''}
            </div>

            <form-field
              label="Unit System"
              type="select"
              .value=${system.unitSystem || 'metric'}
              .options=${unitSystemOptions}
              @field-change=${(e) => this.handleFieldChange('system.unitSystem', e.detail.value)}
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
              <p style="color: var(--hf-text-muted); font-size: 14px; margin-bottom: 16px;">
                No SSH keys configured. Add one below for secure remote access.
              </p>
            `}

            <div class="add-key-row">
              <textarea
                placeholder="Paste SSH public key here (ssh-rsa ...)"
                .value=${this.newSshKey}
                @input=${(e) => { this.newSshKey = e.target.value; }}
              ></textarea>

              <button
                class="add-key-btn"
                @click=${this.addSshKey}
              >
                + Add SSH Key
              </button>
            </div>
          </div>

          <div style="margin-top: 16px; padding: 14px 18px; background: rgba(59, 130, 246, 0.08); border-left: 4px solid var(--hf-accent); border-radius: 8px; font-size: 13px; line-height: 1.5; color: var(--hf-text-muted);">
            <strong style="color: var(--hf-text);">💡 Tip:</strong> The first SSH key will be used for encrypting service secrets.
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
