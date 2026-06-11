import { LitElement, html, css } from 'lit';
import { setUser, setHostname } from '../api/client.js';
import { validatePassword } from '../shared/password-policy.js';
import './shared/password-input.js';

class UsersStep extends LitElement {
  static properties = {
    data: { type: Object },
    username: { type: String },
    fullname: { type: String },
    email: { type: String },
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

    .match-ok {
      color: #4caf50;
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

    .info-box > strong:first-child {
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
    this.email = '';
    this.password = '';
    this.confirmPassword = '';
    this.hostname = 'homefree';
    this.error = '';
  }

  willUpdate(changedProperties) {
    // The wizard owns the canonical copy of the form in installData and
    // passes it back down as .data. Re-seed the local fields from it so
    // that navigating Back to this step shows the values the user
    // already entered instead of an empty form whose Next button is
    // still enabled by the parent's stale copy.
    if (changedProperties.has('data') && this.data) {
      this.username = this.data.username ?? this.username;
      this.fullname = this.data.fullname ?? this.fullname;
      this.email = this.data.email ?? this.email;
      this.password = this.data.password ?? this.password;
      this.confirmPassword = this.data.confirmPassword ?? this.confirmPassword;
      this.hostname = this.data.hostname || this.hostname;
    }
  }

  get passwordError() {
    // Routes through the shared validator; same rules as Zitadel +
    // the Linux-side mkpasswd/chpasswd constraints. The strength
    // meter is drawn by <password-input> itself, so this only needs
    // to return an error string for the parent-side validation
    // (isNextDisabled / commit).
    return validatePassword(this.password).error;
  }

  get isValid() {
    const emailValid = !this.email || /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(this.email);
    return this.username.length >= 3 &&
           this.fullname.length >= 2 &&
           emailValid &&
           !this.passwordError &&
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
        email: this.email,
        password: this.password,
        confirmPassword: this.confirmPassword,
        hostname: this.hostname,
      }
    }));
  }

  async commit() {
    // Called by the wizard before advancing past this step. The install
    // itself reads only the backend's in-memory config, so the account
    // data must be confirmed delivered here: a save that silently
    // failed used to surface only mid-install as "No password
    // configured", after the disks had already been repartitioned.
    // Returns true when the backend has acknowledged both saves.
    this.error = '';

    if (!this.isValid) {
      this.error = 'Please complete all required fields before continuing.';
      return false;
    }

    try {
      const userResult = await setUser(this.username, this.fullname, this.email, this.password);
      if (!userResult || userResult.success === false) {
        this.error = (userResult && userResult.message) || 'Failed to save the user account.';
        return false;
      }

      const hostnameResult = await setHostname(this.hostname);
      if (!hostnameResult || hostnameResult.success === false) {
        this.error = (hostnameResult && hostnameResult.message) || 'Failed to save the hostname.';
        return false;
      }
    } catch (err) {
      this.error = 'Failed to save the user account: ' + err.message;
      return false;
    }

    return true;
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
          <label for="email">Email (optional)</label>
          <input
            type="email"
            id="email"
            placeholder="admin@example.com"
            .value="${this.email}"
            @input="${(e) => {
              this.email = e.target.value;
              this.notifyParent();
            }}"
            class="${!this.email || /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(this.email) ? '' : 'error'}"
          />
          <div class="description">For git commits and notifications</div>
          ${this.email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(this.email) ? html`
            <div class="error-message">Invalid email format</div>
          ` : ''}
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
          <password-input
            placeholder="Enter password"
            withStrength
            .value=${this.password}
            @input=${(e) => {
              this.password = e.detail.value;
              this.notifyParent();
            }}
          ></password-input>
          <div class="description">
            At least 8 characters with upper, lower, number, and symbol.
          </div>
        </div>

        <div class="form-group">
          <label for="confirm-password">Confirm Password</label>
          <password-input
            placeholder="Confirm password"
            .value=${this.confirmPassword}
            @input=${(e) => {
              this.confirmPassword = e.detail.value;
              this.notifyParent();
            }}
          ></password-input>
          ${this.confirmPassword
            ? (this.password === this.confirmPassword
                ? html`<div class="match-ok">✓ Passwords match</div>`
                : html`<div class="error-message">× Passwords do not match</div>`)
            : ''}
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
