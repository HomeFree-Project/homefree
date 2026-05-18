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

    .head {
      display: flex;
      align-items: center;
      gap: 12px;
      min-width: 0;
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

    .titles {
      min-width: 0;
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
  }

  /** Track whether the default slot has any assigned content. */
  _onSlotChange(e) {
    this._hasBody = e.target.assignedNodes({ flatten: true }).length > 0;
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
