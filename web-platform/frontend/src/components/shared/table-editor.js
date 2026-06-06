import { LitElement, html, css } from 'lit';
import { confirmDialog } from './confirm-dialog.js';
import './file-browser.js';
import './tag-input.js';

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
    neutralBooleans: { type: Boolean },
    // The deployed (last-applied) rows, in the SAME display shape as `data`
    // (the parent maps both through the same transform). A `data` row not
    // present here (by value) is flagged as an undeployed add/change. When
    // null/omitted, no row highlighting is done (backward compatible).
    appliedData: { type: Array },
    // Optional stable-identity column (e.g. "label"). When set, a row whose
    // identity still exists is treated as a MODIFICATION (highlighted amber by
    // _rowUndeployed), not a remove+add. Without it, rows match by whole value.
    rowKey: { type: String },
    // Internal state for the path-column file picker.
    _browserOpen: { state: true },
    _browseFieldKey: { state: true },
    _browseRoot: { state: true },
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

    /* Phones: halve the horizontal cell padding so multi-column tables
       (e.g. External Proxies) show a small gap between columns instead
       of a wide one, and less of the wide table sits off-screen. */
    @media (max-width: 600px) {
      th { padding: 10px 8px; }
      td { padding: 11px 8px; }
    }

    tr:hover {
      background: var(--hf-surface-2);
    }

    /* Row whose value differs from the deployed config (added or changed but
       not yet applied). Amber left bar + soft tint — matches the per-field
       highlight; amber = pending, green stays the Apply action. Static. */
    tr.row-undeployed td {
      background: var(--hf-warn-soft);
    }
    tr.row-undeployed td:first-child {
      box-shadow: inset 3px 0 0 0 var(--hf-warn);
    }

    /* Removed-but-not-yet-applied row: struck through, dimmed, amber bar.
       The actions cell (Restore button) is exempt from the strike-through. */
    tr.row-removed td {
      background: var(--hf-warn-soft);
      color: var(--hf-text-subtle);
      text-decoration: line-through;
    }
    tr.row-removed td.actions-cell {
      text-decoration: none;
    }
    tr.row-removed td:first-child {
      box-shadow: inset 3px 0 0 0 var(--hf-warn);
    }

    /* Modal checkbox is wrapped in its <label> so the text toggles it. */
    .modal-field.boolean label {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      cursor: pointer;
    }

    /* Boolean-column cell markers: green check / red cross. */
    .bool-yes { color: var(--hf-accent); font-weight: 600; }
    .bool-no  { color: var(--hf-err);    font-weight: 600; }
    /* Neutral variant — "false" is just a choice here, not a fault. */
    .bool-no.bool-neutral { color: var(--hf-text-muted); }

    /* Boolean columns render a single glyph — shrink them to content
       and let the header text wrap rather than stretch the column (and
       the whole table) to fit a long header on one line.
       width:1px (a sub-min-content length, NOT a percentage) collapses
       the column to its longest word. A percentage here (the old 1%)
       resolves against the table max-content width that the table
       min-width:max-content rule is simultaneously deriving from the
       columns — and the feedback loop balloons the table to thousands
       of px wide on any table that has boolean columns (e.g. External
       Proxies). Keep this a length, never a percent. */
    th.col-bool, td.col-bool {
      width: 1px;
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
      /* Inset so a tall modal never touches the screen edges, and so the
         max-height cap below leaves a visible margin on short/phone
         viewports. box-sizing keeps the padding inside the fixed box. */
      padding: 16px;
      box-sizing: border-box;
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
      /* Cap height to the viewport (overlay adds 16px inset) and lay the
         modal out as a column so the header + action buttons stay pinned
         while only the field list scrolls. Without this a form with many
         fields grows past the screen and the centered overlay clips its
         top and bottom with no way to reach them — the regression that
         long per-field descriptions introduced on phones. */
      max-height: calc(100vh - 32px);
      box-sizing: border-box;
      display: flex;
      flex-direction: column;
    }

    .modal-header {
      margin: 0 0 20px 0;
      font-size: 18px;
      font-weight: 600;
      color: var(--hf-text);
      flex-shrink: 0;
    }

    .modal-body {
      margin-bottom: 24px;
      /* Scroll the field list, not the whole modal. min-height:0 lets a
         flex child actually shrink below its content height so overflow
         engages. The negative margin + matching padding bleed the
         scrollbar to the modal edge while keeping focus rings from being
         clipped. */
      overflow-y: auto;
      flex: 1 1 auto;
      min-height: 0;
      margin-left: -24px;
      margin-right: -24px;
      padding-left: 24px;
      padding-right: 24px;
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
      /* Let an optional .field-desc wrap onto its own full-width line
         below the checkbox+label row instead of crowding beside it. */
      flex-wrap: wrap;
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

    /* Optional helper text under a field in the edit modal (col.description). */
    .modal-field .field-desc {
      display: block;
      font-size: 12px;
      line-height: 1.4;
      color: var(--hf-text-muted);
      margin-top: 4px;
    }

    .modal-field.boolean .field-desc {
      flex-basis: 100%;
      /* The checkbox row's <label> carries order:2, so order it after
         to keep the helper text below the checkbox, not above it. */
      order: 3;
      margin-top: 6px;
    }

    /* Path-type column: text input + Browse button side-by-side. Matches the
       pattern used in developers-module's local-path picker. */
    .modal-field .input-with-browse {
      display: flex;
      gap: 8px;
      align-items: center;
    }
    .modal-field .input-with-browse input { flex: 1; }

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
      /* Stay pinned at the modal's bottom edge while .modal-body scrolls. */
      flex-shrink: 0;
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
    this.appliedData = null;
    this._browserOpen = false;
    this._browseFieldKey = '';
    this._browseRoot = '';
    this.rowKey = null;
  }

  // Stable JSON key for value-equality that ignores object key order (the
  // parent builds `data` and `appliedData` from the same transform, but the
  // underlying stored objects may serialize keys in a different order).
  _stableKey(v) {
    return JSON.stringify(v, (k, val) =>
      (val && typeof val === 'object' && !Array.isArray(val))
        ? Object.keys(val).sort().reduce((o, kk) => { o[kk] = val[kk]; return o; }, {})
        : val);
  }

  // True when `row` is not present (by value) in the deployed `appliedData`,
  // i.e. it was added or changed since the last apply. No baseline → false.
  _rowUndeployed(row) {
    if (!Array.isArray(this.appliedData)) return false;
    const key = this._stableKey(row);
    return !this.appliedData.some(a => this._stableKey(a) === key);
  }

  // Deployed rows no longer present in `data` — removed but not yet applied.
  // Rendered as struck-through ghost rows so a removal stays visible (and
  // restorable) until Apply.
  _removedRows() {
    if (!Array.isArray(this.appliedData) || !Array.isArray(this.data)) return [];
    // With a stable identity column, a row whose identity still exists is a
    // MODIFICATION (shown amber by _rowUndeployed), not a removal — only
    // entries whose identity is gone get ghosted. Without rowKey, fall back to
    // whole-value matching (a modify then unavoidably looks like remove+add).
    if (this.rowKey) {
      const liveIds = new Set(this.data.map(r => r && r[this.rowKey]));
      return this.appliedData.filter(a => a && !liveIds.has(a[this.rowKey]));
    }
    const live = new Set(this.data.map(r => this._stableKey(r)));
    return this.appliedData.filter(a => !live.has(this._stableKey(a)));
  }

  // Re-add a removed (ghost) row to the live list.
  restoreRow(row) {
    this.dispatchEvent(new CustomEvent('data-change', {
      detail: { data: [...this.data, row] },
      bubbles: true,
      composed: true
    }));
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

  // Open the shared file-browser for the given path-type column. The browser
  // overlays the edit modal (its z-index is higher); on selection it writes
  // back via handleFieldChange and closes itself.
  _openBrowse(key, rootPath) {
    this._browseFieldKey = key;
    this._browseRoot = rootPath || '';
    this._browserOpen = true;
  }

  _onBrowsePicked(e) {
    this.handleFieldChange(this._browseFieldKey, e.detail.path);
    this._browserOpen = false;
  }

  _onBrowseClose() {
    this._browserOpen = false;
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

  handleFieldChange(key, value, inputType) {
    // For numeric columns, coerce the DOM string back to an integer or null so
    // the JSON we save is clean (`null` for empty, an integer for a value),
    // not a string that the Nix `nullOr int` option will reject.
    if (inputType === 'number') {
      if (value === '' || value == null) {
        this.editingRow[key] = null;
      } else {
        const n = parseInt(value, 10);
        this.editingRow[key] = Number.isNaN(n) ? null : n;
      }
      return;
    }
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

    // Derive the modal title from `addLabel` so the caller doesn't see a
    // generic "Add New Row" / "Edit Row". e.g. addLabel="Add NFS share" →
    // "Add NFS share" / "Edit NFS share". The default "Add Row" still works.
    const noun = (this.addLabel || 'Add Row').replace(/^Add\s+/i, '');
    const modalTitle = this.editingIndex >= 0 ? `Edit ${noun}` : this.addLabel;

    return html`
      <div class="modal-overlay" @click=${this.closeModal}>
        <div class="modal" @click=${(e) => e.stopPropagation()}>
          <h3 class="modal-header">${modalTitle}</h3>

          <div class="modal-body">
            ${this.columns.map(col => {
              // modalLabel lets a terse table header (e.g. "No KA") expand
              // to a readable label in the edit modal ("Disable keep-alive");
              // falls back to the column label when unset.
              const fieldLabel = col.modalLabel || col.label;
              return html`
              <div class="modal-field ${col.type === 'boolean' ? 'boolean' : ''}">
                ${col.type === 'boolean' ? html`
                  <label>
                    <input
                      type="checkbox"
                      .checked=${this.editingRow[col.key]}
                      @change=${(e) => this.handleFieldChange(col.key, e.target.checked)}
                    />
                    <span>${fieldLabel}</span>
                  </label>
                ` : col.type === 'path' ? html`
                  <label>${fieldLabel}</label>
                  <div class="input-with-browse">
                    <input
                      type="text"
                      .value=${this.editingRow[col.key] || ''}
                      @input=${(e) => this.handleFieldChange(col.key, e.target.value)}
                      placeholder="${col.placeholder || ''}"
                    />
                    <button type="button" class="btn-row"
                            @click=${() => this._openBrowse(col.key, col.rootPath)}>Browse…</button>
                  </div>
                ` : col.type === 'tags' ? html`
                  <label>${fieldLabel}</label>
                  <tag-input
                    .value=${this.editingRow[col.key] || ''}
                    placeholder=${col.placeholder || ''}
                    @change=${(e) => this.handleFieldChange(col.key, e.detail.value)}
                  ></tag-input>
                ` : col.type === 'select' ? html`
                  <label>${fieldLabel}</label>
                  <select
                    .value=${this.editingRow[col.key] ?? ''}
                    @change=${(e) => this.handleFieldChange(col.key, e.target.value)}
                  >
                    ${(col.options || []).map(opt => {
                      const value = typeof opt === 'object' ? opt.value : opt;
                      const label = typeof opt === 'object' ? opt.label : opt;
                      return html`<option value=${value} ?selected=${this.editingRow[col.key] === value}>${label}</option>`;
                    })}
                  </select>
                ` : html`
                  <label>${fieldLabel}</label>
                  <input
                    type="${col.type || 'text'}"
                    .value=${this.editingRow[col.key] ?? ''}
                    @input=${(e) => this.handleFieldChange(col.key, e.target.value, col.type)}
                    placeholder="${col.placeholder || ''}"
                  />
                `}
                ${col.description ? html`<small class="field-desc">${col.description}</small>` : ''}
              </div>
              `;
            })}
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
    const removed = this._removedRows();
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
            ${this.data.length === 0 && removed.length === 0 ? html`
              <tr>
                <td colspan="${this.columns.length + 1}" class="empty-state">
                  No items yet. Click "${this.addLabel}" to add one.
                </td>
              </tr>
            ` : ''}
            ${this.data.map((row, index) => html`
              <tr class=${this._rowUndeployed(row) ? 'row-undeployed' : ''}>
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
            ${removed.map(row => html`
              <tr class="row-removed" title="Removed — Apply to deploy">
                ${this.columns.map(col => html`
                  <td class=${col.type === 'boolean' ? 'col-bool' : ''}>${this.renderCell(row, col)}</td>
                `)}
                <td class="actions-cell">
                  <span class="row-actions">
                    <button
                      class="btn-row"
                      title="Restore this entry"
                      @click=${() => this.restoreRow(row)}
                    >
                      ↩ Restore
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

      ${this._browserOpen ? html`
        <file-browser
          ?open=${this._browserOpen}
          .currentPath=${(this.editingRow && this.editingRow[this._browseFieldKey]) || this._browseRoot || '/'}
          .rootPath=${this._browseRoot}
          @path-selected=${this._onBrowsePicked}
          @close=${this._onBrowseClose}
        ></file-browser>` : ''}
    `;
  }
}

customElements.define('table-editor', TableEditor);
