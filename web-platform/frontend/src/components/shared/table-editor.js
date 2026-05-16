import { LitElement, html, css } from 'lit';

/**
 * Table editor component for list-based configuration
 * Supports add, edit, delete operations
 */
class TableEditor extends LitElement {
  static properties = {
    columns: { type: Array },
    data: { type: Array },
    addLabel: { type: String }
  };

  static styles = css`
    :host {
      display: block;
    }

    .table-container {
      border: 1px solid var(--hf-border);
      border-radius: 8px;
      overflow: hidden;
      background: var(--hf-surface);
    }

    table {
      width: 100%;
      border-collapse: collapse;
    }

    thead {
      background: var(--hf-surface-2);
    }

    th {
      padding: 10px 16px;
      text-align: left;
      font-size: 11px;
      font-weight: 600;
      color: var(--hf-text-muted);
      text-transform: uppercase;
      letter-spacing: 0.06em;
      border-bottom: 1px solid var(--hf-border);
    }

    td {
      padding: 11px 16px;
      border-top: 1px solid var(--hf-border);
      font-size: 13px;
      color: var(--hf-text);
    }

    tr:hover {
      background: var(--hf-surface-2);
    }

    .actions-cell {
      text-align: right;
      white-space: nowrap;
    }

    .btn-icon {
      background: none;
      border: none;
      color: var(--hf-accent);
      cursor: pointer;
      padding: 4px 8px;
      font-size: 15px;
      transition: opacity 0.15s;
    }

    .btn-icon:hover {
      opacity: 0.7;
    }

    .btn-icon.delete {
      color: var(--hf-err);
    }

    .empty-state {
      padding: 40px;
      text-align: center;
      color: var(--hf-text-muted);
    }

    .add-row-btn {
      width: 100%;
      padding: 11px;
      background: var(--hf-surface-2);
      border: none;
      border-top: 1px solid var(--hf-border);
      color: var(--hf-accent);
      font-size: 13px;
      font-weight: 500;
      cursor: pointer;
      transition: background 0.15s;
    }

    .add-row-btn:hover {
      background: var(--hf-surface-3);
    }

    /* Modal for editing */
    .modal-overlay {
      position: fixed;
      top: 0;
      left: 0;
      right: 0;
      bottom: 0;
      background: rgba(0, 0, 0, 0.7);
      display: flex;
      align-items: center;
      justify-content: center;
      z-index: 1000;
      backdrop-filter: blur(4px);
    }

    .modal {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border);
      border-radius: 10px;
      padding: 24px;
      max-width: 500px;
      width: 90%;
      box-shadow: var(--hf-shadow-lg);
      color: var(--hf-text);
    }

    .modal-header {
      margin: 0 0 20px 0;
      font-size: 18px;
      font-weight: 600;
      color: var(--hf-text);
    }

    .modal-body {
      margin-bottom: 24px;
    }

    .modal-field {
      margin-bottom: 16px;
    }

    .modal-field label {
      display: block;
      font-size: 13px;
      font-weight: 500;
      color: var(--hf-text);
      margin-bottom: 6px;
    }

    .modal-field.boolean {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .modal-field.boolean label {
      margin: 0;
      order: 2;
    }

    .modal-field.boolean input[type="checkbox"] {
      margin: 0;
      width: 16px;
      height: 16px;
      flex-shrink: 0;
    }

    .modal-field input,
    .modal-field select {
      width: 100%;
      padding: 9px 12px;
      font-size: 13px;
      background: var(--hf-bg);
      color: var(--hf-text);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      font-family: inherit;
      transition: border-color 0.15s, box-shadow 0.15s;
    }

    .modal-field input:focus,
    .modal-field select:focus {
      outline: none;
      border-color: var(--hf-accent);
      box-shadow: 0 0 0 3px var(--hf-focus-ring);
    }

    .modal-actions {
      display: flex;
      gap: 10px;
      justify-content: flex-end;
    }

    .btn {
      padding: 9px 16px;
      border-radius: 6px;
      border: 1px solid var(--hf-border-2);
      background: var(--hf-surface-2);
      color: var(--hf-text);
      font-size: 13px;
      font-weight: 500;
      cursor: pointer;
      transition: all 0.15s;
    }

    .btn:hover {
      background: var(--hf-surface-3);
      border-color: var(--hf-text-subtle);
    }

    .btn-primary {
      background: var(--hf-accent);
      color: white;
      border-color: var(--hf-accent);
    }

    .btn-primary:hover {
      background: var(--hf-accent-hover);
      border-color: var(--hf-accent-hover);
    }
  `;

