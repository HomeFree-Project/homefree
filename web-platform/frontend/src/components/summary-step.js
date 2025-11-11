import { LitElement, html, css } from 'lit';
import { getInstallSummary } from '../api/client.js';

class SummaryStep extends LitElement {
  static properties = {
    data: { type: Object },
    summary: { type: Object },
    loading: { type: Boolean },
  };

  static styles = css`
    :host {
      display: block;
    }

    .summary-container {
      max-width: 700px;
      margin: 0 auto;
    }

    h2 {
      font-size: 28px;
      color: #333;
      margin-bottom: 24px;
    }

    .summary-section {
      margin-bottom: 24px;
      padding: 20px;
      background: #f8f9fa;
      border-radius: 8px;
      border-left: 4px solid #667eea;
    }

    .summary-section h3 {
      margin-bottom: 12px;
      color: #333;
      font-size: 18px;
    }

    .summary-item {
      display: flex;
      justify-content: space-between;
      padding: 8px 0;
      border-bottom: 1px solid #e0e0e0;
    }

    .summary-item:last-child {
      border-bottom: none;
    }

    .summary-label {
      font-weight: 500;
      color: #666;
    }

    .summary-value {
      color: #333;
      text-align: right;
    }

    .warning {
      background: #fff3cd;
      border: 1px solid #ffc107;
      border-radius: 6px;
      padding: 16px;
      margin-top: 24px;
      color: #856404;
    }

    .warning strong {
      display: block;
      margin-bottom: 8px;
    }

    .warning ul {
      margin: 8px 0 0 20px;
    }

    .warning li {
      margin-bottom: 4px;
    }
  `;

  constructor() {
    super();
    this.summary = null;
    this.loading = true;
  }

  async connectedCallback() {
    super.connectedCallback();
    try {
      this.summary = await getInstallSummary();
      this.loading = false;
    } catch (error) {
      console.error('Error fetching install summary:', error);
      this.loading = false;
    }
  }

  render() {
    if (this.loading) {
      return html`<div style="text-align: center; padding: 40px;">Loading summary...</div>`;
    }

    const s = this.summary || {};

    return html`
      <div class="summary-container">
        <h2>Installation Summary</h2>
        <p style="color: #666; margin-bottom: 24px;">
          Please review your installation settings before proceeding.
        </p>

        <div class="summary-section">
          <h3>System Settings</h3>
          <div class="summary-item">
            <span class="summary-label">Hostname:</span>
            <span class="summary-value">${s.hostname || 'Not set'}</span>
          </div>
          <div class="summary-item">
            <span class="summary-label">Timezone:</span>
            <span class="summary-value">${s.timezone || 'America/Los_Angeles'}</span>
          </div>
          <div class="summary-item">
            <span class="summary-label">Locale:</span>
            <span class="summary-value">${s.locale || 'en_US.UTF-8'}</span>
          </div>
          <div class="summary-item">
            <span class="summary-label">Keyboard Layout:</span>
            <span class="summary-value">${s.keymap || 'us'}</span>
          </div>
        </div>

        <div class="summary-section">
          <h3>Network Configuration</h3>
          ${s.wan_interface && s.lan_interface ? html`
            <div class="summary-item">
              <span class="summary-label">WAN Interface:</span>
              <span class="summary-value">${s.wan_interface}</span>
            </div>
            <div class="summary-item">
              <span class="summary-label">LAN Interface:</span>
              <span class="summary-value">${s.lan_interface}</span>
            </div>
            <div class="summary-item">
              <span class="summary-label">LAN IP Address:</span>
              <span class="summary-value">10.0.0.1/24 (default)</span>
            </div>
          ` : html`
            <div class="summary-item">
              <span class="summary-label">Router Mode:</span>
              <span class="summary-value" style="color: #d32f2f;">Disabled (single NIC detected)</span>
            </div>
          `}
        </div>

        <div class="summary-section">
          <h3>User Account</h3>
          <div class="summary-item">
            <span class="summary-label">Username:</span>
            <span class="summary-value">${s.username || 'Not set'}</span>
          </div>
          <div class="summary-item">
            <span class="summary-label">Full Name:</span>
            <span class="summary-value">${s.fullname || 'Not set'}</span>
          </div>
        </div>

        <div class="summary-section">
          <h3>Disk Partitioning</h3>
          <div class="summary-item">
            <span class="summary-label">Target Disk:</span>
            <span class="summary-value">${s.partitioning?.device || 'Not set'}</span>
          </div>
          <div class="summary-item">
            <span class="summary-label">Filesystem:</span>
            <span class="summary-value">Btrfs with subvolumes</span>
          </div>
          ${s.partitioning?.encryption ? html`
            <div class="summary-item">
              <span class="summary-label">Encryption:</span>
              <span class="summary-value">LUKS (enabled)</span>
            </div>
          ` : ''}
          ${s.partitioning?.swap !== false ? html`
            <div class="summary-item">
              <span class="summary-label">Swap:</span>
              <span class="summary-value">Enabled (with hibernation)</span>
            </div>
          ` : ''}
        </div>

        <div class="warning">
          <strong>⚠️ Ready to Install</strong>
          <p>Clicking "Next" will begin the installation process:</p>
          <ul>
            <li>All data on the selected disk will be permanently erased</li>
            <li>Partitions will be created and formatted</li>
            <li>NixOS will be installed with HomeFree configuration</li>
            <li>This process cannot be undone</li>
          </ul>
          <p style="margin-top: 12px;">
            <strong>Make sure you have backups before proceeding!</strong>
          </p>
        </div>
      </div>
    `;
  }
}

customElements.define('summary-step', SummaryStep);
