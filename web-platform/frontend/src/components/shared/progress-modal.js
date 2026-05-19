import { LitElement, html, css } from 'lit';

/**
 * Progress modal component for showing long-running operations
 * Non-dismissible modal with spinner and status messages
 */
class ProgressModal extends LitElement {
  static properties = {
    visible: { type: Boolean },
    title: { type: String },
    message: { type: String },
    status: { type: String }, // 'progress', 'success', 'error', 'confirm'
    details: { type: Array },
    canClose: { type: Boolean },
    confirmText: { type: String },
    cancelText: { type: String },
    confirmCallback: { type: Object },
    cancelCallback: { type: Object },
    confirmVariant: { type: String } // 'primary' or 'danger'
  };

  static styles = css`
    :host {
      display: block;
    }

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
      z-index: 10000;
      animation: fadeIn 0.2s ease-in;
      backdrop-filter: blur(4px);
    }

    @keyframes fadeIn {
      from { opacity: 0; }
      to { opacity: 1; }
    }

    .modal {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border);
      border-radius: 12px;
      padding: 32px;
      max-width: 500px;
      width: 90%;
      box-shadow: var(--hf-shadow-lg);
      animation: slideUp 0.3s ease-out;
      color: var(--hf-text);
    }

    @keyframes slideUp {
      from {
        transform: translateY(20px);
        opacity: 0;
      }
      to {
        transform: translateY(0);
        opacity: 1;
      }
    }

    .modal-header {
      margin: 0 0 24px 0;
      font-size: 20px;
      font-weight: 600;
      color: var(--hf-text);
      text-align: center;
      letter-spacing: -0.01em;
    }

    .modal-body {
      text-align: center;
    }

    .spinner {
      width: 56px;
      height: 56px;
      margin: 0 auto 20px;
      border: 4px solid var(--hf-border);
      border-top-color: var(--hf-accent);
      border-radius: 50%;
      animation: spin 1s linear infinite;
    }

    @keyframes spin {
      to { transform: rotate(360deg); }
    }

    .status-icon {
      width: 56px;
      height: 56px;
      margin: 0 auto 20px;
      border-radius: 50%;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 28px;
    }

    .status-icon.success {
      background: var(--hf-ok);
      color: white;
    }

    .status-icon.error {
      background: var(--hf-err);
      color: white;
    }

    .message {
      font-size: 14px;
      color: var(--hf-text-muted);
      margin-bottom: 20px;
      line-height: 1.5;
    }

    .details {
      background: var(--hf-bg);
      border: 1px solid var(--hf-border);
      border-radius: 8px;
      padding: 16px;
      margin-top: 20px;
      text-align: left;
      max-height: 200px;
      overflow-y: auto;
    }

    .detail-item {
      font-size: 13px;
      color: var(--hf-text);
      margin-bottom: 8px;
      padding-left: 16px;
      position: relative;
    }

    .detail-item:before {
      content: '•';
      position: absolute;
      left: 0;
      color: var(--hf-text-subtle);
    }

    .detail-item.warning:before {
      content: '⚠️';
    }

    .detail-item.error:before {
      content: '❌';
    }

    .modal-actions {
      display: flex;
      gap: 10px;
      justify-content: center;
      margin-top: 24px;
    }

    /* Canonical admin button — 9px 16px / 13px / radius 6px. */
    .btn {
      padding: 9px 16px;
      border-radius: 6px;
      border: 1px solid var(--hf-border-2);
      background: var(--hf-surface-2);
      color: var(--hf-text);
      font-size: 13px;
      font-weight: 500;
      font-family: inherit;
      cursor: pointer;
      transition: all 0.15s;
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

    .btn-secondary {
      background: var(--hf-surface-2);
      color: var(--hf-text);
      border-color: var(--hf-border-2);
    }

    .btn-secondary:hover {
      background: var(--hf-surface-3);
      border-color: var(--hf-text-subtle);
    }

    /* Danger — bordered, red text (matches the table-row Delete). */
    .btn-danger {
      background: var(--hf-surface-2);
      color: var(--hf-err);
      border-color: color-mix(in srgb, var(--hf-err) 45%, transparent);
    }

    .btn-danger:hover {
      background: color-mix(in srgb, var(--hf-err) 14%, transparent);
      border-color: var(--hf-err);
    }

    .status-icon.warning {
      background: var(--hf-warn);
      color: white;
    }
  `;

