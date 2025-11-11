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
    status: { type: String }, // 'progress', 'success', 'error'
    details: { type: Array },
    canClose: { type: Boolean }
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
      background: rgba(0, 0, 0, 0.6);
      display: flex;
      align-items: center;
      justify-content: center;
      z-index: 10000;
      animation: fadeIn 0.2s ease-in;
    }

    @keyframes fadeIn {
      from { opacity: 0; }
      to { opacity: 1; }
    }

    .modal {
      background: white;
      border-radius: 16px;
      padding: 32px;
      max-width: 500px;
      width: 90%;
      box-shadow: 0 20px 60px rgba(0, 0, 0, 0.3);
      animation: slideUp 0.3s ease-out;
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
      font-size: 24px;
      font-weight: 600;
      color: #1d1d1f;
      text-align: center;
    }

    .modal-body {
      text-align: center;
    }

    .spinner {
      width: 64px;
      height: 64px;
      margin: 0 auto 20px;
      border: 4px solid #f3f4f6;
      border-top-color: #667eea;
      border-radius: 50%;
      animation: spin 1s linear infinite;
    }

    @keyframes spin {
      to { transform: rotate(360deg); }
    }

    .status-icon {
      width: 64px;
      height: 64px;
      margin: 0 auto 20px;
      border-radius: 50%;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 32px;
    }

    .status-icon.success {
      background: #10b981;
      color: white;
    }

    .status-icon.error {
      background: #ef4444;
      color: white;
    }

    .message {
      font-size: 16px;
      color: #6b7280;
      margin-bottom: 20px;
      line-height: 1.5;
    }

    .details {
      background: #f9fafb;
      border-radius: 8px;
      padding: 16px;
      margin-top: 20px;
      text-align: left;
      max-height: 200px;
      overflow-y: auto;
    }

    .detail-item {
      font-size: 13px;
      color: #374151;
      margin-bottom: 8px;
      padding-left: 16px;
      position: relative;
    }

    .detail-item:before {
      content: '•';
      position: absolute;
      left: 0;
      color: #9ca3af;
    }

    .detail-item.warning:before {
      content: '⚠️';
    }

    .detail-item.error:before {
      content: '❌';
    }

    .modal-actions {
      display: flex;
      gap: 12px;
      justify-content: center;
      margin-top: 24px;
    }

    .btn {
      padding: 12px 24px;
      border-radius: 8px;
      border: none;
      font-size: 14px;
      font-weight: 500;
      cursor: pointer;
      transition: all 0.2s;
    }

    .btn-primary {
      background: #667eea;
      color: white;
    }

    .btn-primary:hover {
      background: #5568d3;
    }

    .btn-secondary {
      background: #e5e7eb;
      color: #374151;
    }

    .btn-secondary:hover {
      background: #d1d5db;
    }
  `;

  constructor() {
    super();
    this.visible = false;
    this.title = '';
    this.message = '';
    this.status = 'progress'; // progress, success, error
    this.details = [];
    this.canClose = false;
  }

  show(title, message, status = 'progress') {
    this.visible = true;
    this.title = title;
    this.message = message;
    this.status = status;
    this.details = [];
    this.canClose = false;
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

          ${this.canClose ? html`
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
