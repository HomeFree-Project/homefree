import { LitElement, html, css } from 'lit';
import { createFolder } from '../../api/client.js';

/**
 * File browser modal component
 * Allows browsing server filesystem directories for path selection
 */
class FileBrowser extends LitElement {
  static properties = {
    open: { type: Boolean },
    currentPath: { type: String },
    entries: { type: Array, state: true },
    parent: { type: String, state: true },
    loading: { type: Boolean, state: true },
    error: { type: String, state: true },
    creating: { type: Boolean, state: true },
    newFolderName: { type: String, state: true },
    currentPathSelectable: { type: Boolean, state: true }
  };

  static styles = css`
    :host {
      display: none;
    }

    :host([open]) {
      display: block;
      position: fixed;
      top: 0;
      left: 0;
      right: 0;
      bottom: 0;
      z-index: 1000;
      background: rgba(0, 0, 0, 0.5);
    }

    .modal {
      position: absolute;
      top: 50%;
      left: 50%;
      transform: translate(-50%, -50%);
      background: var(--hf-surface);
      border-radius: 12px;
      box-shadow: var(--hf-shadow-lg);
      width: 90%;
      max-width: 600px;
      max-height: 80vh;
      display: flex;
      flex-direction: column;
    }

    .modal-header {
      padding: 20px;
      border-bottom: 1px solid var(--hf-border);
      display: flex;
      align-items: center;
      justify-content: space-between;
    }

    .modal-title {
      font-size: 18px;
      font-weight: 600;
      color: var(--hf-text);
    }

    .close-btn {
      background: none;
      border: none;
      font-size: 24px;
      color: var(--hf-text-muted);
      cursor: pointer;
      padding: 0;
      width: 32px;
      height: 32px;
      display: flex;
      align-items: center;
      justify-content: center;
      border-radius: 6px;
      transition: background 0.2s;
    }

    .close-btn:hover {
      background: var(--hf-surface-2);
    }

    .breadcrumb {
      padding: 12px 20px;
      background: var(--hf-surface-2);
      border-bottom: 1px solid var(--hf-border);
      font-size: 13px;
      font-family: monospace;
      color: var(--hf-text);
      overflow-x: auto;
      white-space: nowrap;
    }

    .modal-body {
      flex: 1;
      overflow-y: auto;
      padding: 0;
    }

    .directory-list {
      list-style: none;
      margin: 0;
      padding: 0;
    }

    .directory-item {
      padding: 12px 20px;
      border-bottom: 1px solid var(--hf-border);
      cursor: pointer;
      display: flex;
      align-items: center;
      gap: 12px;
      transition: background 0.2s;
    }

    .directory-item:hover {
      background: var(--hf-surface-2);
    }

    .directory-item.parent {
      background: var(--hf-surface-2);
      font-weight: 500;
    }

    .directory-item.non-selectable {
      opacity: 0.6;
    }

    .directory-item.non-selectable .directory-name {
      color: var(--hf-text-muted);
    }

    .directory-icon {
      font-size: 20px;
    }

    .directory-name {
      flex: 1;
      font-size: 14px;
      color: var(--hf-text);
    }

    .loading-indicator {
      padding: 40px;
      text-align: center;
      color: var(--hf-text-muted);
    }

    .error-message {
      padding: 20px;
      margin: 20px;
      background: rgba(239, 68, 68, 0.1);
      border: 1px solid var(--hf-err);
      border-radius: 8px;
      color: var(--hf-err);
    }

    .info-message {
      padding: 12px 20px;
      background: var(--hf-accent-soft);
      border-bottom: 1px solid var(--hf-border);
      color: var(--hf-accent);
      font-size: 13px;
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .empty-message {
      padding: 40px;
      text-align: center;
      color: var(--hf-text-muted);
      font-style: italic;
    }

    .modal-footer {
      padding: 16px 20px;
      border-top: 1px solid var(--hf-border);
      display: flex;
      gap: 12px;
      justify-content: flex-end;
    }

    .btn {
      padding: 10px 20px;
      border-radius: 8px;
      border: none;
      font-size: 14px;
      font-weight: 500;
      cursor: pointer;
      transition: all 0.2s;
    }

    .btn:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }

    .btn-cancel {
      background: var(--hf-surface-2);
      color: var(--hf-text);
    }

    .btn-cancel:hover:not(:disabled) {
      background: var(--hf-surface-3);
    }

    .btn-select {
      background: var(--hf-accent);
      color: var(--hf-text);
    }

    .btn-select:hover:not(:disabled) {
      background: var(--hf-accent-hover);
    }

    .create-folder-section {
      padding: 16px 20px;
      background: var(--hf-surface-2);
      border-bottom: 1px solid var(--hf-border);
    }

    .create-folder-form {
      display: flex;
      gap: 8px;
      align-items: stretch;
    }

    .create-folder-form input {
      flex: 1;
      padding: 8px 12px;
      font-size: 14px;
      background: var(--hf-bg);
      color: var(--hf-text);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      font-family: inherit;
    }

    .create-folder-form input::placeholder {
      color: var(--hf-text-subtle);
    }

    .create-folder-form input:focus {
      outline: none;
      border-color: var(--hf-accent);
      box-shadow: 0 0 0 3px var(--hf-focus-ring);
    }

    .create-folder-form .btn {
      padding: 8px 16px;
      white-space: nowrap;
    }

    .btn-create {
      background: var(--hf-ok);
      color: var(--hf-text);
    }

    .btn-create:hover:not(:disabled) {
      background: #0ea271;
    }

    .create-folder-toggle {
      padding: 12px 20px;
      background: var(--hf-surface-2);
      border-bottom: 1px solid var(--hf-border);
      display: flex;
      justify-content: flex-end;
    }

    .btn-toggle-create {
      padding: 8px 16px;
      background: var(--hf-surface-2);
      color: var(--hf-text);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      font-size: 13px;
      font-weight: 500;
      cursor: pointer;
      transition: all 0.2s;
    }

    .btn-toggle-create:hover:not(:disabled) {
      background: var(--hf-surface-3);
    }
  `;

