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
    host: { type: String },          // Home launcher: host line under the name
    description: { type: String },   // Home launcher: tile tagline
    href: { type: String },
    enabled: { type: Boolean, reflect: true },
    compact: { type: Boolean, reflect: true },
    muted: { type: Boolean, reflect: true },       // Home launcher: a hidden app revealed via "Show hidden"
    undeployed: { type: Boolean, reflect: true },  // has unapplied config changes
    _hasBody: { type: Boolean, state: true },
    _hasHeader: { type: Boolean, state: true },
    _hasStatus: { type: Boolean, state: true },
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
      /* Admin cards (non-compact) carry status + toggles + the
         Details/Config buttons but no inline config body, so they can be
         tight — keeps the one-per-row list from running tall. Symmetric
         padding now that the phantom .body margin (whitespace-only slot)
         is gone. The Home launcher keeps its roomier padding via the
         compact override. */
      padding: 11px 14px;
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

    /* Home launcher tiles keep the original roomier padding. */
    :host([compact]) .card {
      padding: 18px;
    }

    :host([enabled]) .card {
      background: var(--hf-surface-2);
    }

    /* A service with undeployed (changed-but-not-applied) config — amber wash
       + left bar. Placed after the enabled rule so it wins the background. */
    :host([undeployed]) .card {
      background: var(--hf-warn-soft);
      border-color: var(--hf-warn);
      box-shadow: inset 3px 0 0 0 var(--hf-warn);
    }

    /* A hidden app revealed via the Home "Show hidden" toggle — a clear
       dark-purple outline (+ faint wash) so it reads distinctly as
       normally-hidden. Solid, not dashed; the purple persists on hover. */
    :host([muted]) .card {
      border-color: #7c3aed;
      box-shadow: inset 0 0 0 1px #7c3aed;
      background: rgba(124, 58, 237, 0.08);
    }
    :host([muted]) a.card:hover {
      border-color: #7c3aed;
      background: rgba(124, 58, 237, 0.14);
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
       sits on its own line; margin-left:auto then right-aligns it.
       max-width:100% + min-width:0 caps the slot to the card width on
       a wrapped line, so slotted content with flex-wrap can fold inside
       the card instead of overflowing to the right. */
    .head-aside {
      margin-left: auto;
      flex-shrink: 0;
      max-width: 100%;
      min-width: 0;
      display: flex;
      align-items: center;
    }

    /* Status slot — a fixed cell between the icon and the title. The
       admin Apps card slots its status pill here so the pill's LEFT edge
       is constant across cards (it no longer rides the variable-width,
       right-anchored header cluster, which is what kept the pills from
       lining up). flex-shrink:0 keeps it at its natural/fixed width; the
       title column (.titles flex:1) absorbs the rest. Empty and collapsed
       on the Home launcher, which slots nothing here. */
    .head-status {
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
       nothing. The name still ellipsis-truncates inside this column.

       .titles is itself a wrapping flex row (column-direction by
       default would stack name above subtitle). With row-wrap, the
       name and a slotted subtitle (e.g. the service URL on the admin
       card) sit on the same line when there's room and the subtitle
       wraps below the name only when the column gets too narrow. The
       legacy .sub paragraph still flows below the name because it
       takes width:100% via the rule on .sub itself. */
    .titles {
      flex: 1;
      min-width: 140px;
      display: flex;
      flex-wrap: wrap;
      align-items: baseline;
      column-gap: 8px;
      row-gap: 2px;
    }
    .name {
      font-weight: 600;
      font-size: 0.96rem;
      letter-spacing: -0.01em;
      margin: 0;
      color: var(--hf-text);
      /* Admin cards are wide — a long name ellipsis-truncates on one
         line so the row geometry stays predictable. As a flex item in
         the wrapping .titles row, flex-shrink:0 keeps the name at its
         natural width so any slotted subtitle wraps to its own line
         instead of competing for room and triggering early ellipsis. */
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      max-width: 100%;
      flex: 0 0 auto;
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
      /* In the .titles flex-wrap row, force the legacy string subtitle
         onto its own line below name + any inline slotted subtitle. */
      flex: 0 0 100%;
      min-width: 0;
    }

    /* Home launcher: the service host (e.g. photos.homefree.host),
       monospace, on its own line below the name. flex:0 0 100% breaks
       it under the title in the wrapping .titles row. Only the Home
       launcher sets host; admin cards leave it empty. */
    .host {
      flex: 0 0 100%;
      min-width: 0;
      margin: 0;
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: 0.72rem;
      color: var(--hf-text-subtle);
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    /* Home launcher: the app tagline below the head row. Clamped to
       three lines so cards in a row stay close in height. */
    .desc {
      margin: 10px 0 0;
      font-size: 0.8rem;
      line-height: 1.4;
      color: var(--hf-text-muted);
      display: -webkit-box;
      -webkit-box-orient: vertical;
      -webkit-line-clamp: 3;
      line-clamp: 3;
      overflow: hidden;
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
    this.host = '';
    this.description = '';
    this.href = '';
    this.enabled = false;
    this.compact = false;
    this.muted = false;
    this._hasBody = false;
    this._hasHeader = false;
    this._hasStatus = false;
  }

  /** Whether a slot holds real content — element nodes or non-blank
      text. assignedNodes counts the whitespace text nodes that Lit
      leaves between conditional `${...}` slots, so an "empty" slot that
      only renders '' still looked occupied; that falsely set _hasBody and
      left a 14px margin-top gap at the bottom of the card. Filter those
      out so the flag reflects visible content only. */
  _slotHasContent(slot) {
    return slot.assignedNodes({ flatten: true }).some(
      (n) => n.nodeType === Node.ELEMENT_NODE ||
             (n.nodeType === Node.TEXT_NODE && n.textContent.trim() !== '')
    );
  }

  /** Track whether the default slot has any assigned content. */
  _onSlotChange(e) {
    this._hasBody = this._slotHasContent(e.target);
  }

  /** Track whether the named `header` slot has any assigned content. */
  _onHeaderSlotChange(e) {
    this._hasHeader = this._slotHasContent(e.target);
  }

  /** Track whether the named `status` slot has any assigned content. */
  _onStatusSlotChange(e) {
    this._hasStatus = this._slotHasContent(e.target);
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
        <div class="head-status" style=${this._hasStatus ? '' : 'display: none;'}>
          <slot name="status" @slotchange=${this._onStatusSlotChange}></slot>
        </div>
        <div class="titles">
          <p class="name">${this.name || this.label}</p>
          ${this.host ? html`<p class="host">${this.host}</p>` : ''}
          ${sub ? html`<p class="sub">${sub}</p>` : ''}
          <slot name="subtitle"></slot>
        </div>
        <div class="head-aside" style=${this._hasHeader ? '' : 'display: none;'}>
          <slot name="header" @slotchange=${this._onHeaderSlotChange}></slot>
        </div>
      </div>
      ${this.description ? html`<p class="desc">${this.description}</p>` : ''}
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
