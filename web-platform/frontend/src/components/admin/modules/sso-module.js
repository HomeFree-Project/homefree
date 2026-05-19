import { LitElement, html, css } from 'lit';
import '../../shared/config-section.js';
import { getSsoState, reprovisionSso } from '../../../api/client.js';

/**
 * SSO admin module.
 *
 * Two things live here:
 *   1. Bootstrap status. Reads /api/sso/state which checks
 *      /var/lib/homefree-secrets/.sso-provisioned (the global sentinel
 *      created by zitadel-provision.service after a successful run)
 *      and the per-service .provisioned sentinels.
 *   2. Per-service opt-out toggles bound to
 *      config.sso["per-service"].<label>.enable in the homefree-config.json.
 *
 * The toggle state goes through the standard `config-change` event
 * pattern that the rest of the admin modules use, so a click flips
 * pending state immediately and "Apply" rebuilds the system with the
 * new value. (The Caddy oauth2 gate consults a file matcher at request
 * time, so flipping a toggle off doesn't strictly need a rebuild for
 * the gate to relax — but the Nix-evaluated services list needs the
 * rebuild to fully match.)
 */
class SsoModule extends LitElement {
  static properties = {
    config: { type: Object },
    state: { type: Object, state: true },
    loading: { type: Boolean, state: true },
    reprovisioning: { type: Boolean, state: true },
    error: { type: String, state: true },
  };

  static styles = css`
    :host { display: block; }

    .module-container { width: 100%; }

    /* Unified notification box — grey-tinted bg, colored left edge,
       colored heading, normal body text. */
    .info-box {
      background: rgba(59, 130, 246, 0.08);
      border-left: 4px solid var(--hf-accent);
      padding: 14px 18px;
      border-radius: 8px;
      margin-bottom: 20px;
      color: var(--hf-text-muted);
      font-size: 13px;
      line-height: 1.5;
    }

    .info-box strong {
      display: block;
      margin-bottom: 8px;
      color: var(--hf-text);
    }

    .status-row {
      display: flex;
      align-items: center;
      gap: 12px;
      padding: 14px 18px;
      background: var(--hf-surface);
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      margin-bottom: 12px;
    }

    .pill {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 4px 10px;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 600;
    }
    .pill.ok       { background: rgba(74,222,128,0.12); color: #4ade80; }
    .pill.warn     { background: rgba(250,204,21,0.12); color: #facc15; }
    .pill.error    { background: rgba(248,113,113,0.12); color: #f87171; }
    .pill.disabled { background: var(--hf-surface-2);    color: var(--hf-text-muted); }

    table.services {
      width: 100%;
      border-collapse: collapse;
      margin-top: 10px;
    }

    table.services th, table.services td {
      padding: 10px 12px;
      text-align: left;
      font-size: 14px;
      border-bottom: 1px solid var(--hf-border-2);
    }

    table.services th {
      font-weight: 600;
      color: var(--hf-text-muted);
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }

    table.services tr:last-child td { border-bottom: none; }

    .svc-label {
      font-weight: 500;
      color: var(--hf-text);
    }

    .toggle {
      width: 36px;
      height: 20px;
      background: var(--hf-surface-2);
      border-radius: 999px;
      position: relative;
      cursor: pointer;
      transition: background 0.15s;
      border: 1px solid var(--hf-border-2);
    }
    .toggle.on { background: var(--hf-accent); }
    .toggle::after {
      content: '';
      position: absolute;
      top: 2px;
      left: 2px;
      width: 14px;
      height: 14px;
      background: white;
      border-radius: 50%;
      transition: left 0.15s;
    }
    .toggle.on::after { left: 18px; }

    .actions { margin-top: 16px; display: flex; gap: 12px; }

    button.btn {
      padding: 8px 16px;
      background: var(--hf-surface);
      color: var(--hf-text);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      cursor: pointer;
      font-size: 14px;
    }
    button.btn:hover { background: var(--hf-surface-2); }
    button.btn:disabled { opacity: 0.5; cursor: wait; }

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
    this.config = null;
    this.state = null;
    this.loading = true;
    this.reprovisioning = false;
    this.error = '';
  }

  async connectedCallback() {
    super.connectedCallback();
    await this.refresh();
  }

  async refresh() {
    this.loading = true;
    this.error = '';
    try {
      this.state = await getSsoState();
    } catch (e) {
      this.error = `Failed to load SSO state: ${e.message || e}`;
      this.state = null;
    } finally {
      this.loading = false;
    }
  }

  async handleReprovision() {
    this.reprovisioning = true;
    this.error = '';
    try {
      await reprovisionSso();
      // Give the oneshot a moment, then refresh state to pick up new
      // sentinels. The unit's normal exit takes a few seconds.
      await new Promise(r => setTimeout(r, 3000));
      await this.refresh();
    } catch (e) {
      this.error = `Reprovision failed: ${e.message || e}`;
    } finally {
      this.reprovisioning = false;
    }
  }

  _toggleService(label, currentEnabled) {
    // Mirror system-module's handleFieldChange: build a new config
    // object with the toggle flipped, then dispatch config-change.
    // The parent admin-app merges this into pendingConfig.
    const next = JSON.parse(JSON.stringify(this.config || {}));
    if (!next.sso) next.sso = {};
    if (!next.sso['per-service']) next.sso['per-service'] = {};
    if (!next.sso['per-service'][label]) {
      next.sso['per-service'][label] = { enable: true };
    }
    next.sso['per-service'][label].enable = !currentEnabled;

    this.config = next;
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { module: 'sso', config: next },
      bubbles: true,
      composed: true,
    }));
  }

  _isEnabled(label) {
    const cfg = this.config?.sso?.['per-service']?.[label];
    if (cfg && typeof cfg.enable === 'boolean') return cfg.enable;
    return true;   // matches the Nix default
  }

  _allowRegistration() {
    return this.config?.sso?.allowUserRegistration === true;
  }

  _toggleAllowRegistration() {
    const next = JSON.parse(JSON.stringify(this.config || {}));
    if (!next.sso) next.sso = {};
    next.sso.allowUserRegistration = !this._allowRegistration();
    this.config = next;
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { module: 'sso', config: next },
      bubbles: true,
      composed: true,
    }));
  }

  render() {
    if (this.loading && !this.state) {
      return html`<div class="muted">Loading SSO state…</div>`;
    }

    if (this.error && !this.state) {
      return html`<div class="error">${this.error}</div>`;
    }

    const s = this.state || { provisioned: false, services: [] };

    return html`
      <div class="module-container">
        <div class="info-box">
          <strong>Single Sign-On</strong>
          HomeFree provisions a Zitadel OIDC application for each
          integrated service on first boot. Once that completes,
          authenticated logins flow through your Zitadel admin
          account — no per-service username/password forms.
        </div>

