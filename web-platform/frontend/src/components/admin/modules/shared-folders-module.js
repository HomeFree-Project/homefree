import { LitElement, html, css } from 'lit';
import '../../shared/config-section.js';
import '../../shared/table-editor.js';

/**
 * Shared Folders module
 *
 * Lifts the NFS shares editor out of storage-module so that share exports
 * (data this box serves OUT to the LAN) live on their own page, distinct
 * from Storage (data attached to / consumed by this box). SMB support
 * lands on this same page in a later phase.
 *
 * Backing config path: homefree.storage.shares (unchanged). admin-app's
 * pathOwnerModuleId routes that subpath to this module so the nav-dot
 * shows here when a share has an undeployed edit.
 */
class SharedFoldersModule extends LitElement {
  static properties = {
    config: { type: Object },
    appliedConfig: { attribute: false },
  };

  static styles = css`
    :host { display: block; }
    .module-container { width: 100%; }
    code {
      background: var(--hf-surface-2);
      padding: 1px 5px; border-radius: 3px;
      font-family: var(--hf-font-mono, monospace); font-size: 12px;
    }
    .hint { color: var(--hf-text-muted); font-size: 12px; line-height: 1.5; }
    .mount-cmds {
      margin-top: 14px; padding: 12px 14px;
      background: var(--hf-surface-2); border-radius: 8px;
    }
    .mount-cmds-head {
      font-size: 12px; color: var(--hf-text-muted); margin-bottom: 8px;
    }
    .mount-cmd-row {
      display: flex; flex-wrap: wrap; gap: 10px; align-items: baseline;
      font-size: 13px; margin-top: 4px;
    }
    .mc-name { font-weight: 600; color: var(--hf-text); min-width: 100px; }
    .mc-target {
      font-family: var(--hf-font-mono, monospace); font-size: 12px;
      color: var(--hf-text); word-break: break-all;
    }
  `;

  constructor() {
    super();
    this.config = {};
    this.appliedConfig = null;
  }

  _defaultAllowedClients() {
    return this.config?.network?.['lan-subnet'] || '10.0.0.0/24';
  }

  _handleSharesChange(e) {
    // Strip any synthetic `id` the table-editor may have stamped — the deployed
    // applied-config has no id on pre-existing rows, so leaving an id would
    // make every share read as both changed and removed in the diff. Mirrors
    // the same strip in storage-module's old handler.
    const rows = (e.detail.data || []).map(({ id, ...r }) => r);
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: {
        config: { storage: { ...(this.config?.storage || {}), shares: rows } },
        module: 'shared-folders',
      },
      bubbles: true,
      composed: true,
    }));
  }

  render() {
    const shares = this.config?.storage?.shares || [];
    const applied = this.appliedConfig?.storage?.shares || [];
    const lan = this.config?.network?.['lan-address'] || '<server-ip>';
    const mountable = shares.filter((s) => s.enabled !== false && s.path);
    const defAllowed = this._defaultAllowedClients();
    const columns = [
      { key: 'enabled', label: 'Enabled', type: 'boolean', default: true },
      { key: 'name', label: 'Name', type: 'text', placeholder: 'media' },
      { key: 'path', label: 'Path', type: 'path', placeholder: '/mnt/tank/media', rootPath: '/mnt' },
      { key: 'allowed', label: 'Allowed clients', type: 'tags',
        default: defAllowed, placeholder: 'e.g. 10.0.0.0/24, 10.0.0.42' },
      { key: 'read-only', label: 'Read-only', type: 'boolean', default: false },
    ];
    return html`
      <div class="module-container">
        <config-section title="NFS Shares"
          description="Export a volume (or a folder within one) over NFS to your LAN">
          <table-editor
            .columns=${columns}
            .data=${shares}
            .appliedData=${applied}
            .rowKey=${'name'}
            addLabel="Add NFS share"
            .neutralBooleans=${true}
            @data-change=${this._handleSharesChange}
          ></table-editor>
          <div class="hint" style="margin-top:8px">
            NFS uses host/subnet trust (no per-user login) — clients matching any
            listed CIDR or IP may mount the share. New shares default to your
            LAN subnet (<code>${defAllowed}</code>); remove that chip and add
            individual IPs to lock a share down. SMB and per-user access are a
            later phase.
          </div>
          ${mountable.length ? html`
            <div class="mount-cmds">
              <div class="mount-cmds-head">Mount from a LAN client — use the full export path, not the share name:</div>
              ${mountable.map((s) => html`
                <div class="mount-cmd-row">
                  <span class="mc-name">${s.name}</span>
                  <code class="mc-target">${lan}:${s.path}</code>
                </div>`)}
              <div class="hint" style="margin-top:8px">
                e.g. <code class="mc-target">sudo mount -t nfs ${lan}:${mountable[0].path} /mnt/${mountable[0].name}</code>
              </div>
            </div>` : ''}
        </config-section>
      </div>
    `;
  }
}

customElements.define('shared-folders-module', SharedFoldersModule);
