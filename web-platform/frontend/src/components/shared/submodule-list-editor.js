import { LitElement, html, css } from 'lit';
import '../admin/service-option-input.js';

/**
 * Submodule list editor component
 * For editing listOf submodule types (e.g., frigate cameras, mediawiki sites)
 * Each item is a collapsible card with fields based on submodule-fields metadata
 */
class SubmoduleListEditor extends LitElement {
  static properties = {
    label: { type: String },
    description: { type: String },
    submoduleFields: { type: Array },  // Array of field definitions
    value: { type: Array },  // Array of submodule objects
    disabled: { type: Boolean },
    expandedItems: { type: Object, state: true }  // Track which items are expanded
  };

  static styles = css`
    :host {
      display: block;
      margin-bottom: 16px;
    }

    .list-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 12px;
    }

    .list-title {
      font-size: 14px;
      font-weight: 500;
      color: #1d1d1f;
    }

    .list-description {
      font-size: 12px;
      color: #86868b;
      margin-bottom: 12px;
    }

    .btn-add {
      padding: 8px 16px;
      background: #667eea;
      color: white;
      border: none;
      border-radius: 6px;
      font-size: 13px;
      font-weight: 500;
      cursor: pointer;
      transition: background 0.2s;
    }

    .btn-add:hover:not(:disabled) {
      background: #5568d3;
    }

    .btn-add:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }

    .items-container {
      display: flex;
      flex-direction: column;
      gap: 12px;
    }

    .item-card {
      border: 1px solid #d2d2d7;
      border-radius: 8px;
      background: white;
      overflow: hidden;
    }

    .item-card.disabled {
      opacity: 0.6;
    }

    .item-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 12px 16px;
      background: #f5f5f7;
      cursor: pointer;
      user-select: none;
    }

    .item-header:hover {
      background: #e5e5e7;
    }

    .item-title-section {
      display: flex;
      align-items: center;
      gap: 12px;
      flex: 1;
    }

    .expand-icon {
      font-size: 16px;
      transition: transform 0.2s;
    }

    .expand-icon.expanded {
      transform: rotate(90deg);
    }

    .item-title {
      font-size: 14px;
      font-weight: 500;
      color: #1d1d1f;
    }

    .item-subtitle {
      font-size: 12px;
      color: #86868b;
      margin-left: 8px;
    }

    .item-actions {
      display: flex;
      gap: 8px;
    }

    .btn-remove {
      padding: 6px 12px;
      background: #ff3b30;
      color: white;
      border: none;
      border-radius: 4px;
      font-size: 12px;
      cursor: pointer;
      transition: background 0.2s;
    }

    .btn-remove:hover:not(:disabled) {
      background: #e02020;
    }

    .btn-remove:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }

    .item-content {
      padding: 16px;
      display: none;
      flex-direction: column;
      gap: 12px;
    }

    .item-content.expanded {
      display: flex;
    }

    .empty-state {
      padding: 32px;
      text-align: center;
      color: #86868b;
      font-style: italic;
      border: 1px dashed #d2d2d7;
      border-radius: 8px;
    }

    .validation-error {
      padding: 8px 12px;
      background: #fff3f3;
      border: 1px solid #ffccc7;
      border-radius: 6px;
      color: #d32f2f;
      font-size: 12px;
      margin-top: 8px;
    }
  `;

  constructor() {
    super();
    this.label = '';
    this.description = '';
    this.submoduleFields = [];
    this.value = [];
    this.disabled = false;
    this.expandedItems = {};
  }

  handleAddItem() {
    console.log('handleAddItem called');
    console.log('submoduleFields:', this.submoduleFields);
    console.log('current value:', this.value);

    // Create new item with default values
    const newItem = {};
    this.submoduleFields.forEach(field => {
      newItem[field.path] = field.default !== undefined ? field.default : null;
    });

    console.log('newItem created:', newItem);
    const newValue = [...this.value, newItem];
    console.log('newValue:', newValue);

    this.expandedItems = { ...this.expandedItems, [newValue.length - 1]: true };
    this.handleChange(newValue);
  }

