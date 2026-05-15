import { LitElement, html, css } from 'lit';
import '../../shared/config-section.js';
import '../../shared/table-editor.js';

/**
 * Mounts configuration module
 * Handles: NFS/network filesystem mounts (e.g. NAS shares used by media
 * services and as backup destinations).
 */
class MountsModule extends LitElement {
  static properties = {
    config: { type: Object },
    modified: { type: Boolean }
  };

  static styles = css`
    :host {
      display: block;
    }

    .module-container {
      width: 100%;
    }

    .help-box {
      background: rgba(59, 130, 246, 0.08);
      border-left: 4px solid var(--hf-accent);
      padding: 14px 18px;
      border-radius: 8px;
      margin-bottom: 20px;
      color: var(--hf-text-muted);
      font-size: 13px;
      line-height: 1.5;
    }

    .help-box strong {
      display: block;
      margin-bottom: 6px;
      color: var(--hf-text);
      font-size: 14px;
    }

    .help-box code {
      background: var(--hf-surface-2);
      padding: 1px 5px;
      border-radius: 3px;
      font-family: var(--hf-font-mono, monospace);
      font-size: 12px;
    }
  `;

  constructor() {
    super();
    this.config = { mounts: [] };
    this.modified = false;
  }

  handleMountsChange(e) {
    const newConfig = { ...this.config, mounts: e.detail.data };
    this.config = newConfig;
    this.modified = true;

    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { config: newConfig },
      bubbles: true,
      composed: true
    }));
  }

  render() {
    const mounts = this.config.mounts || [];

    // Column definitions for the mount table. The underlying
    // <table-editor> only supports `text` and `boolean` field types;
    // free-form text with a clear placeholder is fine for fs-type and
    // nfs-version (the schema validates the enum on the Nix side).
    const columns = [
      { key: 'mount-point', label: 'Mount Point', type: 'text', placeholder: '/mnt/ellis' },
      { key: 'device', label: 'Device', type: 'text', placeholder: '10.0.0.42:/volume1/ellis' },
      { key: 'fs-type', label: 'FS Type', type: 'text', placeholder: 'nfs' },
      { key: 'nfs-version', label: 'NFS Version', type: 'text', placeholder: '3' },
      { key: 'automount', label: 'Automount', type: 'boolean' },
      { key: 'idle-timeout', label: 'Idle Timeout (s)', type: 'text', placeholder: '600' }
    ];

    return html`
      <div class="module-container">
        <div class="help-box">
          <strong>Network mounts</strong>
          Configure network filesystems (e.g. an NFS share from a NAS)
          that should be available on this host. Mounts are typically
          used as media stores for services like Jellyfin or Frigate, or
          as a destination for backups. With <strong>Automount</strong>
          on, the share is mounted on first access and unmounted after
          <code>idle-timeout</code> seconds of inactivity. For NFS, the
          device is in the form <code>&lt;host&gt;:&lt;export&gt;</code>.
        </div>

        <config-section
          title="Filesystem Mounts"
          description="Each entry produces a fileSystems.<mount-point> declaration"
        >
          <table-editor
            .columns=${columns}
            .data=${mounts}
            addLabel="Add Mount"
            @data-change=${this.handleMountsChange}
          ></table-editor>
        </config-section>
      </div>
    `;
  }
}

customElements.define('mounts-module', MountsModule);
