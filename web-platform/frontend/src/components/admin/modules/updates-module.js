import { LitElement, html, css } from 'lit';
import { checkSystemUpdates, applySystemUpdate } from '../../../api/client.js';

/**
 * System Updates module.
 *
 * Checks whether a newer commit of the `homefree-base` flake input (declared
 * in /etc/nixos/flake.nix, pinned in flake.lock) is available, and lets the
 * admin pull it in. Pulling it in only bumps flake.lock — the admin then
 * clicks "Apply Changes" in the sidebar to rebuild onto the new version.
 */
class UpdatesModule extends LitElement {
  static properties = {
    loading: { type: Boolean, state: true },
    applying: { type: Boolean, state: true },
    info: { type: Object, state: true },
    error: { type: String, state: true },
    updateDone: { type: Boolean, state: true },
  };

  static styles = css`
    :host { display: block; }

    .module-container { width: 100%; }

    .info-box {
      background: var(--hf-accent-soft);
      border-left: 4px solid var(--hf-accent);
      padding: 16px;
      border-radius: 8px;
      margin-bottom: 20px;
      color: var(--hf-accent);
    }
    .info-box strong { display: block; margin-bottom: 8px; }

    .notice {
      background: rgba(74,222,128,0.1);
      border: 1px solid rgba(74,222,128,0.35);
      color: #4ade80;
      padding: 14px 18px;
      border-radius: 8px;
      margin-bottom: 16px;
    }
    .notice strong { color: #4ade80; }

    .warn-box {
      background: rgba(250,204,21,0.1);
      border: 1px solid rgba(250,204,21,0.35);
      color: #facc15;
      padding: 14px 18px;
      border-radius: 8px;
      margin-bottom: 16px;
    }
    .warn-box strong { display: block; margin-bottom: 10px; color: #facc15; }
    .warn-box p { margin: 10px 0 4px; }
    .warn-box .ref {
      display: block;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 12px;
      word-break: break-all;
      margin-left: 14px;
    }
    .warn-box a.ref { color: #facc15; text-decoration: underline; }
    .warn-box a.ref:hover { color: #fde047; }

    .status-row {
      display: flex;
      align-items: center;
      gap: 12px;
      flex-wrap: wrap;
      padding: 14px 18px;
      background: var(--hf-surface);
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      margin-bottom: 12px;
    }
    .status-row .label { color: var(--hf-text-muted); font-size: 13px; }
    .status-row .value {
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      color: var(--hf-text);
      font-weight: 600;
    }
    .status-row .spacer { flex: 1; }

    .pill {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 4px 10px;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 600;
    }
    .pill.ok    { background: rgba(74,222,128,0.12); color: #4ade80; }
    .pill.warn  { background: rgba(250,204,21,0.12); color: #facc15; }
    .pill.error { background: rgba(248,113,113,0.12); color: #f87171; }

    .actions { margin-top: 16px; display: flex; gap: 12px; flex-wrap: wrap; }

    button.btn {
      padding: 8px 16px;
      background: var(--hf-surface);
      color: var(--hf-text);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      cursor: pointer;
      font-size: 14px;
    }
    button.btn:hover:not(:disabled) { background: var(--hf-surface-2); }
    button.btn:disabled { opacity: 0.5; cursor: wait; }
    button.btn.primary {
      background: var(--hf-accent);
      color: #06281c;
      border-color: var(--hf-accent);
      font-weight: 600;
    }
    /* Link styled as a button — for navigating to another admin
       module (e.g. Custom Flakes) at normal body size. */
    a.btn-link {
      display: inline-block;
      margin-top: 6px;
      padding: 8px 16px;
      background: var(--hf-surface);
      color: var(--hf-text);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      font-size: 14px;
      font-weight: 500;
      text-decoration: none;
      cursor: pointer;
    }
    a.btn-link:hover { background: var(--hf-surface-2); }
    button.btn.primary:hover:not(:disabled) { background: var(--hf-accent-hover); }

    .error {
      background: rgba(248,113,113,0.08);
      border: 1px solid rgba(248,113,113,0.3);
      color: #fca5a5;
      padding: 12px 16px;
      border-radius: 6px;
      margin-bottom: 16px;
    }

    .muted { color: var(--hf-text-muted); font-size: 13px; }
  `;

  constructor() {
    super();
    this.loading = true;
    this.applying = false;
    this.info = null;
    this.error = '';
    this.updateDone = false;
  }

