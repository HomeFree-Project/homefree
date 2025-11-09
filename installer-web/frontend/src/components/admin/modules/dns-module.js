import { LitElement, html, css } from 'lit';
import '../../shared/config-section.js';
import '../../shared/table-editor.js';

/**
 * DNS configuration module
 * Handles: Local DNS overrides, dynamic DNS zones
 */
class DnsModule extends LitElement {
  static properties = {
    config: { type: Object },
    modified: { type: Boolean }
  };

  static styles = css`
    :host {
      display: block;
    }

    .module-container {
      max-width: 1000px;
    }
  `;

  constructor() {
    super();
    this.config = {
      dns: {
        overrides: []
      }
    };
    this.modified = false;
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

  handleDnsOverridesChange(e) {
    this.handleFieldChange('dns.overrides', e.detail.data);
  }

  render() {
    const { dns } = this.config;

    // DNS overrides table columns
    const dnsOverrideColumns = [
      { key: 'hostname', label: 'Hostname', type: 'text', placeholder: 'myserver' },
      { key: 'domain', label: 'Domain', type: 'text', placeholder: 'local' },
      { key: 'ip', label: 'IP Address', type: 'text', placeholder: '10.0.0.50' }
    ];

    return html`
      <div class="module-container">
        <!-- Local DNS Overrides -->
        <config-section
          title="Local DNS Overrides"
          description="Map custom hostnames to IP addresses on your local network"
        >
          <p style="color: #86868b; font-size: 14px; margin-bottom: 16px;">
            DNS overrides allow you to resolve custom hostnames like "myserver.local" to specific IP addresses on your network.
          </p>

          <table-editor
            .columns=${dnsOverrideColumns}
            .data=${dns.overrides || []}
            addLabel="Add DNS Override"
            @data-change=${this.handleDnsOverridesChange}
          ></table-editor>
        </config-section>

        <!-- Future: Dynamic DNS -->
        <config-section
          title="Dynamic DNS"
          description="Automatically update your public DNS records (Coming Soon)"
        >
          <p style="color: #86868b; font-size: 14px;">
            Dynamic DNS configuration will be available in a future update. This will allow you to automatically update DNS records when your public IP address changes.
          </p>
        </config-section>
      </div>
    `;
  }
}

customElements.define('dns-module', DnsModule);
