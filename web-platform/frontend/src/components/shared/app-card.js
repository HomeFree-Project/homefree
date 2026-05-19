import { LitElement, html, css } from 'lit';

/**
 * Shared app/service card.
 *
 * One card == one HomeFree app. Used by two surfaces:
 *   - the Home portal app launcher (user-app.js) — the whole card is a
 *     link to the app; no slotted content.
 *   - the admin Apps page (services-module.js) — the card carries a
 *     status line, enable/public toggles and action buttons, passed in
 *     via the default <slot>.
 *
 * Purely presentational: it renders the icon (with an initials
 * fallback when the SVG 404s), the title/subtitle, the enabled tint,
 * and a slot for everything else. Each surface keeps its own data
 * mapping and event wiring.
 *
 * Slots:
 *   header   — optional; sits on the right edge of the icon/title row.
 *              The admin Apps card injects a status badge + action
 *              icons here. The Home launcher leaves it empty.
 *   (default) — the card body, below the header (admin controls etc.).
 *
 * Properties:
 *   label    — service label; drives the icon URL /icons/<label>.svg
 *   name     — display title
 *   subtitle — secondary line (project name); hidden if empty/dup
 *   href     — if set, the whole card is an <a> opening this URL
 *   enabled  — enabled apps get a lighter surface tint (no border)
 *   compact  — Home-style smaller icon/padding (vs. roomier admin card)
 */
class AppCard extends LitElement {
  static properties = {
    label: { type: String },
    name: { type: String },
    subtitle: { type: String },
    href: { type: String },
    enabled: { type: Boolean, reflect: true },
    compact: { type: Boolean, reflect: true },
    _hasBody: { type: Boolean, state: true },
    _hasHeader: { type: Boolean, state: true },
  };

  static styles = css`
    :host {
      display: block;
    }

    .card {
      /* Disabled apps sit on the base surface; enabled apps get a
         lighter tint (set by :host([enabled])) — a calmer signal than
         the old full accent border. */
      background: var(--hf-surface);
      border: 1px solid var(--hf-border);
      border-radius: 12px;
      padding: 18px;
      color: inherit;
      text-decoration: none;
      display: flex;
      flex-direction: column;
      /* Fill the grid cell so every card in a row is the same height —
         a CSS grid stretches the host, and this passes that height
         through to the card itself. */
      height: 100%;
      box-sizing: border-box;
      transition: border-color 0.2s, transform 0.2s, background 0.2s;
    }

    :host([enabled]) .card {
      background: var(--hf-surface-2);
    }

    /* Link mode (Home launcher) — lift slightly on hover. */
    a.card:hover {
      border-color: var(--hf-accent);
      background: var(--hf-surface-3);
      transform: translateY(-1px);
    }

    /* The head row wraps: on a card too narrow to seat the title and
       the header slot side by side (a single-column phone layout), the
       header slot drops to its own line below the icon/title instead of
       overflowing the card's right edge. row-gap spaces that wrapped
       line; on wide cards nothing wraps and row-gap is inert. */
    .head {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: 10px 12px;
      min-width: 0;
    }

    /* Optional header slot — pinned to the right edge of the head row
       (status badge + action icons on the admin card). margin-left:auto
       pushes it past the flexible .titles column. Empty on the Home
       launcher, where it collapses to nothing. When the row wraps it
       sits on its own line; margin-left:auto then right-aligns it. */
    .head-aside {
      margin-left: auto;
      flex-shrink: 0;
      display: flex;
      align-items: center;
    }

    .icon {
      width: 40px;
      height: 40px;
      flex-shrink: 0;
      border-radius: 9px;
      background: rgba(255, 255, 255, 0.06);
      display: grid;
      place-items: center;
      overflow: hidden;
      color: var(--hf-text-muted);
      font-size: 14px;
      font-weight: 700;
      letter-spacing: -0.02em;
    }
    :host([compact]) .icon {
      width: 32px;
      height: 32px;
      border-radius: 8px;
      font-size: 13px;
    }
    /* Icons are full-colour brand SVGs — render them as-is, no filter. */
    .icon img {
      width: 78%;
      height: 78%;
      object-fit: contain;
    }

    /* The flexible column of the head row: it must grow into the space
       left by the icon and the (fixed-size) header slot. Without an
       explicit flex-grow it defaults to flex:0 1 auto and loses the
       shrink contest to the header slot, collapsing the name to a few
       clipped letters. flex:1 makes it claim free space.
       The 140px min-width is the wrap trigger: on a card too narrow to
       seat icon + 140px title + the header slot, flexbox wraps the
       header slot to its own line instead of crushing the title to
       nothing. The name still ellipsis-truncates inside this column. */
    .titles {
      flex: 1;
      min-width: 140px;
    }
    .name {
      font-weight: 600;
      font-size: 0.96rem;
      letter-spacing: -0.01em;
      margin: 0 0 2px;
      color: var(--hf-text);
      /* Admin cards are wide — a long name ellipsis-truncates on one
         line so the row geometry stays predictable. */
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    /* Compact (Home launcher) tiles are narrow, so truncating clips a
       third of the names. Let the name wrap to at most two lines and
       only ellipsis past that — nothing short gets cut off. */
    :host([compact]) .name {
      white-space: normal;
      display: -webkit-box;
      -webkit-box-orient: vertical;
      -webkit-line-clamp: 2;
      line-clamp: 2;
      overflow-wrap: anywhere;
    }
    .sub {
      font-size: 0.78rem;
      color: var(--hf-text-subtle);
      margin: 0;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    /* Slotted admin content (status, toggles, buttons) sits below the
       header. On the Home launcher nothing is slotted, so the body is
       not rendered at all (see _hasBody / slotchange). */
    .body {
      margin-top: 14px;
    }
  `;

