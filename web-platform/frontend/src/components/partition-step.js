import { LitElement, html, css } from 'lit';
import { getSystemInfo, setPartitioning } from '../api/client.js';

/**
 * Disk setup step.
 *
 * Lets the user pick one or more disks, choose a RAID level when 2+ are
 * selected, and toggle LUKS encryption (on by default). The encryption
 * UI adapts to probed hardware capabilities:
 *   - TPM2 present  -> auto-unlock works, reboots stay unattended.
 *   - No TPM2       -> encryption still offered, but a passphrase is
 *                      needed at every boot; the user gets an explicit
 *                      choice (encrypt-with-passphrase vs. disable).
 * Secure Boot (lanzaboote) is an advanced opt-in that hardens measured
 * boot at the cost of one manual BIOS step.
 */
class PartitionStep extends LitElement {
  static properties = {
    data: { type: Object },
    selectedDisks: { type: Array },
    raid: { type: String },
    useEncryption: { type: Boolean },
    useSwap: { type: Boolean },
    useLanzaboote: { type: Boolean },
    disks: { type: Array },
    capabilities: { type: Object },
    loading: { type: Boolean },
    showAdvanced: { type: Boolean },
  };

  static styles = css`
    :host { display: block; }

    .partition-container { max-width: 800px; margin: 0 auto; }

    h2 { font-size: 28px; color: #333; margin-bottom: 8px; }
    .intro { color: #666; margin-bottom: 24px; }

    .section {
      margin-bottom: 24px;
      padding: 24px;
      background: #f8f9fa;
      border-radius: 8px;
    }
    .section h3 { margin: 0 0 16px; color: #333; font-size: 18px; }

    .disk-list { display: flex; flex-direction: column; gap: 8px; }
    .disk-row {
      display: flex;
      align-items: center;
      padding: 12px 16px;
      border: 2px solid #e0e0e0;
      border-radius: 6px;
      background: white;
      cursor: pointer;
      transition: border-color 0.15s;
    }
    .disk-row:hover { border-color: #667eea; }
    .disk-row.selected { border-color: #667eea; background: #f0f4ff; }
    .disk-row input[type="checkbox"] {
      width: 20px; height: 20px; margin-right: 12px; cursor: pointer;
    }
    .disk-meta { display: flex; flex-direction: column; }
    .disk-name { font-weight: 600; color: #333; }
    .disk-sub { font-size: 13px; color: #777; }

    .raid-options { display: flex; gap: 12px; flex-wrap: wrap; }
    .raid-card {
      flex: 1; min-width: 200px;
      padding: 16px;
      border: 2px solid #e0e0e0;
      border-radius: 6px;
      background: white;
      cursor: pointer;
    }
    .raid-card.selected { border-color: #667eea; background: #f0f4ff; }
    .raid-card.disabled { opacity: 0.5; cursor: not-allowed; }
    .raid-card h4 { margin: 0 0 4px; color: #333; }
    .raid-card p { margin: 0; font-size: 13px; color: #777; }

    .checkbox-group { display: flex; align-items: center; margin-bottom: 12px; }
    .checkbox-group input[type="checkbox"] {
      width: 20px; height: 20px; margin-right: 12px; cursor: pointer;
    }
    .checkbox-group label { cursor: pointer; color: #333; }
    .checkbox-hint { margin: 0 0 12px 32px; font-size: 13px; color: #777; }

    .banner {
      border-radius: 6px;
      padding: 14px 16px;
      margin-top: 12px;
      font-size: 14px;
    }
    .banner.info { background: #e7f3ff; border: 1px solid #66a3ff; color: #1a4480; }
    .banner.warn { background: #fff3cd; border: 1px solid #ffc107; color: #856404; }
    .banner.danger { background: #fdecea; border: 1px solid #f5c6cb; color: #842029; }
    .banner > strong:first-child { display: block; margin-bottom: 4px; }

    .advanced-toggle {
      background: none; border: none; color: #667eea;
      cursor: pointer; font-size: 14px; padding: 0; margin-top: 8px;
    }
    .advanced-toggle:hover { text-decoration: underline; }

    .link-btn {
      background: none; border: none; color: #667eea;
      cursor: pointer; font-size: 13px; padding: 0; text-decoration: underline;
    }
  `;

  constructor() {
    super();
    this.selectedDisks = [];
    this.raid = 'none';
    // Default is decided from the probe in connectedCallback: on with a
    // TPM2 (unattended auto-unlock), off without one (a server must not
    // require a passphrase at every boot).
    this.useEncryption = false;
    this.useSwap = true;
    this.useLanzaboote = false;
    this.disks = [];
    this.capabilities = null;
    this.loading = true;
    this.showAdvanced = false;
  }

