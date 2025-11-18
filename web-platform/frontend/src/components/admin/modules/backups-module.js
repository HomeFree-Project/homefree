import { LitElement, html, css } from 'lit';
import '../../shared/config-section.js';
import '../../shared/form-field.js';
import '../../shared/progress-modal.js';
import '../secrets-input.js';

/**
 * Backups configuration module
 * Handles: Local backups, Backblaze B2 cloud backups, and restore operations
 */
class BackupsModule extends LitElement {
  static properties = {
    config: { type: Object },
    modified: { type: Boolean },
    activeTab: { type: String },
    secretsStatus: { type: Object },
    backupConfigStatus: { type: Object },
    services: { type: Array },
    selectedService: { type: String },
    snapshots: { type: Array },
    selectedSnapshot: { type: String },
    loading: { type: Boolean },
    restoreServiceInProgress: { type: String }, // Stores snapshot ID being restored: "latest", snapshot ID, or null
    restoreAllInProgress: { type: Boolean }
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

    .info-box {
      background: #e3f2fd;
      border-left: 4px solid #2196f3;
      padding: 16px;
      border-radius: 8px;
      margin-bottom: 20px;
      color: #1565c0;
      max-width: 1200px;
    }

    .info-box strong {
      display: block;
      margin-bottom: 8px;
    }

    .tabs {
      display: flex;
      gap: 8px;
      margin-bottom: 24px;
      border-bottom: 2px solid #e5e5e7;
    }

    .tab {
      padding: 12px 24px;
      background: none;
      border: none;
      border-bottom: 3px solid transparent;
      cursor: pointer;
      font-size: 15px;
      font-weight: 500;
      color: #86868b;
      transition: all 0.2s;
      margin-bottom: -2px;
    }

    .tab:hover {
      color: #1d1d1f;
    }

    .tab.active {
      color: #667eea;
      border-bottom-color: #667eea;
    }

    .restore-container {
      max-width: 1200px;
    }

    .status-indicator {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 8px 16px;
      border-radius: 8px;
      font-size: 14px;
      margin-bottom: 16px;
    }

    .status-indicator.ready {
      background: #d4edda;
      color: #155724;
    }

    .status-indicator.not-ready {
      background: #f8d7da;
      color: #721c24;
    }

    .status-indicator.warning {
      background: #fff3cd;
      color: #856404;
    }

    select {
      width: 100%;
      padding: 12px;
      font-size: 14px;
      border: 1px solid #d2d2d7;
      border-radius: 8px;
      background: white;
      margin-bottom: 16px;
    }

    .snapshots-list {
      border: 1px solid #d2d2d7;
      border-radius: 8px;
      max-height: 400px;
      overflow-y: auto;
      margin-bottom: 16px;
    }

    .snapshot-item {
      padding: 12px 16px;
      border-bottom: 1px solid #e5e5e7;
      cursor: pointer;
      transition: background 0.2s;
    }

    .snapshot-item:last-child {
      border-bottom: none;
    }

    .snapshot-item:hover {
      background: #f5f5f7;
    }

    .snapshot-item.selected {
      background: #e3f2fd;
      border-left: 4px solid #2196f3;
    }

    .snapshot-id {
      font-family: monospace;
      font-size: 12px;
      color: #86868b;
    }

    .snapshot-time {
      font-size: 14px;
      font-weight: 500;
      color: #1d1d1f;
      margin-bottom: 4px;
    }

    @keyframes spin {
      to { transform: rotate(360deg); }
    }

    .btn-group {
      display: flex;
      gap: 12px;
      margin-top: 16px;
    }

    .btn {
      padding: 12px 24px;
      border-radius: 8px;
      border: none;
      font-size: 14px;
      font-weight: 500;
      cursor: pointer;
      transition: all 0.2s;
    }

    .btn:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }

    .btn-primary {
      background: #667eea;
      color: white;
    }

    .btn-primary:hover:not(:disabled) {
      background: #5568d3;
    }

    .btn-secondary {
      background: #f5f5f7;
      color: #1d1d1f;
      border: 1px solid #d2d2d7;
    }

    .btn-secondary:hover:not(:disabled) {
      background: #e5e5e7;
    }

    .btn-danger {
      background: #ff3b30;
      color: white;
    }

