import { LitElement, html, css } from 'lit';
import { getMode } from './api/client.js';
import './components/installer-app.js';
import './components/admin/admin-app.js';

class HomeFreeApp extends LitElement {
  static properties = {
    mode: { type: String },
    loading: { type: Boolean },
    error: { type: String }
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
  }

  async connectedCallback() {
    super.connectedCallback();
    await this.detectMode();
  }

  async detectMode() {
    // Retry logic to handle transient NetworkErrors during page refresh
    // when old page's cleanup races with new page's first request
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
}

customElements.define('homefree-app', HomeFreeApp);

// Mount the app after custom elements are defined
customElements.whenDefined('homefree-app').then(() => {
  const app = document.getElementById('app');
  app.innerHTML = '<homefree-app></homefree-app>';
});
