import { LitElement, html, css } from 'lit';
import { getMode } from './api/client.js';
import { handleSignOut } from './shared/auth.js';
import './components/installer-app.js';
import './components/admin/admin-app.js';
import './components/user/user-app.js';

// Per-user dashboard lives at home.<domain>. The same index.html is
// served from both admin.<domain> and home.<domain> (one frontend
// bundle, two vhosts in services/admin-web.nix) — so the dispatch
// has to happen at runtime. Hostname is the canonical signal: it's
// what Caddy gates on, what oauth2-proxy whitelisted, and what the
// backend's per-path auth rules already align with.
//
// Substring match instead of strict prefix because the same SPA is
// also served from homefree.<localDomain> in dev (admin) and
// home.homefree.<localDomain> in dev (user). The `home.` prefix is
// unambiguous in both shapes.
const IS_USER_SURFACE = window.location.hostname.startsWith('home.');

class HomeFreeApp extends LitElement {
  static properties = {
    mode: { type: String },
    loading: { type: Boolean },
    error: { type: String },
    // Set when the backend returns 401/403 — distinct from a generic
    // "can't reach backend" failure so the UI can show a tailored
    // page (signed in as X, but admin UI requires Y) instead of the
    // misleading "Connection Error".
    accessDenied: { type: Object },
  };

  static styles = css`
    :host {
      display: block;
      width: 100%;
      height: 100%;
    }

    .loading {
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      color: white;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    }

    .loading-content {
      text-align: center;
    }

    .spinner {
      border: 4px solid rgba(255, 255, 255, 0.3);
      border-top: 4px solid white;
      border-radius: 50%;
      width: 40px;
      height: 40px;
      animation: spin 1s linear infinite;
      margin: 0 auto 20px;
    }

    @keyframes spin {
      0% { transform: rotate(0deg); }
      100% { transform: rotate(360deg); }
    }

    .error {
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      color: white;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      padding: 20px;
    }

    .error-content {
      text-align: center;
      max-width: 500px;
      background: rgba(255, 255, 255, 0.1);
      padding: 40px;
      border-radius: 12px;
      backdrop-filter: blur(10px);
    }

    .error-icon {
      font-size: 48px;
      margin-bottom: 20px;
    }

    h2 {
      margin: 0 0 16px 0;
    }

    p {
      margin: 8px 0;
      opacity: 0.9;
    }
  `;

  constructor() {
    super();
    this.mode = null;
    this.loading = true;
    this.error = null;
    this.accessDenied = null;
  }

  async connectedCallback() {
    super.connectedCallback();
    // On home.<domain> the SPA shows the per-user dashboard
    // regardless of installer/admin mode. The backend's
    // /api/users/me + /api/services/visible-to-me power that view
    // and are gated by oauth2-proxy at the Caddy layer + the
    // SELF_SERVICE_PATHS allowlist in the middleware. No mode
    // detection needed.
    if (IS_USER_SURFACE) {
      this.mode = 'user';
      this.loading = false;
      return;
    }
    await this.detectMode();
  }

  async detectMode() {
    // Retry logic to handle transient NetworkErrors during page refresh
    // when old page's cleanup races with new page's first request.
    // Auth failures (401/403) are NOT transient — short-circuit those
    // immediately so the user doesn't sit through 3x retries before
    // seeing the access-denied page.
    let retries = 3;
    let lastError = null;

    while (retries > 0) {
      try {
        const result = await getMode();
        this.mode = result.mode; // 'installer' or 'admin'
        this.loading = false;
        return;
      } catch (error) {
        lastError = error;

        if (error.status === 401 || error.status === 403) {
          this.accessDenied = {
            status: error.status,
            ...(error.body || {}),
          };
          this.loading = false;
          return;
        }

        retries--;
        if (retries > 0) {
          // Wait 500ms before retry to allow old page cleanup to complete
          await new Promise(resolve => setTimeout(resolve, 500));
        }
      }
    }

    // All retries exhausted
    console.error('Failed to detect mode after retries:', lastError);
    this.error = `Failed to connect to backend: ${lastError.message}`;
    this.loading = false;
  }

  render() {
    if (this.loading) {
      return html`
        <div class="loading">
          <div class="loading-content">
            <div class="spinner"></div>
            <h2>Loading HomeFree...</h2>
            <p>Detecting mode...</p>
          </div>
        </div>
      `;
    }

    if (this.accessDenied) {
      return this._renderAccessDenied();
    }

    if (this.error) {
      return html`
        <div class="error">
          <div class="error-content">
            <div class="error-icon">⚠️</div>
            <h2>Connection Error</h2>
            <p>${this.error}</p>
            <p style="margin-top: 20px;">
              <small>Please ensure the backend service is running.</small>
            </p>
          </div>
        </div>
      `;
    }

    // Route to appropriate app based on mode
    if (this.mode === 'installer') {
      return html`<installer-app></installer-app>`;
    } else if (this.mode === 'admin') {
      return html`<admin-app></admin-app>`;
    } else if (this.mode === 'user') {
      return html`<user-app></user-app>`;
    }

    return html`
      <div class="error">
        <div class="error-content">
          <div class="error-icon">⚠️</div>
          <h2>Unknown Mode</h2>
          <p>Detected mode: ${this.mode}</p>
        </div>
      </div>
    `;
  }

  _renderAccessDenied() {
    const d = this.accessDenied;
    const isUnauth = d.status === 401;
    const currentUser = d.current_user;
    const adminUser = d.admin_user;

    // Differentiate the two cases:
    //   401 = no auth header at all (oauth2-proxy didn't gate this
    //         request, or you're hitting the backend directly).
    //   403 = signed in but not the configured HomeFree admin.
    const title = isUnauth ? 'Sign-in required' : 'Access denied';
    const icon = isUnauth ? '🔒' : '🚫';

    return html`
      <div class="error">
        <div class="error-content">
          <div class="error-icon">${icon}</div>
          <h2>${title}</h2>
          ${isUnauth ? html`
            <p>You're not signed in. Try refreshing the page.</p>
          ` : html`
            ${currentUser && adminUser ? html`
              <p>
                You're signed in as <strong>${currentUser}</strong>,
                but the HomeFree admin UI is only accessible to
                <strong>${adminUser}</strong>.
              </p>
              <p style="margin-top: 16px; opacity: 0.8;">
                <small>
                  Sign out and back in as the admin user, or ask
                  ${adminUser} to grant you access.
                </small>
              </p>
            ` : html`
              <p>${d.detail || 'You do not have permission to view this page.'}</p>
            `}
          `}
          <p style="margin-top: 24px;">
            <a href="#" @click=${handleSignOut} style="color: white;">
              Sign out
            </a>
          </p>
        </div>
      </div>
    `;
  }
}

customElements.define('homefree-app', HomeFreeApp);

// Mount the app after custom elements are defined
customElements.whenDefined('homefree-app').then(() => {
  const app = document.getElementById('app');
  app.innerHTML = '<homefree-app></homefree-app>';
});
// Force rebuild $(date)
