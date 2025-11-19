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
    backupStatus: { type: Object },
    services: { type: Array },
    systemConfig: { type: Array },
    extraPaths: { type: Array },
    localServices: { type: Array },
    localSystemConfig: { type: Array },
    localExtraPaths: { type: Array },
    backblazeServices: { type: Array },
    backblazeSystemConfig: { type: Array },
    backblazeExtraPaths: { type: Array },
    repositoryPaths: { type: Object }, // Map of repository name to paths
    selectedService: { type: String },
    selectedSource: { type: String }, // 'local' or 'backblaze'
    selectedCategory: { type: String }, // 'service', 'system-config', or 'extra-path'
    snapshots: { type: Array },
    selectedSnapshot: { type: String },
    loading: { type: Boolean },
    restoreServiceInProgress: { type: String }, // Stores snapshot ID being restored: "latest", snapshot ID, or null
    restoreAllInProgress: { type: Boolean },
    triggerInProgress: { type: Boolean },
    syncInProgress: { type: Boolean }
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
    this.backupStatus = null;
    this.services = [];
    this.systemConfig = [];
    this.extraPaths = [];
    this.localServices = [];
    this.localSystemConfig = [];
    this.localExtraPaths = [];
    this.backblazeServices = [];
    this.backblazeSystemConfig = [];
    this.backblazeExtraPaths = [];
    this.repositoryPaths = {};
    this.selectedService = null;
    this.selectedSource = null;
    this.selectedCategory = null;
    this.snapshots = [];
    this.loading = false;
    this.restoreServiceInProgress = null; // Stores snapshot ID being restored: "latest", snapshot ID, or null
    this.restoreAllInProgress = false;
    this.triggerInProgress = false;
    this.syncInProgress = false;
    this.statusPollingInterval = null;
    this.abortController = null;
  }

  async connectedCallback() {
    super.connectedCallback();

    // CRITICAL: Stop polling before page unload to prevent connection limit race condition
    // disconnectedCallback fires too late (after new page starts loading)
    this.beforeUnloadHandler = () => {
      this.stopStatusPolling();
    };
    window.addEventListener('beforeunload', this.beforeUnloadHandler);

    await this.loadSecretsStatus();
    await this.loadBackupConfigStatus();
    await this.pollBackupStatus();

    // Start polling if operations are active
    if (this.backupStatus?.backup_running || this.backupStatus?.sync_running) {
      this.startStatusPolling();
    }
  }

  disconnectedCallback() {
    super.disconnectedCallback();

    // Remove beforeunload listener
    if (this.beforeUnloadHandler) {
      window.removeEventListener('beforeunload', this.beforeUnloadHandler);
    }

    this.stopStatusPolling();
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

  async pollBackupStatus() {
    try {
      const response = await fetch('/api/backups/status', {
        signal: this.abortController?.signal
      });
      if (response.ok) {
        this.backupStatus = await response.json();

        // Stop polling if no operations are active
        if (!this.backupStatus.backup_running && !this.backupStatus.sync_running) {
          this.stopStatusPolling();
        }
      }
    } catch (error) {
      // Ignore abort errors - these are expected when component disconnects
      if (error.name === 'AbortError') {
        return;
      }
      console.error('Error polling backup status:', error);
    }
  }

  startStatusPolling() {
    if (this.statusPollingInterval) {
      return; // Already polling
    }

    // Create new AbortController for this polling session
    this.abortController = new AbortController();

    // Poll every 3 seconds
    this.statusPollingInterval = setInterval(() => {
      this.pollBackupStatus();
    }, 3000);
  }

  stopStatusPolling() {
    // Abort any in-flight requests
    if (this.abortController) {
      this.abortController.abort();
      this.abortController = null;
    }

    // Clear the polling interval
    if (this.statusPollingInterval) {
      clearInterval(this.statusPollingInterval);
      this.statusPollingInterval = null;
    }
  }

  async loadServices() {
    this.loading = true;
    try {
      // Fetch from both local and Backblaze sources
      const [localResponse, backblazeResponse] = await Promise.all([
        fetch('/api/backups/services?source=local'),
        fetch('/api/backups/services?source=backblaze')
      ]);

      // Process local backups
      if (localResponse.ok) {
        const data = await localResponse.json();
        this.localServices = data.services || [];
        this.localSystemConfig = data.system_config || [];
        this.localExtraPaths = data.extra_paths || [];
      } else {
        this.localServices = [];
        this.localSystemConfig = [];
        this.localExtraPaths = [];
      }

      // Process Backblaze backups
      if (backblazeResponse.ok) {
        const data = await backblazeResponse.json();
        this.backblazeServices = data.services || [];
        this.backblazeSystemConfig = data.system_config || [];
        this.backblazeExtraPaths = data.extra_paths || [];
      } else {
        this.backblazeServices = [];
        this.backblazeSystemConfig = [];
        this.backblazeExtraPaths = [];
      }

      // For backward compatibility, keep services as union of both
      this.services = [...new Set([...this.localServices, ...this.backblazeServices])];
      this.systemConfig = [...new Set([...this.localSystemConfig, ...this.backblazeSystemConfig])];
      this.extraPaths = [...new Set([...this.localExtraPaths, ...this.backblazeExtraPaths])];

      // Load paths for all repositories from both sources
      const localRepos = [...this.localServices, ...this.localSystemConfig, ...this.localExtraPaths];
      const backblazeRepos = [...this.backblazeServices, ...this.backblazeSystemConfig, ...this.backblazeExtraPaths];

      await Promise.all([
        ...localRepos.map(repo => this.loadRepositoryPaths(repo, 'local')),
        ...backblazeRepos.map(repo => this.loadRepositoryPaths(repo, 'backblaze'))
      ]);
    } catch (error) {
      console.error('Error loading services:', error);
    } finally {
      this.loading = false;
    }
  }

  async loadRepositoryPaths(repo, source = 'auto') {
    try {
      const response = await fetch(`/api/backups/services/${encodeURIComponent(repo)}/paths?source=${source}`);
      if (response.ok) {
        const data = await response.json();
        // Store paths with source-prefixed key
        const key = `${source}:${repo}`;
        this.repositoryPaths = {
          ...this.repositoryPaths,
          [key]: data.paths || []
        };
        this.requestUpdate();
      }
    } catch (error) {
      console.error(`Error loading paths for ${repo} from ${source}:`, error);
    }
  }

  async loadSnapshots(service, source = 'local') {
    if (!service) return;

    this.loading = true;
    try {
      const response = await fetch(`/api/backups/services/${encodeURIComponent(service)}/snapshots?source=${source}`);
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

  async handleServiceChange(service, source = 'local') {
    this.selectedService = service;
    this.selectedSource = source;
    if (this.selectedService) {
      await this.loadSnapshots(this.selectedService, this.selectedSource);
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
      'Restoring Repository',
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
      console.error('Error restoring repository:', error);
      modal.updateStatus('error', `Error restoring ${service}`, [
        { message: error.message, type: 'error' }
      ]);
      this.showNotification(`Error restoring ${service}: ${error.message}`, 'error');
    } finally {
      this.restoreServiceInProgress = null;
    }
  }

  async handleRestoreAll() {
    const repoCount = this.services.length + this.systemConfig.length + this.extraPaths.length;
    const modal = this.renderRoot.querySelector('progress-modal');

    // Show confirmation modal
    modal.show(
      'Restore Entire System',
      `This will restore ALL ${repoCount} backup repositories from their latest snapshots, including services, databases, and system configuration.`,
      'confirm',
      {
        confirmText: 'Restore Entire System',
        cancelText: 'Cancel',
        confirmVariant: 'danger',
        details: [
          { message: 'This will overwrite all current data', type: 'warning' },
          { message: `${repoCount} repositories will be restored`, type: 'warning' },
          { message: 'This operation may take several minutes', type: 'warning' }
        ],
        confirmCallback: async () => {
          await this.performRestoreAll(repoCount);
        }
      }
    );
  }

  async performRestoreAll(serviceCount) {
    const modal = this.renderRoot.querySelector('progress-modal');

    this.restoreAllInProgress = true;

    // Show progress modal
    modal.show(
      'Restoring Entire System',
      `Restoring ${serviceCount} repositories...`,
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
        modal.updateStatus('success', `Successfully restored entire system (${serviceCount} repositories)!`);
        this.showNotification(`Successfully restored entire system (${serviceCount} repositories)!`, 'success');
        await this.loadServices(); // Refresh the list
      } else {
        const error = await response.json();
        modal.updateStatus('error', `Failed to restore entire system`, [
          { message: error.detail || 'Unknown error', type: 'error' }
        ]);
        this.showNotification(`Failed to restore entire system: ${error.detail || 'Unknown error'}`, 'error');
      }
    } catch (error) {
      console.error('Error restoring entire system:', error);
      modal.updateStatus('error', `Error restoring entire system`, [
        { message: error.message, type: 'error' }
      ]);
      this.showNotification(`Error restoring entire system: ${error.message}`, 'error');
    } finally {
      this.restoreAllInProgress = false;
    }
  }

  async handleTriggerBackups() {
    const modal = this.renderRoot.querySelector('progress-modal');

    // Show confirmation modal
    modal.show(
      'Trigger Backups',
      'This will immediately start backup jobs for all enabled services.',
      'confirm',
      {
        confirmText: 'Run Backup Now',
        cancelText: 'Cancel',
        confirmVariant: 'primary',
        details: [
          { message: 'All enabled backup services will be triggered', type: 'info' },
          { message: 'Backups will run in the background', type: 'info' }
        ],
        confirmCallback: async () => {
          await this.performTriggerBackups();
        }
      }
    );
  }

  async performTriggerBackups() {
    const modal = this.renderRoot.querySelector('progress-modal');

    this.triggerInProgress = true;

    // Show progress modal
    modal.show(
      'Triggering Backups',
      'Starting backup services...',
      'progress'
    );

    try {
      const response = await fetch('/api/backups/trigger', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' }
      });

      if (response.ok) {
        const result = await response.json();

        // Wait for backup to actually start (with timeout)
        // The API returns immediately now (async), but we need to wait for backup_running to become true
        modal.updateStatus('progress', 'Waiting for backups to start...');

        let backupStarted = false;
        const maxWaitTime = 3000; // 3 seconds max
        const pollInterval = 300; // Check every 300ms
        const maxAttempts = Math.floor(maxWaitTime / pollInterval);

        for (let attempt = 0; attempt < maxAttempts; attempt++) {
          await this.pollBackupStatus();

          if (this.backupStatus?.backup_running) {
            backupStarted = true;
            break;
          }

          // Wait before next poll
          await new Promise(resolve => setTimeout(resolve, pollInterval));
        }

        // Show success and start polling
        const count = result.output?.match(/(\d+) services/)?.[1] || 'backup';
        if (backupStarted) {
          modal.updateStatus('success', `Backups running for ${count} service${count !== '1' ? 's' : ''}`);
          this.showNotification(`Backups started for ${count} service${count !== '1' ? 's' : ''}`, 'success');
        } else {
          // Backup may start later, still show success
          modal.updateStatus('success', `Backup trigger sent for ${count} service${count !== '1' ? 's' : ''}`);
          this.showNotification(`Backup trigger sent for ${count} service${count !== '1' ? 's' : ''}`, 'success');
        }

        // Continue polling
        this.startStatusPolling();
      } else {
        const error = await response.json();
        modal.updateStatus('error', 'Failed to trigger backups', [
          { message: error.detail || 'Unknown error', type: 'error' }
        ]);
        this.showNotification(`Failed to trigger backups: ${error.detail || 'Unknown error'}`, 'error');
      }
    } catch (error) {
      console.error('Error triggering backups:', error);
      modal.updateStatus('error', 'Error triggering backups', [
        { message: error.message, type: 'error' }
      ]);
      this.showNotification(`Error triggering backups: ${error.message}`, 'error');
    } finally {
      this.triggerInProgress = false;
    }
  }

  async handleSyncBackblaze() {
    const modal = this.renderRoot.querySelector('progress-modal');

    // Show confirmation modal
    modal.show(
      'Sync to Backblaze',
      'This will sync all local backups to Backblaze B2 cloud storage.',
      'confirm',
      {
        confirmText: 'Sync to Backblaze',
        cancelText: 'Cancel',
        confirmVariant: 'primary',
        details: [
          { message: 'Local backups will be copied to Backblaze', type: 'info' },
          { message: 'This may take some time depending on data size', type: 'info' }
        ],
        confirmCallback: async () => {
          await this.performSyncBackblaze();
        }
      }
    );
  }

  async performSyncBackblaze() {
    const modal = this.renderRoot.querySelector('progress-modal');

    this.syncInProgress = true;

    // Show progress modal
    modal.show(
      'Syncing to Backblaze',
      'Syncing local backups to Backblaze...',
      'progress'
    );

    try {
      const response = await fetch('/api/backups/sync-backblaze', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' }
      });

      if (response.ok) {
        modal.updateStatus('success', 'Successfully triggered Backblaze sync');
        this.showNotification('Backblaze sync started', 'success');

        // Start polling for backup status
        await this.pollBackupStatus();
        this.startStatusPolling();
      } else {
        const error = await response.json();
        modal.updateStatus('error', 'Failed to trigger Backblaze sync', [
          { message: error.detail || 'Unknown error', type: 'error' }
        ]);
        this.showNotification(`Failed to sync to Backblaze: ${error.detail || 'Unknown error'}`, 'error');
      }
    } catch (error) {
      console.error('Error syncing to Backblaze:', error);
      modal.updateStatus('error', 'Error syncing to Backblaze', [
        { message: error.message, type: 'error' }
      ]);
      this.showNotification(`Error syncing to Backblaze: ${error.message}`, 'error');
    } finally {
      this.syncInProgress = false;
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

          <div style="margin-top: 16px; display: flex; gap: 12px; flex-wrap: wrap;">
            <button
              class="btn btn-primary"
              @click=${() => this.handleTriggerBackups()}
              ?disabled=${this.triggerInProgress || !this.secretsStatus?.['restic-password']}
            >
              ${this.triggerInProgress ? html`
                <span style="display: inline-block; width: 14px; height: 14px; border: 2px solid white; border-top-color: transparent; border-radius: 50%; animation: spin 1s linear infinite; margin-right: 6px; vertical-align: middle;"></span>
                Triggering Backups...
              ` : '▶️ Run Backup Now'}
            </button>

            ${backups.backblaze_enable ? html`
              <button
                class="btn btn-primary"
                @click=${() => this.handleSyncBackblaze()}
                ?disabled=${this.syncInProgress || !this.secretsStatus?.['restic-password']}
              >
                ${this.syncInProgress ? html`
                  <span style="display: inline-block; width: 14px; height: 14px; border: 2px solid white; border-top-color: transparent; border-radius: 50%; animation: spin 1s linear infinite; margin-right: 6px; vertical-align: middle;"></span>
                  Syncing...
                ` : '☁️ Sync to Backblaze'}
              </button>
            ` : ''}

            ${!this.secretsStatus?.['restic-password'] ? html`
              <p style="font-size: 13px; color: #666; margin-top: 8px; width: 100%;">
                ⚠️ Configure Restic password below before running backups
              </p>
            ` : ''}
          </div>

          <!-- Backup Status Display -->
          ${this.backupStatus?.backup_running || this.backupStatus?.sync_running ? html`
            <div style="margin-top: 16px; padding: 16px; background: #e3f2fd; border-left: 4px solid #2196f3; border-radius: 8px;">
              <div style="font-weight: 600; margin-bottom: 8px; color: #1565c0; display: flex; align-items: center; gap: 8px;">
                <span style="display: inline-block; width: 16px; height: 16px; border: 2px solid #2196f3; border-top-color: transparent; border-radius: 50%; animation: spin 1s linear infinite;"></span>
                Active Operations
              </div>

              ${this.backupStatus.backup_running ? html`
                <div style="margin-bottom: 12px;">
                  <div style="font-size: 14px; color: #1565c0; margin-bottom: 4px;">
                    <strong>Backing up:</strong>
                  </div>
                  <div style="display: flex; flex-wrap: wrap; gap: 6px;">
                    ${this.backupStatus.active_backups.map(service => html`
                      <span style="display: inline-block; padding: 4px 8px; background: #2196f3; color: white; border-radius: 4px; font-size: 12px;">
                        ${service}
                      </span>
                    `)}
                  </div>
                </div>
              ` : ''}

              ${this.backupStatus.sync_running ? html`
                <div style="font-size: 14px; color: #1565c0;">
                  ☁️ Syncing to Backblaze...
                </div>
              ` : ''}
            </div>
          ` : ''}
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
          description="Restore data from backup repositories"
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
                    <li>Backblaze B2 cloud backups (${this.services.length + this.systemConfig.length + this.extraPaths.length} repositories found)</li>
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
                <div style="font-size: 16px; margin-bottom: 8px;">Loading available repositories...</div>
                <div style="font-size: 14px;">Checking backup repositories</div>
              </div>
            ` : html`
              <!-- Restore All Button -->
              <div style="margin-bottom: 32px; padding: 20px; background: #fff3cd; border: 2px solid #ffc107; border-radius: 8px;">
                <div style="font-size: 16px; font-weight: 600; margin-bottom: 8px; color: #856404;">
                  🔄 Restore Entire System
                </div>
                <div style="font-size: 14px; color: #856404; margin-bottom: 12px;">
                  Restore all backup repositories from their latest snapshots. This includes ${this.services.length + this.systemConfig.length + this.extraPaths.length} repositories: services, databases, system configuration, and arbitrary paths. This is useful when setting up a new machine or performing disaster recovery.
                </div>
                <button
                  class="btn btn-danger"
                  @click=${() => this.handleRestoreAll()}
                  ?disabled=${this.restoreAllInProgress || this.restoreServiceInProgress || (this.services.length + this.systemConfig.length + this.extraPaths.length) === 0}
                >
                  ${this.restoreAllInProgress ? 'Restoring Entire System...' : 'Restore Entire System from Latest Backups'}
                </button>
              </div>

              <div style="margin-bottom: 32px;">
                <h3 style="font-size: 16px; font-weight: 600; margin-bottom: 16px;">
                  Or restore individual repositories:
                </h3>

                <!-- Services Section -->
                ${this.services.length > 0 ? html`
                  <div style="margin-bottom: 24px; padding: 16px; border: 1px solid #d1d1d6; border-radius: 8px;">
                    <h4 style="font-size: 15px; font-weight: 600; margin: 0 0 12px 0;">
                      📦 Services
                    </h4>
                    <p style="font-size: 13px; color: #666; margin: 0 0 12px 0;">
                      Service data, databases, and application configurations
                    </p>
                    <div style="display: grid; gap: 8px;">
                      ${this.localServices.map(service => html`
                        <button
                          class="btn btn-secondary"
                          style="text-align: left; padding: 12px; justify-content: flex-start;"
                          @click=${() => this.handleServiceChange(service, 'local')}
                          ?disabled=${this.loading || this.restoreServiceInProgress || this.restoreAllInProgress}
                        >
                          <div>
                            <div style="font-weight: 600;">${service} <span style="font-size: 11px; color: #666;">(Local)</span></div>
                            ${this.repositoryPaths[`local:${service}`] ? html`
                              <div style="font-size: 12px; color: #666; margin-top: 4px;">
                                ${this.repositoryPaths[`local:${service}`].slice(0, 2).join(', ')}${this.repositoryPaths[`local:${service}`].length > 2 ? ` +${this.repositoryPaths[`local:${service}`].length - 2} more` : ''}
                              </div>
                            ` : ''}
                          </div>
                        </button>
                      `)}
                      ${this.backblazeServices.map(service => html`
                        <button
                          class="btn btn-secondary"
                          style="text-align: left; padding: 12px; justify-content: flex-start;"
                          @click=${() => this.handleServiceChange(service, 'backblaze')}
                          ?disabled=${this.loading || this.restoreServiceInProgress || this.restoreAllInProgress}
                        >
                          <div>
                            <div style="font-weight: 600;">${service} <span style="font-size: 11px; color: #007bff;">☁️ Backblaze</span></div>
                            ${this.repositoryPaths[`backblaze:${service}`] ? html`
                              <div style="font-size: 12px; color: #666; margin-top: 4px;">
                                ${this.repositoryPaths[`backblaze:${service}`].slice(0, 2).join(', ')}${this.repositoryPaths[`backblaze:${service}`].length > 2 ? ` +${this.repositoryPaths[`backblaze:${service}`].length - 2} more` : ''}
                              </div>
                            ` : ''}
                          </div>
                        </button>
                      `)}
                    </div>
                  </div>
                ` : ''}

                <!-- System Configuration Section -->
                ${this.systemConfig.length > 0 ? html`
                  <div style="margin-bottom: 24px; padding: 16px; border: 2px solid #ff9500; border-radius: 8px; background: #fff9f0;">
                    <h4 style="font-size: 15px; font-weight: 600; margin: 0 0 8px 0; color: #856404;">
                      ⚙️ System Configuration
                    </h4>
                    <div style="padding: 8px 12px; background: #fff3cd; border-left: 3px solid #ffc107; margin-bottom: 12px;">
                      <strong>⚠️ Warning:</strong> Restoring system configuration will overwrite /etc/nixos. This may affect network settings, service configurations, and system behavior.
                    </div>
                    <div style="display: grid; gap: 8px;">
                      ${this.localSystemConfig.map(repo => html`
                        <button
                          class="btn btn-secondary"
                          style="text-align: left; padding: 12px; justify-content: flex-start;"
                          @click=${() => this.handleServiceChange(repo, 'local')}
                          ?disabled=${this.loading || this.restoreServiceInProgress || this.restoreAllInProgress}
                        >
                          <div>
                            <div style="font-weight: 600;">
                              /etc/nixos <span style="font-size: 11px; color: #666;">(Local)</span>
                            </div>
                            ${this.repositoryPaths[`local:${repo}`] ? html`
                              <div style="font-size: 12px; color: #666; margin-top: 4px;">
                                ${this.repositoryPaths[`local:${repo}`].length} files
                              </div>
                            ` : ''}
                          </div>
                        </button>
                      `)}
                      ${this.backblazeSystemConfig.map(repo => html`
                        <button
                          class="btn btn-secondary"
                          style="text-align: left; padding: 12px; justify-content: flex-start;"
                          @click=${() => this.handleServiceChange(repo, 'backblaze')}
                          ?disabled=${this.loading || this.restoreServiceInProgress || this.restoreAllInProgress}
                        >
                          <div>
                            <div style="font-weight: 600;">
                              /etc/nixos <span style="font-size: 11px; color: #007bff;">☁️ Backblaze</span>
                            </div>
                            ${this.repositoryPaths[`backblaze:${repo}`] ? html`
                              <div style="font-size: 12px; color: #666; margin-top: 4px;">
                                ${this.repositoryPaths[`backblaze:${repo}`].length} files
                              </div>
                            ` : ''}
                          </div>
                        </button>
                      `)}
                    </div>
                  </div>
                ` : ''}

                <!-- Extra Paths Section -->
                ${this.extraPaths.length > 0 ? html`
                  <div style="margin-bottom: 24px; padding: 16px; border: 1px solid #d1d1d6; border-radius: 8px;">
                    <h4 style="font-size: 15px; font-weight: 600; margin: 0 0 12px 0;">
                      📁 Extra Paths
                    </h4>
                    <p style="font-size: 13px; color: #666; margin: 0 0 12px 0;">
                      User-defined custom paths
                    </p>
                    <div style="display: grid; gap: 8px;">
                      ${this.localExtraPaths.map(repo => html`
                        <button
                          class="btn btn-secondary"
                          style="text-align: left; padding: 12px; justify-content: flex-start;"
                          @click=${() => this.handleServiceChange(repo, 'local')}
                          ?disabled=${this.loading || this.restoreServiceInProgress || this.restoreAllInProgress}
                        >
                          <div>
                            <div style="font-weight: 600;">${repo} <span style="font-size: 11px; color: #666;">(Local)</span></div>
                            ${this.repositoryPaths[`local:${repo}`] && this.repositoryPaths[`local:${repo}`].length > 0 ? html`
                              <div style="font-size: 12px; color: #666; margin-top: 4px;">
                                📂 ${this.repositoryPaths[`local:${repo}`][0]}
                              </div>
                            ` : ''}
                          </div>
                        </button>
                      `)}
                      ${this.backblazeExtraPaths.map(repo => html`
                        <button
                          class="btn btn-secondary"
                          style="text-align: left; padding: 12px; justify-content: flex-start;"
                          @click=${() => this.handleServiceChange(repo, 'backblaze')}
                          ?disabled=${this.loading || this.restoreServiceInProgress || this.restoreAllInProgress}
                        >
                          <div>
                            <div style="font-weight: 600;">${repo} <span style="font-size: 11px; color: #007bff;">☁️ Backblaze</span></div>
                            ${this.repositoryPaths[`backblaze:${repo}`] && this.repositoryPaths[`backblaze:${repo}`].length > 0 ? html`
                              <div style="font-size: 12px; color: #666; margin-top: 4px;">
                                📂 ${this.repositoryPaths[`backblaze:${repo}`][0]}
                              </div>
                            ` : ''}
                          </div>
                        </button>
                      `)}
                    </div>
                  </div>
                ` : ''}
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
                  <p style="color: #86868b;">No snapshots found for this repository.</p>
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