  handleRemoveItem(index) {
    const newValue = this.value.filter((_, i) => i !== index);
    // Update expanded items indices
    const newExpandedItems = {};
    Object.keys(this.expandedItems).forEach(key => {
      const idx = parseInt(key);
      if (idx < index) {
        newExpandedItems[idx] = this.expandedItems[key];
      } else if (idx > index) {
        newExpandedItems[idx - 1] = this.expandedItems[key];
      }
    });
    this.expandedItems = newExpandedItems;
    this.handleChange(newValue);
  }

  handleToggleExpand(index) {
    this.expandedItems = {
      ...this.expandedItems,
      [index]: !this.expandedItems[index]
    };
  }

  handleFieldChange(index, fieldPath, fieldValue) {
    const newValue = [...this.value];
    newValue[index] = {
      ...newValue[index],
      [fieldPath]: fieldValue
    };
    this.handleChange(newValue);
  }

  handleChange(value) {
    console.log('handleChange called with value:', value);
    this.dispatchEvent(new CustomEvent('list-changed', {
      detail: { value },
      bubbles: true,
      composed: true
    }));
    console.log('list-changed event dispatched');
  }

  getItemTitle(item, index) {
    // Try to find a good display field (name, subdomain, etc.)
    const titleField = item.name || item.subdomain || item.label || `Item ${index + 1}`;
    return titleField;
  }

  getItemSubtitle(item) {
    // Show additional identifying info if available
    if (item.path) return item.path;
    if (item.subdomain) return `@${item.subdomain}`;
    return '';
  }

  validateField(field, value) {
    if (field.required && (value === null || value === undefined || value === '')) {
      return `${field.path} is required`;
    }
    return null;
  }

  renderField(field, item, index) {
    const currentValue = item[field.path];
    const error = this.validateField(field, currentValue);

    return html`
      <service-option-input
        .optionKey=${field.path}
        .label=${field.path.replace(/-/g, ' ').replace(/\b\w/g, l => l.toUpperCase())}
        .description=${field.description || ''}
        .type=${field.type}
        .defaultValue=${field.default}
        .currentValue=${currentValue}
        .enumValues=${field['enum-values'] || []}
        .submoduleFields=${field['submodule-fields'] || []}
        ?disabled=${this.disabled}
        @option-changed=${(e) => {
          e.stopPropagation();
          this.handleFieldChange(index, e.detail.optionKey, e.detail.value);
        }}
      ></service-option-input>
      ${error ? html`<div class="validation-error">⚠️ ${error}</div>` : ''}
    `;
  }

  renderItem(item, index) {
    const isExpanded = this.expandedItems[index] || false;
    const title = this.getItemTitle(item, index);
    const subtitle = this.getItemSubtitle(item);

    return html`
      <div class="item-card ${this.disabled ? 'disabled' : ''}">
        <div class="item-header" @click=${() => this.handleToggleExpand(index)}>
          <div class="item-title-section">
            <span class="expand-icon ${isExpanded ? 'expanded' : ''}">▶</span>
            <span class="item-title">${title}</span>
            ${subtitle ? html`<span class="item-subtitle">${subtitle}</span>` : ''}
          </div>
          <div class="item-actions" @click=${(e) => e.stopPropagation()}>
            <button
              class="btn-remove"
              @click=${() => this.handleRemoveItem(index)}
              ?disabled=${this.disabled}
            >
              Remove
            </button>
          </div>
        </div>

        <div class="item-content ${isExpanded ? 'expanded' : ''}">
          ${this.submoduleFields.map(field => this.renderField(field, item, index))}
        </div>
      </div>
    `;
  }

  render() {
    return html`
      <div class="list-header">
        <div class="list-title">${this.label}</div>
        <button
          class="btn-add"
          @click=${this.handleAddItem}
          ?disabled=${this.disabled}
        >
          ➕ Add Item
        </button>
      </div>

      ${this.description ? html`
        <div class="list-description">${this.description}</div>
      ` : ''}

      ${this.value.length === 0 ? html`
        <div class="empty-state">
          No items yet. Click "Add Item" to create one.
        </div>
      ` : html`
        <div class="items-container">
          ${this.value.map((item, index) => this.renderItem(item, index))}
        </div>
      `}
    `;
  }
}

customElements.define('submodule-list-editor', SubmoduleListEditor);
