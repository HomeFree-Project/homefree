import { LitElement, html, css } from 'lit';
import { getSystemInfo, setPartitioning } from '../api/client.js';
import './shared/dropdown-select.js';

class PartitionStep extends LitElement {
  static properties = {
    data: { type: Object },
    useCockpit: { type: Boolean },
    autoPartition: { type: Boolean },
    selectedDisk: { type: String },
    useEncryption: { type: Boolean },
    useSwap: { type: Boolean },
    disks: { type: Array },
    loading: { type: Boolean },
  };

  static styles = css`
    :host {
      display: block;
    }

    .partition-container {
      max-width: 800px;
      margin: 0 auto;
    }

    h2 {
      font-size: 28px;
      color: #333;
      margin-bottom: 24px;
    }

    .partition-mode {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 16px;
      margin-bottom: 32px;
    }

    .mode-card {
      padding: 24px;
      border: 2px solid #e0e0e0;
      border-radius: 8px;
      cursor: pointer;
      transition: all 0.2s;
      background: white;
    }

    .mode-card:hover {
      border-color: #667eea;
    }

    .mode-card.selected {
      border-color: #667eea;
      background: #f0f4ff;
    }

    .mode-card h3 {
      margin-bottom: 8px;
      color: #333;
    }

    .mode-card p {
      color: #666;
      font-size: 14px;
    }

    .auto-partition-options {
      margin-top: 24px;
      padding: 24px;
      background: #f8f9fa;
      border-radius: 8px;
    }

    .form-group {
      margin-bottom: 20px;
    }

    label {
      display: block;
      margin-bottom: 8px;
      font-weight: 500;
      color: #333;
    }

    select {
      width: 100%;
      padding: 12px 16px;
      font-size: 14px;
      border: 2px solid #e0e0e0;
      border-radius: 6px;
      background: white;
    }

    .checkbox-group {
      display: flex;
      align-items: center;
      margin-bottom: 16px;
    }

    .checkbox-group input[type="checkbox"] {
      width: 20px;
      height: 20px;
      margin-right: 12px;
      cursor: pointer;
    }

    .checkbox-group label {
      margin: 0;
      cursor: pointer;
    }

    .cockpit-frame {
      width: 100%;
      height: 600px;
      border: 2px solid #e0e0e0;
      border-radius: 8px;
      margin-top: 24px;
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
  `;

  constructor() {
    super();
    this.useCockpit = false;
    this.autoPartition = true;
    this.selectedDisk = '';
    this.useEncryption = false;
    this.useSwap = true;
    this.disks = [];
    this.loading = true;
  }

  async connectedCallback() {
    super.connectedCallback();
    try {
      const systemInfo = await getSystemInfo();
      this.disks = systemInfo.disks || [];
      this.loading = false;
    } catch (error) {
      console.error('Error fetching disk information:', error);
      this.loading = false;
    }
  }

  formatSize(bytes) {
    const gb = bytes / (1024 ** 3);
    if (gb >= 1000) {
      return `${(gb / 1024).toFixed(1)} TB`;
    }
    return `${gb.toFixed(1)} GB`;
  }

  notifyParent() {
    const config = this.selectedDisk ? {
      disk: this.selectedDisk,
      use_swap: this.useSwap,
      use_encryption: this.useEncryption,
    } : null;

    this.dispatchEvent(new CustomEvent('data-changed', {
      bubbles: true,
      composed: true,
      detail: {
        partitioning: config,
      }
    }));
  }

  async savePartitionConfig() {
    if (!this.selectedDisk) {
      return;
    }

    const config = {
      disk: this.selectedDisk,
      use_swap: this.useSwap,
      use_encryption: this.useEncryption,
    };

    try {
      await setPartitioning(JSON.stringify(config));
      console.log('Partition config saved:', config);
      // Notify parent of changes
      this.notifyParent();
    } catch (error) {
      console.error('Failed to save partition config:', error);
    }
  }

  handleDiskChange(e) {
    this.selectedDisk = e.target.value;
    this.savePartitionConfig();
  }

  handleSwapChange(e) {
    this.useSwap = e.target.checked;
    this.savePartitionConfig();
  }

  handleEncryptionChange(e) {
    this.useEncryption = e.target.checked;
    this.savePartitionConfig();
  }

  render() {
    return html`
      <div class="partition-container">
        <h2>Disk Partitioning</h2>

        <div class="partition-mode">
          <div
            class="mode-card ${this.autoPartition ? 'selected' : ''}"
            @click="${() => { this.autoPartition = true; this.useCockpit = false; }}"
          >
            <h3>🎯 Automatic</h3>
            <p>
              Erase disk and create partitions automatically.
              Recommended for most users.
            </p>
          </div>

          <div
            class="mode-card ${this.useCockpit ? 'selected' : ''}"
            @click="${() => { this.useCockpit = true; this.autoPartition = false; }}"
          >
            <h3>⚙️ Manual (Cockpit Storage)</h3>
            <p>
              Use Cockpit Storage for advanced partitioning,
              LVM, RAID, and encryption options.
            </p>
          </div>
        </div>

        ${this.autoPartition ? html`
          <div class="auto-partition-options">
            <div class="form-group">
              <label for="disk">Select Disk</label>
              <dropdown-select
                .options=${this.disks.map(disk => ({
                  value: disk.name,
                  label: `${disk.name} (${this.formatSize(disk.size)}${disk.model !== 'Unknown' ? ` - ${disk.model}` : ''})`
                }))}
                .value=${this.selectedDisk || null}
                .placeholder=${this.loading ? 'Loading disks...' : '-- Select a disk --'}
                ?disabled=${this.loading}
                @change=${(e) => this.handleDiskChange({ target: { value: e.detail.value } })}
              ></dropdown-select>
              ${!this.loading && this.disks.length === 0 ? html`
                <p style="color: #d32f2f; margin-top: 8px;">
                  ⚠️ No disks detected. Please check your hardware.
                </p>
              ` : ''}
            </div>

            <div class="checkbox-group">
              <input
                type="checkbox"
                id="swap"
                .checked="${this.useSwap}"
                @change="${this.handleSwapChange}"
              />
              <label for="swap">Enable swap partition (with hibernation support)</label>
            </div>

            <div class="checkbox-group">
              <input
                type="checkbox"
                id="encryption"
                .checked="${this.useEncryption}"
                @change="${this.handleEncryptionChange}"
              />
              <label for="encryption">Encrypt disk with LUKS</label>
            </div>
          </div>

          <div class="warning">
            <strong>⚠️ Warning:</strong>
            All data on ${this.selectedDisk || 'the selected disk'} will be permanently erased.
          </div>
        ` : ''}

        ${this.useCockpit ? html`
          <iframe
            class="cockpit-frame"
            src="/cockpit/storage"
            title="Cockpit Storage Manager"
          ></iframe>

          <div class="warning">
            <strong>ℹ️ Note:</strong>
            When using Cockpit Storage, make sure to create an EFI System Partition
            (for UEFI) or set up GRUB (for BIOS), and mount the root partition at /.
          </div>
        ` : ''}
      </div>
    `;
  }
}

customElements.define('partition-step', PartitionStep);
