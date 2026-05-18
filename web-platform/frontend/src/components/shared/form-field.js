import { LitElement, html, css } from 'lit';
import './dropdown-select.js';

/**
 * Generic form field component
 * Supports: text, number, boolean, select
 */
class FormField extends LitElement {
  static properties = {
    label: { type: String },
    type: { type: String },
    value: {},
    options: { type: Array },
    placeholder: { type: String },
    required: { type: Boolean },
    disabled: { type: Boolean },
    help: { type: String },
    error: { type: String }
  };

  static styles = css`
    :host {
      display: block;
      margin-bottom: 20px;
    }

    .field-group {
      display: flex;
      flex-direction: column;
    }

    label {
      font-size: 13px;
      font-weight: 500;
      color: var(--hf-text);
      margin-bottom: 6px;
      display: block;
    }

    label .required {
      color: var(--hf-err);
      margin-left: 4px;
    }

    input[type="text"],
    input[type="email"],
    input[type="number"],
    select {
      padding: 9px 12px;
      font-size: 13px;
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      background: var(--hf-bg);
      color: var(--hf-text);
      font-family: inherit;
      transition: border-color 0.15s, box-shadow 0.15s;
      max-width: 500px;
      width: 100%;
      /* Without border-box, the 12px padding + 1px border add ONTO a
         width:100%, so the field overflows its parent on narrow
         screens and gets clipped on the right edge. */
      box-sizing: border-box;
    }

    input[type="text"]::placeholder,
    input[type="email"]::placeholder,
    input[type="number"]::placeholder {
      color: var(--hf-text-subtle);
    }

    input[type="text"]:focus,
    input[type="email"]:focus,
    input[type="number"]:focus,
    select:focus {
      outline: none;
      border-color: var(--hf-accent);
      box-shadow: 0 0 0 3px var(--hf-focus-ring);
    }

    input[type="text"]:disabled,
    input[type="email"]:disabled,
    input[type="number"]:disabled,
    select:disabled {
      background: var(--hf-surface-2);
      color: var(--hf-text-muted);
      cursor: not-allowed;
    }

    input[type="text"].error,
    input[type="email"].error,
    input[type="number"].error,
    select.error {
      border-color: var(--hf-err);
    }

    .checkbox-wrapper {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    input[type="checkbox"] {
      width: 16px;
      height: 16px;
      cursor: pointer;
      accent-color: var(--hf-accent);
    }

    input[type="checkbox"]:disabled {
      cursor: not-allowed;
      opacity: 0.5;
    }

    .help-text {
      font-size: 12px;
      color: var(--hf-text-muted);
      margin-top: 6px;
    }

    .error-text {
      font-size: 12px;
      color: var(--hf-err);
      margin-top: 6px;
    }
  `;

  constructor() {
    super();
    this.label = '';
    this.type = 'text';
    this.value = '';
    this.options = [];
    this.placeholder = '';
    this.required = false;
    this.disabled = false;
    this.help = '';
    this.error = '';
  }

  handleInput(e) {
    let value;

    if (this.type === 'boolean') {
      value = e.target.checked;
    } else if (this.type === 'number') {
      value = e.target.value ? parseInt(e.target.value, 10) : null;
    } else {
      value = e.target.value;
    }

    this.dispatchEvent(new CustomEvent('field-change', {
      detail: { value },
      bubbles: true,
      composed: true
    }));
  }

  renderInput() {
    if (this.type === 'boolean') {
      return html`
        <div class="checkbox-wrapper">
          <input
            type="checkbox"
            .checked=${this.value}
            ?disabled=${this.disabled}
            @change=${this.handleInput}
          />
          <label>${this.label}</label>
        </div>
      `;
    }

    if (this.type === 'select') {
      return html`
        <label>
          ${this.label}
          ${this.required ? html`<span class="required">*</span>` : ''}
        </label>
        <dropdown-select
          .options=${this.options}
          .value=${this.value || null}
          .placeholder=${this.placeholder || 'Select an option...'}
          ?disabled=${this.disabled}
          @change=${(e) => this.handleInput({ target: { value: e.detail.value } })}
        ></dropdown-select>
      `;
    }

    return html`
      <label>
        ${this.label}
        ${this.required ? html`<span class="required">*</span>` : ''}
      </label>
      <input
        type="${this.type}"
        .value=${this.value || ''}
        placeholder="${this.placeholder}"
        ?disabled=${this.disabled}
        ?required=${this.required}
        class="${this.error ? 'error' : ''}"
        @input=${this.handleInput}
      />
    `;
  }

  render() {
    return html`
      <div class="field-group">
        ${this.renderInput()}
        ${this.help && !this.error ? html`<div class="help-text">${this.help}</div>` : ''}
        ${this.error ? html`<div class="error-text">${this.error}</div>` : ''}
      </div>
    `;
  }
}

customElements.define('form-field', FormField);