    .btn-danger:hover:not(:disabled) {
      background: #ff2d20;
    }
  `;

  constructor() {
    super();
    this.config = {
      backups: {
        enable: false,
        to_path: '',
        backblaze_enable: false,
        backblaze_bucket: ''
      }
    };
    this.modified = false;
    this.activeTab = 'configuration';
    this.secretsStatus = null;
    this.backupConfigStatus = null;
    this.services = [];
    this.selectedService = null;
    this.snapshots = [];
    this.loading = false;
    this.restoreServiceInProgress = null; // Stores snapshot ID being restored: "latest", snapshot ID, or null
    this.restoreAllInProgress = false;
  }

  async connectedCallback() {
    super.connectedCallback();
    await this.loadSecretsStatus();
    await this.loadBackupConfigStatus();
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

  async loadSecretsStatus() {
    try {
      const response = await fetch('/api/secrets/status');
      if (response.ok) {
        const data = await response.json();
        this.secretsStatus = data.secrets?.backup || {};
      }
    } catch (error) {
      console.error('Error loading secrets status:', error);
    }
  }

  async loadBackupConfigStatus() {
    try {
      const response = await fetch('/api/backups/config/status');
      if (response.ok) {
        this.backupConfigStatus = await response.json();
      }
    } catch (error) {
      console.error('Error loading backup config status:', error);
    }
  }

  async loadServices() {
    this.loading = true;
    try {
      const response = await fetch('/api/backups/services');
      if (response.ok) {
        const data = await response.json();
        this.services = data.services || [];
      }
    } catch (error) {
      console.error('Error loading services:', error);
    } finally {
      this.loading = false;
    }
  }

  async loadSnapshots(service) {
    if (!service) return;

    this.loading = true;
    try {
      const response = await fetch(`/api/backups/services/${encodeURIComponent(service)}/snapshots`);
      if (response.ok) {
        const data = await response.json();
        // Reverse to show newest snapshots first (restic returns oldest first)
        this.snapshots = (data.snapshots || []).reverse();
        // Auto-select the latest (first) snapshot
        if (this.snapshots.length > 0) {
          this.selectedSnapshot = this.snapshots[0].id;
        }
      }
    } catch (error) {
      console.error('Error loading snapshots:', error);
    } finally {
      this.loading = false;
    }
  }

  async handleTabChange(tab) {
    this.activeTab = tab;
    if (tab === 'restore') {
      await this.loadServices();
    }
  }

  async handleServiceChange(e) {
    this.selectedService = e.target.value;
    if (this.selectedService) {
      await this.loadSnapshots(this.selectedService);
    } else {
      this.snapshots = [];
    }
  }

  async handleRestore(service, snapshotId = null) {
    const snapshotDesc = snapshotId ? `snapshot ${snapshotId.substring(0, 8)}` : 'latest snapshot';
    const modal = this.renderRoot.querySelector('progress-modal');

    // Show confirmation modal
    modal.show(
      'Confirm Restore',
      `Are you sure you want to restore ${service} from ${snapshotDesc}?`,
      'confirm',
      {
        confirmText: 'Restore',
        cancelText: 'Cancel',
        confirmVariant: 'danger',
        details: [
          { message: 'This will overwrite current data', type: 'warning' }
        ],
        confirmCallback: async () => {
          await this.performRestore(service, snapshotId);
        }
      }
    );
  }

  async performRestore(service, snapshotId = null) {
    const modal = this.renderRoot.querySelector('progress-modal');

    // Store which snapshot is being restored: "latest" or the specific snapshot ID
    this.restoreServiceInProgress = snapshotId || "latest";

    // Show progress modal
    modal.show(
      'Restoring Service',
      `Restoring ${service}...`,
      'progress'
    );

    try {
      const response = await fetch(`/api/backups/services/${encodeURIComponent(service)}/restore`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          snapshot_id: snapshotId,
          source: 'auto',
          dry_run: false,
          create_snapshot: false
        })
      });

      if (response.ok) {
        modal.updateStatus('success', `Successfully restored ${service}`);
        this.showNotification(`Successfully restored ${service}`, 'success');
      } else {
        const error = await response.json();
        modal.updateStatus('error', `Failed to restore ${service}`, [
          { message: error.detail || 'Unknown error', type: 'error' }
        ]);
        this.showNotification(`Failed to restore ${service}: ${error.detail || 'Unknown error'}`, 'error');
      }
    } catch (error) {
      console.error('Error restoring service:', error);
      modal.updateStatus('error', `Error restoring ${service}`, [
        { message: error.message, type: 'error' }
      ]);
      this.showNotification(`Error restoring ${service}: ${error.message}`, 'error');
    } finally {
      this.restoreServiceInProgress = null;
    }
  }

  async handleRestoreAll() {
    const serviceCount = this.services.length;
    const modal = this.renderRoot.querySelector('progress-modal');

    // Show confirmation modal
    modal.show(
      'Restore All Services',
      `This will restore ALL ${serviceCount} services from their latest backups.`,
      'confirm',
      {
        confirmText: 'Restore All',
        cancelText: 'Cancel',
        confirmVariant: 'danger',
        details: [
          { message: 'This will overwrite all current service data', type: 'warning' },
          { message: `${serviceCount} services will be restored`, type: 'warning' }
        ],
        confirmCallback: async () => {
          await this.performRestoreAll(serviceCount);
        }
      }
    );
  }

  async performRestoreAll(serviceCount) {
    const modal = this.renderRoot.querySelector('progress-modal');

    this.restoreAllInProgress = true;

    // Show progress modal
    modal.show(
      'Restoring All Services',
      `Restoring ${serviceCount} services...`,
      'progress'
    );

    try {
      const response = await fetch('/api/backups/restore-all', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          snapshot_id: null,
          source: 'auto',
          dry_run: false
        })
      });

      if (response.ok) {
        modal.updateStatus('success', `Successfully restored all ${serviceCount} services!`);
        this.showNotification(`Successfully restored all ${serviceCount} services!`, 'success');
        await this.loadServices(); // Refresh the list
      } else {
        const error = await response.json();
        modal.updateStatus('error', `Failed to restore all services`, [
          { message: error.detail || 'Unknown error', type: 'error' }
        ]);
        this.showNotification(`Failed to restore all services: ${error.detail || 'Unknown error'}`, 'error');
      }
    } catch (error) {
      console.error('Error restoring all services:', error);
      modal.updateStatus('error', `Error restoring all services`, [
        { message: error.message, type: 'error' }
      ]);
      this.showNotification(`Error restoring all services: ${error.message}`, 'error');
    } finally {
      this.restoreAllInProgress = false;
    }
  }

  handleSecretUpdated() {
    this.loadSecretsStatus();
    this.loadBackupConfigStatus();
  }

  showNotification(message, type = 'info') {
    // Dispatch event to parent component (admin-app) to show toast
    this.dispatchEvent(new CustomEvent('show-toast', {
      detail: { message, type },
      bubbles: true,
      composed: true
    }));
  }

  renderConfigurationTab() {
    const { backups } = this.config;

    return html`
      <!-- Local Backups -->
      <config-section
        title="Local Backups"
        description="Automatic backups to a local storage device using Restic"
      >
        <form-field
          label="Enable Local Backups"
          type="boolean"
          .value=${backups.enable}
          help="Enable automatic backups of service data"
          @field-change=${(e) => this.handleFieldChange('backups.enable', e.detail.value)}
        ></form-field>