  constructor() {
    super();
    this.open = false;
    this.currentPath = '/';
    this.entries = [];
    this.parent = null;
    this.loading = false;
    this.error = null;
    this.creating = false;
    this.newFolderName = '';
    this.currentPathSelectable = false;
  }

  async connectedCallback() {
    super.connectedCallback();
    if (this.open) {
      await this.loadDirectory(this.currentPath);
    }
  }

  async loadDirectory(path) {
    this.loading = true;
    this.error = null;

    try {
      const response = await fetch(`/api/filesystem/browse?path=${encodeURIComponent(path)}`);

      if (!response.ok) {
        const error = await response.json();
        throw new Error(error.detail || 'Failed to browse directory');
      }

      const data = await response.json();
      this.currentPath = data.path;
      this.entries = data.entries || [];
      this.parent = data.parent;
      this.currentPathSelectable = data.selectable || false;
    } catch (err) {
      this.error = err.message;
      console.error('Error loading directory:', err);
    } finally {
      this.loading = false;
    }
  }

  handleDirectoryClick(path) {
    this.loadDirectory(path);
  }

  handleParentClick() {
    if (this.parent) {
      this.loadDirectory(this.parent);
    }
  }

  handleSelect() {
    // Emit selected path
    this.dispatchEvent(new CustomEvent('path-selected', {
      detail: { path: this.currentPath },
      bubbles: true,
      composed: true
    }));
    this.handleClose();
  }

  handleClose() {
    this.dispatchEvent(new CustomEvent('close', {
      bubbles: true,
      composed: true
    }));
  }

  handleBackdropClick(e) {
    if (e.target === e.currentTarget) {
      this.handleClose();
    }
  }

  handleToggleCreate() {
    this.creating = !this.creating;
    this.newFolderName = '';
    this.error = null;
  }

