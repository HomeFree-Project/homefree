import { LitElement, html, css } from 'lit';
import {
  getCurrentUser,
  updateOwnProfile,
  changeOwnPassword,
  getVisibleServices,
} from '../../api/client.js';
import {
  loadPasswordPolicy,
  passwordRequirements,
  validatePassword,
  DEFAULT_POLICY,
} from '../../shared/password-policy.js';
import { handleSignOut } from '../../shared/auth.js';

// Per-user dashboard. Lives at home.<domain>. Three sections:
//   1. App launcher grid — services the user can actually open.
//   2. Profile — first/last name, email (read-only-ish: backend
//      applies the change to Zitadel).
//   3. Password change — same validation as the admin Users page.
// Plus a sticky top bar with the user's name, manual link, admin
// link (only when is_admin_role), and sign-out.

class UserApp extends LitElement {
  static properties = {
    user: { type: Object },
    services: { type: Array },
    policy: { type: Object },
    loading: { type: Boolean },
    error: { type: String },
    // Per-section editing state. Kept on the host so each form can
    // surface its own toast without cross-talk.
    profileSaving: { type: Boolean, state: true },
    profileMessage: { type: Object, state: true }, // {kind, text}
    passwordSaving: { type: Boolean, state: true },
    passwordMessage: { type: Object, state: true },
  };

  static styles = css`
    :host {
      display: block;
      min-height: 100vh;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI',
        Roboto, sans-serif;
      background: #f5f5f7;
      color: #1d1d1f;

      --hf-accent: #6366f1;
      --hf-accent-hover: #5558e0;
      --hf-border: #e5e5ea;
      --hf-text-muted: #6e6e73;
      --hf-ok: #10b981;
      --hf-err: #ef4444;
      --hf-shadow: 0 1px 3px rgba(0, 0, 0, 0.06);
      --hf-shadow-lg: 0 8px 24px rgba(0, 0, 0, 0.08);
    }

    /* Top bar */
    .topbar {
      position: sticky;
      top: 0;
      z-index: 10;
      background: white;
      border-bottom: 1px solid var(--hf-border);
      padding: 14px 24px;
      display: flex;
      align-items: center;
      gap: 20px;
    }
    .brand {
      font-weight: 600;
      font-size: 18px;
    }
    .topbar-spacer { flex: 1; }
    .topbar a, .topbar button.linklike {
      color: #1d1d1f;
      text-decoration: none;
      font-size: 14px;
      padding: 6px 10px;
      border-radius: 6px;
      background: transparent;
      border: none;
      cursor: pointer;
      font: inherit;
    }
    .topbar a:hover, .topbar button.linklike:hover {
      background: #f0f0f3;
    }
    .topbar .user {
      color: var(--hf-text-muted);
      font-size: 13px;
    }

    /* Layout */
    main {
      max-width: 1100px;
      margin: 0 auto;
      padding: 32px 24px 80px;
      display: grid;
      gap: 24px;
    }
    h1 {
      margin: 8px 0 16px;
      font-size: 28px;
      font-weight: 600;
    }
    h2 {
      margin: 0 0 12px;
      font-size: 17px;
      font-weight: 600;
    }

    .card {
      background: white;
      border-radius: 12px;
      padding: 24px;
      box-shadow: var(--hf-shadow);
    }

    /* App grid */
    .app-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(140px, 1fr));
      gap: 16px;
      margin-top: 8px;
    }
    .app-tile {
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 12px;
      padding: 20px 12px;
      background: white;
      border: 1px solid var(--hf-border);
      border-radius: 10px;
      color: inherit;
      text-decoration: none;
      transition: transform 120ms ease, box-shadow 120ms ease,
                  border-color 120ms ease;
      text-align: center;
    }
    .app-tile:hover {
      transform: translateY(-2px);
      box-shadow: var(--hf-shadow-lg);
      border-color: var(--hf-accent);
    }
    .app-icon {
      width: 48px;
      height: 48px;
      display: flex;
      align-items: center;
      justify-content: center;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      color: white;
      font-weight: 600;
      font-size: 20px;
      border-radius: 12px;
      overflow: hidden;
    }
    .app-icon img {
      width: 100%;
      height: 100%;
      object-fit: contain;
      background: white;
    }
    .app-name {
      font-size: 13px;
      font-weight: 500;
      word-break: break-word;
    }
    .empty {
      color: var(--hf-text-muted);
      font-size: 14px;
      padding: 16px 0;
    }

    /* Forms */
    .row {
      display: grid;
      grid-template-columns: 140px 1fr;
      gap: 12px;
      align-items: center;
      margin-bottom: 12px;
    }
    .row label {
      color: var(--hf-text-muted);
      font-size: 14px;
    }
    .row input {
      padding: 8px 10px;
      border: 1px solid var(--hf-border);
      border-radius: 6px;
      font-size: 14px;
      font: inherit;
      width: 100%;
      max-width: 360px;
    }
    .row input:focus {
      outline: none;
      border-color: var(--hf-accent);
      box-shadow: 0 0 0 3px rgba(99, 102, 241, 0.18);
    }
    .actions {
      display: flex;
      gap: 12px;
      align-items: center;
      margin-top: 8px;
    }
    button.primary {
      background: var(--hf-accent);
      color: white;
      border: none;
      padding: 8px 16px;
      border-radius: 6px;
      font-weight: 500;
      cursor: pointer;
      font: inherit;
    }
    button.primary:hover { background: var(--hf-accent-hover); }
    button.primary:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }

    .msg {
      font-size: 13px;
      padding: 6px 10px;
      border-radius: 4px;
    }
    .msg.ok  { color: var(--hf-ok); }
    .msg.err { color: var(--hf-err); }

    /* Password requirements */
    .req-list {
      list-style: none;
      padding: 0;
      margin: 8px 0 0;
      font-size: 13px;
      color: var(--hf-text-muted);
    }
    .req-list li::before {
      content: '○ ';
      color: var(--hf-text-muted);
    }
    .req-list li.ok::before {
      content: '✓ ';
      color: var(--hf-ok);
    }

    /* Loading + error */
    .loading-page, .error-page {
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      background: linear-gradient(135deg, #667eea, #764ba2);
      color: white;
    }
    .spinner {
      width: 40px;
      height: 40px;
      border: 4px solid rgba(255,255,255,0.3);
      border-top-color: white;
      border-radius: 50%;
      animation: spin 1s linear infinite;
      margin: 0 auto 16px;
    }
    @keyframes spin { to { transform: rotate(360deg); } }
  `;

