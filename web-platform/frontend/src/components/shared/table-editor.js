import { LitElement, html, css } from 'lit';
import { confirmDialog } from './confirm-dialog.js';

/**
 * Table editor component for list-based configuration
 * Supports add, edit, delete operations
 *
 * This is the canonical list-table pattern for the admin UI: a
 * bordered box whose TABLE scrolls horizontally on its own when too
 * wide, with the "Add" control as a fixed footer button BELOW the
 * scroll area (so it never scrolls sideways out of view). Other
 * modules with hand-rolled tables should match this shape — bordered,
 * internally-scrolling container + attached footer add button.
 */
class TableEditor extends LitElement {
  static properties = {
    columns: { type: Array },
    data: { type: Array },
    addLabel: { type: String },
    // When true, an unset boolean renders the ✗ in muted gray instead
    // of red — for tables where "false" is a neutral choice, not a fault.
    neutralBooleans: { type: Boolean }
  };

  static styles = css`
    :host {
      display: block;
    }

    /* Outer wrapper — owns the border + rounded corners so the table
       can scroll inside it while the footer add button stays put. */
    .table-editor {
      border: 1px solid var(--hf-border);
      border-radius: 8px;
      overflow: hidden;
      background: var(--hf-surface);
    }

    .table-container {
      /* Scroll horizontally rather than clip when the table is wider
         than this box (many columns). Narrow tables fit with no
         scrollbar at all — see the table min-width below. */
      overflow-x: auto;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      /* Size columns to their content; only scroll when genuinely too
         wide. A small 3-column table (e.g. Additional Domains) fits a
         phone with no horizontal scroll. */
      min-width: max-content;
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

    /* Boolean-column cell markers: green check / red cross. */
    .bool-yes { color: var(--hf-accent); font-weight: 600; }
    .bool-no  { color: var(--hf-err);    font-weight: 600; }
    /* Neutral variant — "false" is just a choice here, not a fault. */
    .bool-no.bool-neutral { color: var(--hf-text-muted); }

    /* Boolean columns render a single glyph — shrink them to content
       and let the header text wrap rather than stretch the column (and
       the whole table) to fit a long header on one line. */
    th.col-bool, td.col-bool {
      width: 1%;
      white-space: normal;
    }
    th.col-bool { text-align: center; }
    td.col-bool { text-align: center; }

    .actions-cell {
      text-align: right;
      white-space: nowrap;
    }

    .row-actions {
      display: inline-flex;
      gap: 8px;
    }

    /* Real text buttons (Edit / Delete) — clearer than glyphs and the
       same on desktop and mobile. */
    .btn-row {
      background: var(--hf-surface-2);
      border: 1px solid var(--hf-border-2);
      color: var(--hf-text);
      cursor: pointer;
      padding: 5px 12px;
      border-radius: 6px;
      font-size: 12px;
      font-weight: 500;
      font-family: inherit;
      transition: all 0.15s;
    }

    .btn-row:hover {
      background: var(--hf-surface-3);
      border-color: var(--hf-text-subtle);
    }

    .btn-row.delete {
      color: var(--hf-err);
      border-color: color-mix(in srgb, var(--hf-err) 45%, transparent);
    }

    .btn-row.delete:hover {
      background: color-mix(in srgb, var(--hf-err) 14%, transparent);
      border-color: var(--hf-err);
    }

    .empty-state {
      padding: 40px;
      text-align: center;
      color: var(--hf-text-muted);
    }

    /* Footer add button — sibling of (not inside) .table-container, so
       it stays fixed when the table scrolls horizontally. */
    .add-row-btn {
      display: block;
      width: 100%;
      padding: 11px;
      background: var(--hf-surface-2);
      border: none;
      border-top: 1px solid var(--hf-border);
      color: var(--hf-accent);
      font-size: 13px;
      font-weight: 500;
      font-family: inherit;
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
      backdrop-filter: blur(2px);
    }

    /* Opaque card with a clearly visible frame — see confirm-dialog.js
       for the rationale (lighter surface + stronger border so it reads
       distinctly against the blurred overlay). */
    .modal {
      background: var(--hf-surface-2);
      border: 1px solid var(--hf-border-2);
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
      /* border-box so the 12px right padding stays inside the field
         instead of pushing its edge past the modal content box. */
      box-sizing: border-box;
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
      color: #06281c;
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

  async deleteRow(index) {
    const ok = await confirmDialog({
      title: 'Delete entry?',
      message: 'This removes the entry from the list. The change takes effect when you click Apply.',
      confirmText: 'Delete',
      variant: 'danger',
    });
    if (!ok) return;

    const newData = this.data.filter((_, i) => i !== index);

    this.dispatchEvent(new CustomEvent('data-change', {
      detail: { data: newData },
      bubbles: true,
      composed: true
    }));
  }

  handleFieldChange(key, value) {
    this.editingRow[key] = value;
  }

  renderCell(row, column) {
    const value = row[column.key];

    if (column.type === 'boolean') {
      return value
        ? html`<span class="bool-yes">✓</span>`
        : html`<span class="bool-no ${this.neutralBooleans ? 'bool-neutral' : ''}">✗</span>`;
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
      <div class="table-editor">
        <div class="table-container">
        <table>
          <thead>
            <tr>
              ${this.columns.map(col => html`<th class=${col.type === 'boolean' ? 'col-bool' : ''}>${col.label}</th>`)}
              <th style="text-align: right;">Actions</th>
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
                  <td class=${col.type === 'boolean' ? 'col-bool' : ''}>${this.renderCell(row, col)}</td>
                `)}
                <td class="actions-cell">
                  <span class="row-actions">
                    <button
                      class="btn-row"
                      @click=${() => this.openEditModal(row, index)}
                    >
                      Edit
                    </button>
                    <button
                      class="btn-row delete"
                      @click=${() => this.deleteRow(index)}
                    >
                      Delete
                    </button>
                  </span>
                </td>
              </tr>
            `)}
          </tbody>
        </table>
        </div>

        <button class="add-row-btn" @click=${this.openAddModal}>
          + ${this.addLabel}
        </button>
      </div>

      ${this.renderEditModal()}
    `;
  }
}

customElements.define('table-editor', TableEditor);
