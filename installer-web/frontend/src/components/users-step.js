import { LitElement, html, css } from 'lit';
import { setUser } from '../api/client.js';

class UsersStep extends LitElement {
  static properties = {
    data: { type: Object },
    username: { type: String },
    fullname: { type: String },
    password: { type: String },
    confirmPassword: { type: String },
    hostname: { type: String },
    error: { type: String },
  };

  static styles = css`
    :host {
      display: block;
    }

    .users-container {
      max-width: 600px;
      margin: 0 auto;
    }

    h2 {
      font-size: 28px;
      color: #333;
      margin-bottom: 24px;
    }

    .form-group {
      margin-bottom: 24px;
    }

    label {
      display: block;
      margin-bottom: 8px;
      font-weight: 500;
      color: #333;
    }

    input {
      width: 100%;
      padding: 12px 16px;
      font-size: 14px;
      border: 2px solid #e0e0e0;
      border-radius: 6px;
      background: white;
    }

    input:focus {
      outline: none;
      border-color: #667eea;
    }

    input.error {
      border-color: #f44336;
    }

    .description {
      font-size: 14px;
      color: #666;
      margin-top: 4px;
    }

    .error-message {
      color: #f44336;
      font-size: 14px;
      margin-top: 4px;
    }

    .password-strength {
      margin-top: 8px;
      height: 4px;
      background: #e0e0e0;
      border-radius: 2px;
      overflow: hidden;
    }

    .password-strength-fill {
      height: 100%;
      transition: all 0.3s;
    }

    .password-strength-fill.weak {
      width: 33%;
      background: #f44336;
    }

    .password-strength-fill.medium {
      width: 66%;
      background: #ff9800;
    }

    .password-strength-fill.strong {
      width: 100%;
      background: #4caf50;
    }

    .info-box {
      background: #e3f2fd;
      border: 1px solid #2196f3;
      border-radius: 6px;
      padding: 16px;
      margin-top: 24px;
      color: #1565c0;
    }

    .info-box strong {
      display: block;
      margin-bottom: 8px;
    }

    .error {
      background: #ffebee;
      border: 1px solid #f44336;
      color: #c62828;
      padding: 12px;
      border-radius: 6px;
      margin-bottom: 16px;
    }
  `;

  constructor() {
    super();
    this.username = '';
    this.fullname = '';
    this.password = '';
    this.confirmPassword = '';
    this.hostname = 'homefree';
    this.error = '';
  }

  get passwordStrength() {
    const pw = this.password;
    if (pw.length < 6) return 'weak';
    if (pw.length < 10) return 'medium';
    if (pw.length >= 10 && /[A-Z]/.test(pw) && /[0-9]/.test(pw) && /[^A-Za-z0-9]/.test(pw)) {
      return 'strong';
    }
    return 'medium';
  }

  get isValid() {
    return this.username.length >= 3 &&
           this.fullname.length >= 2 &&
           this.password.length >= 8 &&
           this.password === this.confirmPassword &&
           this.hostname.length >= 2 &&
           /^[a-z][a-z0-9-]*$/.test(this.username) &&
           /^[a-z][a-z0-9-]*$/.test(this.hostname);
  }

  notifyParent() {
    this.dispatchEvent(new CustomEvent('data-changed', {
      bubbles: true,
      composed: true,
      detail: {
        username: this.username,
        fullname: this.fullname,
        password: this.password,
        confirmPassword: this.confirmPassword,
        hostname: this.hostname,
      }
    }));
  }

  async saveUserConfig() {
    // Only save if all required fields are filled
    if (this.username.length >= 3 && this.fullname.length >= 2 && this.password.length >= 8) {
      try {
        await setUser(this.username, this.fullname, this.password);
        console.log('User config saved:', { username: this.username, fullname: this.fullname });

        // Also save hostname
        const response = await fetch('/api/config/hostname', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ hostname: this.hostname })
        });
        if (response.ok) {
          console.log('Hostname saved:', this.hostname);
        }
      } catch (error) {
        console.error('Failed to save user config:', error);
      }
    }
  }

  render() {
    const passwordsMatch = !this.confirmPassword || this.password === this.confirmPassword;

    return html`
      <div class="users-container">
        <h2>User Account</h2>

        ${this.error ? html`<div class="error">${this.error}</div>` : ''}

        <div class="form-group">
          <label for="fullname">Full Name</label>
          <input
            type="text"
            id="fullname"
            placeholder="John Doe"
            .value="${this.fullname}"
            @input="${(e) => {
              this.fullname = e.target.value;
              this.notifyParent();
            }}"
          />
          <div class="description">Your display name</div>
        </div>

        <div class="form-group">
          <label for="username">Username</label>
          <input
            type="text"
            id="username"
            placeholder="admin"
            .value="${this.username}"
            @input="${(e) => {
              this.username = e.target.value.toLowerCase();
              this.notifyParent();
            }}"
            class="${/^[a-z][a-z0-9-]*$/.test(this.username) || !this.username ? '' : 'error'}"
          />
          <div class="description">
            Lowercase letters, numbers, and hyphens only. Must start with a letter.
          </div>
          ${this.username && !/^[a-z][a-z0-9-]*$/.test(this.username) ? html`
            <div class="error-message">Invalid username format</div>
          ` : ''}
        </div>

        <div class="form-group">
          <label for="hostname">Hostname</label>
          <input
            type="text"
            id="hostname"
            placeholder="homefree"
            .value="${this.hostname}"
            @input="${(e) => {
              this.hostname = e.target.value.toLowerCase();
              this.notifyParent();
            }}"
            class="${/^[a-z][a-z0-9-]*$/.test(this.hostname) || !this.hostname ? '' : 'error'}"
          />
          <div class="description">
            System hostname. Lowercase letters, numbers, and hyphens only.
          </div>
          ${this.hostname && !/^[a-z][a-z0-9-]*$/.test(this.hostname) ? html`
            <div class="error-message">Invalid hostname format</div>
          ` : ''}
        </div>

        <div class="form-group">
          <label for="password">Password</label>
          <input
            type="password"
            id="password"
            placeholder="Enter password"
            .value="${this.password}"
            @input="${(e) => {
              this.password = e.target.value;
              this.notifyParent();
            }}"
          />
          ${this.password ? html`
            <div class="password-strength">
              <div class="password-strength-fill ${this.passwordStrength}"></div>
            </div>
          ` : ''}
          <div class="description">
            At least 8 characters. Longer is better.
          </div>
        </div>

        <div class="form-group">
          <label for="confirm-password">Confirm Password</label>
          <input
            type="password"
            id="confirm-password"
            placeholder="Confirm password"
            .value="${this.confirmPassword}"
            @input="${(e) => {
              this.confirmPassword = e.target.value;
              this.notifyParent();
              // Auto-save when passwords match and form is complete
              if (this.password === e.target.value && this.password.length >= 8) {
                this.saveUserConfig();
              }
            }}"
            class="${passwordsMatch ? '' : 'error'}"
          />
          ${!passwordsMatch ? html`
            <div class="error-message">Passwords do not match</div>
          ` : ''}
        </div>

        <div class="info-box">
          <strong>ℹ️ Note:</strong>
          This user will be created as the admin user with sudo privileges.
          The root account will use the same password.
        </div>
      </div>
    `;
  }
}

customElements.define('users-step', UsersStep);