  constructor() {
    super();
    this.user = null;
    this.services = [];
    this.policy = DEFAULT_POLICY;
    this.loading = true;
    this.error = null;
    this.profileSaving = false;
    this.profileMessage = null;
    this.passwordSaving = false;
    this.passwordMessage = null;
  }

  async connectedCallback() {
    super.connectedCallback();
    try {
      // Three independent fetches; let them race. The password
      // policy is allowed to fall back to DEFAULT_POLICY so we
      // don't need to await it before rendering — but the user
      // record is required for the profile form to prefill.
      const [user, services, policy] = await Promise.all([
        getCurrentUser(),
        getVisibleServices().catch(() => []),
        loadPasswordPolicy().catch(() => DEFAULT_POLICY),
      ]);
      this.user = user;
      this.services = services || [];
      this.policy = policy || DEFAULT_POLICY;
    } catch (e) {
      this.error = e.message || String(e);
    } finally {
      this.loading = false;
    }
  }

  render() {
    if (this.loading) {
      return html`
        <div class="loading-page">
          <div>
            <div class="spinner"></div>
            <p>Loading your dashboard…</p>
          </div>
        </div>
      `;
    }
    if (this.error) {
      return html`
        <div class="error-page">
          <div style="text-align:center; padding: 24px;">
            <h2>Couldn't load dashboard</h2>
            <p>${this.error}</p>
            <p style="margin-top: 16px;">
              <a href="#" @click=${handleSignOut} style="color: white;">
                Sign out
              </a>
            </p>
          </div>
        </div>
      `;
    }

    const u = this.user || {};
    const greeting = u.display_name || u.first_name || u.username || 'there';
    return html`
      <header class="topbar">
        <div class="brand">HomeFree</div>
        <span class="topbar-spacer"></span>
        <a href="https://manual.${location.hostname.replace(/^home\./, '')}/"
           target="_blank" rel="noopener">Manual</a>
        ${u.is_admin_role ? html`
          <a href="https://admin.${location.hostname.replace(/^home\./, '')}/">
            Admin
          </a>
        ` : ''}
        <span class="user">${u.username || ''}</span>
        <button class="linklike" @click=${handleSignOut}>Sign out</button>
      </header>

      <main>
        <h1>Welcome, ${greeting}.</h1>

        <section class="card">
          <h2>Your apps</h2>
          ${this.services.length === 0 ? html`
            <p class="empty">No apps are available yet.</p>
          ` : html`
            <div class="app-grid">
              ${this.services.map(s => this._renderTile(s))}
            </div>
          `}
        </section>

        ${this._renderProfileCard()}
        ${this._renderPasswordCard()}
      </main>
    `;
  }

  _renderTile(s) {
    // Two-letter initials fallback for missing icons. Take the
    // first letter of each whitespace-separated chunk of the
    // display name; cap at two so single-word names still produce
    // one big letter.
    const initials = (s.name || s.label || '?')
      .split(/[\s\-_/]+/)
      .map(w => w.charAt(0))
      .join('')
      .slice(0, 2)
      .toUpperCase();
    return html`
      <a class="app-tile" href="${s.url}" target="_blank" rel="noopener">
        <div class="app-icon">
          ${s.icon
            ? html`<img src="/icons/${s.label}.svg" alt="">`
            : initials}
        </div>
        <div class="app-name">${s.name}</div>
      </a>
    `;
  }

