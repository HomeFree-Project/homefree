import { LitElement, html, css } from 'lit';

/**
 * Custom dropdown component.
 *
 * Replaces native <select>, which renders unreliably inside deeply-nested
 * shadow DOM (popover doesn't appear, options invisible against dark theme,
 * etc.). This is a pure-DOM equivalent: a button trigger plus an
 * absolutely-positioned options panel.
 *
 * Usage:
 *   <dropdown-select
 *     .options=${[{ value: 'a', label: 'Option A' }, ...]}
 *     .value=${currentValue}
 *     placeholder="Select an option..."
 *     ?disabled=${false}
 *     @change=${(e) => doSomething(e.detail.value)}
 *   ></dropdown-select>
 *
 * options can be either:
 *   - an array of strings: ['a', 'b', 'c']  (value === label)
 *   - an array of {value, label} objects
 *   - a flat array containing optional {group: 'Section'} markers, which
 *     render as non-selectable section headers between the option groups:
 *       [{group: 'Americas'}, {value: 'NY', label: 'New York'}, ...]
 */
class DropdownSelect extends LitElement {
  static properties = {
    options: { type: Array },
    value: { type: String },
    placeholder: { type: String },
    disabled: { type: Boolean },
    _open: { type: Boolean, state: true }
  };

  constructor() {
    super();
    this.options = [];
    this.value = null;
    this.placeholder = 'Select an option...';
    this.disabled = false;
    this._open = false;
    this._closeOnOutsideClick = null;
  }

  static styles = css`
    :host {
      display: block;
      color-scheme: dark;
    }

    .dropdown {
      position: relative;
      width: 100%;
    }

    .trigger {
      width: 100%;
      padding: 8px 36px 8px 12px;
      font-size: 14px;
      font-family: inherit;
      color: var(--hf-text);
      background-color: var(--hf-bg);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      box-sizing: border-box;
      cursor: pointer;
      text-align: left;
      position: relative;
    }

    .trigger::after {
      content: '';
      position: absolute;
      right: 12px;
      top: 50%;
      width: 8px;
      height: 8px;
      border-right: 1.5px solid var(--hf-text-muted);
      border-bottom: 1.5px solid var(--hf-text-muted);
      transform: translateY(-70%) rotate(45deg);
      pointer-events: none;
    }

    .trigger.placeholder {
      color: var(--hf-text-subtle);
    }

    .trigger:focus,
    .dropdown.open .trigger {
      outline: none;
      border-color: var(--hf-accent);
      box-shadow: 0 0 0 3px var(--hf-focus-ring);
    }

    .trigger:disabled {
      background-color: var(--hf-surface-2);
      cursor: not-allowed;
      opacity: 0.6;
    }

    .options {
      position: absolute;
      top: calc(100% + 4px);
      left: 0;
      right: 0;
      max-height: 280px;
      overflow-y: auto;
      background: var(--hf-surface);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      box-shadow: var(--hf-shadow-lg);
      z-index: 1000;
      padding: 4px 0;
    }

    .option {
      padding: 8px 12px;
      font-size: 14px;
      color: var(--hf-text);
      cursor: pointer;
      user-select: none;
    }

    .option:hover {
      background: var(--hf-surface-3);
    }

    .option.selected {
      background: var(--hf-accent-soft);
      color: var(--hf-accent);
    }

    .option.empty {
      color: var(--hf-text-muted);
      font-style: italic;
      cursor: default;
    }

    .option.empty:hover {
      background: transparent;
    }

    .group-header {
      padding: 8px 12px 4px 12px;
      font-size: 11px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.06em;
      color: var(--hf-text-subtle);
      user-select: none;
    }
  `;

  // Normalize options to either {value, label} or {group}.
  _normalizedOptions() {
    return (this.options || []).map(o =>
      typeof o === 'string' ? { value: o, label: o } : o
    );
  }

  _selectedLabel() {
    if (this.value === null || this.value === undefined || this.value === '') {
      return null;
    }
    const match = this._normalizedOptions().find(o =>
      o.group === undefined && o.value === this.value
    );
    return match ? match.label : this.value;
  }

  toggleOpen(e) {
    if (this.disabled) return;
    e.stopPropagation();
    this._open = !this._open;
    if (this._open) {
      this._closeOnOutsideClick = (evt) => {
        const path = evt.composedPath();
        if (!path.includes(this)) {
          this._open = false;
          this._removeOutsideClick();
        }
      };
      // Defer so the click that opened it doesn't immediately close it.
      setTimeout(() => {
        document.addEventListener('click', this._closeOnOutsideClick, true);
      }, 0);
    } else {
      this._removeOutsideClick();
    }
  }

  _removeOutsideClick() {
    if (this._closeOnOutsideClick) {
      document.removeEventListener('click', this._closeOnOutsideClick, true);
      this._closeOnOutsideClick = null;
    }
  }

  selectOption(option, e) {
    e.stopPropagation();
    this._open = false;
    this._removeOutsideClick();
    this.dispatchEvent(new CustomEvent('change', {
      detail: { value: option.value },
      bubbles: true,
      composed: true
    }));
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    this._removeOutsideClick();
  }

  render() {
    const opts = this._normalizedOptions();
    const selectedLabel = this._selectedLabel();
    const display = selectedLabel ?? this.placeholder;
    const isPlaceholder = selectedLabel === null;

    return html`
      <div class="dropdown ${this._open ? 'open' : ''}">
        <button
          type="button"
          class="trigger ${isPlaceholder ? 'placeholder' : ''}"
          ?disabled=${this.disabled}
          @click=${this.toggleOpen}
        >${display}</button>
        ${this._open ? html`
          <div class="options">
            ${opts.length === 0 ? html`
              <div class="option empty">No options available</div>
            ` : opts.map(o =>
              o.group !== undefined
                ? html`<div class="group-header">${o.group}</div>`
                : html`
                    <div
                      class="option ${this.value === o.value ? 'selected' : ''}"
                      @click=${(e) => this.selectOption(o, e)}
                    >${o.label}</div>
                  `
            )}
          </div>
        ` : ''}
      </div>
    `;
  }
}

customElements.define('dropdown-select', DropdownSelect);
