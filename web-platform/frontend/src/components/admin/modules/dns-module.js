import { LitElement, html, css } from 'lit';
import '../../shared/config-section.js';
import '../../shared/form-field.js';
import '../../shared/table-editor.js';
import '../secrets-input.js';

// Synthetic service labels under which DNS-related secrets are stored in
// SOPS. write_secret_files() materialises them at
// /var/lib/homefree-secrets/<label>/<key>, which is exactly where
// ddclient and the DNS-01 cert provider read their credentials.
const DDNS_SECRET_LABEL = 'ddclient';
const DNS_CERT_SECRET_LABEL = 'dns';
const DNS_CERT_SECRET_KEY = 'api-token';

/**
 * DNS configuration module
 * Handles: Local DNS overrides, dynamic DNS zones, and DNS-01 wildcard
 * certificate provider configuration.
 */
class DnsModule extends LitElement {
  static properties = {
    config: { type: Object },
    modified: { type: Boolean },
    hasAuthorizedKeys: { type: Boolean },
    secretsStatus: { type: Object, state: true }
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

    .help-box {
      background: rgba(59, 130, 246, 0.08);
      border-left: 4px solid var(--hf-accent);
      padding: 14px 18px;
      border-radius: 8px;
      margin-bottom: 20px;
      color: var(--hf-text-muted);
      font-size: 13px;
      line-height: 1.5;
    }

    .help-box strong {
      display: block;
      margin-bottom: 6px;
      color: var(--hf-text);
      font-size: 14px;
    }

    .help-box code {
      background: var(--hf-surface-2);
      padding: 1px 5px;
      border-radius: 3px;
      font-family: var(--hf-font-mono, monospace);
      font-size: 12px;
    }
  `;

  constructor() {
    super();
    this.config = {
      dns: {
        overrides: [],
        'dynamic-dns': { interval: '10m', usev4: '', usev6: '', zones: [] },
        'cert-management': null
      }
    };
    this.modified = false;
    this.hasAuthorizedKeys = false;
    // Map of "<label>": { "<key>": boolean } — which secrets are set.
    this.secretsStatus = {};
  }

  connectedCallback() {
    super.connectedCallback();
    this.loadSecretsStatus();
  }

  async loadSecretsStatus() {
    try {
      const response = await fetch('/api/secrets/status');
      if (response.ok) {
        const data = await response.json();
        this.secretsStatus = data.secrets || {};
      }
    } catch (error) {
      // Non-fatal: secrets-input falls back to "Not Set" and still works.
      console.error('Error loading secrets status:', error);
    }
  }

  secretExists(label, key) {
    return !!(this.secretsStatus[label] && this.secretsStatus[label][key]);
  }

  handleSecretUpdated() {
    // Refresh status so the Set/Not Set badges reflect the change.
    this.loadSecretsStatus();
  }

  handleFieldChange(field, value) {
    const newConfig = { ...this.config };
    const path = field.split('.');

    // Ensure intermediate objects exist so the user can fill in
    // dns['cert-management'].provider when cert-management was null.
    let current = newConfig;
    for (let i = 0; i < path.length - 1; i++) {
      if (current[path[i]] == null || typeof current[path[i]] !== 'object') {
        current[path[i]] = {};
      }
      current = current[path[i]];
    }
    current[path[path.length - 1]] = value;

    this.config = newConfig;
    this.modified = true;

    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { config: newConfig },
      bubbles: true,
      composed: true
    }));
  }

  handleDnsOverridesChange(e) {
    this.handleFieldChange('dns.overrides', e.detail.data);
  }

  handleZonesChange(e) {
    // table-editor returns rows with snake_case keys matching the
    // schema. Coerce `domains` from comma-separated text to an array
    // and back so users can edit it as a string in the modal.
    const data = (e.detail.data || []).map(row => ({
      ...row,
      domains: Array.isArray(row.domains)
        ? row.domains
        : (typeof row.domains === 'string'
            ? row.domains.split(',').map(s => s.trim()).filter(Boolean)
            : [])
    }));
    this.handleFieldChange('dns.dynamic-dns.zones', data);
  }

  render() {
    const dns = this.config.dns || {};
    const dynamicDns = dns['dynamic-dns'] || { zones: [] };
    const certMgmt = dns['cert-management'] || {};

    const dnsOverrideColumns = [
      { key: 'hostname', label: 'Hostname', type: 'text', placeholder: 'myserver' },
      { key: 'domain', label: 'Domain', type: 'text', placeholder: 'local' },
      { key: 'ip', label: 'IP Address', type: 'text', placeholder: '10.0.0.50' }
    ];

    // For zones we model `domains` as text inside the table-editor
    // (it doesn't support array fields) and split/join on write/read.
    const zoneRows = (dynamicDns.zones || []).map(z => ({
      ...z,
      domains: Array.isArray(z.domains) ? z.domains.join(', ') : (z.domains || '')
    }));
    const zoneColumns = [
      { key: 'zone', label: 'Zone', type: 'text', placeholder: 'example.com' },
      { key: 'protocol', label: 'Protocol', type: 'text', placeholder: 'hetzner' },
      { key: 'username', label: 'Username', type: 'text', placeholder: 'erahhal' },
      { key: 'domains', label: 'Domains (comma-sep)', type: 'text', placeholder: '@, *, www' },
      { key: 'password-secret-key', label: 'Password File Key', type: 'text', placeholder: 'password' },
      { key: 'disable', label: 'Disabled', type: 'boolean' }
    ];

    // Distinct password keys referenced by the zones — one secret input
    // each. Zones sharing a key share a single credential.
    const ddnsSecretKeys = [...new Set(
      (dynamicDns.zones || [])
        .map(z => (z['password-secret-key'] || '').trim())
        .filter(Boolean)
    )];
    const certProviderSet = !!(certMgmt.provider && certMgmt.provider.trim());

    return html`
      <div class="module-container">
        <config-section
          title="Local DNS Overrides"
          description="Map custom hostnames to IP addresses on your local network"
        >
          <p style="color: var(--hf-text-muted); font-size: 14px; margin-bottom: 16px;">
            DNS overrides allow you to resolve custom hostnames like
            "myserver.local" to specific IP addresses on your network.
          </p>
          <table-editor
            .columns=${dnsOverrideColumns}
            .data=${dns.overrides || []}
            addLabel="Add DNS Override"
            @data-change=${this.handleDnsOverridesChange}
          ></table-editor>
        </config-section>

        <config-section
          title="Dynamic DNS Zones"
          description="Keep public DNS records pointed at this box's current WAN IP"
        >
          <div class="help-box">
            <strong>How DDNS zone passwords work</strong>
            Each zone needs an API password or token. Give the secret a
            short key in the zone's <code>Password File Key</code>
            column (e.g. <code>password</code>), then enter the secret
            value below. It is encrypted into the SOPS config and
            ddclient picks it up automatically. Zones can share a single
            key if they share a credential.
          </div>

          <div class="field-row">
            <form-field
              label="Refresh Interval"
              type="text"
              .value=${dynamicDns.interval || '10m'}
              placeholder="10m"
              help="How often ddclient re-checks the WAN IP (systemd time spec)."
              @field-change=${(e) => this.handleFieldChange('dns.dynamic-dns.interval', e.detail.value)}
            ></form-field>
          </div>

          <div class="field-row">
            <form-field
              label="IPv4 use= directive"
              type="text"
              .value=${dynamicDns.usev4 || ''}
              placeholder="webv4, webv4=ipinfo.io/ip"
              help="ddclient's 'use=' directive for IPv4."
              @field-change=${(e) => this.handleFieldChange('dns.dynamic-dns.usev4', e.detail.value)}
            ></form-field>

            <form-field
              label="IPv6 use= directive"
              type="text"
              .value=${dynamicDns.usev6 || ''}
              placeholder="webv6, webv6=v6.ipinfo.io/ip"
              help="ddclient's 'use=' directive for IPv6."
              @field-change=${(e) => this.handleFieldChange('dns.dynamic-dns.usev6', e.detail.value)}
            ></form-field>
          </div>

          <table-editor
            .columns=${zoneColumns}
            .data=${zoneRows}
            addLabel="Add Zone"
            @data-change=${this.handleZonesChange}
          ></table-editor>

          ${ddnsSecretKeys.length > 0 ? html`
            <h4 style="font-size: 14px; color: var(--hf-text); margin: 20px 0 12px;">
              Zone Credentials
            </h4>
            ${ddnsSecretKeys.map(key => html`
              <secrets-input
                .serviceLabel=${DDNS_SECRET_LABEL}
                .secretKey=${key}
                .label=${`Password / API token (key: ${key})`}
                .description=${'API password or token for every zone using this Password File Key.'}
                .required=${true}
                .disabled=${!this.hasAuthorizedKeys}
                .exists=${this.secretExists(DDNS_SECRET_LABEL, key)}
                @secret-updated=${this.handleSecretUpdated}
              ></secrets-input>
            `)}
          ` : html`
            <p style="color: var(--hf-text-muted); font-size: 13px; margin-top: 16px;">
              Add a zone with a <code>Password File Key</code> to enter its credential here.
            </p>
          `}
        </config-section>

        <config-section
          title="Wildcard Certificates (DNS-01)"
          description="ACME DNS-01 provider for *.<domain> certificates"
        >
          <div class="help-box">
            <strong>How the API token is stored</strong>
            Select a provider, then enter its API token below. It is
            encrypted into the SOPS config and Caddy uses it for
            wildcard cert renewal automatically — no files to place by
            hand.
          </div>

          <div class="field-row">
            <form-field
              label="DNS Provider"
              type="text"
              .value=${certMgmt.provider || ''}
              placeholder="hetzner"
              help="Currently supported: hetzner. Leave blank to disable wildcard certs."
              @field-change=${(e) => this.handleFieldChange('dns.cert-management.provider', e.detail.value || null)}
            ></form-field>
          </div>

          ${certProviderSet ? html`
            <secrets-input
              .serviceLabel=${DNS_CERT_SECRET_LABEL}
              .secretKey=${DNS_CERT_SECRET_KEY}
              .label=${'DNS Provider API Token'}
              .description=${'API token for the DNS-01 challenge, used to issue *.<domain> certificates.'}
              .required=${true}
              .disabled=${!this.hasAuthorizedKeys}
              .exists=${this.secretExists(DNS_CERT_SECRET_LABEL, DNS_CERT_SECRET_KEY)}
              @secret-updated=${this.handleSecretUpdated}
            ></secrets-input>
          ` : ''}
        </config-section>
      </div>
    `;
  }
}

customElements.define('dns-module', DnsModule);
