import { LitElement, html, css } from 'lit';
import { getNetworkInterfaces, configureNetwork } from '../api/client.js';

class NetworkStep extends LitElement {
  static properties = {
    data: { type: Object },
    interfaces: { type: Array },
    loading: { type: Boolean },
    wanInterface: { type: String },
    lanInterface: { type: String },
    error: { type: String },
  };

  static styles = css`
    :host {
      display: block;
    }

    .network-container {
      max-width: 700px;
      margin: 0 auto;
    }

    h2 {
      font-size: 28px;
      color: #333;
      margin-bottom: 24px;
    }

    .description {
      color: #666;
      margin-bottom: 32px;
      line-height: 1.6;
    }

    .interface-selection {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 24px;
      margin-bottom: 24px;
    }

    .interface-card {
      padding: 24px;
      border: 2px solid #e0e0e0;
      border-radius: 8px;
      background: #f8f9fa;
    }

    .interface-card h3 {
      margin-bottom: 16px;
      color: #333;
    }

    .interface-list {
      margin-top: 16px;
    }

    .interface-option {
      padding: 12px;
      margin-bottom: 8px;
      border: 2px solid #e0e0e0;
      border-radius: 6px;
      background: white;
      cursor: pointer;
      transition: all 0.2s;
    }

    .interface-option:hover {
      border-color: #667eea;
    }

    .interface-option.selected {
      border-color: #667eea;
      background: #f0f4ff;
    }

    .interface-option input[type="radio"] {
      margin-right: 12px;
    }

    .interface-details {
      font-size: 12px;
      color: #666;
      margin-top: 4px;
      margin-left: 24px;
    }

    .info-box {
      background: #e3f2fd;
      border: 1px solid #2196f3;
      border-radius: 6px;
      padding: 16px;
      margin-top: 24px;
      color: #1565c0;
    }

    .info-box strong {
      display: block;
      margin-bottom: 8px;
    }

    .error {
      background: #ffebee;
      border: 1px solid #f44336;
      color: #c62828;
      padding: 12px;
      border-radius: 6px;
      margin-bottom: 16px;
    }

    .loading {
      text-align: center;
      padding: 40px;
      color: #666;
    }
  `;

  constructor() {
    super();
    this.interfaces = [];
    this.loading = true;
    this.wanInterface = '';
    this.lanInterface = '';
    this.error = '';
  }

  async connectedCallback() {
    super.connectedCallback();
    await this.loadInterfaces();
  }

  async loadInterfaces() {
    try {
      this.loading = true;
      const interfaces = await getNetworkInterfaces();

      this.interfaces = interfaces.filter(iface => iface.is_ethernet);

      // Show warning if insufficient interfaces
      if (this.interfaces.length < 2) {
        this.error = `Warning: Only ${this.interfaces.length} network interface(s) detected. HomeFree router mode requires 2 interfaces (WAN and LAN). Installation will continue but router functionality will be disabled.`;

        // If only 1 interface, select it for both WAN and LAN
        if (this.interfaces.length === 1) {
          this.wanInterface = this.interfaces[0].name;
          this.lanInterface = this.interfaces[0].name;
          this.notifyParent();
        }
      } else {
        // Auto-select if exactly 2 interfaces
        if (this.interfaces.length === 2) {
          this.wanInterface = this.interfaces[0].name;
          this.lanInterface = this.interfaces[1].name;
          // Auto-save when auto-selected
          this.autoSaveConfig();
          this.notifyParent();
        }
      }
    } catch (err) {
      this.error = 'Failed to load network interfaces: ' + err.message;
    } finally {
      this.loading = false;
    }
  }

  handleWanChange(name) {
    this.wanInterface = name;
    // If LAN is same as WAN, clear it (unless only 1 interface available)
    if (this.lanInterface === name && this.interfaces.length > 1) {
      this.lanInterface = '';
    }
    // Notify parent of changes
    this.notifyParent();
    // Auto-save when both interfaces selected
    this.autoSaveConfig();
  }

