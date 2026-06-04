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
    .ms-name {
      display: block; margin-top: 16px;
    }
    .ms-name > span:first-child {
      display: block; font-size: 13px; font-weight: 500;
      color: var(--hf-text); margin-bottom: 6px;
    }
    .ms-name input {
      width: 100%; max-width: 320px; box-sizing: border-box;
      padding: 9px 12px; font-size: 13px;
      background: var(--hf-bg); color: var(--hf-text);
      border: 1px solid var(--hf-border-2); border-radius: 6px;
      font-family: inherit;
    }
    .ms-name input:focus {
      outline: none; border-color: var(--hf-accent);
      box-shadow: 0 0 0 3px var(--hf-focus-ring);
    }
    .ms-name .hint { display: block; margin-top: 6px; }
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

  _handleMediaServerName(e) {
    const name = (e.target.value || '').trim();
    const storage = { ...(this.config?.storage || {}) };
    storage['media-server'] = { ...(storage['media-server'] || {}), 'friendly-name': name };
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { config: { storage }, module: 'shared-folders' },
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
    const msName = this.config?.storage?.['media-server']?.['friendly-name'] || '';
    const columns = [
      { key: 'name', label: 'Name', type: 'text', placeholder: 'media' },
      { key: 'path', label: 'Path', type: 'path', placeholder: '/mnt/tank/media', rootPath: '/mnt' },
      // NFS protocol
      { key: 'enabled', label: 'NFS', type: 'boolean', default: true },
      { key: 'allowed', label: 'NFS allowed clients', type: 'tags',
        default: defAllowed, placeholder: 'e.g. 10.0.0.0/24, 10.0.0.42' },
      { key: 'read-only', label: 'NFS read-only', type: 'boolean', default: false },
      { key: 'squash', label: 'NFS squash', type: 'select',
        options: [
          { value: 'root', label: 'root (default)' },
          { value: 'none', label: 'none (trust client root)' },
          { value: 'all',  label: 'all (map every UID)' },
        ],
        default: 'root' },
      { key: 'anon-uid', label: 'NFS anon UID', type: 'number',
        default: null, placeholder: 'e.g. 1000' },
      { key: 'anon-gid', label: 'NFS anon GID', type: 'number',
        default: null, placeholder: 'e.g. 100' },
      // Media server (DLNA / minidlna)
      { key: 'media', label: 'Media server', type: 'boolean', default: false },
      { key: 'media-type', label: 'Media type', type: 'select',
        options: [
          { value: 'all',      label: 'All (audio + video + photos)' },
          { value: 'audio',    label: 'Audio only' },
          { value: 'video',    label: 'Video only' },
          { value: 'pictures', label: 'Photos only' },
        ],
        default: 'all' },
    ];
    return html`
      <div class="module-container">
        <config-section title="Shared Folders"
          description="A folder on this box exposed to your LAN — over NFS, the DLNA Media Server, or both">
          <table-editor
            .columns=${columns}
            .data=${shares}
            .appliedData=${applied}
            .rowKey=${'name'}
            addLabel="Add shared folder"
            .neutralBooleans=${true}
            @data-change=${this._handleSharesChange}
          ></table-editor>
          <div class="hint" style="margin-top:8px">
            <strong>NFS</strong> uses host/subnet trust (no per-user login) —
            clients matching any listed CIDR or IP may mount the folder. New
            folders default to your LAN subnet (<code>${defAllowed}</code>);
            remove that chip and add individual IPs to lock one down. SMB and
            per-user access are a later phase.
          </div>
          <div class="hint" style="margin-top:8px">
            <strong>Media server (DLNA)</strong>: ticking this exposes the folder
            to TVs and AV receivers on your LAN via DLNA/UPnP — the role a
            Synology "Media Server" played. DLNA has <strong>no login</strong>:
            any device on the LAN can browse and play the folder's contents. It
            is never reachable from the internet. The folder must be readable by
            the media-server account. Use <em>Media type</em> to keep, say, a
            music folder out of the TV's video menu.
          </div>
          <label class="ms-name">
            <span>Media server name</span>
            <input type="text" .value=${msName}
              placeholder=${lan === '<server-ip>' ? 'e.g. Living Room NAS' : (this.config?.system?.hostName || 'homefree')}
              @change=${this._handleMediaServerName} />
            <span class="hint">Name shown to TVs and receivers. Blank uses the box hostname.</span>
          </label>
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
