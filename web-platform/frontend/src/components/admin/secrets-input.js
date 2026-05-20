import { LitElement, html, css } from 'lit';
import { confirmDialog, alertDialog } from '../shared/confirm-dialog.js';

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
    // When true AND the secret is not yet set, the card draws a warning
    // ring + inline "required" message. Used by the consumer to flag
    // fields that must be filled in for a feature to work.
    missing: { type: Boolean },
    missingMessage: { type: String },
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
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      padding: 16px;
      background: var(--hf-surface-2);
    }

    .secret-field.disabled {
      opacity: 0.6;
      cursor: not-allowed;
    }

    /* Highlight when the consumer flags this field as required-but-unset. */
    .secret-field.missing {
      border-color: var(--hf-warn);
      box-shadow: 0 0 0 1px var(--hf-warn) inset;
    }

    .missing-message {
      margin-top: 10px;
      font-size: 12.5px;
      color: var(--hf-warn);
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
      color: var(--hf-text);
    }

    .field-label .required {
      color: var(--hf-err);
      margin-left: 4px;
    }

    .status-badge {
      padding: 4px 12px;
      border-radius: 12px;
      font-size: 12px;
      font-weight: 500;
    }

    .status-badge.set {
      background: rgba(16, 185, 129, 0.12);
      color: var(--hf-ok);
    }

    .status-badge.not-set {
      background: rgba(239, 68, 68, 0.1);
      color: var(--hf-err);
    }

    .field-description {
      font-size: 13px;
      color: var(--hf-text-muted);
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
      /* min-width:0 so the textarea can shrink inside its flex row
         instead of overflowing; box-sizing so padding/border stay
         inside the measured width. */
      min-width: 0;
      box-sizing: border-box;
      padding: 10px 12px;
      font-size: 14px;
      background: var(--hf-bg);
      color: var(--hf-text);
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      font-family: monospace;
      resize: vertical;
      min-height: 80px;
    }

    textarea::placeholder {
      color: var(--hf-text-subtle);
    }

    textarea:focus {
      outline: none;
      border-color: var(--hf-accent);
      box-shadow: 0 0 0 3px var(--hf-focus-ring);
    }

    textarea:disabled {
      background: var(--hf-surface-2);
      cursor: not-allowed;
    }

    textarea.masked {
      -webkit-text-security: disc;
      text-security: disc;
    }

    /* Canonical admin button — matches admin-app / table-editor:
       9px 16px / 13px / radius 6px, bordered surface look. */
    .btn {
      padding: 9px 16px;
      border-radius: 6px;
      border: 1px solid var(--hf-border-2);
      background: var(--hf-surface-2);
      color: var(--hf-text);
      font-size: 13px;
      font-weight: 500;
      font-family: inherit;
      cursor: pointer;
      transition: all 0.15s;
    }

    .btn:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }

    .btn-toggle {
      min-width: 60px;
    }

    .btn-toggle:hover:not(:disabled) {
      background: var(--hf-surface-3);
      border-color: var(--hf-text-subtle);
    }

    /* Primary action — accent fill, dark text. */
    .btn-set {
      background: var(--hf-accent);
      color: #06281c;
      border-color: var(--hf-accent);
    }

    .btn-set:hover:not(:disabled) {
      background: var(--hf-accent-hover);
      border-color: var(--hf-accent-hover);
    }

    /* Danger action — bordered, red text (matches the table-row
       Delete button), not a solid-red fill. */
    .btn-clear {
      color: var(--hf-err);
      border-color: color-mix(in srgb, var(--hf-err) 45%, transparent);
    }

    .btn-clear:hover:not(:disabled) {
      background: color-mix(in srgb, var(--hf-err) 14%, transparent);
      border-color: var(--hf-err);
    }

    .btn-group {
      display: flex;
      gap: 8px;
    }

    /* Unified notification box — grey-tinted bg, colored left edge. */
    .warning-message {
      padding: 14px 18px;
      background: rgba(59, 130, 246, 0.08);
      border-left: 4px solid var(--hf-warn);
      border-radius: 8px;
      font-size: 13px;
      line-height: 1.5;
      color: var(--hf-text-muted);
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
    this.missing = false;
    this.missingMessage = '';
    this.inputValue = '';
    this.showValue = false;
    this.saving = false;
  }

  async handleSet() {
    if (!this.inputValue || !this.inputValue.trim()) {
      await alertDialog({ message: 'Please enter a secret value.' });
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
      await alertDialog({
        title: 'Error',
        message: `Failed to set secret: ${error.message}`,
        variant: 'danger',
      });
    } finally {
      this.saving = false;
    }
  }

  async handleClear() {
    const ok = await confirmDialog({
      title: 'Clear secret?',
      message: 'This permanently deletes the stored secret value. This action cannot be undone.',
      confirmText: 'Clear',
      variant: 'danger',
    });
    if (!ok) {
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
      await alertDialog({
        title: 'Error',
        message: `Failed to delete secret: ${error.message}`,
        variant: 'danger',
      });
    } finally {
      this.saving = false;
    }
  }

  toggleShow() {
    this.showValue = !this.showValue;
  }

  render() {
    const showMissing = this.missing && !this.exists;
    return html`
      <div class="secret-field
                  ${this.disabled ? 'disabled' : ''}
                  ${showMissing ? 'missing' : ''}">
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

        ${showMissing ? html`
          <div class="missing-message">
            ⚠️ ${this.missingMessage || 'This value is required.'}
          </div>
        ` : ''}
      </div>
    `;
  }
}

customElements.define('secrets-input', SecretsInput);
