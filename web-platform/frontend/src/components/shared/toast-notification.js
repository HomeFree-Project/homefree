import { LitElement, html, css } from 'lit';

/**
 * Toast Notification Component
 *
 * Non-blocking notification that appears at the bottom-left of the screen
 * and auto-dismisses after a configurable duration.
 *
 * @property {String} message - The message to display
 * @property {String} type - Type of toast: 'success', 'error', 'warning', 'info'
 * @property {Number} duration - Auto-dismiss duration in ms (0 = no auto-dismiss)
 * @property {Boolean} visible - Whether the toast is visible
 * @fires toast-close - Fired when toast is closed
 */
export class ToastNotification extends LitElement {
  static styles = css`
    :host {
      display: block;
      position: fixed;
      bottom: 20px;
      left: 20px;
      z-index: 10000;
      max-width: 400px;
      min-width: 300px;
    }

    :host([hidden]) {
      display: none;
    }

    .toast {
      display: flex;
      align-items: flex-start;
      padding: 16px;
      border-radius: 8px;
      box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
      background: white;
      animation: slideIn 0.3s ease-out;
      margin-bottom: 10px;
      border-left: 4px solid #ddd;
    }

    .toast.success {
      border-left-color: #10b981;
    }

    .toast.error {
      border-left-color: #ef4444;
    }

    .toast.warning {
      border-left-color: #f59e0b;
    }

    .toast.info {
      border-left-color: #3b82f6;
    }

    .toast-icon {
      font-size: 20px;
      margin-right: 12px;
      flex-shrink: 0;
    }

    .toast-content {
      flex: 1;
      display: flex;
      flex-direction: column;
      min-width: 0;
    }

    .toast-message {
      font-size: 14px;
      color: #1f2937;
      line-height: 1.5;
      word-wrap: break-word;
    }

    .toast-close {
      background: none;
      border: none;
      color: #6b7280;
      cursor: pointer;
      font-size: 20px;
      padding: 0;
      margin-left: 12px;
      width: 24px;
      height: 24px;
      display: flex;
      align-items: center;
      justify-content: center;
      border-radius: 4px;
      flex-shrink: 0;
      transition: all 0.2s;
    }

    .toast-close:hover {
      background: #f3f4f6;
      color: #1f2937;
    }

    @keyframes slideIn {
      from {
        transform: translateX(-100%);
        opacity: 0;
      }
      to {
        transform: translateX(0);
        opacity: 1;
      }
    }

    @keyframes slideOut {
      from {
        transform: translateX(0);
        opacity: 1;
      }
      to {
        transform: translateX(-100%);
        opacity: 0;
      }
    }

    .toast.closing {
      animation: slideOut 0.3s ease-in forwards;
    }
  `;

  static properties = {
    message: { type: String },
    type: { type: String },
    duration: { type: Number },
    visible: { type: Boolean, reflect: true },
  };

  constructor() {
    super();
    this.message = '';
    this.type = 'info'; // 'success', 'error', 'warning', 'info'
    this.duration = 5000; // Auto-dismiss after 5 seconds
    this.visible = true;
    this._timeout = null;
  }

  connectedCallback() {
    super.connectedCallback();
    if (this.duration > 0) {
      this._startAutoDismiss();
    }
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    this._clearAutoDismiss();
  }

  _startAutoDismiss() {
    this._clearAutoDismiss();
    this._timeout = setTimeout(() => {
      this.close();
    }, this.duration);
  }

  _clearAutoDismiss() {
    if (this._timeout) {
      clearTimeout(this._timeout);
      this._timeout = null;
    }
  }

  close() {
    // Add closing animation class
    const toastEl = this.shadowRoot.querySelector('.toast');
    if (toastEl) {
      toastEl.classList.add('closing');
      // Wait for animation to complete before firing event
      setTimeout(() => {
        this.dispatchEvent(new CustomEvent('toast-close', {
          bubbles: true,
          composed: true,
        }));
      }, 300);
    } else {
      this.dispatchEvent(new CustomEvent('toast-close', {
        bubbles: true,
        composed: true,
      }));
    }
  }

  _getIcon() {
    switch (this.type) {
      case 'success':
        return '✓';
      case 'error':
        return '✕';
      case 'warning':
        return '⚠';
      case 'info':
      default:
        return 'ℹ';
    }
  }

  render() {
    if (!this.visible) {
      return html``;
    }

    return html`
      <div class="toast ${this.type}">
        <div class="toast-icon">${this._getIcon()}</div>
        <div class="toast-content">
          <div class="toast-message">${this.message}</div>
        </div>
        <button
          class="toast-close"
          @click=${this.close}
          aria-label="Close notification"
        >
          ×
        </button>
      </div>
    `;
  }
}

customElements.define('toast-notification', ToastNotification);