        <form-field
          label="Backup Directory"
          type="text"
          .value=${backups.to_path}
          placeholder="/var/lib/backups"
          help="Path to local backup storage (shown for restore even if backups disabled)"
          @field-change=${(e) => this.handleFieldChange('backups.to_path', e.detail.value)}
        ></form-field>

        ${backups.enable ? html`
          <div class="info-box">
            <strong>ℹ️ Backup Information</strong>
            <div style="font-size: 14px;">
              HomeFree uses Restic for encrypted, deduplicated backups. Backups run automatically at 2 AM daily and include all enabled service data.
            </div>
          </div>
        ` : ''}
      </config-section>

      <!-- Backup Secrets -->
      <config-section
        title="Backup Secrets"
        description="Encryption password and cloud storage credentials"
      >
        <secrets-input
          serviceLabel="backup"
          secretKey="restic-password"
          label="Restic Password"
          description="Encryption password for backup repositories (required for backups and restores)"
          .exists=${this.secretsStatus?.['restic-password'] || false}
          @secret-updated=${() => this.handleSecretUpdated()}
        ></secrets-input>

        ${backups.backblaze_enable ? html`
          <secrets-input
            serviceLabel="backup"
            secretKey="backblaze-id"
            label="Backblaze Account ID"
            description="Your Backblaze B2 account ID"
            .exists=${this.secretsStatus?.['backblaze-id'] || false}
            @secret-updated=${() => this.handleSecretUpdated()}
          ></secrets-input>

          <secrets-input
            serviceLabel="backup"
            secretKey="backblaze-key"
            label="Backblaze Application Key"
            description="Your Backblaze B2 application key"
            .exists=${this.secretsStatus?.['backblaze-key'] || false}
            @secret-updated=${() => this.handleSecretUpdated()}
          ></secrets-input>
        ` : ''}
      </config-section>