  connectedCallback() {
    super.connectedCallback();
    // Auto-check for updates as soon as the page opens.
    this.checkUpdates();
  }

  async checkUpdates() {
    this.loading = true;
    this.error = '';
    this.updateDone = false;
    try {
      this.info = await checkSystemUpdates();
    } catch (e) {
      this.error = e.message || 'Failed to check for updates.';
      this.info = null;
    } finally {
      this.loading = false;
    }
  }

  async applyUpdate() {
    this.applying = true;
    this.error = '';
    try {
      const result = await applySystemUpdate();
      if (result.success) {
        this.updateDone = true;
        // Refresh so the displayed "current version" reflects the bump.
        this.info = await checkSystemUpdates();
        // Nudge the shell to re-check dirty state so the sidebar Apply
        // button enables immediately instead of on the next 5s poll.
        this.dispatchEvent(new CustomEvent('updates-applied', {
          bubbles: true, composed: true,
        }));
      } else {
        this.error = result.message || 'Failed to update the system version.';
      }
    } catch (e) {
      this.error = e.message || 'Failed to update the system version.';
    } finally {
      this.applying = false;
    }
  }

  _formatDate(iso) {
    if (!iso) return '';
    try {
      return new Date(iso).toLocaleString();
    } catch {
      return iso;
    }
  }

  _renderStatus() {
    const info = this.info;

    if (!info.applicable) {
      return html`
        <div class="info-box">
          <strong>Updates are managed from your local source tree</strong>
          This is a development install — it builds from a local checkout
          rather than a tracked release branch, so there is nothing to check
          for here.
        </div>
      `;
    }

    const busy = this.loading || this.applying;

    return html`
      ${info.baseOverrideActive ? html`
        <div class="warn-box">
          <strong>⚠️ Warning: using an alternate HomeFree repository</strong>
          <p>An alternate HomeFree repository is activated:</p>
          <span class="ref">${info.baseOverrideUrl || 'unknown'}</span>
          <p>Updates here won't apply unless the official repository is
            re-enabled:</p>
          <a class="btn-link" href="#/developers">Custom Flakes</a>
        </div>
      ` : ''}

      ${this.updateDone ? html`
        <div class="notice">
          <strong>System version updated</strong>
          Click <strong>Apply Changes</strong> in the sidebar to rebuild your
          system onto the new version.
        </div>
      ` : ''}

      <div class="status-row">
        <span class="label">Current version</span>
        <span class="value">${info.current_short || 'unknown'}</span>
        ${info.current_date
          ? html`<span class="muted">pinned ${this._formatDate(info.current_date)}</span>`
          : ''}
        <span class="spacer"></span>
        ${this._renderPill()}
      </div>

      ${info.available && !this.updateDone ? html`
        <div class="status-row">
          <span class="label">Latest available</span>
          <span class="value">${info.latest_short}</span>
          <span class="muted">on branch ${info.ref}</span>
        </div>
      ` : ''}

      ${info.error
        ? html`<div class="error">${info.error}</div>`
        : ''}

      <div class="actions">
        <button
          class="btn"
          @click=${this.checkUpdates}
          ?disabled=${busy}
        >${this.loading ? 'Checking…' : 'Check again'}</button>

        ${info.available && !this.updateDone ? html`
          <button
            class="btn primary"
            @click=${this.applyUpdate}
            ?disabled=${busy}
          >${this.applying ? 'Updating…' : 'Update to latest'}</button>
        ` : ''}
      </div>
    `;
  }

  _renderPill() {
    const info = this.info;
    if (info.error) {
      return html`<span class="pill error">Check failed</span>`;
    }
    if (info.available) {
      return html`<span class="pill warn">Update available</span>`;
    }
    return html`<span class="pill ok">Up to date</span>`;
  }

  render() {
    return html`
      <div class="module-container">
        <div class="info-box">
          <strong>Updates</strong>
          HomeFree checks the release branch it tracks for newer commits.
          Pulling an update in only changes the pinned version — click
          <strong>Apply Changes</strong> afterwards to rebuild the system.
        </div>

        ${this.error ? html`<div class="error">${this.error}</div>` : ''}

        ${this.loading && !this.info
          ? html`<p class="muted">Checking for updates…</p>`
          : this.info
            ? this._renderStatus()
            : html`<p class="muted">No update information available.</p>`}
      </div>
    `;
  }
}

customElements.define('updates-module', UpdatesModule);