  constructor() {
    super();
    this.columns = [];
    this.data = [];
    this.addLabel = 'Add Row';
    this.editingRow = null;
    this.editingIndex = -1;
    this.showModal = false;
  }

  openAddModal() {
    // Create empty row based on columns. A column can specify an
    // explicit `default` to override the type-based fallback.
    this.editingRow = {};
    this.columns.forEach(col => {
      if (col.default !== undefined) {
        this.editingRow[col.key] = col.default;
      } else if (col.type === 'boolean') {
        this.editingRow[col.key] = false;
      } else {
        this.editingRow[col.key] = '';
      }
    });
    this.editingIndex = -1;
    this.showModal = true;
    this.requestUpdate();
  }

  openEditModal(row, index) {
    this.editingRow = { ...row };
    this.editingIndex = index;
    this.showModal = true;
    this.requestUpdate();
  }

  closeModal() {
    this.showModal = false;
    this.editingRow = null;
    this.editingIndex = -1;
    this.requestUpdate();
  }

  saveRow() {
    const newData = [...this.data];

    if (this.editingIndex >= 0) {
      // Edit existing row
      newData[this.editingIndex] = this.editingRow;
    } else {
      // Add new row
      newData.push(this.editingRow);
    }

    this.dispatchEvent(new CustomEvent('data-change', {
      detail: { data: newData },
      bubbles: true,
      composed: true
    }));

    this.closeModal();
  }

  deleteRow(index) {
    if (confirm('Are you sure you want to delete this row?')) {
      const newData = this.data.filter((_, i) => i !== index);

      this.dispatchEvent(new CustomEvent('data-change', {
        detail: { data: newData },
        bubbles: true,
        composed: true
      }));
    }
  }

  handleFieldChange(key, value) {
    this.editingRow[key] = value;
  }

  renderCell(row, column) {
    const value = row[column.key];

    if (column.type === 'boolean') {
      return value ? '✓' : '✗';
    }

    return value || '-';
  }

  renderEditModal() {
    if (!this.showModal || !this.editingRow) {
      return '';
    }

    return html`
      <div class="modal-overlay" @click=${this.closeModal}>
        <div class="modal" @click=${(e) => e.stopPropagation()}>
          <h3 class="modal-header">
            ${this.editingIndex >= 0 ? 'Edit Row' : 'Add New Row'}
          </h3>

          <div class="modal-body">
            ${this.columns.map(col => html`
              <div class="modal-field ${col.type === 'boolean' ? 'boolean' : ''}">
                ${col.type === 'boolean' ? html`
                  <input
                    type="checkbox"
                    .checked=${this.editingRow[col.key]}
                    @change=${(e) => this.handleFieldChange(col.key, e.target.checked)}
                  />
                  <label>${col.label}</label>
                ` : html`
                  <label>${col.label}</label>
                  <input
                    type="${col.type || 'text'}"
                    .value=${this.editingRow[col.key]}
                    @input=${(e) => this.handleFieldChange(col.key, e.target.value)}
                    placeholder="${col.placeholder || ''}"
                  />
                `}
              </div>
            `)}
          </div>

          <div class="modal-actions">
            <button class="btn" @click=${this.closeModal}>Cancel</button>
            <button class="btn btn-primary" @click=${this.saveRow}>Save</button>
          </div>
        </div>
      </div>
    `;
  }

  render() {
    return html`
      <div class="table-container">
        <table>
          <thead>
            <tr>
              ${this.columns.map(col => html`<th>${col.label}</th>`)}
              <th style="width: 100px;">Actions</th>
            </tr>
          </thead>
          <tbody>
            ${this.data.length === 0 ? html`
              <tr>
                <td colspan="${this.columns.length + 1}" class="empty-state">
                  No items yet. Click "${this.addLabel}" to add one.
                </td>
              </tr>
            ` : this.data.map((row, index) => html`
              <tr>
                ${this.columns.map(col => html`
                  <td>${this.renderCell(row, col)}</td>
                `)}
                <td class="actions-cell">
                  <button
                    class="btn-icon"
                    @click=${() => this.openEditModal(row, index)}
                    title="Edit"
                  >
                    ✏️
                  </button>
                  <button
                    class="btn-icon delete"
                    @click=${() => this.deleteRow(index)}
                    title="Delete"
                  >
                    🗑️
                  </button>
                </td>
              </tr>
            `)}
          </tbody>
        </table>

        <button class="add-row-btn" @click=${this.openAddModal}>
          + ${this.addLabel}
        </button>
      </div>

      ${this.renderEditModal()}
    `;
  }
}

customElements.define('table-editor', TableEditor);
