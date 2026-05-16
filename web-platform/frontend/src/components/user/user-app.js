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
import { themeVars } from '../../shared/theme.js';
import {
  userMenuStyles,
  renderUserMenu,
} from '../../shared/user-menu.js';
import { shellStyles } from '../../shared/shell.js';

// Per-user dashboard at home.<domain>. Same app-shell shape as
// admin-app: left sidebar for intra-site nav, top-bar with the
// current page title on the left and the user-menu on the right.
// The user-menu carries cross-SITE links (Admin, Manual) plus
// Profile & password and Sign out.
//
// Hash routes: #/apps (default), #/profile.

const ROUTE_APPS = 'apps';
const ROUTE_PROFILE = 'profile';

function routeFromHash() {
  const h = (window.location.hash || '').replace(/^#\/?/, '').trim();
  if (h === ROUTE_PROFILE) return ROUTE_PROFILE;
  return ROUTE_APPS;
}

const MODULES = [
  { id: ROUTE_APPS,    title: 'Apps',    icon: '⊞', section: 'Home' },
  { id: ROUTE_PROFILE, title: 'Profile', icon: '👤', section: 'Account' },
];

class UserApp extends LitElement {
  static properties = {
    route: { type: String },
    user: { type: Object },
    services: { type: Array },
    policy: { type: Object },
    loading: { type: Boolean },
    error: { type: String },
    userMenuOpen: { type: Boolean, state: true },
    sidebarCollapsed: { type: Boolean, state: true },
    isMobile: { type: Boolean, state: true },
    profileSaving: { type: Boolean, state: true },
    profileMessage: { type: Object, state: true },
    passwordSaving: { type: Boolean, state: true },
    passwordMessage: { type: Object, state: true },
  };

  static styles = [themeVars, userMenuStyles, shellStyles, css`
    :host {
      display: block;
      width: 100%;
      /* 100dvh respects mobile browser chrome (Safari/Chrome bottom
         bars resize the viewport as you scroll). 100vh would leave
         the last row of content hidden behind the URL bar on small
         screens. Fallback to 100vh on browsers without dvh support
         — they get the old behavior, no regression. */
      height: 100vh;
      height: 100dvh;
    }
    *, *::before, *::after { box-sizing: border-box; }

    /* App launcher grid */
    .app-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(170px, 1fr));
      gap: 14px;
    }
    .app-tile {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border);
      border-radius: 12px;
      padding: 18px 18px 16px;
      transition: border-color 0.2s, transform 0.2s, background 0.2s;
      color: inherit;
      text-decoration: none;
      display: block;
    }
    .app-tile:hover {
      border-color: var(--hf-accent);
      background: var(--hf-surface-2);
      transform: translateY(-1px);
    }
    .app-tile-icon {
      width: 32px;
      height: 32px;
      border-radius: 8px;
      background: rgba(255, 255, 255, 0.06);
      display: grid;
      place-items: center;
      margin-bottom: 12px;
      color: var(--hf-text-muted);
      font-size: 13px;
      font-weight: 700;
      letter-spacing: -0.02em;
      overflow: hidden;
    }
    .app-tile-icon img {
      width: 70%;
      height: 70%;
      object-fit: contain;
      filter: invert(1) brightness(0.92);
    }
    .app-tile-name {
      font-weight: 600;
      font-size: 0.96rem;
      letter-spacing: -0.01em;
      margin: 0 0 2px;
      color: var(--hf-text);
    }
    .app-tile-sub {
      font-size: 0.78rem;
      color: var(--hf-text-subtle);
      margin: 0;
    }
    .empty {
      color: var(--hf-text-muted);
      font-size: 14px;
      padding: 24px 0;
    }

    /* Cards (Profile page) */
    .card {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border);
      border-radius: 12px;
      padding: 24px;
      max-width: 720px;
    }
    .card + .card { margin-top: 16px; }
    .card h3 {
      margin: 0 0 16px;
      font-size: 15px;
      font-weight: 600;
      color: var(--hf-text);
    }

    /* Forms */
    .form-row {
      display: grid;
      grid-template-columns: 160px 1fr;
      gap: 16px;
      align-items: center;
      margin-bottom: 14px;
    }
    @media (max-width: 560px) {
      .form-row { grid-template-columns: 1fr; gap: 6px; }
    }
    .form-row label {
      color: var(--hf-text-muted);
      font-size: 14px;
    }
    .form-row input {
      padding: 9px 12px;
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      font-size: 14px;
      font: inherit;
      width: 100%;
      max-width: 380px;
      background: var(--hf-bg);
      color: var(--hf-text);
    }
    .form-row input:focus {
      outline: none;
      border-color: var(--hf-accent);
      box-shadow: 0 0 0 3px var(--hf-focus-ring);
    }
    .form-row input:disabled {
      opacity: 0.55;
      cursor: not-allowed;
    }
    .actions {
      display: flex;
      gap: 12px;
      align-items: center;
      margin-top: 16px;
    }
    button.primary {
      background: var(--hf-accent);
      color: #0a0c0a;
      border: none;
      padding: 9px 18px;
      border-radius: 6px;
      font-weight: 600;
      cursor: pointer;
      font: inherit;
      transition: background 0.15s;
    }
    button.primary:hover { background: var(--hf-accent-hover); }
    button.primary:disabled { opacity: 0.5; cursor: not-allowed; }
    .msg { font-size: 13px; }
    .msg.ok  { color: var(--hf-ok); }
    .msg.err { color: var(--hf-err); }
    .req-list {
      list-style: none;
      padding: 0;
      margin: 8px 0 0 176px;
      font-size: 13px;
      color: var(--hf-text-muted);
    }
    @media (max-width: 560px) { .req-list { margin-left: 0; } }
    .req-list li::before {
      content: '○ '; color: var(--hf-text-subtle);
    }
    .req-list li.ok::before {
      content: '✓ '; color: var(--hf-ok);
    }

    /* Full-page states */
    .full-page {
      min-height: 60vh;
      display: flex;
      align-items: center;
      justify-content: center;
      flex-direction: column;
      gap: 12px;
      color: var(--hf-text-muted);
    }
    .spinner {
      width: 32px;
      height: 32px;
      border: 3px solid var(--hf-border-2);
      border-top-color: var(--hf-accent);
      border-radius: 50%;
      animation: spin 1s linear infinite;
    }
    @keyframes spin { to { transform: rotate(360deg); } }
  `];

  constructor() {
    super();
    this.route = routeFromHash();
    this.user = null;
    this.services = [];
    this.policy = DEFAULT_POLICY;
    this.loading = true;
    this.error = null;
    this.userMenuOpen = false;
    this.profileSaving = false;
    this.profileMessage = null;
    this.passwordSaving = false;
    this.passwordMessage = null;
    // Mobile breakpoint mirrors admin-app's behavior: the sidebar
    // starts collapsed on mobile (hidden overlay) and open on
    // desktop. matchMedia keeps the two in sync if the viewport
    // crosses the boundary mid-session.
    this._mobileMQ = window.matchMedia('(max-width: 768px)');
    this.isMobile = this._mobileMQ.matches;
    this.sidebarCollapsed = this.isMobile;
    this._mobileMQListener = (e) => {
      const wasMobile = this.isMobile;
      this.isMobile = e.matches;
      if (this.isMobile !== wasMobile) {
        this.sidebarCollapsed = this.isMobile;
      }
    };
    this._onHashChange = () => {
      this.route = routeFromHash();
      // Auto-close the overlay sidebar when nav-clicking on mobile.
      if (this.isMobile) this.sidebarCollapsed = true;
      // Reset transient form messages when navigating away.
      this.profileMessage = null;
      this.passwordMessage = null;
    };
  }

  connectedCallback() {
    super.connectedCallback();
    window.addEventListener('hashchange', this._onHashChange);
    this._mobileMQ.addEventListener('change', this._mobileMQListener);
    this._loadInitialData();
  }

  disconnectedCallback() {
    window.removeEventListener('hashchange', this._onHashChange);
    this._mobileMQ.removeEventListener('change', this._mobileMQListener);
    super.disconnectedCallback();
  }

  async _loadInitialData() {
    try {
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

  toggleSidebar() {
    this.sidebarCollapsed = !this.sidebarCollapsed;
  }

  toggleUserMenu() {
    this.userMenuOpen = !this.userMenuOpen;
    if (this.userMenuOpen) {
      const onDocClick = (e) => {
        const wrap = this.renderRoot?.querySelector('.user-menu-wrap');
        if (wrap && !wrap.contains(e.target)) {
          this.userMenuOpen = false;
          document.removeEventListener('click', onDocClick, true);
        }
      };
      setTimeout(() =>
        document.addEventListener('click', onDocClick, true), 0);
    }
  }

  _apexDomain() {
    return window.location.hostname.replace(/^home\./, '');
  }
  _adminUrl()  { return `${window.location.protocol}//admin.${this._apexDomain()}/`; }
  _manualUrl() { return `${window.location.protocol}//manual.${this._apexDomain()}/`; }

  _currentTitle() {
    return MODULES.find(m => m.id === this.route)?.title || 'Home';
  }

  render() {
    if (this.loading) {
      return html`
        <div class="full-page">
          <div class="spinner"></div>
          <p>Loading your dashboard…</p>
        </div>
      `;
    }
    if (this.error) {
      return html`
        <div class="full-page">
          <h2>Couldn't load dashboard</h2>
          <p>${this.error}</p>
          <p>
            <a href="#" @click=${handleSignOut}
               style="color: var(--hf-accent);">Sign out</a>
          </p>
        </div>
      `;
    }

    // Sections for the sidebar nav. We only have two items today
    // but section headers keep the layout aligned with admin's
    // structure so the eye trains the same way.
    const sections = {};
    for (const m of MODULES) {
      (sections[m.section] ||= []).push(m);
    }

    // Cross-site links live in the user-menu (right side of topbar).
    // Admin shows up only if the caller has the homefree-admin role.
    const crossSiteItems = [
      ...(this.user?.is_admin_role ? [
        { label: 'Admin', href: this._adminUrl() },
      ] : []),
      { label: 'Manual', href: this._manualUrl(), target: '_blank' },
    ];

    return html`
      <div class="app-container">
        <div class="sidebar ${this.sidebarCollapsed ? 'collapsed' : ''}">
          <div class="sidebar-header">
            <h1>HomeFree</h1>
            <button class="collapse-btn" @click=${() => this.toggleSidebar()}>
              ${this.sidebarCollapsed ? '→' : '←'}
            </button>
          </div>
          <nav class="nav-menu">
            ${Object.entries(sections).map(([sect, mods]) => html`
              <div class="nav-section-title">${sect}</div>
              ${mods.map(m => html`
                <a class="nav-item ${this.route === m.id ? 'active' : ''}"
                   href="#/${m.id}">
                  <span class="nav-item-icon">${m.icon}</span>
                  <span class="nav-item-text">${m.title}</span>
                </a>
              `)}
            `)}
          </nav>
        </div>
        <div class="sidebar-backdrop"
             @click=${() => this.toggleSidebar()}></div>

        <div class="main-content">
          <div class="top-bar">
            <div class="top-bar-title">
              <button class="hamburger-btn"
                      @click=${() => this.toggleSidebar()}
                      aria-label="Toggle navigation">☰</button>
              <h2>${this._currentTitle()}</h2>
            </div>
            <div class="top-bar-actions">
              ${renderUserMenu({
                currentUser: this.user,
                open: this.userMenuOpen,
                onToggle: () => this.toggleUserMenu(),
                profileUrl: '#/profile',
                extraItems: crossSiteItems,
              })}
            </div>
          </div>

          <div class="content-area">
            ${this.route === ROUTE_PROFILE
              ? this._renderProfileView()
              : this._renderAppsView()}
          </div>
        </div>
      </div>
    `;
  }

  _renderAppsView() {
    if (this.services.length === 0) {
      return html`<p class="empty">No apps are available yet.</p>`;
    }
    return html`
      <div class="app-grid">
        ${this.services.map(s => this._renderTile(s))}
      </div>
    `;
  }

  _renderTile(s) {
    const title = s.name || s.label || '?';
    const subtitle = s.project_name && s.project_name !== title
      ? s.project_name : '';
    const initials = title
      .split(/[\s\-_/]+/)
      .map(w => w.charAt(0))
      .join('')
      .slice(0, 2)
      .toUpperCase();
    return html`
      <a class="app-tile" href="${s.url}"
         target="_blank" rel="noopener">
        <div class="app-tile-icon">
          <img src="/icons/${s.label}.svg" alt=""
               @error=${this._onIconError}
               data-initials="${initials}">
        </div>
        <p class="app-tile-name">${title}</p>
        ${subtitle ? html`
          <p class="app-tile-sub">${subtitle}</p>
        ` : ''}
      </a>
    `;
  }

  _onIconError(e) {
    const img = e.currentTarget;
    const initials = img.getAttribute('data-initials') || '?';
    const parent = img.parentElement;
    if (parent) parent.textContent = initials;
  }

  _renderProfileView() {
    return html`
      ${this._renderProfileCard()}
      ${this._renderPasswordCard()}
    `;
  }

  _renderProfileCard() {
    const u = this.user || {};
    return html`
      <section class="card">
        <h3>Account</h3>
        <form @submit=${this._submitProfile}>
          <div class="form-row">
            <label for="username">Username</label>
            <input id="username" type="text"
                   value="${u.username || ''}" disabled>
          </div>
          <div class="form-row">
            <label for="first_name">First name</label>
            <input id="first_name" type="text"
                   .value="${u.first_name || ''}">
          </div>
          <div class="form-row">
            <label for="last_name">Last name</label>
            <input id="last_name" type="text"
                   .value="${u.last_name || ''}">
          </div>
          <div class="form-row">
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
      this.user = await getCurrentUser();
      this.profileMessage = { kind: 'ok', text: 'Saved.' };
    } catch (err) {
      this.profileMessage = { kind: 'err', text: err.message || 'Save failed.' };
    } finally {
      this.profileSaving = false;
    }
  }

  _renderPasswordCard() {
    const requirements = passwordRequirements(
      this._pendingNewPassword || '', this.policy);
    return html`
      <section class="card">
        <h3>Password</h3>
        <form @submit=${this._submitPassword}>
          <div class="form-row">
            <label for="cur_pw">Current password</label>
            <input id="cur_pw" type="password" autocomplete="current-password">
          </div>
          <div class="form-row">
            <label for="new_pw">New password</label>
            <input id="new_pw" type="password" autocomplete="new-password"
                   @input=${this._onNewPasswordInput}>
          </div>
          <div class="form-row">
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
      this.passwordMessage = { kind: 'err', text: 'Current and new password required.' };
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
      this.passwordMessage = { kind: 'err', text: err.message || 'Password change failed.' };
    } finally {
      this.passwordSaving = false;
    }
  }
}

customElements.define('user-app', UserApp);