  constructor() {
    super();
    this.label = '';
    this.name = '';
    this.subtitle = '';
    this.href = '';
    this.enabled = false;
    this.compact = false;
    this._hasBody = false;
    this._hasHeader = false;
  }

  /** Track whether the default slot has any assigned content. */
  _onSlotChange(e) {
    this._hasBody = e.target.assignedNodes({ flatten: true }).length > 0;
  }

  /** Track whether the named `header` slot has any assigned content. */
  _onHeaderSlotChange(e) {
    this._hasHeader = e.target.assignedNodes({ flatten: true }).length > 0;
  }

  /** Two-letter initials fallback, derived from the display name. */
  _initials() {
    const t = this.name || this.label || '?';
    return t
      .split(/[\s\-_/]+/)
      .map((w) => w.charAt(0))
      .join('')
      .slice(0, 2)
      .toUpperCase();
  }

  /** Swap the failed <img> for its initials text. */
  _onIconError(e) {
    const img = e.currentTarget;
    const parent = img.parentElement;
    if (parent) parent.textContent = img.getAttribute('data-initials') || '?';
  }

  _renderInner() {
    const initials = this._initials();
    const sub =
      this.subtitle && this.subtitle !== this.name ? this.subtitle : '';
    return html`
      <div class="head">
        <div class="icon">
          <img
            src="/icons/${this.label}.svg"
            alt=""
            data-initials="${initials}"
            @error=${this._onIconError}
          />
        </div>
        <div class="titles">
          <p class="name">${this.name || this.label}</p>
          ${sub ? html`<p class="sub">${sub}</p>` : ''}
        </div>
        <div class="head-aside" style=${this._hasHeader ? '' : 'display: none;'}>
          <slot name="header" @slotchange=${this._onHeaderSlotChange}></slot>
        </div>
      </div>
      <div class="body" style=${this._hasBody ? '' : 'margin-top: 0;'}>
        <slot @slotchange=${this._onSlotChange}></slot>
      </div>
    `;
  }

  render() {
    if (this.href) {
      return html`
        <a class="card" href="${this.href}" target="_blank" rel="noopener">
          ${this._renderInner()}
        </a>
      `;
    }
    return html`<div class="card">${this._renderInner()}</div>`;
  }
}

customElements.define('app-card', AppCard);