  _renderProfileCard() {
    const u = this.user || {};
    return html`
      <section class="card">
        <h2>Profile</h2>
        <form @submit=${this._submitProfile}>
          <div class="row">
            <label for="username">Username</label>
            <input id="username" type="text"
                   value="${u.username || ''}" disabled>
          </div>
          <div class="row">
            <label for="first_name">First name</label>
            <input id="first_name" type="text"
                   .value="${u.first_name || ''}">
          </div>
          <div class="row">
            <label for="last_name">Last name</label>
            <input id="last_name" type="text"
                   .value="${u.last_name || ''}">
          </div>
          <div class="row">
            <label for="email">Email</label>
            <input id="email" type="email"
                   .value="${u.email || ''}">
          </div>
          <div class="actions">
            <button class="primary" type="submit"
                    ?disabled=${this.profileSaving}>
              ${this.profileSaving ? 'Saving…' : 'Save profile'}
            </button>
            ${this.profileMessage ? html`
              <span class="msg ${this.profileMessage.kind}">
                ${this.profileMessage.text}
              </span>
            ` : ''}
          </div>
        </form>
      </section>
    `;
  }

  async _submitProfile(e) {
    e.preventDefault();
    const root = this.renderRoot;
    const first = root.querySelector('#first_name').value.trim();
    const last  = root.querySelector('#last_name').value.trim();
    const email = root.querySelector('#email').value.trim();

    // Only send changed fields. Avoids round-tripping a "blank
    // email" PUT that would 400 in Zitadel's validator if the
    // user never had one set.
    const patch = {};
    if (first !== (this.user.first_name || '')) patch.first_name = first;
    if (last  !== (this.user.last_name  || '')) patch.last_name  = last;
    if (email !== (this.user.email      || '')) patch.email      = email;

    if (Object.keys(patch).length === 0) {
      this.profileMessage = { kind: 'ok', text: 'No changes to save.' };
      return;
    }

    this.profileSaving = true;
    this.profileMessage = null;
    try {
      await updateOwnProfile(patch);
      // Refresh local copy from server so display name + similar
      // derived fields reflect the new values.
      this.user = await getCurrentUser();
      this.profileMessage = { kind: 'ok', text: 'Saved.' };
    } catch (err) {
      this.profileMessage = {
        kind: 'err',
        text: err.message || 'Save failed.',
      };
    } finally {
      this.profileSaving = false;
    }
  }

  _renderPasswordCard() {
    const requirements = passwordRequirements(
      this._pendingNewPassword || '', this.policy);
    return html`
      <section class="card">
        <h2>Change password</h2>
        <form @submit=${this._submitPassword}>
          <div class="row">
            <label for="cur_pw">Current password</label>
            <input id="cur_pw" type="password" autocomplete="current-password">
          </div>
          <div class="row">
            <label for="new_pw">New password</label>
            <input id="new_pw" type="password" autocomplete="new-password"
                   @input=${this._onNewPasswordInput}>
          </div>
          <div class="row">
            <label for="new_pw2">Confirm</label>
            <input id="new_pw2" type="password" autocomplete="new-password">
          </div>
          <ul class="req-list">
            ${requirements.map(r => html`
              <li class="${r.satisfied ? 'ok' : ''}">${r.label}</li>
            `)}
          </ul>
          <div class="actions">
            <button class="primary" type="submit"
                    ?disabled=${this.passwordSaving}>
              ${this.passwordSaving ? 'Saving…' : 'Change password'}
            </button>
            ${this.passwordMessage ? html`
              <span class="msg ${this.passwordMessage.kind}">
                ${this.passwordMessage.text}
              </span>
            ` : ''}
          </div>
        </form>
      </section>
    `;
  }

  _onNewPasswordInput(e) {
    this._pendingNewPassword = e.target.value;
    this.requestUpdate();
  }

  async _submitPassword(e) {
    e.preventDefault();
    const root = this.renderRoot;
    const cur = root.querySelector('#cur_pw').value;
    const np  = root.querySelector('#new_pw').value;
    const np2 = root.querySelector('#new_pw2').value;

    if (!cur || !np) {
      this.passwordMessage = {
        kind: 'err',
        text: 'Current and new password required.',
      };
      return;
    }
    if (np !== np2) {
      this.passwordMessage = { kind: 'err', text: 'New passwords do not match.' };
      return;
    }
    const v = validatePassword(np, this.policy);
    if (!v.ok) {
      this.passwordMessage = { kind: 'err', text: v.error };
      return;
    }

    this.passwordSaving = true;
    this.passwordMessage = null;
    try {
      await changeOwnPassword(cur, np);
      this.passwordMessage = { kind: 'ok', text: 'Password updated.' };
      root.querySelector('#cur_pw').value = '';
      root.querySelector('#new_pw').value = '';
      root.querySelector('#new_pw2').value = '';
      this._pendingNewPassword = '';
      this.requestUpdate();
    } catch (err) {
      this.passwordMessage = {
        kind: 'err',
        text: err.message || 'Password change failed.',
      };
    } finally {
      this.passwordSaving = false;
    }
  }
}

customElements.define('user-app', UserApp);
