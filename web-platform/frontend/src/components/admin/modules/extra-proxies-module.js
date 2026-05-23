import { LitElement, html, css } from 'lit';
import '../../shared/config-section.js';
import '../../shared/table-editor.js';

/**
 * Extra reverse-proxy module
 * Surfaces homefree.service-config entries for non-HomeFree hardware:
 * NAS admin UI, solar inverter, smart-plug PSU, router admin, etc.
 * HomeFree's own services declare their own service-config entries
 * inside their .nix files; this UI is for additional hosts.
 */
class ExtraProxiesModule extends LitElement {
  static properties = {
    config: { type: Object },
    appliedConfig: { attribute: false },  // deployed baseline for row highlight
    modified: { type: Boolean }
  };

  static styles = css`
    :host { display: block; }
    /* Width cap + centering is applied once, app-wide, on
       admin-app.js's .content-area > * — no per-module max-width. */
    .module-container { width: 100%; }
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
    .help-box strong { color: var(--hf-text); }
    /* Only the leading title strong is a block heading; inline <strong>
       emphasis within the body text stays inline. */
    .help-box > strong:first-child {
      display: block;
      margin-bottom: 6px;
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
    this.config = { 'service-config': [] };
    this.appliedConfig = null;
    this.modified = false;
  }

  handleProxiesChange(e) {
    // table-editor returns rows with snake_case keys; subdomains is a
    // comma-separated text field that we split/join.
    const data = (e.detail.data || []).map(row => {
      const parsedSubdomains = Array.isArray(row.subdomains)
        ? row.subdomains
        : (typeof row.subdomains === 'string'
            ? row.subdomains.split(',').map(s => s.trim()).filter(Boolean)
            : []);
      const entry = {
        ...row,
        port: row.port === '' || row.port == null ? 80 : Number(row.port),
        // The help box promises subdomains defaults to [label] when
        // blank — apply it here so the saved entry actually has a
        // subdomain (an empty list yields no URL and no Caddy route).
        subdomains: parsedSubdomains.length > 0
          ? parsedSubdomains
          : (row.label ? [row.label] : [])
      };
      // Keep the entry minimal: store enable/public only when they differ
      // from their defaults (enable=true, public=false). This matches the
      // deployed shape — so toggling to a default value isn't read as an
      // undeployed change — and keeps this form and the App Configuration
      // toggle in the same representation.
      if (entry.enable !== false) delete entry.enable;
      if (!entry.public) delete entry.public;
      return entry;
    });

    const newConfig = { ...this.config, 'service-config': data };
    this.config = newConfig;
    this.modified = true;
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { module: 'extra-proxies', config: newConfig },
      bubbles: true,
      composed: true
    }));
  }

  render() {
    const toRow = (r) => ({
      ...r,
      enable: r.enable !== false,   // absent => enabled (the default)
      public: !!r.public,
      subdomains: Array.isArray(r.subdomains) ? r.subdomains.join(', ') : (r.subdomains || '')
    });
    const rows = (this.config['service-config'] || []).map(toRow);
    // Deployed rows in the same shape, so table-editor can flag added/changed
    // rows (those not present in the last-applied config).
    const appliedRows = (this.appliedConfig?.['service-config'] || []).map(toRow);

    const columns = [
      { key: 'enable', label: 'Enabled', type: 'boolean', default: true },
      { key: 'label', label: 'Label', type: 'text', placeholder: 'envoy' },
      { key: 'name', label: 'Display Name', type: 'text', placeholder: 'Enphase Solar' },
      { key: 'host', label: 'Backend Host', type: 'text', placeholder: 'envoy.lan or 10.0.0.43' },
      { key: 'port', label: 'Port', type: 'text', placeholder: '80' },
      { key: 'subdomains', label: 'Subdomains (comma-sep)', type: 'text', placeholder: 'envoy' },
      // Short headers — the boolean columns render a single ✓/✗ glyph,
      // so a long header needlessly widens the whole table. The help
      // box above the table explains each field in full.
      { key: 'ssl', label: 'HTTPS', type: 'boolean' },
      { key: 'ssl-no-verify', label: 'No Verify', type: 'boolean' },
      { key: 'disable-keepalive', label: 'No KA', type: 'boolean' },
      { key: 'public', label: 'Public', type: 'boolean' }
    ];

    return html`
      <div class="module-container">
        <div class="help-box">
          <strong>Reverse-proxy entries for external hardware</strong>
          Add a row for each non-HomeFree host you want to reach
          through Caddy — NAS admin UI, solar inverter, router admin
          page, smart-plug PSU, etc. <strong>Label</strong> is a
          unique short identifier. <strong>Subdomains</strong> defaults
          to <code>[label]</code> if blank. Use <strong>Backend Uses
          HTTPS</strong> when the device serves HTTPS itself (most
          consumer hardware does on port 443 with a self-signed cert
          — combine with <strong>Skip Cert Verify</strong>).
          HomeFree's own services have their own auto-generated
          entries; you don't need to list them here.
        </div>

        <config-section
          title="External Reverse-Proxy Entries"
          description="Routed alongside HomeFree's own services in Caddy"
        >
          <table-editor
            .columns=${columns}
            .data=${rows}
            .appliedData=${appliedRows}
            .rowKey=${'label'}
            .neutralBooleans=${true}
            addLabel="Add Entry"
            @data-change=${this.handleProxiesChange}
          ></table-editor>
        </config-section>
      </div>
    `;
  }
}

customElements.define('extra-proxies-module', ExtraProxiesModule);
