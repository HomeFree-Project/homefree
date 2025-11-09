import { LitElement, html, css } from 'lit';
import '../../shared/config-section.js';
import '../../shared/form-field.js';

/**
 * Backups configuration module
 * Handles: Local backups and Backblaze B2 cloud backups
 */
class BackupsModule extends LitElement {
  static properties = {
    config: { type: Object },
    modified: { type: Boolean }
  };

  static styles = css`
    :host {
      display: block;
    }

    .module-container {
      max-width: 800px;
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
    }

    .info-box strong {
      display: block;
      margin-bottom: 8px;
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

  render() {
    const { backups } = this.config;

    return html`
      <div class="module-container">
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

          ${backups.enable ? html`
            <form-field
              label="Backup Directory"
              type="text"
              .value=${backups.to_path}
              placeholder="/mnt/backup"
              help="Path to local backup storage (e.g., external drive mount point)"
              required
              @field-change=${(e) => this.handleFieldChange('backups.to_path', e.detail.value)}
            ></form-field>

            <div class="info-box">
              <strong>ℹ️ Backup Information</strong>
              <div style="font-size: 14px;">
                HomeFree uses Restic for encrypted, deduplicated backups. Backups run automatically at 2 AM daily and include all enabled service data.
              </div>
            </div>
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

          ${backups.backblaze_enable ? html`
            <form-field
              label="Backblaze Bucket Name"
              type="text"
              .value=${backups.backblaze_bucket}
              placeholder="my-homefree-backups"
              help="B2 bucket name for storing backups"
              required
              @field-change=${(e) => this.handleFieldChange('backups.backblaze_bucket', e.detail.value)}
            ></form-field>

            <div class="info-box">
              <strong>ℹ️ Backblaze Configuration</strong>
              <div style="font-size: 14px; margin-top: 8px;">
                To use Backblaze B2:
                <ul style="margin: 8px 0 0 20px; padding: 0;">
                  <li>Create a B2 account at backblaze.com</li>
                  <li>Create a bucket for your backups</li>
                  <li>Generate application keys with read/write access</li>
                  <li>Store credentials in your secrets configuration</li>
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
      </div>
    `;
  }
}

customElements.define('backups-module', BackupsModule);
