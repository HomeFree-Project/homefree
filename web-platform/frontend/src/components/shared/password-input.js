import { LitElement, html, css } from 'lit';
import { validatePassword, strengthBar } from '../../shared/password-policy.js';

/**
 * Password input with:
 *   - Eye icon on the right to toggle reveal
 *   - Live strength meter (4-step colored bar) when `withStrength`
 *   - Inline validation message against the policy in
 *     shared/password-policy.js (same as Zitadel + Linux constraints)
 *
 * Use as a controlled input — bind `.value`, listen to `input` to
 * read the new value. The component does NOT internally store state
 * other than the reveal toggle, so the parent stays the single
 * source of truth.
 *
 *   <password-input
 *     placeholder="New password"
 *     .value=${this.pw}
 *     withStrength
 *     @input=${(e) => { this.pw = e.target.value; }}
 *   ></password-input>
 *
 * Properties:
 *   - withStrength (bool): show the strength bar + label
 *   - placeholder, required, disabled, autocomplete, name: native input
 *   - hideErrors (bool): suppress the inline error line (e.g. for a
 *     "confirm" field where the parent shows a combined error)
 */
class PasswordInput extends LitElement {
  static properties = {
    value: { type: String },
    placeholder: { type: String },
    required: { type: Boolean },
    disabled: { type: Boolean },
    autocomplete: { type: String },
    name: { type: String },
    withStrength: { type: Boolean },
    hideErrors: { type: Boolean },
    _revealed: { type: Boolean, state: true },
  };

  static styles = css`
    :host { display: block; }

    .wrap {
      position: relative;
      display: block;
    }

    input {
      width: 100%;
      padding: 8px 36px 8px 12px;
      font-size: 14px;
      font-family: inherit;
      color: var(--hf-text, #eee);
      background: var(--hf-bg, #111);
      border: 1px solid var(--hf-border-2, #444);
      border-radius: 6px;
      box-sizing: border-box;
    }
    input:focus {
      outline: none;
      border-color: var(--hf-accent, #8ab4f8);
      box-shadow: 0 0 0 3px var(--hf-focus-ring, rgba(138,180,248,0.18));
    }
    input.error {
      border-color: #f44336;
    }

    button.eye {
      position: absolute;
      right: 6px;
      top: 50%;
      transform: translateY(-50%);
      width: 28px;
      height: 28px;
      border: none;
      background: transparent;
      cursor: pointer;
      padding: 0;
      display: flex;
      align-items: center;
      justify-content: center;
      color: var(--hf-text-muted, #888);
      border-radius: 4px;
    }
    button.eye:hover {
      color: var(--hf-text, #eee);
      background: var(--hf-surface-2, #2a2a2a);
    }
    button.eye:focus { outline: none; }
    button.eye svg { width: 18px; height: 18px; }

    .meter {
      height: 4px;
      background: var(--hf-surface-2, #2a2a2a);
      border-radius: 2px;
      overflow: hidden;
      margin-top: 8px;
    }
    .meter-fill {
      height: 100%;
      transition: width 0.2s, background 0.2s;
    }
    .meter-row {
      display: flex;
      justify-content: space-between;
      font-size: 12px;
      margin-top: 4px;
      color: var(--hf-text-muted, #888);
    }
    .meter-label.weak { color: #f44336; }
    .meter-label.medium { color: #ff9800; }
    .meter-label.good { color: #7cb342; }
    .meter-label.strong { color: #4caf50; }

    .error-msg {
      color: #fca5a5;
      font-size: 12px;
      margin-top: 6px;
    }
  `;

  constructor() {
    super();
    this.value = '';
    this.placeholder = '';
    this.required = false;
    this.disabled = false;
    this.autocomplete = 'new-password';
    this.name = '';
    this.withStrength = false;
    this.hideErrors = false;
    this._revealed = false;
  }

  _onInput(e) {
    // Re-dispatch as our own `input` event so the parent can bind
    // @input naturally with e.target.value semantics.
    this.dispatchEvent(new CustomEvent('input', {
      bubbles: true,
      composed: true,
      detail: { value: e.target.value },
    }));
    // Also assign so .value bindings stay in sync without parent
    // round-trip via property re-render.
    this.value = e.target.value;
  }

  _toggleReveal(e) {
    e.preventDefault();
    this._revealed = !this._revealed;
  }

  render() {
    const v = validatePassword(this.value);
    const bar = strengthBar(v.strength);
    const labelClass =
      v.strength === 1 ? 'weak'
        : v.strength === 2 ? 'medium'
        : v.strength === 3 ? 'good'
        : v.strength === 4 ? 'strong'
        : '';

    return html`
      <div class="wrap">
        <input
          type=${this._revealed ? 'text' : 'password'}
          .value=${this.value || ''}
          placeholder=${this.placeholder}
          ?required=${this.required}
          ?disabled=${this.disabled}
          autocomplete=${this.autocomplete}
          name=${this.name}
          class=${this.value && !v.ok && this.withStrength ? 'error' : ''}
          @input=${this._onInput}
        />
        <button
          type="button"
          class="eye"
          @click=${this._toggleReveal}
          tabindex="-1"
          aria-label=${this._revealed ? 'Hide password' : 'Show password'}
          title=${this._revealed ? 'Hide password' : 'Show password'}
        >
          ${this._revealed
            ? html`
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor"
                stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24"/>
                <line x1="1" y1="1" x2="23" y2="23"/>
              </svg>`
            : html`
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor"
                stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/>
                <circle cx="12" cy="12" r="3"/>
              </svg>`}
        </button>
      </div>

      ${this.withStrength && this.value ? html`
        <div class="meter">
          <div class="meter-fill"
            style="width: ${bar.width}; background: ${bar.color};"></div>
        </div>
        <div class="meter-row">
          <span class="meter-label ${labelClass}">${bar.label}</span>
        </div>
      ` : ''}

      ${this.withStrength && this.value && v.error && !this.hideErrors
        ? html`<div class="error-msg">${v.error}</div>`
        : ''}
    `;
  }
}

customElements.define('password-input', PasswordInput);