  async connectedCallback() {
    super.connectedCallback();
    try {
      const systemInfo = await getSystemInfo();
      this.disks = systemInfo.disks || [];
      this.capabilities = systemInfo.capabilities || { uefi: false, tpm2_available: false };
    } catch (error) {
      console.error('Error fetching disk information:', error);
      this.capabilities = { uefi: false, tpm2_available: false };
    } finally {
      this.loading = false;
      // Enable encryption by default only when the disk can unlock
      // itself unattended: TPM2 present on a UEFI system. Otherwise it
      // stays off (the user can still opt in, accepting boot prompts).
      this.useEncryption = this.tpm2 && this.uefi;
      // Push the default config up so the step is valid immediately
      // once a disk is chosen.
      this.notifyParent();
    }
  }

  get tpm2() {
    return !!(this.capabilities && this.capabilities.tpm2_available);
  }

  get uefi() {
    return !!(this.capabilities && this.capabilities.uefi);
  }

  formatSize(bytes) {
    const gb = bytes / (1024 ** 3);
    if (gb >= 1000) return `${(gb / 1024).toFixed(1)} TB`;
    return `${gb.toFixed(1)} GB`;
  }

  // -- config plumbing ----------------------------------------------

  buildConfig() {
    if (this.selectedDisks.length === 0) return null;
    // RAID requires 2+ disks; collapse to 'none' otherwise.
    let raid = this.raid;
    if (this.selectedDisks.length < 2) raid = 'none';
    return {
      disks: [...this.selectedDisks],
      raid,
      use_encryption: this.useEncryption,
      use_swap: this.useSwap,
      use_lanzaboote: this.useLanzaboote && this.useEncryption && this.uefi,
    };
  }

  notifyParent() {
    this.dispatchEvent(new CustomEvent('data-changed', {
      bubbles: true,
      composed: true,
      detail: { partitioning: this.buildConfig() },
    }));
  }

  async persist() {
    const config = this.buildConfig();
    this.notifyParent();
    if (!config) return;
    try {
      await setPartitioning(JSON.stringify(config));
    } catch (error) {
      console.error('Failed to save partition config:', error);
    }
  }

  // -- event handlers -----------------------------------------------

  toggleDisk(name) {
    const i = this.selectedDisks.indexOf(name);
    if (i >= 0) {
      this.selectedDisks = this.selectedDisks.filter(d => d !== name);
    } else {
      this.selectedDisks = [...this.selectedDisks, name];
    }
    // A single disk cannot be a RAID; reset the level.
    if (this.selectedDisks.length < 2) this.raid = 'none';
    // Picking 2+ disks with no RAID level set is invalid; default to
    // raid1 (the safe choice) so the step is immediately valid.
    else if (this.raid === 'none') this.raid = 'raid1';
    this.persist();
  }

  setRaid(level) {
    if (this.selectedDisks.length < 2) return;
    this.raid = level;
    this.persist();
  }

  handleSwapChange(e) {
    this.useSwap = e.target.checked;
    this.persist();
  }

  handleEncryptionChange(e) {
    this.useEncryption = e.target.checked;
    if (!this.useEncryption) this.useLanzaboote = false;
    this.persist();
  }

  handleLanzabooteChange(e) {
    this.useLanzaboote = e.target.checked;
    this.persist();
  }

  // -- render -------------------------------------------------------

  renderEncryptionBanner() {
    if (!this.useEncryption) {
      return html`
        <div class="banner warn">
          <strong>⚠️ Disk encryption is off</strong>
          Data on the disk is stored unencrypted. Anyone with physical
          access to the drive can read it.
        </div>`;
    }
    if (!this.uefi) {
      return html`
        <div class="banner danger">
          <strong>⚠️ Legacy BIOS detected</strong>
          Unattended unlock needs UEFI. The disk will be encrypted, but
          you must type the passphrase at the console on every boot.
        </div>`;
    }
    if (this.tpm2) {
      return html`
        <div class="banner info">
          <strong>✅ Unattended encryption</strong>
          A TPM2 chip was detected. After the first boot the disk unlocks
          automatically using the TPM, so the server reboots unattended.
          You will type the recovery passphrase once, on the first boot.
        </div>`;
    }
    // Encryption on, UEFI, but no TPM2.
    return html`
      <div class="banner warn">
        <strong>⚠️ No TPM2 detected — reboots need the passphrase</strong>
        The disk will be encrypted, but without a TPM the server cannot
        unlock itself. Someone must enter the passphrase at the console
        on every boot.
        <div style="margin-top:8px;">
          <button class="link-btn" @click=${() => { this.useEncryption = false; this.useLanzaboote = false; this.persist(); }}>
            Disable encryption so the server reboots unattended
          </button>
        </div>
      </div>`;
  }