  handleLanChange(name) {
    this.lanInterface = name;
    // If WAN is same as LAN, clear it (unless only 1 interface available)
    if (this.wanInterface === name && this.interfaces.length > 1) {
      this.wanInterface = '';
    }
    // Notify parent of changes
    this.notifyParent();
    // Auto-save when both interfaces selected
    this.autoSaveConfig();
  }

  notifyParent() {
    this.dispatchEvent(new CustomEvent('data-changed', {
      bubbles: true,
      composed: true,
      detail: {
        wanInterface: this.wanInterface,
        lanInterface: this.lanInterface,
      }
    }));
  }

  async autoSaveConfig() {
    // Only save if both interfaces are selected
    if (!this.wanInterface || !this.lanInterface) {
      return;
    }

    this.error = '';

    try {
      const result = await configureNetwork(this.wanInterface, this.lanInterface);

      if (!result.success) {
        this.error = result.message;
      }
    } catch (err) {
      this.error = 'Failed to save network configuration: ' + err.message;
    }
  }

  async handleNext() {
    if (!this.wanInterface || !this.lanInterface) {
      this.error = 'Please select both WAN and LAN interfaces';
      return;
    }

    try {
      const result = await configureNetwork(this.wanInterface, this.lanInterface);

      if (result.success) {
        this.dispatchEvent(new CustomEvent('step-complete', {
          detail: {
            wanInterface: this.wanInterface,
            lanInterface: this.lanInterface,
          }
        }));
      } else {
        this.error = result.message;
      }
    } catch (err) {
      this.error = 'Failed to save network configuration: ' + err.message;
    }
  }

  render() {
    if (this.loading) {
      return html`<div class="loading">Loading network interfaces...</div>`;
    }

    return html`
      <div class="network-container">
        <h2>Network Configuration</h2>
        <div class="description">
          HomeFree functions as a router and requires two ethernet interfaces:
          one for WAN (internet connection) and one for LAN (local network).
        </div>

        ${this.error ? html`<div class="error">${this.error}</div>` : ''}

        <div class="interface-selection">
            <div class="interface-card">
              <h3>WAN Interface</h3>
              <p>Connect to your modem/ISP</p>
              <div class="interface-list">
                ${this.interfaces.map(iface => html`
                  <div
                    class="interface-option ${this.wanInterface === iface.name ? 'selected' : ''}"
                    @click="${() => this.handleWanChange(iface.name)}"
                  >
                    <input
                      type="radio"
                      name="wan"
                      value="${iface.name}"
                      .checked="${this.wanInterface === iface.name}"
                      ?disabled="${this.lanInterface === iface.name && this.interfaces.length > 1}"
                    />
                    ${iface.name}
                    <div class="interface-details">
                      ${iface.mac} • ${iface.speed}
                    </div>
                  </div>
                `)}
              </div>
            </div>

            <div class="interface-card">
              <h3>LAN Interface</h3>
              <p>Connect to your local network</p>
              <div class="interface-list">
                ${this.interfaces.map(iface => html`
                  <div
                    class="interface-option ${this.lanInterface === iface.name ? 'selected' : ''}"
                    @click="${() => this.handleLanChange(iface.name)}"
                  >
                    <input
                      type="radio"
                      name="lan"
                      value="${iface.name}"
                      .checked="${this.lanInterface === iface.name}"
                      ?disabled="${this.wanInterface === iface.name && this.interfaces.length > 1}"
                    />
                    ${iface.name}
                    <div class="interface-details">
                      ${iface.mac} • ${iface.speed}
                    </div>
                  </div>
                `)}
              </div>
            </div>
        </div>

        <div class="info-box">
          <strong>ℹ️ Note:</strong>
          After installation, the WAN interface will receive an IP from your ISP,
          and the LAN interface will be configured as 10.0.0.1 with DHCP server.
        </div>
      </div>
    `;
  }
}

customElements.define('network-step', NetworkStep);
