import { LitElement, html, css } from 'lit';

/**
 * List input component
 * Handles simple lists (listOf string, listOf int, listOf path)
 * Uses textarea with one item per line
 */
class ListInput extends LitElement {
  static properties = {
    itemType: { type: String },      // string, int, path
    value: { type: Array },           // Current array value
    placeholder: { type: String },
    disabled: { type: Boolean },
    label: { type: String },
    description: { type: String }
  };

  static styles = css`
    :host {
      display: block;
    }

    .list-container {
      display: flex;
      flex-direction: column;
      gap: 8px;
    }

    .list-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
    }

    .list-label {
      font-size: 13px;
      font-weight: 500;
      color: #1d1d1f;
    }

    .list-count {
      font-size: 11px;
      color: #86868b;
      background: #f5f5f7;
      padding: 2px 8px;
      border-radius: 10px;
    }

    .list-description {
      font-size: 12px;
      color: #86868b;
      margin-bottom: 4px;
    }

    textarea {
      width: 100%;
      min-height: 100px;
      padding: 10px 12px;
      font-size: 13px;
      font-family: monospace;
      border: 1px solid #d2d2d7;
      border-radius: 6px;
      resize: vertical;
      box-sizing: border-box;
    }

    textarea:focus {
      outline: none;
      border-color: #667eea;
    }

    textarea:disabled {
      background: #f5f5f7;
      cursor: not-allowed;
      opacity: 0.6;
    }

    textarea::placeholder {
      color: #c7c7cc;
      font-style: italic;
    }

    .list-hint {
      font-size: 11px;
      color: #86868b;
      font-style: italic;
    }

    .validation-error {
      font-size: 12px;
      color: #ff3b30;
      margin-top: 4px;
    }
  `;

  constructor() {
    super();
    this.itemType = 'string';
    this.value = [];
    this.placeholder = 'Enter one item per line...';
    this.disabled = false;
    this.label = 'Items';
    this.description = '';
    this.validationError = '';
  }

  /**
   * Convert array to textarea string (one item per line)
   */
  arrayToText(arr) {
    if (!arr || !Array.isArray(arr)) {
      return '';
    }
    return arr.join('\n');
  }

  /**
   * Convert textarea string to array (split by newline, trim, filter empty)
   */
  textToArray(text) {
    if (!text || typeof text !== 'string') {
      return [];
    }
    return text
      .split('\n')
      .map(line => line.trim())
      .filter(line => line.length > 0);
  }

  /**
   * Validate items based on type
   */
  validateItems(items) {
    this.validationError = '';

    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      const lineNum = i + 1;

      if (this.itemType === 'int') {
        const num = parseInt(item, 10);
        if (isNaN(num)) {
          this.validationError = `Line ${lineNum}: "${item}" is not a valid integer`;
          return false;
        }
        // Replace string with actual number
        items[i] = num;
      } else if (this.itemType === 'path') {
        // Basic path validation - must start with /
        if (!item.startsWith('/')) {
          this.validationError = `Line ${lineNum}: "${item}" is not an absolute path (must start with /)`;
          return false;
        }
      } else if (this.itemType === 'string') {
        // String validation - just check it's not empty (already filtered)
        if (item.length > 500) {
          this.validationError = `Line ${lineNum}: String too long (max 500 characters)`;
          return false;
        }
      }
    }

    // Check for duplicates
    const uniqueItems = new Set(items);
    if (uniqueItems.size !== items.length) {
      this.validationError = 'Duplicate items found - each item must be unique';
      return false;
    }

    return true;
  }

  handleInput(e) {
    const text = e.target.value;
    const items = this.textToArray(text);

    // Validate items
    if (!this.validateItems(items)) {
      this.requestUpdate();
      return;
    }

    // Emit change event with validated array
    this.dispatchEvent(new CustomEvent('list-changed', {
      detail: { value: items },
      bubbles: true,
      composed: true
    }));
  }

  getPlaceholder() {
    if (this.placeholder) {
      return this.placeholder;
    }

    switch (this.itemType) {
      case 'int':
        return 'Enter numbers, one per line...\nExample:\n80\n443\n8080';
      case 'path':
        return 'Enter paths, one per line...\nExample:\n/home/user/data\n/mnt/backup\n/var/lib/app';
      case 'string':
      default:
        return 'Enter items, one per line...\nExample:\nitem1\nitem2\nitem3';
    }
  }

  getHint() {
    switch (this.itemType) {
      case 'int':
        return 'Enter one integer per line';
      case 'path':
        return 'Enter one absolute path per line (must start with /)';
      case 'string':
      default:
        return 'Enter one item per line';
    }
  }

  render() {
    const textValue = this.arrayToText(this.value);
    const itemCount = this.value ? this.value.length : 0;

    return html`
      <div class="list-container">
        ${this.label || this.description ? html`
          <div class="list-header">
            ${this.label ? html`
              <span class="list-label">${this.label}</span>
            ` : ''}
            <span class="list-count">${itemCount} item${itemCount !== 1 ? 's' : ''}</span>
          </div>
        ` : ''}

        ${this.description ? html`
          <div class="list-description">${this.description}</div>
        ` : ''}

        <textarea
          .value=${textValue}
          placeholder="${this.getPlaceholder()}"
          ?disabled=${this.disabled}
          @input=${this.handleInput}
          rows="5"
        ></textarea>

        <div class="list-hint">${this.getHint()}</div>

        ${this.validationError ? html`
          <div class="validation-error">⚠️ ${this.validationError}</div>
        ` : ''}
      </div>
    `;
  }
}

customElements.define('list-input', ListInput);