  renderAdvanced() {
    // Secure Boot opt-in only makes sense with encryption + UEFI.
    const sbAvailable = this.useEncryption && this.uefi;
    return html`
      <div class="section">
        <h3>Advanced</h3>
        <div class="checkbox-group">
          <input type="checkbox" id="lanzaboote"
            .checked=${this.useLanzaboote}
            ?disabled=${!sbAvailable}
            @change=${this.handleLanzabooteChange} />
          <label for="lanzaboote">Enable Secure Boot (lanzaboote)</label>
        </div>
        <p class="checkbox-hint">
          ${sbAvailable
            ? html`Hardens measured boot so the firmware rejects tampered
                kernels. Requires a one-time manual BIOS step (putting
                firmware into Setup Mode) after installation. Leave off
                if you are not comfortable changing BIOS settings.`
            : html`Available only with disk encryption on a UEFI system.`}
        </p>
      </div>`;
  }

  render() {
    if (this.loading) {
      return html`<div class="partition-container"><h2>Disk Setup</h2>
        <p class="intro">Detecting disks…</p></div>`;
    }

    const multi = this.selectedDisks.length >= 2;

    return html`
      <div class="partition-container">
        <h2>Disk Setup</h2>
        <p class="intro">
          Select the disk(s) to install HomeFree on. All data on the
          selected disks will be erased.
        </p>

        <div class="section">
          <h3>Disks</h3>
          ${this.disks.length === 0 ? html`
            <div class="banner danger">
              <strong>No disks detected</strong>
              Please check that storage hardware is connected.
            </div>
          ` : html`
            <div class="disk-list">
              ${this.disks.map(disk => {
                const selected = this.selectedDisks.includes(disk.name);
                return html`
                  <label class="disk-row ${selected ? 'selected' : ''}">
                    <input type="checkbox" .checked=${selected}
                      @change=${() => this.toggleDisk(disk.name)} />
                    <span class="disk-meta">
                      <span class="disk-name">${disk.name}</span>
                      <span class="disk-sub">
                        ${this.formatSize(disk.size)}${disk.model && disk.model !== 'Unknown' ? ` · ${disk.model}` : ''}
                      </span>
                    </span>
                  </label>`;
              })}
            </div>
          `}
        </div>

        ${multi ? html`
          <div class="section">
            <h3>RAID Layout</h3>
            <div class="raid-options">
              <div class="raid-card ${this.raid === 'raid1' ? 'selected' : ''}"
                @click=${() => this.setRaid('raid1')}>
                <h4>Mirror (RAID1)</h4>
                <p>Every disk holds a full copy. Survives a disk failure.
                   Usable space = size of the smallest disk.</p>
              </div>
              <div class="raid-card ${this.raid === 'raid0' ? 'selected' : ''}"
                @click=${() => this.setRaid('raid0')}>
                <h4>Stripe (RAID0)</h4>
                <p>Data spread across disks for capacity and speed.
                   No redundancy — one disk failure loses everything.</p>
              </div>
            </div>
          </div>
        ` : ''}

        <div class="section">
          <h3>Encryption &amp; Options</h3>
          <div class="checkbox-group">
            <input type="checkbox" id="encryption"
              .checked=${this.useEncryption}
              @change=${this.handleEncryptionChange} />
            <label for="encryption">
              Encrypt disk with LUKS${(this.tpm2 && this.uefi) ? ' (recommended)' : ''}
            </label>
          </div>
          ${this.renderEncryptionBanner()}

          <div class="checkbox-group" style="margin-top:16px;">
            <input type="checkbox" id="swap"
              .checked=${this.useSwap}
              @change=${this.handleSwapChange} />
            <label for="swap">Enable swap partition</label>
          </div>
          ${multi ? html`
            <p class="checkbox-hint">
              On a multi-disk install swap is not mirrored and
              hibernation is disabled.
            </p>` : ''}

          <button class="advanced-toggle"
            @click=${() => { this.showAdvanced = !this.showAdvanced; }}>
            ${this.showAdvanced ? '▾ Hide advanced options' : '▸ Show advanced options'}
          </button>
        </div>

        ${this.showAdvanced ? this.renderAdvanced() : ''}

        <div class="banner warn">
          <strong>⚠️ Warning</strong>
          ${this.selectedDisks.length > 0
            ? html`All data on ${this.selectedDisks.join(', ')} will be permanently erased.`
            : html`Select at least one disk to continue.`}
        </div>
      </div>
    `;
  }
}

customElements.define('partition-step', PartitionStep);
