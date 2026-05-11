import { LitElement, html, css } from 'lit';

class WelcomeStep extends LitElement {
  static properties = {
    data: { type: Object },
  };

  static styles = css`
    :host {
      display: block;
    }

    .welcome-container {
      max-width: 600px;
      margin: 0 auto;
      text-align: center;
    }

    h2 {
      font-size: 32px;
      color: #333;
      margin-bottom: 16px;
    }

    .logo {
      width: 120px;
      height: 120px;
      margin: 0 auto 24px;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      border-radius: 24px;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 48px;
      color: white;
      font-weight: bold;
    }

    p {
      font-size: 16px;
      color: #666;
      line-height: 1.6;
      margin-bottom: 32px;
    }

    .features {
      text-align: left;
      margin: 32px 0;
      padding: 24px;
      background: #f8f9fa;
      border-radius: 8px;
    }

    .features h3 {
      margin-bottom: 16px;
      color: #333;
    }

    .features ul {
      list-style: none;
      padding: 0;
    }

    .features li {
      padding: 8px 0;
      color: #666;
    }

    .features li:before {
      content: "✓ ";
      color: #667eea;
      font-weight: bold;
      margin-right: 8px;
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

  constructor() {
    super();
  }

  render() {
    return html`
      <div class="welcome-container">
        <div class="logo">HF</div>
        <h2>Welcome to HomeFree</h2>
        <p>
          HomeFree is a NixOS-based self-hosting platform that combines
          router functionality with integrated services. This installer will guide
          you through setting up your HomeFree system.
        </p>

        <div class="features">
          <h3>What's Included:</h3>
          <ul>
            <li>Router & Firewall with dual WAN/LAN interfaces</li>
            <li>DNS resolver (Unbound) with ad-blocking</li>
            <li>DHCP server (DNSMasq)</li>
            <li>Reverse proxy (Caddy) with automatic HTTPS</li>
            <li>Self-hosted services (Nextcloud, Jellyfin, Home Assistant, and more)</li>
            <li>Automated backups with Restic</li>
            <li>VPN mesh networking with Headscale</li>
          </ul>
        </div>

        <div class="warning">
          <strong>⚠️ Important:</strong>
          This installation will erase all data on the selected disk.
          Make sure you have backups of any important data before proceeding.
        </div>
      </div>
    `;
  }

}

customElements.define('welcome-step', WelcomeStep);
