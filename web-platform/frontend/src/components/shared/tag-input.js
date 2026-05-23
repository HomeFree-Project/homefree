import { LitElement, html, css } from 'lit';

/**
 * Chip / tag input.
 *
 * Used when the underlying config is a single string of comma- or
 * whitespace-separated tokens (e.g. NFS share "Allowed clients" — CIDRs / IPs).
 * The component renders each token as a removable pill plus a trailing text
 * field for adding more, and emits `change` with `detail.value` = the canonical
 * `joined-with-", "` string. So the backend / table-editor still sees a plain
 * string; the chip UI is purely presentational.
 *
 * Add semantics: Enter or comma commits the trailing input as a new chip;
 * pasting text containing commas auto-splits; Backspace on an empty input
 * removes the last chip; blur commits whatever is in the input. Duplicate
 * tokens are silently de-duped.
 */
class TagInput extends LitElement {
  static properties = {
    value: { type: String },           // canonical "a, b, c" string
    placeholder: { type: String },
    _draft: { state: true },            // unsubmitted input text
  };

  static styles = css`
    :host { display: block; }
    .wrap {
      display: flex; flex-wrap: wrap; align-items: center; gap: 6px;
      padding: 6px 8px;
      background: var(--hf-bg);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      min-height: 38px;
      box-sizing: border-box;
      transition: border-color 0.15s, box-shadow 0.15s;
      cursor: text;
    }
    .wrap:focus-within {
      border-color: var(--hf-accent);
      box-shadow: 0 0 0 3px color-mix(in srgb, var(--hf-accent) 18%, transparent);
    }
    .chip {
      display: inline-flex; align-items: center; gap: 4px;
      background: var(--hf-surface-2);
      border: 1px solid var(--hf-border-2);
      border-radius: 12px;
      padding: 2px 4px 2px 10px;
      font-size: 12px;
      color: var(--hf-text);
      font-family: var(--hf-font-mono, monospace);
      white-space: nowrap;
    }
    .chip button {
      background: none; border: none; cursor: pointer;
      color: var(--hf-text-muted);
      font-size: 15px; line-height: 1;
      padding: 0 4px;
      border-radius: 8px;
    }
    .chip button:hover { color: var(--hf-err); background: color-mix(in srgb, var(--hf-err) 14%, transparent); }
    input {
      flex: 1; min-width: 80px;
      background: transparent; border: none; outline: none;
      color: var(--hf-text);
      font-family: inherit; font-size: 13px;
      padding: 3px 2px;
    }
  `;

  constructor() {
    super();
    this.value = '';
    this.placeholder = '';
    this._draft = '';
  }

  // Canonical-form parse: split on commas or whitespace, drop empties.
  get _tags() {
    return (this.value || '').split(/[,\s]+/).filter(Boolean);
  }

  _emit(tags) {
    const joined = tags.join(', ');
    this.value = joined;
    this.dispatchEvent(new CustomEvent('change', {
      detail: { value: joined },
      bubbles: true, composed: true,
    }));
  }

  _commitDraft() {
    const t = (this._draft || '').trim();
    this._draft = '';
    if (!t) return;
    const tags = this._tags;
    if (!tags.includes(t)) {
      tags.push(t);
      this._emit(tags);
    }
  }

  _remove(idx) {
    const tags = this._tags;
    tags.splice(idx, 1);
    this._emit(tags);
  }

  _onKeydown(e) {
    if (e.key === 'Enter' || e.key === ',') {
      e.preventDefault();
      this._commitDraft();
    } else if (e.key === 'Backspace' && !this._draft) {
      const tags = this._tags;
      if (tags.length) { tags.pop(); this._emit(tags); }
    }
  }

  _onInput(e) {
    // If a paste or fast-typed text contains commas, commit everything before
    // the last comma as chips and keep the trailing fragment as the draft.
    const v = e.target.value;
    if (v.includes(',')) {
      const parts = v.split(',');
      this._draft = parts.pop();
      const tags = this._tags;
      for (const p of parts) {
        const t = p.trim();
        if (t && !tags.includes(t)) tags.push(t);
      }
      this._emit(tags);
    } else {
      this._draft = v;
    }
  }

  _onBlur() { this._commitDraft(); }

  _focusInput() {
    const el = this.renderRoot.querySelector('input');
    if (el) el.focus();
  }

  render() {
    const tags = this._tags;
    return html`
      <div class="wrap" @click=${this._focusInput}>
        ${tags.map((t, i) => html`
          <span class="chip">
            ${t}
            <button type="button"
                    @click=${(e) => { e.stopPropagation(); this._remove(i); }}
                    aria-label="Remove ${t}">×</button>
          </span>`)}
        <input
          type="text"
          .value=${this._draft}
          placeholder=${tags.length ? '' : (this.placeholder || '')}
          @input=${this._onInput}
          @keydown=${this._onKeydown}
          @blur=${this._onBlur}
        />
      </div>
    `;
  }
}

customElements.define('tag-input', TagInput);
