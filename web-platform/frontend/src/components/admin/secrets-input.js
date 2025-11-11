import { LitElement, html, css } from 'lit';

/**
 * Secrets input component
 * Displays a masked input field for secret values with show/hide toggle
 * Shows status (Set/Not Set) and allows setting/clearing secrets
 */
class SecretsInput extends LitElement {
  static properties = {
    serviceLabel: { type: String },
    secretKey: { type: String },
    label: { type: String },
    description: { type: String },
    required: { type: Boolean },
    disabled: { type: Boolean },
    exists: { type: Boolean },  // Whether secret is currently set
    inputValue: { type: String, state: true },
    showValue: { type: Boolean, state: true },
    saving: { type: Boolean, state: true }
  };

  static styles = css`
    :host {
      display: block;
      margin-bottom: 20px;
    }

    .secret-field {
      border: 1px solid #d2d2d7;
      border-radius: 8px;
      padding: 16px;
      background: #f9f9f9;
    }

    .secret-field.disabled {
      opacity: 0.6;
      cursor: not-allowed;
    }

    .field-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 12px;
    }

    .field-label {
      font-size: 14px;
      font-weight: 500;
      color: #1d1d1f;
    }

    .field-label .required {
      color: #ff3b30;
      margin-left: 4px;
    }

    .status-badge {
      padding: 4px 12px;
      border-radius: 12px;
      font-size: 12px;
      font-weight: 500;
    }

    .status-badge.set {
      background: #d4edda;
      color: #155724;
    }

    .status-badge.not-set {
      background: #f8d7da;
      color: #721c24;
    }

    .field-description {
      font-size: 13px;
      color: #86868b;
      margin-bottom: 12px;
    }

    .input-row {
      display: flex;
      gap: 8px;
      align-items: flex-start;
      margin-bottom: 12px;
    }

    textarea {
      flex: 1;
      padding: 10px 12px;
      font-size: 14px;
      border: 1px solid #d2d2d7;
      border-radius: 8px;
      font-family: monospace;
      resize: vertical;
      min-height: 80px;
    }

    textarea:focus {
      outline: none;
      border-color: #667eea;
    }

    textarea:disabled {
      background: #f5f5f7;
      cursor: not-allowed;
    }

    textarea.masked {
      -webkit-text-security: disc;
      text-security: disc;
    }

    .btn {
      padding: 10px 16px;
      border-radius: 8px;
      border: none;
      font-size: 14px;
      font-weight: 500;
      cursor: pointer;
      transition: all 0.2s;
    }

    .btn:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }

    .btn-toggle {
      background: #f5f5f7;
      color: #1d1d1f;
      border: 1px solid #d2d2d7;
      min-width: 60px;
    }

    .btn-toggle:hover:not(:disabled) {
      background: #e5e5e7;
    }

    .btn-set {
      background: #667eea;
      color: white;
    }

    .btn-set:hover:not(:disabled) {
      background: #5568d3;
    }

    .btn-clear {
      background: #ff3b30;
      color: white;
    }

    .btn-clear:hover:not(:disabled) {
      background: #e02020;
    }

    .btn-group {
      display: flex;
      gap: 8px;
    }

    .warning-message {
      padding: 12px;
      background: #fff3cd;
      border: 1px solid #ffc107;
      border-radius: 8px;
      font-size: 13px;
      color: #856404;
      margin-top: 12px;
    }
  `;

  constructor() {
    super();
    this.serviceLabel = '';
    this.secretKey = '';
    this.label = '';
    this.description = '';
    this.required = false;
    this.disabled = false;
    this.exists = false;
    this.inputValue = '';
    this.showValue = false;
    this.saving = false;
  }

  async handleSet() {
    if (!this.inputValue || !this.inputValue.trim()) {
      alert('Please enter a secret value');
      return;
    }

    this.saving = true;

    try {
      const response = await fetch(`/api/secrets/${this.serviceLabel}/${this.secretKey}`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          value: this.inputValue
        })
      });

      if (!response.ok) {
        const error = await response.json();
        throw new Error(error.detail || 'Failed to set secret');
      }

      // Clear input and mark as exists
      this.inputValue = '';
      this.exists = true;
      this.showValue = false;

      // Emit success event
      this.dispatchEvent(new CustomEvent('secret-updated', {
        detail: { serviceLabel: this.serviceLabel, secretKey: this.secretKey, action: 'set' },
        bubbles: true,
        composed: true
      }));

    } catch (error) {
      console.error('Error setting secret:', error);
      alert(`Failed to set secret: ${error.message}`);
    } finally {
      this.saving = false;
    }
  }

  async handleClear() {
    if (!confirm('Are you sure you want to delete this secret? This action cannot be undone.')) {
      return;
    }

    this.saving = true;

    try {
      const response = await fetch(`/api/secrets/${this.serviceLabel}/${this.secretKey}`, {
        method: 'DELETE'
      });

      if (!response.ok) {
        const error = await response.json();
        throw new Error(error.detail || 'Failed to delete secret');
      }

      // Mark as not exists
      this.exists = false;
      this.inputValue = '';

      // Emit success event
      this.dispatchEvent(new CustomEvent('secret-updated', {
        detail: { serviceLabel: this.serviceLabel, secretKey: this.secretKey, action: 'delete' },
        bubbles: true,
        composed: true
      }));

    } catch (error) {
      console.error('Error deleting secret:', error);
      alert(`Failed to delete secret: ${error.message}`);
    } finally {
      this.saving = false;
    }
  }

  toggleShow() {
    this.showValue = !this.showValue;
  }

  render() {
    return html`
      <div class="secret-field ${this.disabled ? 'disabled' : ''}">
        <div class="field-header">
          <div class="field-label">
            ${this.label}
            ${this.required ? html`<span class="required">*</span>` : ''}
          </div>
          <div class="status-badge ${this.exists ? 'set' : 'not-set'}">
            ${this.exists ? '✓ Set' : '✗ Not Set'}
          </div>
        </div>

        ${this.description ? html`
          <div class="field-description">${this.description}</div>
        ` : ''}

        <div class="input-row">
          <textarea
            class="${this.showValue ? '' : 'masked'}"
            .value=${this.inputValue}
            placeholder="${this.exists ? '(secret is set)' : 'Enter secret value...'}"
            ?disabled=${this.disabled || this.saving}
            @input=${(e) => { this.inputValue = e.target.value; }}
            rows="3"
          ></textarea>
          <button
            class="btn btn-toggle"
            @click=${this.toggleShow}
            ?disabled=${this.disabled || this.saving}
            title="${this.showValue ? 'Hide' : 'Show'} value"
          >
            ${this.showValue ? '👁️' : '👁️‍🗨️'}
          </button>
        </div>

        <div class="btn-group">
          <button
            class="btn btn-set"
            @click=${this.handleSet}
            ?disabled=${this.disabled || this.saving || !this.inputValue}
          >
            ${this.saving ? 'Saving...' : (this.exists ? 'Update' : 'Set Secret')}
          </button>

          ${this.exists ? html`
            <button
              class="btn btn-clear"
              @click=${this.handleClear}
              ?disabled=${this.disabled || this.saving}
            >
              Clear
            </button>
          ` : ''}
        </div>

        ${this.disabled ? html`
          <div class="warning-message">
            ⚠️ Secrets management is disabled. Please add an SSH authorized key in the System page to enable secrets.
          </div>
        ` : ''}
      </div>
    `;
  }
}

customElements.define('secrets-input', SecretsInput);
