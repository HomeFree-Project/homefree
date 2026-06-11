import { LitElement, html, css } from 'lit';
import { confirmDialog } from './shared/confirm-dialog.js';

class FinishedStep extends LitElement {
  static properties = {
    data: { type: Object },
  };

  static styles = css`
    :host {
      display: block;
    }

    .finished-container {
      max-width: 800px;
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

    /* Prominent finish-setup callout — the single most important
       thing the user needs to do after reboot, so it is not buried
       among the info boxes. */
    .finish-setup {
      background: #eef0ff;
      border: 2px solid #667eea;
      border-radius: 8px;
      padding: 24px;
      margin: 24px 0;
      text-align: left;
    }

    .finish-setup h3 {
      color: #4c51bf;
      margin: 0 0 8px;
      font-size: 20px;
    }

    .finish-setup p {
      color: #444;
      line-height: 1.6;
      margin: 8px 0;
    }

    .finish-setup .urls {
      margin: 14px 0;
      padding: 14px 18px;
      background: white;
      border-radius: 6px;
      border: 1px solid #d6d9f5;
    }

    .finish-setup .urls code {
      background: #e0e0e0;
      padding: 3px 10px;
      border-radius: 3px;
      font-family: 'Courier New', monospace;
      font-size: 15px;
      font-weight: bold;
    }

    .finish-setup .note {
      font-size: 13px;
      color: #666;
    }
  `;

  async handleReboot() {
    const ok = await confirmDialog({
      title: 'Reboot system?',
      message: 'Are you sure you want to reboot? Make sure to remove the installation media.',
      confirmText: 'Reboot',
      variant: 'danger',
    });
    if (ok) {
      // Trigger reboot via backend
      window.location.href = '/reboot';
    }
  }

  render() {
    const { data } = this;
    // localDomain defaults to "lan" and lan-address to 10.0.0.1 (module.nix);
    // the installer doesn't currently let the user change either.
    // Primary URL is the bare LAN IP — a hostname in a link is resolved by
    // the user's own device, which may map admin.<localDomain> to a
    // different HomeFree box; the IP is unambiguous.
    const localDomain = data.localDomain || 'lan';
    const lanAddress = data.lanAddress || '10.0.0.1';
    const wizardUrl = `http://${lanAddress}/`;
    const wizardNameUrl = `http://admin.${localDomain}/`;

    return html`
      <div class="finished-container">
        <div class="success-icon">✓</div>
        <h2>Installation Complete!</h2>
        <p class="subtitle">
          HomeFree has been successfully installed on your system.
        </p>

        <div class="finish-setup">
          <h3>⚠️ One more step: finish setup in a browser</h3>
          <p>
            HomeFree still needs an SSH key and a DNS provider token to
            secure the admin site — these couldn't be entered here. After
            you reboot, complete setup from a phone or laptop
            <strong>connected to the LAN port</strong>
            (the <code>${data.lanInterface}</code> interface).
          </p>
          <div class="urls">
            Open: <code>${wizardUrl}</code><br/>
            <span class="note">
              Or try <code>${wizardNameUrl}</code>.
              Many devices will also show a "Sign in to network" prompt
              automatically when you connect.
            </span>
          </div>
          <p class="note">
            <strong>Write this address down now</strong> — you'll need it
            after the system reboots.
          </p>
        </div>

        <div class="info-boxes">
          <div class="info-box">
            <h4>🌐 Admin Dashboard</h4>
            <p>
              After finishing setup, access at:<br/>
              <code>${wizardUrl}</code>
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
              <strong>Connect a laptop or phone to the LAN port</strong>
              (the ${data.lanInterface} interface)
            </li>
            <li>
              <strong>Finish setup</strong> by opening <code>${wizardUrl}</code>
              in that device's browser
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
