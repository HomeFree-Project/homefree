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
    modified: { type: Boolean }
  };

  static styles = css`
    :host { display: block; }
    .module-container { width: 100%; }
    .help-box {
      background: rgba(59, 130, 246, 0.08);
      border-left: 4px solid var(--hf-accent);
      padding: 14px 18px;
      border-radius: 8px;
      margin-bottom: 20px;
      color: var(--hf-text-muted);
      font-size: 13px;
      max-width: 1200px;
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
    this.config = { service_config: [] };
    this.modified = false;
  }

  handleProxiesChange(e) {
    // table-editor returns rows with snake_case keys; subdomains is a
    // comma-separated text field that we split/join.
    const data = (e.detail.data || []).map(row => ({
      ...row,
      port: row.port === '' || row.port == null ? 80 : Number(row.port),
      subdomains: Array.isArray(row.subdomains)
        ? row.subdomains
        : (typeof row.subdomains === 'string'
            ? row.subdomains.split(',').map(s => s.trim()).filter(Boolean)
            : [])
    }));

    const newConfig = { ...this.config, service_config: data };
    this.config = newConfig;
    this.modified = true;
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { config: newConfig },
      bubbles: true,
      composed: true
    }));
  }

  render() {
    const rows = (this.config.service_config || []).map(r => ({
      ...r,
      subdomains: Array.isArray(r.subdomains) ? r.subdomains.join(', ') : (r.subdomains || '')
    }));

    const columns = [
      { key: 'label', label: 'Label', type: 'text', placeholder: 'envoy' },
      { key: 'name', label: 'Display Name', type: 'text', placeholder: 'Enphase Solar' },
      { key: 'host', label: 'Backend Host', type: 'text', placeholder: 'envoy.lan or 10.0.0.43' },
      { key: 'port', label: 'Port', type: 'text', placeholder: '80' },
      { key: 'subdomains', label: 'Subdomains (comma-sep)', type: 'text', placeholder: 'envoy' },
      { key: 'ssl', label: 'Backend Uses HTTPS', type: 'boolean' },
      { key: 'ssl_no_verify', label: 'Skip Cert Verify', type: 'boolean' },
      { key: 'disable_keepalive', label: 'No Keep-Alive', type: 'boolean' },
      { key: 'public', label: 'Public on WAN', type: 'boolean' }
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
            addLabel="Add Entry"
            @data-change=${this.handleProxiesChange}
          ></table-editor>
        </config-section>
      </div>
    `;
  }
}

customElements.define('extra-proxies-module', ExtraProxiesModule);