      <!-- Backblaze B2 Cloud Backups -->
      <config-section
        title="Backblaze B2 Cloud Backups"
        description="Off-site encrypted backups to Backblaze B2 cloud storage"
      >
        <form-field
          label="Enable Backblaze Backups"
          type="boolean"
          .value=${backups.backblaze_enable}
          help="Send encrypted backups to Backblaze B2 cloud storage"
          @field-change=${(e) => this.handleFieldChange('backups.backblaze_enable', e.detail.value)}
        ></form-field>

        <form-field
          label="Backblaze Bucket Name"
          type="text"
          .value=${backups.backblaze_bucket}
          placeholder="my-homefree-backups"
          help="B2 bucket name for storing backups (shown for restore even if Backblaze disabled)"
          @field-change=${(e) => this.handleFieldChange('backups.backblaze_bucket', e.detail.value)}
        ></form-field>

        ${backups.backblaze_enable ? html`
          <div class="info-box">
            <strong>ℹ️ Backblaze Configuration</strong>
            <div style="font-size: 14px; margin-top: 8px;">
              To use Backblaze B2:
              <ul style="margin: 8px 0 0 20px; padding: 0;">
                <li>Create a B2 account at backblaze.com</li>
                <li>Create a bucket for your backups</li>
                <li>Generate application keys with read/write access</li>
                <li>Configure credentials above in Backup Secrets</li>
              </ul>
            </div>
          </div>
        ` : ''}
      </config-section>