  constructor() {
    super();
    this.visible = false;
    this.title = '';
    this.message = '';
    this.status = 'progress'; // progress, success, error, confirm
    this.details = [];
    this.canClose = false;
    this.confirmText = 'Confirm';
    this.cancelText = 'Cancel';
    this.confirmCallback = null;
    this.cancelCallback = null;
    this.confirmVariant = 'primary';
  }

  show(title, message, status = 'progress', options = {}) {
    this.visible = true;
    this.title = title;
    this.message = message;
    this.status = status;
    this.details = options.details || [];
    this.canClose = status === 'success' || status === 'error' || status === 'confirm';
    this.confirmText = options.confirmText || 'Confirm';
    this.cancelText = options.cancelText || 'Cancel';
    this.confirmCallback = options.confirmCallback || null;
    this.cancelCallback = options.cancelCallback || null;
    this.confirmVariant = options.confirmVariant || 'primary';
    this.requestUpdate();
  }

  hide() {
    this.visible = false;
    this.requestUpdate();
  }

  updateStatus(status, message, details = []) {
    this.status = status;
    this.message = message;
    this.details = details;
    this.canClose = status === 'success' || status === 'error';
    this.requestUpdate();
  }

  handleClose() {
    if (this.canClose) {
      this.hide();
      this.dispatchEvent(new CustomEvent('modal-closed', {
        bubbles: true,
        composed: true
      }));
    }
  }

  handleConfirm() {
    if (this.confirmCallback) {
      this.confirmCallback();
    }
    this.dispatchEvent(new CustomEvent('modal-confirmed', {
      bubbles: true,
      composed: true
    }));
    this.hide();
  }

  handleCancel() {
    if (this.cancelCallback) {
      this.cancelCallback();
    }
    this.dispatchEvent(new CustomEvent('modal-cancelled', {
      bubbles: true,
      composed: true
    }));
    this.hide();
  }

  renderIcon() {
    if (this.status === 'progress') {
      return html`<div class="spinner"></div>`;
    }

    if (this.status === 'success') {
      return html`<div class="status-icon success">✓</div>`;
    }

    if (this.status === 'error') {
      return html`<div class="status-icon error">✕</div>`;
    }

    if (this.status === 'confirm') {
      return html`<div class="status-icon warning">⚠</div>`;
    }

    return '';
  }

  render() {
    if (!this.visible) {
      return html``;
    }

    return html`
      <div class="modal-overlay" @click=${this.handleClose}>
        <div class="modal" @click=${(e) => e.stopPropagation()}>
          <h2 class="modal-header">${this.title}</h2>

          <div class="modal-body">
            ${this.renderIcon()}

            <div class="message">${this.message}</div>

            ${this.details && this.details.length > 0 ? html`
              <div class="details">
                ${this.details.map(detail => html`
                  <div class="detail-item ${detail.type || ''}">${detail.message || detail}</div>
                `)}
              </div>
            ` : ''}
          </div>

          ${this.status === 'confirm' ? html`
            <div class="modal-actions">
              <button class="btn btn-secondary" @click=${this.handleCancel}>
                ${this.cancelText}
              </button>
              <button class="btn ${this.confirmVariant === 'danger' ? 'btn-danger' : 'btn-primary'}"
                      @click=${this.handleConfirm}>
                ${this.confirmText}
              </button>
            </div>
          ` : this.canClose ? html`
            <div class="modal-actions">
              <button class="btn btn-primary" @click=${this.handleClose}>
                ${this.status === 'success' ? 'Done' : 'Close'}
              </button>
            </div>
          ` : ''}
        </div>
      </div>
    `;
  }
}

customElements.define('progress-modal', ProgressModal);
