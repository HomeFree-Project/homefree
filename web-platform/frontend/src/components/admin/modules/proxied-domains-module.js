import { LitElement, html, css } from 'lit';
import '../../shared/config-section.js';
import '../../shared/table-editor.js';

/**
 * Proxied-domains module
 * Surfaces homefree.proxied-domains — transparent forwarding of an
 * entire domain (incl. wildcards) to a single backend host. Different
 * from extra-proxies: extra-proxies adds a subdomain under HomeFree's
 * primary domain; proxied-domains forwards a third-party domain
 * wholesale to a different server.
 */
class ProxiedDomainsModule extends LitElement {
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
    this.config = { proxied_domains: [] };
    this.modified = false;
  }

  handleChange(e) {
    // Normalize: domains comma-sep string → list, blank ports → null.
    const data = (e.detail.data || []).map(row => {
      const httpRaw = row.http_port;
      const httpsRaw = row.https_port;
      const toPort = v =>
        v === '' || v == null ? null : Number(v);
      return {
        ...row,
        domains: Array.isArray(row.domains)
          ? row.domains
          : (typeof row.domains === 'string'
              ? row.domains.split(',').map(s => s.trim()).filter(Boolean)
              : []),
        http_port: toPort(httpRaw),
        https_port: toPort(httpsRaw),
        ignore_self_signed: !!row.ignore_self_signed,
        public: !!row.public
      };
    });

    const newConfig = { ...this.config, proxied_domains: data };
    this.config = newConfig;
    this.modified = true;
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { config: newConfig },
      bubbles: true,
      composed: true
    }));
  }

  render() {
    const rows = (this.config.proxied_domains || []).map(r => ({
      ...r,
      domains: Array.isArray(r.domains) ? r.domains.join(', ') : (r.domains || ''),
      http_port:  r.http_port  == null ? '' : r.http_port,
      https_port: r.https_port == null ? '' : r.https_port
    }));

    const columns = [
      { key: 'domains', label: 'Domains (comma-sep)', type: 'text', placeholder: 'example.com, *.example.com' },
      { key: 'host', label: 'Backend Host', type: 'text', placeholder: '10.0.0.59' },
      { key: 'http_port', label: 'HTTP Port', type: 'text', placeholder: '(blank = off)' },
      { key: 'https_port', label: 'HTTPS Port', type: 'text', placeholder: '(blank = off)' },
      { key: 'ignore_self_signed', label: 'Ignore Self-Signed', type: 'boolean' },
      { key: 'public', label: 'Public on WAN', type: 'boolean' }
    ];

    return html`
      <div class="module-container">
        <div class="help-box">
          <strong>Transparent whole-domain proxy</strong>
          Forward all traffic for one or more domains (wildcards
          supported) to a single backend server. Different from
          <strong>External Proxies</strong>: those add a subdomain
          under HomeFree's own domain, while these forward a
          third-party domain wholesale. Use cases: routing
          <code>*.slacktopia.org</code> at an internal dev box,
          fronting a legacy app on its own domain, etc.
          Leave <strong>HTTP Port</strong> or <strong>HTTPS
          Port</strong> blank to disable that protocol leg.
          <strong>Ignore Self-Signed</strong> applies to the HTTPS
          backend leg only — set when the backend serves its own
          self-signed cert.
        </div>

        <config-section
          title="Proxied Domains"
          description="Transparently forward entire domains to a backend server"
        >
          <table-editor
            .columns=${columns}
            .data=${rows}
            addLabel="Add Domain"
            @data-change=${this.handleChange}
          ></table-editor>
        </config-section>
      </div>
    `;
  }
}

customElements.define('proxied-domains-module', ProxiedDomainsModule);
