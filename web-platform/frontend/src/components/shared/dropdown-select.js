import { LitElement, html, css } from 'lit';

/**
 * Custom dropdown component with:
 *  - Type-to-filter search box at the top of the panel.
 *  - Keyboard navigation: Up/Down to move, Enter to select, Escape to close.
 *  - Popover panel rendered into <body> so ancestor `overflow:hidden` or
 *    `<details>` collapsing can't clip the list.
 *  - Auto-flip: opens above the trigger if there's more room above the
 *    fold than below.
 *
 * Replaces native <select>, which renders unreliably inside deeply-nested
 * shadow DOM and has no search affordance.
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
    _open: { type: Boolean, state: true },
    _query: { type: String, state: true },
    _highlight: { type: Number, state: true },
  };

  constructor() {
    super();
    this.options = [];
    this.value = null;
    this.placeholder = 'Select an option...';
    this.disabled = false;
    this._open = false;
    this._query = '';
    this._highlight = -1;
    // The options panel lives in document.body so ancestor overflow
    // can't clip it. _panel holds the detached DOM node; we move it
    // into <body> on open and back out (or simply remove) on close.
    this._panel = null;
    this._closeOnOutsideClick = null;
    this._reposition = null;
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

    .trigger.placeholder { color: var(--hf-text-subtle); }

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
  `;

  // ── option normalization & filtering ───────────────────────────────────
  _normalizedOptions() {
    return (this.options || []).map(o =>
      typeof o === 'string' ? { value: o, label: o } : o
    );
  }

  /** Returns options filtered by the search query, with group headers
   *  dropped when they have no matching children underneath. */
  _filteredOptions() {
    const opts = this._normalizedOptions();
    const q = this._query.trim().toLowerCase();
    if (!q) return opts;

    // Pass 1: keep options matching the query; preserve every group
    // header for now (will prune empty groups in pass 2).
    const matched = opts.filter(o =>
      o.group !== undefined || String(o.label || '').toLowerCase().includes(q)
    );

    // Pass 2: drop a group header whose next entry is another group
    // header (or end of list).
    return matched.filter((o, i) => {
      if (o.group === undefined) return true;
      const next = matched[i + 1];
      return !!next && next.group === undefined;
    });
  }

  /** Indices of selectable (non-group) entries in _filteredOptions. */
  _selectableIndices() {
    return this._filteredOptions()
      .map((o, i) => (o.group === undefined ? i : -1))
      .filter(i => i >= 0);
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

  // ── open / close / outside-click ───────────────────────────────────────
  toggleOpen(e) {
    if (this.disabled) return;
    e.stopPropagation();
    if (this._open) {
      this._close();
    } else {
      this._openPanel();
    }
  }

  _openPanel() {
    this._open = true;
    this._query = '';
    // Highlight the current selection if any, else the first match.
    const idxs = this._selectableIndices();
    const cur = this._filteredOptions().findIndex(
      o => o.group === undefined && o.value === this.value
    );
    this._highlight = cur >= 0 ? cur : (idxs[0] ?? -1);

    // Defer panel creation until the next paint so the trigger has
    // finalized its layout — getBoundingClientRect must be accurate.
    requestAnimationFrame(() => {
      this._attachPanel();
      this._positionPanel();
      // Focus the search input so the user can start typing.
      const search = this._panel?.querySelector('input.search');
      if (search) search.focus();
    });

    this._closeOnOutsideClick = (evt) => {
      const path = evt.composedPath();
      if (path.includes(this) || (this._panel && path.includes(this._panel))) {
        return;
      }
      this._close();
    };
    // Defer to avoid the opening click being treated as outside.
    setTimeout(() => {
      document.addEventListener('mousedown', this._closeOnOutsideClick, true);
    }, 0);

    this._reposition = () => this._positionPanel();
    window.addEventListener('scroll', this._reposition, true);
    window.addEventListener('resize', this._reposition);
  }

  _close() {
    this._open = false;
    if (this._closeOnOutsideClick) {
      document.removeEventListener('mousedown', this._closeOnOutsideClick, true);
      this._closeOnOutsideClick = null;
    }
    if (this._reposition) {
      window.removeEventListener('scroll', this._reposition, true);
      window.removeEventListener('resize', this._reposition);
      this._reposition = null;
    }
    this._detachPanel();
  }

  // ── panel: portal-style attach to <body> ───────────────────────────────
  /** Build the panel DOM once and append it to <body>. We re-render its
   *  content (option list, search box) by directly setting properties /
   *  innerHTML — the panel is outside Lit's render tree because Lit
   *  doesn't support portals natively. */
  _attachPanel() {
    if (this._panel) return;
    const panel = document.createElement('div');
    panel.className = 'hf-dropdown-popover';
    // Inline styles instead of a stylesheet: the panel is in light DOM
    // outside our shadow root, so component-scoped styles wouldn't
    // apply, and we don't want to pollute the global stylesheet.
    Object.assign(panel.style, {
      position: 'fixed',
      zIndex: '10000',
      maxHeight: '320px',
      overflow: 'hidden',
      display: 'flex',
      flexDirection: 'column',
      background: 'var(--hf-surface, #1a1a1a)',
      border: '1px solid var(--hf-border-2, #444)',
      borderRadius: '6px',
      boxShadow: 'var(--hf-shadow-lg, 0 8px 24px rgba(0,0,0,0.4))',
      padding: '4px 0',
      boxSizing: 'border-box',
      colorScheme: 'dark',
    });

    // Build the header + body shells exactly once. The search input
    // is created here and never re-created — otherwise typing into
    // it loses focus when the options list re-renders.
    //
    // The header's border (top vs bottom) and the panel's flex
    // direction get flipped in _positionPanel when the panel opens
    // upward, so the search box always sits next to the trigger
    // rather than at the far end of the panel.
    const header = document.createElement('div');
    header.className = 'header';
    Object.assign(header.style, {
      padding: '6px 8px',
      borderBottom: '1px solid var(--hf-border-2, #444)',
      borderTop: 'none',
    });
    const search = document.createElement('input');
    search.type = 'text';
    search.className = 'search';
    search.placeholder = 'Type to filter…';
    search.autocomplete = 'off';
    Object.assign(search.style, {
      width: '100%',
      padding: '6px 8px',
      fontSize: '13px',
      fontFamily: 'inherit',
      color: 'var(--hf-text, #eee)',
      background: 'var(--hf-bg, #111)',
      border: '1px solid var(--hf-border-2, #444)',
      borderRadius: '4px',
      boxSizing: 'border-box',
    });
    search.value = this._query;
    search.addEventListener('input', (e) => {
      this._query = e.target.value;
      // Reset highlight to first selectable filtered entry.
      const idxs = this._selectableIndices();
      this._highlight = idxs[0] ?? -1;
      // Only re-render the options body — leave the search input
      // (and its caret/focus) untouched.
      this._renderOptionsBody();
    });
    search.addEventListener('keydown', (e) => this._onKeydown(e));
    header.appendChild(search);

    const body = document.createElement('div');
    body.className = 'options-list';
    Object.assign(body.style, {
      overflowY: 'auto',
      flex: '1',
      padding: '4px 0',
    });

    panel.appendChild(header);
    panel.appendChild(body);

    document.body.appendChild(panel);
    this._panel = panel;
    this._renderOptionsBody();
  }

  _detachPanel() {
    if (this._panel && this._panel.parentNode) {
      this._panel.parentNode.removeChild(this._panel);
    }
    this._panel = null;
  }

  /** Position the panel under the trigger, flipping above if the
   *  trigger is near the viewport bottom. Width matches the trigger. */
  _positionPanel() {
    if (!this._panel) return;
    const triggerEl = this.renderRoot?.querySelector('button.trigger');
    if (!triggerEl) return;

    const rect = triggerEl.getBoundingClientRect();
    const viewportH = window.innerHeight;
    const gap = 4;
    const panelH = Math.min(320, this._panel.scrollHeight || 320);

    const spaceBelow = viewportH - rect.bottom;
    const spaceAbove = rect.top;
    const placeAbove = spaceBelow < panelH + gap && spaceAbove > spaceBelow;

    this._panel.style.width = `${rect.width}px`;
    this._panel.style.left = `${rect.left}px`;

    // Keep the search box visually adjacent to the trigger. The panel
    // anchors by its bottom edge when above, so DOM order needs to be
    // reversed (column-reverse) — that puts the header at the visual
    // bottom of the panel, next to the trigger. Below-the-trigger
    // layout uses normal column order with the header at the top.
    // Without this, filtering the list (which shrinks the panel) makes
    // the header jump because it's anchored to the free edge.
    const header = this._panel.querySelector('.header');
    if (placeAbove) {
      this._panel.style.flexDirection = 'column-reverse';
      if (header) {
        header.style.borderBottom = 'none';
        header.style.borderTop = '1px solid var(--hf-border-2, #444)';
      }
      // Anchor by `bottom` so the panel grows upward; subtract from
      // viewportH because position is fixed (viewport-relative).
      this._panel.style.top = 'auto';
      this._panel.style.bottom = `${viewportH - rect.top + gap}px`;
      this._panel.style.maxHeight = `${Math.max(120, spaceAbove - gap - 8)}px`;
    } else {
      this._panel.style.flexDirection = 'column';
      if (header) {
        header.style.borderTop = 'none';
        header.style.borderBottom = '1px solid var(--hf-border-2, #444)';
      }
      this._panel.style.bottom = 'auto';
      this._panel.style.top = `${rect.bottom + gap}px`;
      this._panel.style.maxHeight = `${Math.max(120, spaceBelow - gap - 8)}px`;
    }
  }

  /** Re-render ONLY the scrollable options list. The search input
   *  header is built once in _attachPanel and never replaced — that's
   *  what lets the user type uninterrupted (innerHTML rewrites would
   *  destroy the input element and steal focus). */
  _renderOptionsBody() {
    if (!this._panel) return;
    const body = this._panel.querySelector('.options-list');
    if (!body) return;
    const opts = this._filteredOptions();

    let html = '';
    if (opts.length === 0) {
      html = `<div style="padding: 8px 12px; font-size: 14px; color: var(--hf-text-muted, #888); font-style: italic;">No matches</div>`;
    } else {
      opts.forEach((o, i) => {
        if (o.group !== undefined) {
          html += `
            <div style="padding: 8px 12px 4px 12px; font-size: 11px; font-weight: 600;
                        text-transform: uppercase; letter-spacing: 0.06em;
                        color: var(--hf-text-subtle, #888); user-select: none;">
              ${this._escape(o.group)}
            </div>
          `;
          return;
        }
        const isSelected = o.value === this.value;
        const isHi = i === this._highlight;
        const bg = isHi
          ? 'background: var(--hf-surface-3, #333);'
          : (isSelected ? 'background: var(--hf-accent-soft, #2a3a4a);' : '');
        const color = isSelected
          ? 'color: var(--hf-accent, #8ab4f8);'
          : 'color: var(--hf-text, #eee);';
        html += `
          <div
            class="opt"
            data-index="${i}"
            style="padding: 8px 12px; font-size: 14px; cursor: pointer;
                   user-select: none; ${bg} ${color}"
          >${this._escape(o.label)}</div>
        `;
      });
    }
    body.innerHTML = html;

    // Re-hook option click + hover handlers. (Cheap; the body content
    // was just rebuilt so no listener leaks.)
    body.querySelectorAll('.opt').forEach(el => {
      el.addEventListener('mousedown', (e) => e.preventDefault());
      el.addEventListener('click', (e) => {
        e.stopPropagation();
        const i = parseInt(el.getAttribute('data-index'), 10);
        const o = this._filteredOptions()[i];
        if (o && o.group === undefined) this._commit(o);
      });
      el.addEventListener('mouseenter', () => {
        const i = parseInt(el.getAttribute('data-index'), 10);
        if (!isNaN(i)) {
          this._highlight = i;
          this._renderOptionsBody();
        }
      });
    });

    // Scroll the highlighted option into view if needed.
    const hiEl = body.querySelector(`.opt[data-index="${this._highlight}"]`);
    if (hiEl) {
      hiEl.scrollIntoView({ block: 'nearest' });
    }
  }

  _onKeydown(e) {
    const idxs = this._selectableIndices();
    if (e.key === 'Escape') {
      e.preventDefault();
      this._close();
      return;
    }
    if (e.key === 'Enter') {
      e.preventDefault();
      const opts = this._filteredOptions();
      const o = opts[this._highlight];
      if (o && o.group === undefined) this._commit(o);
      return;
    }
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      if (idxs.length === 0) return;
      const curPos = idxs.indexOf(this._highlight);
      let nextPos;
      if (e.key === 'ArrowDown') {
        nextPos = curPos < 0 ? 0 : (curPos + 1) % idxs.length;
      } else {
        nextPos = curPos < 0 ? idxs.length - 1
                             : (curPos - 1 + idxs.length) % idxs.length;
      }
      this._highlight = idxs[nextPos];
      this._renderOptionsBody();
      return;
    }
  }

  _commit(option) {
    this._close();
    this.dispatchEvent(new CustomEvent('change', {
      detail: { value: option.value },
      bubbles: true,
      composed: true,
    }));
  }

  _escape(s) {
    return String(s ?? '').replace(/[&<>"']/g, c => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[c]));
  }
  _escapeAttr(s) { return this._escape(s); }

  // ── Lit lifecycle ──────────────────────────────────────────────────────
  /** When state changes while open (options swapped, value changed
   *  externally, highlight moved by keyboard), keep the popover in sync. */
  updated(changed) {
    if (this._open) {
      this._renderOptionsBody();
      // Don't reposition on every keystroke — the panel size hasn't
      // changed materially. Reposition only when options array swaps.
      if (changed.has('options')) this._positionPanel();
    }
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    this._close();
  }

  render() {
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
      </div>
    `;
  }
}

customElements.define('dropdown-select', DropdownSelect);
