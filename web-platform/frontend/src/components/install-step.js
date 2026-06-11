import { LitElement, html, css } from 'lit';
import { startInstallation, pollInstallStatus } from '../api/client.js';

class InstallStep extends LitElement {
  static properties = {
    data: { type: Object },
    progress: { type: Number },
    currentStep: { type: String },
    message: { type: String },
    completed: { type: Boolean },
    error: { type: String },
    logs: { type: Array },
    recoveryPassphrase: { type: String },
  };

  static styles = css`
    :host {
      display: block;
    }

    .install-container {
      max-width: 800px;
      margin: 0 auto;
    }

    h2 {
      font-size: 28px;
      color: #333;
      margin-bottom: 24px;
    }

    .progress-section {
      margin-bottom: 32px;
    }

    .progress-bar {
      width: 100%;
      height: 24px;
      background: #e0e0e0;
      border-radius: 12px;
      overflow: hidden;
      margin-bottom: 12px;
    }

    .progress-fill {
      height: 100%;
      background: linear-gradient(90deg, #667eea 0%, #764ba2 100%);
      transition: width 0.5s ease;
      display: flex;
      align-items: center;
      justify-content: center;
      color: white;
      font-weight: 500;
      font-size: 14px;
    }

    .current-step {
      font-size: 18px;
      color: #333;
      font-weight: 500;
      margin-bottom: 8px;
    }

    .message {
      color: #666;
      font-size: 14px;
    }

    .logs-section {
      margin-top: 32px;
    }

    .logs-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 12px;
    }

    .logs-container {
      background: #1e1e1e;
      color: #d4d4d4;
      padding: 16px;
      border-radius: 6px;
      font-family: 'Courier New', monospace;
      font-size: 13px;
      max-height: 400px;
      overflow-y: auto;
      line-height: 1.5;
    }

    .log-line {
      margin-bottom: 4px;
      white-space: pre-wrap;
      word-break: break-word;
    }

    .log-line.error {
      color: #f48771;
    }

    .log-line.success {
      color: #89d185;
    }

    .log-line.info {
      color: #569cd6;
    }

    .spinner {
      display: inline-block;
      width: 20px;
      height: 20px;
      border: 3px solid rgba(102, 126, 234, 0.3);
      border-top-color: #667eea;
      border-radius: 50%;
      animation: spin 1s linear infinite;
      margin-right: 12px;
      vertical-align: middle;
    }

    @keyframes spin {
      to { transform: rotate(360deg); }
    }

    .success-message {
      background: #d4edda;
      border: 1px solid #c3e6cb;
      color: #155724;
      padding: 16px;
      border-radius: 6px;
      margin-top: 24px;
    }

    .error-message {
      background: #f8d7da;
      border: 1px solid #f5c6cb;
      color: #721c24;
      padding: 16px;
      border-radius: 6px;
      margin-top: 24px;
    }

    .recovery-box {
      background: #fff3cd;
      border: 1px solid #ffc107;
      color: #856404;
      padding: 16px;
      border-radius: 6px;
      margin-top: 16px;
    }
    .recovery-box p { margin: 8px 0; font-size: 14px; }
    .recovery-code {
      display: block;
      margin-top: 8px;
      padding: 12px;
      background: #fff;
      border: 1px dashed #856404;
      border-radius: 4px;
      font-family: monospace;
      font-size: 16px;
      font-weight: bold;
      letter-spacing: 1px;
      color: #333;
      user-select: all;
      word-break: break-all;
    }
  `;

  constructor() {
    super();
    this.progress = 0;
    this.currentStep = 'Starting installation...';
    this.message = '';
    this.completed = false;
    this.error = '';
    this.logs = [];
    this.recoveryPassphrase = '';
    this.stopPolling = null;
    this.followTail = true;
    this.errorDetailShown = false;
  }

  willUpdate(changedProperties) {
    // Decide BEFORE the new log lines render whether the user was
    // reading the tail; only then does the panel follow the new
    // bottom, so scrolling up to inspect earlier lines sticks.
    if (changedProperties.has('logs')) {
      const c = this.shadowRoot && this.shadowRoot.querySelector('.logs-container');
      this.followTail = !c || (c.scrollHeight - c.scrollTop - c.clientHeight) < 48;
    }
  }

  updated(changedProperties) {
    if (changedProperties.has('logs') && this.followTail) {
      const c = this.shadowRoot.querySelector('.logs-container');
      if (c) {
        c.scrollTop = c.scrollHeight;
      }
    }
  }

