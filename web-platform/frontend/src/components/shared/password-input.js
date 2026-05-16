import { LitElement, html, css } from 'lit';
import {
  validatePassword, strengthBar, loadPasswordPolicy, DEFAULT_POLICY,
} from '../../shared/password-policy.js';

/**
 * Password input with:
 *   - Eye icon on the right to toggle reveal
 *   - Live strength meter (4-step colored bar) when `withStrength`
 *   - Live per-requirement checklist below the field, with each item
 *     turning green as the user satisfies it. Driven by the policy
 *     fetched from /api/sso/password-policy (Zitadel) — falls back
 *     to the static DEFAULT_POLICY if offline.
 *
 * Use as a controlled input — bind `.value`, listen to `input` to
 * read the new value. The component does NOT internally store state
 * other than the reveal toggle and the loaded policy, so the parent
 * stays the single source of truth for the password text.
 *
 *   <password-input
 *     placeholder="New password"
 *     .value=${this.pw}
 *     withStrength
 *     @input=${(e) => { this.pw = e.detail.value; }}
 *   ></password-input>
 *
 * Properties:
 *   - withStrength (bool): show the strength bar + requirement
 *     checklist. Use this for "new password" fields. Confirm /
 *     current-password fields should leave it off.
 *   - placeholder, required, disabled, autocomplete, name: native
 *   - policy (object, optional): pre-loaded policy to skip the
 *     async fetch. Useful in the installer where Zitadel doesn't
 *     exist yet.
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
    policy: { type: Object },
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

    ul.reqs {
      list-style: none;
      padding: 0;
      margin: 8px 0 0 0;
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 2px 16px;
    }
    @media (max-width: 480px) {
      ul.reqs { grid-template-columns: 1fr; }
    }

    ul.reqs li {
      display: flex;
      align-items: center;
      gap: 6px;
      font-size: 12px;
      color: var(--hf-text-muted, #888);
      transition: color 0.15s;
    }
    ul.reqs li.met {
      color: #7cb342;
    }
    ul.reqs li .check {
      display: inline-flex;
      width: 14px;
      height: 14px;
      align-items: center;
      justify-content: center;
      border-radius: 50%;
      font-size: 9px;
      font-weight: bold;
      flex-shrink: 0;
      background: var(--hf-surface-2, #2a2a2a);
      color: var(--hf-text-muted, #888);
    }
    ul.reqs li.met .check {
      background: rgba(124, 179, 66, 0.2);
      color: #7cb342;
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
    this.policy = null;
    this._revealed = false;
  }

  async connectedCallback() {
    super.connectedCallback();
    // Only fetch the policy if we need it (the requirement checklist
    // only renders for `withStrength` fields) and the parent hasn't
    // passed one explicitly.
    if (this.withStrength && !this.policy) {
      try {
        this.policy = await loadPasswordPolicy();
      } catch (e) {
        this.policy = DEFAULT_POLICY;
      }
    }
  }

  _onInput(e) {
    // Stop the native <input>'s bubbling input event. Otherwise the
    // parent's @input=... listener fires twice per keystroke: once
    // with the native event (e.detail === undefined → e.detail.value
    // throws inside the parent's arrow function, kills the handler
    // silently in Lit) and once with our CustomEvent. Worse, in some
    // browsers the native event arrives AFTER our custom one,
    // overwriting our state update with garbage. Stopping the native
    // event here leaves only our well-formed CustomEvent for the
    // parent to see.
    e.stopPropagation();
    this.value = e.target.value;
    this.dispatchEvent(new CustomEvent('input', {
      bubbles: true,
      composed: true,
      detail: { value: e.target.value },
    }));
  }

  _toggleReveal(e) {
    e.preventDefault();
    this._revealed = !this._revealed;
  }

  render() {
    const policy = this.policy || DEFAULT_POLICY;
    const v = validatePassword(this.value || '', policy);
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

      ${this.withStrength ? html`
        <div class="meter">
          <div class="meter-fill"
            style="width: ${bar.width}; background: ${bar.color};"></div>
        </div>
        <div class="meter-row">
          <span class="meter-label ${labelClass}">${bar.label}</span>
        </div>

        <ul class="reqs">
          ${v.requirements.map(r => html`
            <li class=${r.satisfied ? 'met' : ''}>
              <span class="check">${r.satisfied ? '✓' : ''}</span>
              <span>${r.label}</span>
            </li>
          `)}
        </ul>
      ` : ''}
    `;
  }
}

customElements.define('password-input', PasswordInput);