  async handleCreateSubmit() {
    if (!this.newFolderName.trim()) {
      this.error = 'Folder name cannot be empty';
      return;
    }

    // Construct full path
    const newPath = `${this.currentPath}/${this.newFolderName.trim()}`;

    this.loading = true;
    this.error = null;

    try {
      await createFolder(newPath);

      // Success - reload directory and reset form
      this.creating = false;
      this.newFolderName = '';
      await this.loadDirectory(this.currentPath);
    } catch (err) {
      this.error = err.message;
      console.error('Error creating folder:', err);
    } finally {
      this.loading = false;
    }
  }

  handleCreateCancel() {
    this.creating = false;
    this.newFolderName = '';
    this.error = null;
  }

  render() {
    return html`
      <div class="backdrop" @click=${this.handleBackdropClick}>
        <div class="modal" @click=${(e) => e.stopPropagation()}>
          <div class="modal-header">
            <div class="modal-title">Select Directory</div>
            <button class="close-btn" @click=${this.handleClose}>×</button>
          </div>

          <div class="breadcrumb">${this.currentPath}</div>

          ${this.creating ? html`
            <div class="create-folder-section">
              <div class="create-folder-form">
                <input
                  type="text"
                  placeholder="Enter folder name..."
                  .value=${this.newFolderName}
                  @input=${(e) => this.newFolderName = e.target.value}
                  @keydown=${(e) => {
                    if (e.key === 'Enter') this.handleCreateSubmit();
                    if (e.key === 'Escape') this.handleCreateCancel();
                  }}
                  ?disabled=${this.loading}
                  autofocus
                />
                <button
                  class="btn btn-create"
                  @click=${this.handleCreateSubmit}
                  ?disabled=${this.loading || !this.newFolderName.trim()}
                >
                  Create
                </button>
                <button
                  class="btn btn-cancel"
                  @click=${this.handleCreateCancel}
                  ?disabled=${this.loading}
                >
                  Cancel
                </button>
              </div>
            </div>
          ` : html`
            <div class="create-folder-toggle">
              <button
                class="btn-toggle-create"
                @click=${this.handleToggleCreate}
                ?disabled=${this.loading}
              >
                ➕ New Folder
              </button>
            </div>
          `}

          ${!this.loading && !this.error && !this.currentPathSelectable ? html`
            <div class="info-message">
              ℹ️ This directory cannot be selected. Navigate to a whitelisted path (home, mnt, var/lib, media, srv, opt) to enable selection.
            </div>
          ` : ''}

          <div class="modal-body">
            ${this.loading ? html`
              <div class="loading-indicator">Loading...</div>
            ` : this.error ? html`
              <div class="error-message">⚠️ ${this.error}</div>
            ` : html`
              <ul class="directory-list">
                ${this.parent ? html`
                  <li class="directory-item parent" @click=${this.handleParentClick}>
                    <span class="directory-icon">⬆️</span>
                    <span class="directory-name">.. (Parent Directory)</span>
                  </li>
                ` : ''}

                ${this.entries.length === 0 ? html`
                  <div class="empty-message">No subdirectories found</div>
                ` : this.entries.map(entry => html`
                  <li
                    class="directory-item ${entry.selectable ? '' : 'non-selectable'}"
                    @click=${() => this.handleDirectoryClick(entry.path)}
                  >
                    <span class="directory-icon">${entry.selectable ? '📁' : '🔒'}</span>
                    <span class="directory-name">${entry.name}</span>
                  </li>
                `)}
              </ul>
            `}
          </div>

          <div class="modal-footer">
            <button class="btn btn-cancel" @click=${this.handleClose}>
              Cancel
            </button>
            <button
              class="btn btn-select"
              @click=${this.handleSelect}
              ?disabled=${this.loading || !this.currentPathSelectable}
            >
              Select This Directory
            </button>
          </div>
        </div>
      </div>
    `;
  }
}

customElements.define('file-browser', FileBrowser);
