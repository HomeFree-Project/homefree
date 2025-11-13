import { LitElement, html, css } from 'lit';
import '../shared/list-input.js';
import '../shared/file-browser.js';
import '../shared/submodule-list-editor.js';

/**
 * Service option input component
 * Displays input fields for different service option types (bool, string, int, path, etc.)
 * Handles user input and emits change events to parent
 */
class ServiceOptionInput extends LitElement {
  static properties = {
    optionKey: { type: String },
    label: { type: String },
    description: { type: String },
    type: { type: String },  // bool, string, int, path, nullOr string, nullOr int, listOf string, listOf submodule, etc.
    defaultValue: { type: Object },  // Default value from schema
    currentValue: { type: Object },  // Current value from config
    disabled: { type: Boolean },
    submoduleFields: { type: Array },  // For listOf submodule types
    enumValues: { type: Array },  // For enum types
    uiHint: { type: Object },  // UI rendering hints
    fileBrowserOpen: { type: Boolean, state: true }  // Track file browser modal state
  };

  static styles = css`
    :host {
      display: block;
      margin-bottom: 16px;
    }

    .option-field {
      border: 1px solid #d2d2d7;
      border-radius: 8px;
      padding: 14px;
      background: #fafafa;
    }

    .option-field.disabled {
      opacity: 0.6;
      cursor: not-allowed;
    }

    .field-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 8px;
    }

    .field-label {
      font-size: 14px;
      font-weight: 500;
      color: #1d1d1f;
    }

    .field-type {
      font-size: 11px;
      color: #86868b;
      font-family: monospace;
      background: #f5f5f7;
      padding: 2px 6px;
      border-radius: 4px;
    }

    .field-description {
      font-size: 12px;
      color: #86868b;
      margin-bottom: 10px;
    }

    input[type="text"],
    input[type="number"] {
      width: 100%;
      padding: 8px 12px;
      font-size: 14px;
      border: 1px solid #d2d2d7;
      border-radius: 6px;
      font-family: inherit;
      box-sizing: border-box;
    }

    input[type="text"]:focus,
    input[type="number"]:focus {
      outline: none;
      border-color: #667eea;
    }

    input[type="text"]:disabled,
    input[type="number"]:disabled {
      background: #f5f5f7;
      cursor: not-allowed;
    }

    input[type="text"]::placeholder,
    input[type="number"]::placeholder {
      color: #c7c7cc;
      font-style: italic;
    }

    .input-with-browse {
      display: flex;
      gap: 8px;
      align-items: stretch;
    }

    .input-with-browse input {
      flex: 1;
    }

    .btn-browse {
      padding: 8px 16px;
      background: #f5f5f7;
      color: #1d1d1f;
      border: 1px solid #d2d2d7;
      border-radius: 6px;
      font-size: 13px;
      font-weight: 500;
      cursor: pointer;
      transition: all 0.2s;
      white-space: nowrap;
    }

    .btn-browse:hover:not(:disabled) {
      background: #e5e5e7;
    }

    .btn-browse:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }

    .toggle-container {
      display: flex;
      align-items: center;
      justify-content: space-between;
    }

    .toggle-switch {
      position: relative;
      display: inline-block;
      width: 48px;
      height: 28px;
    }

    .toggle-switch input {
      opacity: 0;
      width: 0;
      height: 0;
    }

    .toggle-slider {
      position: absolute;
      cursor: pointer;
      top: 0;
      left: 0;
      right: 0;
      bottom: 0;
      background-color: #d2d2d7;
      transition: 0.3s;
      border-radius: 28px;
    }

    .toggle-slider:before {
      position: absolute;
      content: "";
      height: 20px;
      width: 20px;
      left: 4px;
      bottom: 4px;
      background-color: white;
      transition: 0.3s;
      border-radius: 50%;
    }

    input:checked + .toggle-slider {
      background-color: #667eea;
    }

    input:checked + .toggle-slider:before {
      transform: translateX(20px);
    }

    input:disabled + .toggle-slider {
      opacity: 0.5;
      cursor: not-allowed;
    }

    .default-hint {
      font-size: 11px;
      color: #86868b;
      margin-top: 4px;
      font-style: italic;
    }

    .null-indicator {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      font-size: 12px;
      color: #86868b;
      margin-top: 6px;
    }

    .clear-btn {
      padding: 4px 8px;
      background: #ff3b30;
      color: white;
      border: none;
      border-radius: 4px;
      font-size: 11px;
      cursor: pointer;
      transition: background 0.2s;
    }

    .clear-btn:hover:not(:disabled) {
      background: #e02020;
    }

    .clear-btn:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }

    .submodule-fields {
      margin-left: 16px;
      padding-left: 16px;
      border-left: 2px solid #e5e5e7;
      display: flex;
      flex-direction: column;
      gap: 12px;
    }
  `;

