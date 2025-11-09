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
      border: 1px solid #e5e5e7;
      border-radius: 8px;
      overflow: hidden;
    }

    table {
      width: 100%;
      border-collapse: collapse;
    }

    thead {
      background: #f5f5f7;
    }

    th {
      padding: 12px 16px;
      text-align: left;
      font-size: 12px;
      font-weight: 600;
      color: #86868b;
      text-transform: uppercase;
      letter-spacing: 0.5px;
    }

    td {
      padding: 12px 16px;
      border-top: 1px solid #e5e5e7;
      font-size: 14px;
      color: #1d1d1f;
    }

    tr:hover {
      background: #fafafa;
    }

    .actions-cell {
      text-align: right;
      white-space: nowrap;
    }

    .btn-icon {
      background: none;
      border: none;
      color: #667eea;
      cursor: pointer;
      padding: 4px 8px;
      font-size: 16px;
      transition: opacity 0.2s;
    }

    .btn-icon:hover {
      opacity: 0.7;
    }

    .btn-icon.delete {
      color: #ff3b30;
    }

    .empty-state {
      padding: 40px;
      text-align: center;
      color: #86868b;
    }

    .add-row-btn {
      width: 100%;
      padding: 12px;
      background: #f5f5f7;
      border: none;
      color: #667eea;
      font-size: 14px;
      font-weight: 500;
      cursor: pointer;
      transition: background 0.2s;
    }

    .add-row-btn:hover {
      background: #ebebed;
    }

    /* Modal for editing */
    .modal-overlay {
      position: fixed;
      top: 0;
      left: 0;
      right: 0;
      bottom: 0;
      background: rgba(0, 0, 0, 0.5);
      display: flex;
      align-items: center;
      justify-content: center;
      z-index: 1000;
    }

    .modal {
      background: white;
      border-radius: 12px;
      padding: 24px;
      max-width: 500px;
      width: 90%;
      box-shadow: 0 8px 24px rgba(0, 0, 0, 0.2);
    }

    .modal-header {
      margin: 0 0 20px 0;
      font-size: 20px;
      font-weight: 600;
      color: #1d1d1f;
    }

    .modal-body {
      margin-bottom: 24px;
    }

    .modal-field {
      margin-bottom: 16px;
    }

    .modal-field label {
      display: block;
      font-size: 14px;
      font-weight: 500;
      color: #1d1d1f;
      margin-bottom: 6px;
    }

    .modal-field input,
    .modal-field select {
      width: 100%;
      padding: 10px 12px;
      font-size: 14px;
      border: 1px solid #d2d2d7;
      border-radius: 8px;
      font-family: inherit;
    }

    .modal-field input:focus,
    .modal-field select:focus {
      outline: none;
      border-color: #667eea;
    }

    .modal-actions {
      display: flex;
      gap: 12px;
      justify-content: flex-end;
    }

    .btn {
      padding: 10px 20px;
      border-radius: 8px;
      border: 1px solid #d2d2d7;
      background: white;
      color: #1d1d1f;
      font-size: 14px;
      font-weight: 500;
      cursor: pointer;
      transition: all 0.2s;
    }

    .btn:hover {
      background: #f5f5f7;
    }

    .btn-primary {
      background: #667eea;
      color: white;
      border-color: #667eea;
    }

    .btn-primary:hover {
      background: #5568d3;
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
    // Create empty row based on columns
    this.editingRow = {};
    this.columns.forEach(col => {
      if (col.type === 'boolean') {
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
              <div class="modal-field">
                <label>${col.label}</label>
                ${col.type === 'boolean' ? html`
                  <input
                    type="checkbox"
                    .checked=${this.editingRow[col.key]}
                    @change=${(e) => this.handleFieldChange(col.key, e.target.checked)}
                  />
                ` : html`
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