      <!-- Future: Backup Schedule -->
      <config-section
        title="Backup Schedule"
        description="Configure backup timing and retention (Coming Soon)"
      >
        <p style="color: #86868b; font-size: 14px;">
          Custom backup schedules and retention policies will be available in a future update. Currently, backups run daily at 2 AM with automatic retention management.
        </p>
      </config-section>
    `;
  }

  renderRestoreTab() {
    const isReady = this.backupConfigStatus?.restic_password_configured;
    const hasLocalBackups = this.backupConfigStatus?.local_backups_available;
    const hasBackblaze = this.backupConfigStatus?.backblaze_configured;
    const backblazeMounted = this.backupConfigStatus?.backblaze_mounted;

    return html`
      <div class="restore-container">
        <config-section
          title="Restore from Backup"
          description="Restore service data from backups"
        >
          ${!isReady ? html`
            <div class="status-indicator not-ready">
              ⚠️ Restic password not configured. Please configure it in the Configuration tab before restoring.
            </div>
          ` : this.loading ? html`
            <div class="status-indicator" style="background: #f5f5f7; border-color: #d1d1d6;">
              <div style="display: flex; align-items: flex-start; gap: 8px;">
                <span style="display: block; width: 16px; height: 16px; border: 2px solid #86868b; border-top-color: transparent; border-radius: 50%; animation: spin 1s linear infinite; flex-shrink: 0; margin-top: 2px;"></span>
                <div style="color: #86868b;">
                  <div style="font-weight: 600; margin-bottom: 4px;">Loading backup information...</div>
                  <div style="font-size: 14px;">Checking available backup repositories</div>
                </div>
              </div>
            </div>
          ` : html`
            <div class="status-indicator ready">
              <div style="font-weight: 600; margin-bottom: 8px;">✓ Restore is ready</div>
              <div style="font-size: 14px;">
                <strong>Available backup sources:</strong>
                <ul style="margin: 4px 0 0 20px; padding: 0;">
                  ${hasLocalBackups ? html`
                    <li>Local backups (${this.backupConfigStatus?.local_backup_path})</li>
                  ` : ''}
                  ${backblazeMounted ? html`
                    <li>Backblaze B2 cloud backups (${this.services.length} services found)</li>
                  ` : hasBackblaze ? html`
                    <li>Backblaze configured but not mounted (enable in Configuration to restore)</li>
                  ` : ''}
                  ${!hasLocalBackups && !backblazeMounted ? html`
                    <li style="color: #856404;">⚠️ No backup sources found. Configure Backblaze or check local backup path.</li>
                  ` : ''}
                </ul>
              </div>
            </div>

            ${this.loading ? html`
              <div style="padding: 40px; text-align: center; color: #86868b;">
                <div style="font-size: 16px; margin-bottom: 8px;">Loading available services...</div>
                <div style="font-size: 14px;">Checking backup repositories</div>
              </div>
            ` : html`
              <!-- Restore All Button -->
              <div style="margin-bottom: 32px; padding: 20px; background: #fff3cd; border: 2px solid #ffc107; border-radius: 8px;">
                <div style="font-size: 16px; font-weight: 600; margin-bottom: 8px; color: #856404;">
                  🔄 Restore All Services
                </div>
                <div style="font-size: 14px; color: #856404; margin-bottom: 12px;">
                  Restore all ${this.services.length} services from their latest backups. This is useful when setting up a new machine.
                </div>
                <button
                  class="btn btn-danger"
                  @click=${() => this.handleRestoreAll()}
                  ?disabled=${this.restoreAllInProgress || this.restoreServiceInProgress || this.services.length === 0}
                >
                  ${this.restoreAllInProgress ? 'Restoring All Services...' : 'Restore All Services from Latest Backups'}
                </button>
              </div>

              <div style="margin-bottom: 16px;">
                <label style="display: block; font-size: 14px; font-weight: 500; margin-bottom: 8px;">
                  Or restore individual service:
                </label>
                <select
                  @change=${this.handleServiceChange}
                  ?disabled=${this.loading || this.restoreServiceInProgress || this.restoreAllInProgress}
                >
                  <option value="">-- Select a service --</option>
                  ${this.services.map(service => html`
                    <option value="${service}" ?selected=${service === this.selectedService}>
                      ${service}
                    </option>
                  `)}
                </select>
              </div>
            `}

            ${this.selectedService ? html`
              <div style="margin-bottom: 16px;">
                <label style="display: block; font-size: 14px; font-weight: 500; margin-bottom: 8px;">
                  Available Snapshots for ${this.selectedService}
                </label>

                ${this.loading ? html`
                  <p style="color: #86868b;">Loading snapshots...</p>
                ` : this.snapshots.length === 0 ? html`
                  <p style="color: #86868b;">No snapshots found for this service.</p>
                ` : html`
                  <div class="snapshots-list">
                    ${this.snapshots.map((snapshot, index) => html`
                      <div
                        class="snapshot-item ${this.selectedSnapshot === snapshot.id ? 'selected' : ''}"
                        @click=${() => { this.selectedSnapshot = snapshot.id; this.requestUpdate(); }}
                      >
                        <div class="snapshot-time">${snapshot.time}</div>
                        <div class="snapshot-id">ID: ${snapshot.id?.substring(0, 8)}... ${index === 0 ? '(latest)' : ''}</div>
                        ${snapshot.hostname ? html`<div class="snapshot-id">Host: ${snapshot.hostname}</div>` : ''}
                      </div>
                    `)}
                  </div>

                  <div class="btn-group">
                    <button
                      class="btn btn-primary"
                      @click=${() => this.handleRestore(this.selectedService, this.selectedSnapshot)}
                      ?disabled=${this.restoreServiceInProgress || this.restoreAllInProgress || !this.selectedSnapshot}
                    >
                      ${this.restoreServiceInProgress === this.selectedSnapshot ? html`
                        <span style="display: inline-block; width: 14px; height: 14px; border: 2px solid white; border-top-color: transparent; border-radius: 50%; animation: spin 1s linear infinite; margin-right: 6px; vertical-align: middle;"></span>
                        Restoring...
                      ` : 'Restore Snapshot'}
                    </button>
                  </div>
                `}
              </div>
            ` : ''}

            <div class="info-box" style="margin-top: 24px;">
              <strong>⚠️ Important Notes</strong>
              <div style="font-size: 14px; margin-top: 8px;">
                <ul style="margin: 8px 0 0 20px; padding: 0;">
                  <li>Restoring will stop the service and overwrite its current data</li>
                  <li>Database contents will be replaced with backup data</li>
                  <li>The service will be automatically restarted after restore</li>
                  <li>Consider creating a manual backup before restoring if needed</li>
                </ul>
              </div>
            </div>
          `}
        </config-section>
      </div>
    `;
  }

  render() {
    return html`
      <div class="module-container">
        <div class="tabs">
          <button
            class="tab ${this.activeTab === 'configuration' ? 'active' : ''}"
            @click=${() => this.handleTabChange('configuration')}
          >
            Configuration
          </button>
          <button
            class="tab ${this.activeTab === 'restore' ? 'active' : ''}"
            @click=${() => this.handleTabChange('restore')}
          >
            Restore
          </button>
        </div>

        ${this.activeTab === 'configuration' ? this.renderConfigurationTab() : this.renderRestoreTab()}
      </div>

      <progress-modal></progress-modal>
    `;
  }
}

customElements.define('backups-module', BackupsModule);