        ${this.error ? html`<div class="error">${this.error}</div>` : ''}

        <config-section
          title="Sign-in options"
          description="Knobs that change what appears on the Zitadel sign-in page."
        >
          <div class="status-row" style="justify-content: space-between;">
            <div>
              <div style="font-weight: 500; color: var(--hf-text);">
                Allow user self-registration
              </div>
              <div class="muted" style="margin-top: 4px; max-width: 560px;">
                When off, the sign-in page hides the "Register" link
                so only admins can create accounts. New users still
                need to be granted access to individual services
                after registration — turning this on does not, by
                itself, give registrants access to anything.
              </div>
            </div>
            <div
              class="toggle ${this._allowRegistration() ? 'on' : ''}"
              @click=${this._toggleAllowRegistration}
              title="Toggle sign-up link visibility"
            ></div>
          </div>
        </config-section>

        <config-section title="Bootstrap status">
          <div class="status-row">
            ${s.provisioned
              ? html`<span class="pill ok">● Provisioned</span>`
              : html`<span class="pill warn">● Not yet provisioned</span>`}
            <span class="muted">
              ${s.provisioned
                ? 'zitadel-provision.service completed at least once. /var/lib/homefree-secrets/.sso-provisioned exists.'
                : 'Run zitadel-provision (or wait for it on first boot) to create the OIDC apps.'}
            </span>
          </div>

          <div class="actions">
            <button
              class="btn"
              @click=${this.refresh}
              ?disabled=${this.loading}
            >${this.loading ? 'Refreshing…' : 'Refresh'}</button>
            <button
              class="btn"
              @click=${this.handleReprovision}
              ?disabled=${this.reprovisioning}
              title="Re-run zitadel-provision.service. Idempotent — safe to retry."
            >${this.reprovisioning ? 'Reprovisioning…' : 'Re-run provisioning'}</button>
          </div>
        </config-section>

        <div class="muted" style="font-size: 12px; margin-top: 8px;">
          Per-service SSO status is shown inline on the Services page.
        </div>
      </div>
    `;
  }
}

customElements.define('sso-module', SsoModule);