  constructor() {
    super();
    this.optionKey = '';
    this.label = '';
    this.description = '';
    this.type = 'string';
    this.defaultValue = null;
    this.currentValue = null;
    this.disabled = false;
    this.submoduleFields = [];
    this.uiHint = null;
    this.fileBrowserOpen = false;
  }

  handleChange(value) {
    // Emit change event with the new value
    this.dispatchEvent(new CustomEvent('option-changed', {
      detail: {
        optionKey: this.optionKey,
        value: value
      },
      bubbles: true,
      composed: true
    }));
  }

  handleClear() {
    // For nullOr types, set value to null
    this.handleChange(null);
  }

  openFileBrowser() {
    this.fileBrowserOpen = true;
  }

  closeFileBrowser() {
    this.fileBrowserOpen = false;
  }

  handlePathSelected(e) {
    const selectedPath = e.detail.path;
    this.handleChange(selectedPath);
    this.closeFileBrowser();
  }

  renderBoolInput() {
    const value = this.currentValue !== null && this.currentValue !== undefined
      ? this.currentValue
      : (this.defaultValue || false);

    return html`
      <div class="toggle-container">
        <label class="toggle-switch">
          <input
            type="checkbox"
            .checked=${value}
            ?disabled=${this.disabled}
            @change=${(e) => this.handleChange(e.target.checked)}
          />
          <span class="toggle-slider"></span>
        </label>
      </div>
      ${this.renderDefaultHint()}
    `;
  }

  renderStringInput() {
    const isNullOr = this.type.startsWith('nullOr');
    const isPath = this.type.includes('path');
    const value = this.currentValue !== null && this.currentValue !== undefined
      ? this.currentValue
      : (this.defaultValue || '');
    const isNull = isNullOr && (this.currentValue === null || this.currentValue === undefined);

    const inputField = html`
      <input
        type="text"
        .value=${isNull ? '' : String(value)}
        placeholder="${isNull ? '(not set)' : (isPath ? 'Enter path or click Browse...' : 'Enter value...')}"
        ?disabled=${this.disabled}
        @input=${(e) => this.handleChange(e.target.value || (isNullOr ? null : ''))}
      />
    `;

    return html`
      ${isPath ? html`
        <div class="input-with-browse">
          ${inputField}
          <button
            class="btn-browse"
            @click=${this.openFileBrowser}
            ?disabled=${this.disabled}
          >
            📁 Browse
          </button>
        </div>
      ` : inputField}

      ${isNullOr && !isNull ? html`
        <div class="null-indicator">
          <span>Value is set</span>
          <button
            class="clear-btn"
            @click=${this.handleClear}
            ?disabled=${this.disabled}
          >
            Clear
          </button>
        </div>
      ` : ''}
      ${this.renderDefaultHint()}
    `;
  }

  renderIntInput() {
    const isNullOr = this.type.startsWith('nullOr');
    const value = this.currentValue !== null && this.currentValue !== undefined
      ? this.currentValue
      : (this.defaultValue !== null && this.defaultValue !== undefined ? this.defaultValue : '');
    const isNull = isNullOr && (this.currentValue === null || this.currentValue === undefined);

    return html`
      <input
        type="number"
        .value=${isNull ? '' : String(value)}
        placeholder="${isNull ? '(not set)' : 'Enter number...'}"
        ?disabled=${this.disabled}
        @input=${(e) => {
          const val = e.target.value;
          this.handleChange(val === '' ? (isNullOr ? null : 0) : parseInt(val, 10));
        }}
      />
      ${isNullOr && !isNull ? html`
        <div class="null-indicator">
          <span>Value is set</span>
          <button
            class="clear-btn"
            @click=${this.handleClear}
            ?disabled=${this.disabled}
          >
            Clear
          </button>
        </div>
      ` : ''}
      ${this.renderDefaultHint()}
    `;
  }

  renderDefaultHint() {
    if (this.defaultValue === null || this.defaultValue === undefined) {
      return '';
    }

    const defaultStr = typeof this.defaultValue === 'boolean'
      ? (this.defaultValue ? 'true' : 'false')
      : String(this.defaultValue);

    return html`
      <div class="default-hint">
        Default: ${defaultStr}
      </div>
    `;
  }

