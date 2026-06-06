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
    const splitList = (v) => Array.isArray(v)
      ? v
      : (typeof v === 'string'
          ? v.split(',').map(s => s.trim()).filter(Boolean)
          : []);
    const data = (e.detail.data || []).map(row => {
      const parsedSubdomains = splitList(row.subdomains);
      const parsedCspSources = splitList(row['extra-csp-sources']);
      const entry = {
        ...row,
        port: row.port === '' || row.port == null ? 80 : Number(row.port),
        // The help box promises subdomains defaults to [label] when
        // blank — apply it here so the saved entry actually has a
        // subdomain (an empty list yields no URL and no Caddy route).
        subdomains: parsedSubdomains.length > 0
          ? parsedSubdomains
          : (row.label ? [row.label] : []),
        'extra-csp-sources': parsedCspSources
      };
      // Keep the entry minimal: drop the CSP-allowlist key entirely when
      // empty (the common case), so a blank field isn't read as an
      // undeployed change against deployed entries that omit it.
      if (parsedCspSources.length === 0) delete entry['extra-csp-sources'];
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
      subdomains: Array.isArray(r.subdomains) ? r.subdomains.join(', ') : (r.subdomains || ''),
      'extra-csp-sources': Array.isArray(r['extra-csp-sources'])
        ? r['extra-csp-sources'].join(', ')
        : (r['extra-csp-sources'] || '')
    });
    const rows = (this.config['service-config'] || []).map(toRow);
    // Deployed rows in the same shape, so table-editor can flag added/changed
    // rows (those not present in the last-applied config).
    const appliedRows = (this.appliedConfig?.['service-config'] || []).map(toRow);

    // Short table headers keep the grid narrow (each boolean renders a
    // single ✓/✗ glyph); `modalLabel` spells the field out in the edit
    // modal and `description` adds subtext there. The help box above the
    // table still gives the overview.
    const columns = [
      { key: 'enable', label: 'Enabled', type: 'boolean', default: true,
        description: 'Uncheck to keep this entry but stop routing it — no Caddy vhost and no DNS record are emitted.' },
      { key: 'label', label: 'Label', type: 'text', placeholder: 'envoy',
        description: 'Unique short identifier for this entry.' },
      { key: 'name', label: 'Display Name', type: 'text', placeholder: 'Enphase Solar',
        description: 'Friendly name shown in the app catalog.' },
      { key: 'host', label: 'Backend Host', type: 'text', placeholder: 'envoy.lan or 10.0.0.43',
        description: 'Hostname or IP of the device on your network.' },
      { key: 'port', label: 'Port', type: 'text', placeholder: '80',
        description: 'Backend port (typically 80, or 443 when the device serves HTTPS).' },
      { key: 'subdomains', label: 'Subdomains (comma-sep)', type: 'text', placeholder: 'envoy',
        description: 'Subdomains to serve this on; defaults to the label if blank.' },
      { key: 'ssl', label: 'HTTPS', type: 'boolean', modalLabel: 'Backend uses HTTPS',
        description: 'Enable when the device serves HTTPS itself (most consumer hardware on port 443, usually with a self-signed cert).' },
      { key: 'ssl-no-verify', label: 'No Verify', type: 'boolean', modalLabel: 'Skip certificate verification',
        description: 'Trust the backend TLS cert without validating it — needed for the self-signed certs most appliances ship. Only meaningful with “Backend uses HTTPS”.' },
      { key: 'disable-keepalive', label: 'No KA', type: 'boolean', modalLabel: 'Disable keep-alive',
        description: 'Open a fresh connection per request (HTTP/1.1) instead of reusing one. Turn on for tiny embedded servers that close the socket after each response, which otherwise cause intermittent 502s (OpenSprinkler, some NAS admin pages).' },
      { key: 'strip-cookies', label: 'No Cookie', type: 'boolean', modalLabel: 'Strip cookies',
        description: 'Remove the browser’s Cookie header before forwarding. Turn on if the device returns “The request was too large” — its small request buffer can’t hold HomeFree’s SSO session cookie, which the device never needs.' },
      { key: 'public', label: 'Public', type: 'boolean', modalLabel: 'Public (expose on WAN)',
        description: 'Serve this on the WAN interface. Leave off to keep it reachable only from the LAN.' },
      { key: 'extra-csp-sources', label: 'CSP Allow', type: 'text',
        placeholder: 'https://ui.opensprinkler.com',
        modalLabel: 'Allowed external sources (CSP)',
        description: 'Comma-separated origins to allow in this vhost’s Content-Security-Policy (script/style/img/font/connect). Leave blank for almost everything — only needed when a proxied device loads its own UI from a vendor CDN (e.g. OpenSprinkler from ui.opensprinkler.com). This lets the page make off-box requests, so prefer self-hosting where possible.' }
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
          For tiny embedded appliances (OpenSprinkler and similar),
          <strong>No KA</strong> disables HTTP keep-alive and
          <strong>No Cookie</strong> strips the forwarded cookie header
          — turn the latter on if the device returns
          <em>"The request was too large"</em> when reached through its
          <code>homefree.host</code> subdomain (its buffer can't hold
          the browser's SSO cookie, which the device never needs).
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
