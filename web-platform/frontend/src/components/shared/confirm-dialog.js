import { LitElement, html, css } from 'lit';
import { themeVars } from '../../shared/theme.js';

/**
 * In-page confirmation dialog — a centered modal that replaces the
 * native window.confirm(). One singleton instance is mounted lazily on
 * <body>; call the exported confirmDialog() helper to use it.
 *
 *   import { confirmDialog } from '../../shared/confirm-dialog.js';
 *
 *   if (await confirmDialog({
 *     title: 'Delete user?',
 *     message: 'This permanently removes the account.',
 *     confirmText: 'Delete',
 *     variant: 'danger',
 *   })) {
 *     ...proceed...
 *   }
 *
 * confirmDialog() returns a Promise<boolean> — true if the user
 * confirmed, false if they cancelled / dismissed (overlay click or
 * Escape). The singleton is mounted on <body>, outside every app
 * shadow root, so it imports `themeVars` into its own `static styles`
 * to declare the --hf-* tokens itself — they are not inherited.
 */
class ConfirmDialog extends LitElement {
  static properties = {
    open: { type: Boolean, state: true },
    title: { type: String, state: true },
    message: { type: String, state: true },
    confirmText: { type: String, state: true },
    cancelText: { type: String, state: true },
    variant: { type: String, state: true }, // 'danger' | 'primary'
    alertOnly: { type: Boolean, state: true }, // hide Cancel, single OK
  };

  // themeVars FIRST — this element is mounted on <body>, outside every
  // app shadow root, so it inherits none of the page's --hf-* tokens.
  // It must declare them itself or the panel renders transparent /
  // borderless with invisible text.
  static styles = [themeVars, css`
    :host { display: block; }

    .overlay {
      position: fixed;
      inset: 0;
      background: rgba(0, 0, 0, 0.7);
      backdrop-filter: blur(2px);
      display: flex;
      align-items: center;
      justify-content: center;
      z-index: 10001;
      animation: fadeIn 0.15s ease-in;
    }

    @keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }

    /* Opaque card with a clearly visible frame — the overlay behind it
       is blurred, so a weak border lets the panel blend into the
       backdrop and the text reads poorly. A lighter surface + stronger
       border keeps it a distinct, legible card. */
    .dialog {
      background: var(--hf-surface-2);
      border: 1px solid var(--hf-border-2);
      border-radius: 12px;
      padding: 28px;
      max-width: 440px;
      width: 90%;
      box-shadow: var(--hf-shadow-lg);
      color: var(--hf-text);
      animation: slideUp 0.2s ease-out;
    }

    @keyframes slideUp {
      from { transform: translateY(16px); opacity: 0; }
      to   { transform: translateY(0);    opacity: 1; }
    }

    .title {
      margin: 0 0 12px;
      font-size: 18px;
      font-weight: 600;
      letter-spacing: -0.01em;
    }

    .message {
      font-size: 14px;
      color: var(--hf-text-muted);
      line-height: 1.5;
      margin-bottom: 24px;
      white-space: pre-line;
    }

    .actions {
      display: flex;
      gap: 10px;
      justify-content: flex-end;
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
  `];

  constructor() {
    super();
    this.open = false;
    this.title = '';
    this.message = '';
    this.confirmText = 'Confirm';
    this.cancelText = 'Cancel';
    this.variant = 'primary';
    this.alertOnly = false;
    this._resolve = null;
  }

  /** Show the dialog and resolve true/false on the user's choice. */
  ask(options = {}) {
    this.title = options.title || 'Are you sure?';
    this.message = options.message || '';
    this.confirmText = options.confirmText || 'Confirm';
    this.cancelText = options.cancelText || 'Cancel';
    this.variant = options.variant || 'primary';
    this.alertOnly = options.alertOnly === true;
    this.open = true;

    // Close a previous pending dialog (resolve it false) before reusing.
    if (this._resolve) this._resolve(false);

    return new Promise((resolve) => {
      this._resolve = resolve;
    });
  }

  _finish(result) {
    this.open = false;
    const resolve = this._resolve;
    this._resolve = null;
    if (resolve) resolve(result);
  }

  _onConfirm() { this._finish(true); }
  _onCancel()  { this._finish(false); }

  connectedCallback() {
    super.connectedCallback();
    this._onKeydown = (e) => {
      if (!this.open) return;
      if (e.key === 'Escape') { e.preventDefault(); this._onCancel(); }
      if (e.key === 'Enter')  { e.preventDefault(); this._onConfirm(); }
    };
    window.addEventListener('keydown', this._onKeydown);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    window.removeEventListener('keydown', this._onKeydown);
  }

  render() {
    if (!this.open) return html``;

    return html`
      <div class="overlay" @click=${this._onCancel}>
        <div class="dialog" @click=${(e) => e.stopPropagation()}>
          <h2 class="title">${this.title}</h2>
          ${this.message
            ? html`<div class="message">${this.message}</div>`
            : ''}
          <div class="actions">
            ${this.alertOnly ? '' : html`
              <button class="btn" @click=${this._onCancel}>
                ${this.cancelText}
              </button>`}
            <button
              class="btn ${this.variant === 'danger' ? 'btn-danger' : 'btn-primary'}"
              @click=${this._onConfirm}
            >${this.confirmText}</button>
          </div>
        </div>
      </div>
    `;
  }
}

customElements.define('confirm-dialog', ConfirmDialog);

// Lazily-mounted singleton — created on first confirmDialog() call.
let _instance = null;

/**
 * Show the shared confirmation dialog. Drop-in async replacement for
 * window.confirm(). Resolves true if confirmed, false otherwise.
 */
export function confirmDialog(options = {}) {
  if (!_instance) {
    _instance = document.createElement('confirm-dialog');
    document.body.appendChild(_instance);
  }
  return _instance.ask(options);
}

/**
 * Show a single-button informational dialog. Drop-in async replacement
 * for window.alert(). Resolves when the user dismisses it.
 */
export function alertDialog(options = {}) {
  return confirmDialog({
    title: options.title || 'Notice',
    message: options.message || '',
    confirmText: options.confirmText || 'OK',
    variant: options.variant || 'primary',
    alertOnly: true,
  });
}
