import { LitElement, html, css } from 'lit';

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
      font-size: 14px;
      font-weight: 500;
      color: #1d1d1f;
      margin-bottom: 8px;
      display: block;
    }

    label .required {
      color: #ff3b30;
      margin-left: 4px;
    }

    input[type="text"],
    input[type="number"],
    select {
      padding: 10px 12px;
      font-size: 14px;
      border: 1px solid #d2d2d7;
      border-radius: 8px;
      background: white;
      color: #1d1d1f;
      font-family: inherit;
      transition: border-color 0.2s;
    }

    input[type="text"]:focus,
    input[type="number"]:focus,
    select:focus {
      outline: none;
      border-color: #667eea;
    }

    input[type="text"]:disabled,
    input[type="number"]:disabled,
    select:disabled {
      background: #f5f5f7;
      color: #86868b;
      cursor: not-allowed;
    }

    input[type="text"].error,
    input[type="number"].error,
    select.error {
      border-color: #ff3b30;
    }

    .checkbox-wrapper {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    input[type="checkbox"] {
      width: 18px;
      height: 18px;
      cursor: pointer;
    }

    input[type="checkbox"]:disabled {
      cursor: not-allowed;
      opacity: 0.5;
    }

    .help-text {
      font-size: 12px;
      color: #86868b;
      margin-top: 6px;
    }

    .error-text {
      font-size: 12px;
      color: #ff3b30;
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
        <select
          .value=${this.value}
          ?disabled=${this.disabled}
          ?required=${this.required}
          class="${this.error ? 'error' : ''}"
          @change=${this.handleInput}
        >
          ${this.placeholder ? html`<option value="" ?selected=${!this.value}>${this.placeholder}</option>` : ''}
          ${this.options.map(opt => html`
            <option value="${opt.value}" ?selected=${opt.value === this.value}>${opt.label}</option>
          `)}
        </select>
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