  renderEnumInput() {
    const value = this.currentValue !== null && this.currentValue !== undefined
      ? this.currentValue
      : this.defaultValue;

    return html`
      <select
        .value=${value || ''}
        ?disabled=${this.disabled}
        @change=${(e) => this.handleChange(e.target.value)}
      >
        <option value="">Select an option...</option>
        ${this.enumValues.map(option => html`
          <option value=${option} ?selected=${value === option}>
            ${option}
          </option>
        `)}
      </select>
      ${this.renderDefaultHint()}
    `;
  }

  renderSubmoduleInput() {
    if (!this.submoduleFields || this.submoduleFields.length === 0) {
      return html`<div class="field-description">No fields defined for this submodule</div>`;
    }

    // Get current value (object with nested fields)
    const currentValue = this.currentValue || this.defaultValue || {};

    return html`
      <div class="submodule-fields">
        ${this.submoduleFields.map(field => html`
          <service-option-input
            .optionKey=${field.path}
            .label=${field.path.replace(/-/g, ' ').replace(/\b\w/g, l => l.toUpperCase())}
            .description=${field.description || ''}
            .type=${field.type}
            .defaultValue=${field.default}
            .currentValue=${currentValue[field.path]}
            .enumValues=${field['enum-values'] || []}
            .submoduleFields=${field['submodule-fields'] || []}
            ?disabled=${this.disabled}
            @option-changed=${(e) => this.handleSubmoduleFieldChange(e.detail.optionKey, e.detail.value)}
          ></service-option-input>
        `)}
      </div>
    `;
  }

  handleSubmoduleFieldChange(fieldPath, fieldValue) {
    // Get current submodule value
    const currentValue = this.currentValue || this.defaultValue || {};

    // Update nested field
    const newValue = {
      ...currentValue,
      [fieldPath]: fieldValue
    };

    // Emit change event with updated submodule object
    this.handleChange(newValue);
  }

  renderListInput() {
    // Extract item type from "listOf <type>" string
    const itemType = this.type.replace(/^(nullOr )?listOf /, '');
    const value = this.currentValue || this.defaultValue || [];

    // Check if this is a submodule list (complex type)
    if (itemType === 'submodule' && this.submoduleFields && this.submoduleFields.length > 0) {
      return html`
        <submodule-list-editor
          .label=${this.label}
          .description=${this.description}
          .submoduleFields=${this.submoduleFields}
          .value=${value}
          ?disabled=${this.disabled}
          @list-changed=${(e) => this.handleChange(e.detail.value)}
        ></submodule-list-editor>
      `;
    }

    // Simple list (listOf str, listOf int, etc.)
    return html`
      <list-input
        .itemType=${itemType}
        .value=${value}
        ?disabled=${this.disabled}
        @list-changed=${(e) => this.handleChange(e.detail.value)}
      ></list-input>
      ${this.renderDefaultHint()}
    `;
  }

  renderInput() {
    // Check if this is an enum type (has enum-values array)
    if (this.enumValues && this.enumValues.length > 0) {
      return this.renderEnumInput();
    }

    // Determine base type (strip nullOr prefix)
    const baseType = this.type.replace(/^nullOr /, '');

    if (baseType === 'bool') {
      return this.renderBoolInput();
    } else if (baseType === 'int') {
      return this.renderIntInput();
    } else if (baseType === 'str' || baseType === 'string' || baseType === 'path') {
      return this.renderStringInput();
    } else if (baseType === 'submodule') {
      return this.renderSubmoduleInput();
    } else if (baseType.startsWith('listOf')) {
      return this.renderListInput();
    } else {
      // Unknown type
      return html`<div class="field-description">Type "${this.type}" not yet supported</div>`;
    }
  }

  render() {
    const currentPath = this.currentValue || this.defaultValue || '/';

    return html`
      <div class="option-field ${this.disabled ? 'disabled' : ''}">
        <div class="field-header">
          <div class="field-label">${this.label}</div>
          <div class="field-type">${this.type}</div>
        </div>

        ${this.description ? html`
          <div class="field-description">${this.description}</div>
        ` : ''}

        ${this.renderInput()}
      </div>

      ${this.fileBrowserOpen ? html`
        <file-browser
          ?open=${this.fileBrowserOpen}
          .currentPath=${currentPath}
          @path-selected=${this.handlePathSelected}
          @close=${this.closeFileBrowser}
        ></file-browser>
      ` : ''}
    `;
  }
}

customElements.define('service-option-input', ServiceOptionInput);