  async connectedCallback() {
    super.connectedCallback();
    await this.startInstallation();
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this.stopPolling) {
      this.stopPolling();
    }
  }

  async startInstallation() {
    try {
      const result = await startInstallation();

      if (result.success) {
        this.pollProgress();
      } else {
        this.error = result.message || 'Failed to start installation';
      }
    } catch (err) {
      this.error = 'Failed to start installation: ' + err.message;
    }
  }

  pollProgress() {
    this.stopPolling = pollInstallStatus((status) => {
      this.progress = status.progress || 0;
      this.currentStep = status.step || 'Starting installation...';
      this.message = status.message || '';
      this.completed = status.completed || false;
      this.error = status.error || '';
      // Surfaced once disk encryption secrets are generated.
      if (status.recovery_passphrase) {
        this.recoveryPassphrase = status.recovery_passphrase;
      }

      // Add log if message changed. Cap the list so a long install
      // (30 min @ 1s polling) doesn't grow an unbounded array that the
      // log container re-renders in full on every tick.
      if (status.message && !this.logs.find(l => l.message === status.message)) {
        const entry = {
          type: status.error ? 'error' : 'info',
          message: status.message,
          timestamp: new Date().toISOString(),
        };
        this.logs = [...this.logs, entry].slice(-200);
      }

      // On failure the backend captures the tail of the failing
      // command's output (disko / nixos-install); append it to the log
      // panel so the actual cause is visible without shelling in and
      // reading the backend journal.
      if (status.error_detail && !this.errorDetailShown) {
        this.errorDetailShown = true;
        const now = new Date().toISOString();
        const detailLines = status.error_detail
          .split('\n')
          .filter(line => line.trim() !== '')
          .map(line => ({ type: 'error', raw: true, message: line, timestamp: now }));
        this.logs = [
          ...this.logs,
          { type: 'info', message: '--- output of the failing step ---', timestamp: now },
          ...detailLines,
        ].slice(-200);
      }

      if (this.completed || this.error) {
        if (this.stopPolling) {
          this.stopPolling();
        }
        if (this.completed) {
          this.dispatchEvent(new CustomEvent('installation-complete', {
            bubbles: true,
            composed: true
          }));
        }
      }
    }, 1000);
  }

  render() {
    return html`
      <div class="install-container">
        <h2>
          ${!this.completed ? html`
            <span class="spinner"></span>
          ` : ''}
          Installing HomeFree
        </h2>

        <div class="progress-section">
          <div class="progress-bar">
            <div class="progress-fill" style="width: ${this.progress}%">
              ${this.progress > 10 ? `${Math.round(this.progress)}%` : ''}
            </div>
          </div>
          <div class="current-step">${this.currentStep}</div>
          ${this.message ? html`
            <div class="message">${this.message}</div>
          ` : ''}
        </div>

        ${this.completed && !this.error ? html`
          <div class="success-message">
            <strong>✓ Installation Complete!</strong>
            <p>HomeFree has been successfully installed. Click Next to finish.</p>
          </div>
          ${this.recoveryPassphrase ? html`
            <div class="recovery-box">
              <strong>🔑 Write down this disk passphrase before continuing</strong>
              <p>
                <strong>You will need to type this passphrase at the next
                boot.</strong> The encrypted disk does not unlock itself
                until the system has booted once and registered with the
                TPM &mdash; so on the first reboot you must enter it at the
                console. After that, reboots are automatic.
              </p>
              <p>
                Keep it somewhere safe long-term too: it is also the only
                way to unlock the disk if the TPM is cleared or the drive
                is moved to another machine. <strong>It is not shown
                again.</strong>
              </p>
              <code class="recovery-code">${this.recoveryPassphrase}</code>
            </div>
          ` : ''}
        ` : ''}

        ${this.error ? html`
          <div class="error-message">
            <strong>✗ Installation Failed</strong>
            <p>${this.error}</p>
            ${this.errorDetailShown ? html`
              <p>The output of the failing step is at the end of the installation log below.</p>
            ` : ''}
          </div>
        ` : ''}

        <div class="logs-section">
          <div class="logs-header">
            <h3>Installation Log</h3>
          </div>
          <div class="logs-container">
            ${this.logs.map(log => html`
              <div class="log-line ${log.type}">
                ${log.raw
                  ? log.message
                  : html`[${new Date(log.timestamp).toLocaleTimeString()}] ${log.message}`}
              </div>
            `)}
            ${this.logs.length === 0 ? html`
              <div class="log-line info">Waiting for installation to start...</div>
            ` : ''}
          </div>
        </div>
      </div>
    `;
  }
}

customElements.define('install-step', InstallStep);
