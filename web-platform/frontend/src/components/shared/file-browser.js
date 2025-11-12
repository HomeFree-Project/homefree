import { LitElement, html, css } from 'lit';

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
    error: { type: String, state: true }
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
      background: white;
      border-radius: 12px;
      box-shadow: 0 8px 32px rgba(0, 0, 0, 0.3);
      width: 90%;
      max-width: 600px;
      max-height: 80vh;
      display: flex;
      flex-direction: column;
    }

    .modal-header {
      padding: 20px;
      border-bottom: 1px solid #e5e5e7;
      display: flex;
      align-items: center;
      justify-content: space-between;
    }

    .modal-title {
      font-size: 18px;
      font-weight: 600;
      color: #1d1d1f;
    }

    .close-btn {
      background: none;
      border: none;
      font-size: 24px;
      color: #86868b;
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
      background: #f5f5f7;
    }

    .breadcrumb {
      padding: 12px 20px;
      background: #f9f9f9;
      border-bottom: 1px solid #e5e5e7;
      font-size: 13px;
      font-family: monospace;
      color: #1d1d1f;
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
      border-bottom: 1px solid #f5f5f7;
      cursor: pointer;
      display: flex;
      align-items: center;
      gap: 12px;
      transition: background 0.2s;
    }

    .directory-item:hover {
      background: #f9f9f9;
    }

    .directory-item.parent {
      background: #f5f5f7;
      font-weight: 500;
    }

    .directory-icon {
      font-size: 20px;
    }

    .directory-name {
      flex: 1;
      font-size: 14px;
      color: #1d1d1f;
    }

    .loading-indicator {
      padding: 40px;
      text-align: center;
      color: #86868b;
    }

    .error-message {
      padding: 20px;
      margin: 20px;
      background: #fff3f3;
      border: 1px solid #ffccc7;
      border-radius: 8px;
      color: #d32f2f;
    }

    .empty-message {
      padding: 40px;
      text-align: center;
      color: #86868b;
      font-style: italic;
    }

    .modal-footer {
      padding: 16px 20px;
      border-top: 1px solid #e5e5e7;
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
      background: #f5f5f7;
      color: #1d1d1f;
    }

    .btn-cancel:hover:not(:disabled) {
      background: #e5e5e7;
    }

    .btn-select {
      background: #667eea;
      color: white;
    }

    .btn-select:hover:not(:disabled) {
      background: #5568d3;
    }
  `;

  constructor() {
    super();
    this.open = false;
    this.currentPath = '/home';
    this.entries = [];
    this.parent = null;
    this.loading = false;
    this.error = null;
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

  render() {
    return html`
      <div class="backdrop" @click=${this.handleBackdropClick}>
        <div class="modal" @click=${(e) => e.stopPropagation()}>
          <div class="modal-header">
            <div class="modal-title">Select Directory</div>
            <button class="close-btn" @click=${this.handleClose}>×</button>
          </div>

          <div class="breadcrumb">${this.currentPath}</div>

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
                  <li class="directory-item" @click=${() => this.handleDirectoryClick(entry.path)}>
                    <span class="directory-icon">📁</span>
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
              ?disabled=${this.loading}
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
