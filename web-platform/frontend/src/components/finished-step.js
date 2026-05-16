import { LitElement, html, css } from 'lit';

class FinishedStep extends LitElement {
  static properties = {
    data: { type: Object },
  };

  static styles = css`
    :host {
      display: block;
    }

    .finished-container {
      max-width: 700px;
      margin: 0 auto;
      text-align: center;
    }

    .success-icon {
      width: 120px;
      height: 120px;
      margin: 0 auto 24px;
      background: linear-gradient(135deg, #4caf50 0%, #45a049 100%);
      border-radius: 50%;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 64px;
      color: white;
    }

    h2 {
      font-size: 32px;
      color: #333;
      margin-bottom: 16px;
    }

    .subtitle {
      font-size: 18px;
      color: #666;
      margin-bottom: 32px;
    }

    .next-steps {
      text-align: left;
      margin: 32px 0;
      padding: 24px;
      background: #f8f9fa;
      border-radius: 8px;
    }

    .next-steps h3 {
      margin-bottom: 16px;
      color: #333;
    }

    .next-steps ol {
      margin-left: 20px;
      color: #666;
      line-height: 1.8;
    }

    .next-steps li {
      margin-bottom: 12px;
    }

    .next-steps code {
      background: #e0e0e0;
      padding: 2px 8px;
      border-radius: 3px;
      font-family: 'Courier New', monospace;
      font-size: 14px;
    }

    .info-boxes {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 16px;
      margin: 32px 0;
    }

    .info-box {
      padding: 20px;
      background: white;
      border: 2px solid #e0e0e0;
      border-radius: 8px;
      text-align: left;
    }

    .info-box h4 {
      color: #667eea;
      margin-bottom: 8px;
    }

    .info-box p {
      color: #666;
      font-size: 14px;
      margin: 0;
    }

    .reboot-button {
      margin-top: 32px;
      padding: 16px 48px;
      font-size: 18px;
      font-weight: 500;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      color: white;
      border: none;
      border-radius: 8px;
      cursor: pointer;
      transition: transform 0.2s, box-shadow 0.2s;
    }

    .reboot-button:hover {
      transform: translateY(-2px);
      box-shadow: 0 8px 16px rgba(102, 126, 234, 0.3);
    }

    .warning {
      background: #fff3cd;
      border: 1px solid #ffc107;
      border-radius: 6px;
      padding: 16px;
      margin-top: 24px;
      text-align: left;
      color: #856404;
    }

    .warning strong {
      display: block;
      margin-bottom: 8px;
    }
  `;

  handleReboot() {
    if (confirm('Are you sure you want to reboot? Make sure to remove the installation media.')) {
      // Trigger reboot via backend
      window.location.href = '/reboot';
    }
  }

  render() {
    const { data } = this;

    return html`
      <div class="finished-container">
        <div class="success-icon">✓</div>
        <h2>Installation Complete!</h2>
        <p class="subtitle">
          HomeFree has been successfully installed on your system.
        </p>

        <div class="info-boxes">
          <div class="info-box">
            <h4>🌐 Admin Dashboard</h4>
            <p>
              Access at:<br/>
              <code>http://${data.hostname || 'homefree'}.lan</code>
            </p>
          </div>

          <div class="info-box">
            <h4>🔐 Login Credentials</h4>
            <p>
              Username: <code>${data.username || 'admin'}</code><br/>
              Password: <em>(as configured)</em>
            </p>
          </div>

          <div class="info-box">
            <h4>📡 Network Setup</h4>
            <p>
              WAN: <code>${data.wanInterface}</code><br/>
              LAN: <code>${data.lanInterface}</code> (default: 10.0.0.1)
            </p>
          </div>

          <div class="info-box">
            <h4>🛠️ SSH Access</h4>
            <p>
              Connect via:<br/>
              <code>ssh ${data.username}@10.0.0.1</code> (or configured LAN address)
            </p>
          </div>
        </div>

        <div class="next-steps">
          <h3>Next Steps:</h3>
          <ol>
            <li>
              <strong>Remove the installation media</strong> (USB drive or ISO)
            </li>
            <li>
              <strong>Reboot the system</strong> using the button below
            </li>
            <li>
              <strong>Connect LAN devices</strong> to the ${data.lanInterface} interface
            </li>
            <li>
              <strong>Configure services</strong> at the admin dashboard
            </li>
            <li>
              <strong>Set up backups</strong> in <code>/etc/nixos/homefree-configuration.nix</code>
            </li>
          </ol>
        </div>

        <div class="warning">
          <strong>📚 Documentation:</strong>
          Visit <code>https://git.homefree.host/homefree/homefree</code> for complete
          documentation on configuring HomeFree services and advanced features.
        </div>

        <button class="reboot-button" @click="${this.handleReboot}">
          Reboot System
        </button>
      </div>
    `;
  }
}

customElements.define('finished-step', FinishedStep);
