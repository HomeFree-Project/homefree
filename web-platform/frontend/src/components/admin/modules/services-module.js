import { LitElement, html, css } from 'lit';
import { getServices, getServiceOptionsSchema, postServiceAction } from '../../../api/client.js';
import '../../shared/config-section.js';
import '../../shared/app-card.js';
import '../secrets-input.js';
import '../service-option-input.js';
import { confirmDialog } from '../../shared/confirm-dialog.js';
import { actionIcon } from '../../../shared/icons.js';

/**
 * Services configuration module
 * Displays all services with runtime status, enable/disable toggles, and public access settings
 */
class ServicesModule extends LitElement {
  static properties = {
    services: { type: Array },           // Display array (merged view for UI)
    serverConfig: { type: Object },      // Server/deployed state (from parent)
    pendingConfig: { type: Object },     // Pending changes (from parent)
    loading: { type: Boolean },
    error: { type: String },
    searchQuery: { type: String },
    sortKey: { type: String, state: true },   // 'name' | 'exposed' | 'enabled' | 'status'
    sortDir: { type: String, state: true },   // 'asc' | 'desc'
    apiUnavailable: { type: Boolean },   // Track if API is temporarily down
    secretsSchema: { type: Object },     // Secrets schema for all services
    secretsStatus: { type: Object },     // Status of which secrets are set
    optionsSchema: { type: Object },     // Service options schema for all services
    hasAuthorizedKeys: { type: Boolean }, // Whether SSH keys are configured (from parent)
    undeployedPaths: { attribute: false }, // Set<dotted-path> not yet deployed
    appliedConfig: { attribute: false },   // deployed baseline (reserved)
    // The open config modal, or null. { id: expandId, view: 'details' | 'config' }.
    // Only one modal is open at a time (no stacking).
    openModal: { type: Object, state: true },
    pendingActions: { type: Object, state: true }, // {label: 'start'|'restart'|'stop'} while in-flight
    actionErrors: { type: Object, state: true } // {label: 'message'} last error per service
  };

  static styles = css`
    :host {
      display: block;
    }

    .module-container {
      width: 100%;
    }

    .info-box {
      background: var(--hf-surface-2);
      border-radius: 8px;
      padding: 16px;
      margin-bottom: 20px;
      font-size: 14px;
      color: var(--hf-text);
      display: flex;
      align-items: center;
      justify-content: space-between;
    }

    .info-text {
      flex: 1;
    }

    /* Unified notification box — grey-tinted bg, colored left edge. */
    .warning-box {
      background: rgba(59, 130, 246, 0.08);
      border-left: 4px solid var(--hf-warn);
      border-radius: 8px;
      padding: 14px 18px;
      margin-bottom: 16px;
      font-size: 13px;
      line-height: 1.5;
      color: var(--hf-text-muted);
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .warning-box::before {
      content: '⚠️';
      font-size: 16px;
    }

    /* Sticky sort/filter bar. Pins to the top of the .content-area
       scroll viewport (admin-app.js moved its top padding onto the
       module's first child specifically so position:sticky;top:0 pins
       flush). The negative margin-top + padding-top trick extends the
       bar's background up into the gutter so content scrolling under it
       doesn't peek out above. Reuses the same approach as the Backups
       module's .tabs strip, but rendered as pill-shaped sort selectors
       — these are not tabs and shouldn't look like them. */
    .filter-bar {
      position: sticky;
      top: 0;
      z-index: 5;
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      margin-top: -24px;
      padding: 16px 0 12px;
      margin-bottom: 16px;
      background: var(--hf-bg);
      border-bottom: 1px solid var(--hf-border);
    }
    .sort-group {
      display: flex;
      flex-wrap: wrap;
      gap: 6px;
    }
    .sort-btn {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 7px 12px;
      font-size: 13px;
      font-weight: 500;
      color: var(--hf-text-muted);
      background: var(--hf-surface);
      border: 1px solid var(--hf-border-2);
      border-radius: 999px;
      cursor: pointer;
      transition: color 0.15s, border-color 0.15s, background 0.15s;
      font-family: inherit;
    }
    .sort-btn:hover { color: var(--hf-text); border-color: var(--hf-accent); }
    .sort-btn.active {
      color: var(--hf-accent);
      border-color: var(--hf-accent);
      background: var(--hf-surface-3);
    }
    .sort-arrow {
      font-size: 11px;
      opacity: 0.85;
      width: 0.9em;
      text-align: center;
    }
    .filter-input {
      flex: 0 1 280px;
      min-width: 160px;
      padding: 8px 12px;
      font-size: 13px;
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      font-family: inherit;
      background: var(--hf-surface);
      color: var(--hf-text);
    }
    .filter-input:focus { outline: none; border-color: var(--hf-accent); }

    /* Card grid — single column. App Configuration is a list the user
       scans while flipping Enable / Exposed toggles, often in a row.
       Multi-column auto-fill caused cards to swap positions whenever
       the column count changed (window resize, devtools toggle, etc.)
       and amplified sort churn. One card per row keeps every card's
       position deterministic from one render to the next, which is
       what matters while configuring services. */
    .service-grid {
      display: grid;
      grid-template-columns: 1fr;
      gap: 12px;
    }

    /* ---- App card: inline header strip + URL under the name ----------
       The admin app card was a ragged stack of left-aligned rows. It is
       now an inline strip inside <app-card>'s header slot:
         status badge + lifecycle icon-buttons + Enable / Expose
         toggles, pinned beside the icon/title row.
       The service URL is slotted into the title column on its own
       line below the service name (the subtitle slot on <app-card>),
       matching the legacy project-name subtitle.
       The whole header strip wraps below the title on narrow / mobile
       cards, and its chips wrap among themselves on widths too narrow
       even for that.
       The SSO pill + per-unit systemd list open in the Details modal;
       the editable config form opens in the Config modal. ------------- */

    /* Zone 1 — header slot content (sits in <app-card>'s .head-aside).
       Contains the status badge, lifecycle icon buttons, the service
       URL link, and the Enabled / Exposed-to-internet toggles inline.
       Wraps to a second line on narrow cards: the inner flex row of
       app-card already wraps the whole head-aside below the title on a
       phone-width card, and this wrap lets the chips themselves drop
       across multiple lines if the badge + URL + toggles still don't
       fit on the wrapped line. */
    .card-head {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      justify-content: flex-end;
      gap: 6px 10px;
    }

    /* Service URL, slotted into <app-card>'s subtitle slot. It always
       sits on its own line below the service name (flex-basis:100% in
       the .titles wrapping row), matching the legacy project-name
       subtitle: a card with only a name and a card with a name +
       project subtitle then look consistent rather than one putting the
       URL inline and the other below. Single-line internally with
       ellipsis truncation so a long URL can't widen the title column;
       the full URL is on the title attribute and reachable via click. */
    .title-url {
      display: inline-flex;
      align-items: center;
      gap: 4px;
      font-size: 12px;
      color: var(--hf-accent);
      text-decoration: none;
      flex: 0 0 100%;
      min-width: 0;
      max-width: 100%;
    }
    .title-url:hover { text-decoration: underline; }
    .title-url > span {
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      min-width: 0;
    }
    .title-url svg {
      width: 11px;
      height: 11px;
      flex-shrink: 0;
      opacity: 0.8;
    }

    /* Status as a single pill: a coloured dot + word. Replaces the old
       loose dot+text row and the separate monospace systemd line. */
    .status-badge {
      display: inline-flex;
      align-items: center;
      /* The pill lives in app-card's fixed 'status' slot (between icon
         and title), so its LEFT edge is already constant across cards —
         alignment no longer depends on width. min-width just keeps every
         pill a uniform width (so the app names line up too), and center
         keeps the label centered within it. */
      justify-content: center;
      min-width: 92px;
      box-sizing: border-box;
      gap: 6px;
      padding: 3px 10px;
      border-radius: 999px;
      font-size: 11.5px;
      font-weight: 600;
      letter-spacing: 0.01em;
      white-space: nowrap;
      background: var(--hf-surface-3);
      color: var(--hf-text-muted);
    }
    .status-badge.running  { background: rgba(52,211,153,0.13);  color: var(--hf-ok); }
    .status-badge.failed   { background: rgba(239,68,68,0.13);   color: var(--hf-err); }
    .status-badge.degraded { background: rgba(245,158,11,0.13);  color: var(--hf-warn); }
    .status-badge.starting { background: rgba(245,158,11,0.13);  color: var(--hf-warn); }
    /* External (off-box reverse-proxy entry) — a neutral accent-tinted
       pill; it has no run-state to be good/bad about. */
    .status-badge.external { background: rgba(96,165,250,0.13);  color: var(--hf-accent); }

    /* Compact square lifecycle buttons (play / restart / stop). They sit
       in the header beside the badge — icon-only, with title tooltips —
       so they cost no vertical space on the card face. */
    .icon-actions {
      display: flex;
      gap: 4px;
    }
    .icon-action {
      width: 32px;
      height: 32px;
      padding: 0;
      display: grid;
      place-items: center;
      background: var(--hf-surface);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      color: var(--hf-text-muted);
      cursor: pointer;
      transition: background 0.15s, border-color 0.15s, color 0.15s;
    }
    .icon-action svg {
      width: 16px;
      height: 16px;
    }
    /* Invisible stand-in for a single lifecycle button. Matches the real
       button's full border-box footprint (32px + a 1px transparent
       border = 34px, same as .icon-action) so a card with no buttons
       reserves the identical header width — this lines the status pills
       up into a column. Mirrors .hf-btn-spacer. */
    .icon-action-spacer {
      display: inline-block;
      width: 32px;
      height: 32px;
      border: 1px solid transparent;
      box-sizing: content-box;
      visibility: hidden;
    }
    .icon-action:hover:not(:disabled) {
      background: var(--hf-surface-3);
      border-color: var(--hf-accent);
      color: var(--hf-text);
    }
    .icon-action.danger:hover:not(:disabled) {
      border-color: var(--hf-err);
      color: var(--hf-err);
    }
    .icon-action:disabled {
      opacity: 0.35;
      cursor: not-allowed;
    }
    /* The in-flight button keeps a steady accent tint while its request
       is outstanding (the icon itself doesn't spin — title says why). */
    .icon-action.busy {
      border-color: var(--hf-accent);
      color: var(--hf-accent);
    }

    /* SSO posture as a pill (inside the "Details & Config" expander).
       Mirrors the .status-badge pill so it reads as a badge, not as a
       link — the old inline coloured text was indistinguishable from
       the URL anchor. */
    .sso-pill {
      display: inline-flex;
      align-items: center;
      padding: 3px 9px;
      border-radius: 999px;
      font-size: 11.5px;
      font-weight: 600;
      letter-spacing: 0.01em;
      white-space: nowrap;
      background: var(--hf-surface-3);
      color: var(--hf-text-muted);
    }
    .sso-pill.ok       { background: rgba(52,211,153,0.13); color: var(--hf-ok); }
    .sso-pill.warn     { background: rgba(245,158,11,0.13); color: var(--hf-warn); }
    .sso-pill.disabled { background: var(--hf-surface-3);   color: var(--hf-text-subtle); }

    /* A system service (admin/admin-api) has no toggles in the header
       slot — show a single muted note pinned to the bottom of the card
       so the card still reads as having a base. The Enabled / Exposed
       toggles for normal services live inline in the header (.card-head),
       not in a separate footer block. */
    .system-note {
      margin-top: 12px;
      padding-top: 12px;
      border-top: 1px solid var(--hf-border);
      font-size: 12px;
      color: var(--hf-text-subtle);
    }

    /* The Details and Config buttons live in the header strip beside the
       toggles. Both are icon-only square buttons (info / gear) in the
       site's canonical secondary-button style (border + surface-2, radius
       6px — same family as .btn-secondary in progress-modal.js). Clicking
       opens the corresponding modal, keeping the card face short.

       Both buttons are CONDITIONAL. To stop a present/absent button from
       shifting the row and misaligning cards, the pair lives in a
       fixed-geometry .head-buttons box (two 32px slots + gap), and an
       invisible same-size .hf-btn-spacer stands in for an absent button.
       Icon-only keeps that reserved gap small. */
    .head-buttons {
      display: flex;
      align-items: center;
      justify-content: flex-end;
      gap: 6px;
      flex-shrink: 0;
    }
    .hf-btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      font-family: inherit;
      color: var(--hf-text);
      background: var(--hf-surface-2);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      cursor: pointer;
      box-sizing: border-box;
      transition: background 0.15s, border-color 0.15s, color 0.15s;
    }
    .hf-btn:hover {
      background: var(--hf-surface-3);
      border-color: var(--hf-text-subtle);
    }
    /* Square icon-only button (Details / Config). */
    .hf-btn-icon {
      width: 32px;
      height: 32px;
      padding: 0;
    }
    .hf-btn svg {
      width: 18px;
      height: 18px;
      opacity: 0.9;
    }
    /* Invisible stand-in that keeps the row geometry fixed when a button
       is absent. flex-shrink:0 so it never collapses. */
    .hf-btn-spacer {
      display: inline-block;
      flex-shrink: 0;
      visibility: hidden;
      width: 32px;
      height: 32px;
    }
    /* Gear/Config button when the service has changed-but-unapplied options
       inside its config modal — amber border + tint points you to it. */
    .hf-btn.config-changed,
    .hf-btn.config-changed:hover {
      border-color: var(--hf-warn);
      background: var(--hf-warn-soft);
      color: var(--hf-warn);
    }

    /* ---- Config modal -----------------------------------------------
       Unlike the other (fixed-width, centred) modals on the site, the
       service config modal tracks the WIDTH OF THE CONTENT SECTION with
       a gutter on each side — a service's config can be a wide form +
       systemd unit list, and a narrow centred card would force a lot of
       wrapping. It is capped at the app-wide content max so it lines up
       with the section behind it, and scrolls vertically when its
       content is taller than the viewport. */
    .config-modal-overlay {
      position: fixed;
      top: 0; left: 0; right: 0; bottom: 0;
      background: rgba(0, 0, 0, 0.7);
      backdrop-filter: blur(2px);
      display: flex;
      align-items: flex-start;
      justify-content: center;
      padding: 24px;
      box-sizing: border-box;
      z-index: 1000;
    }
    .config-modal {
      width: 100%;
      max-width: var(--hf-content-max);
      max-height: calc(100vh - 48px);
      overflow-y: auto;
      background: var(--hf-surface-2);
      border: 1px solid var(--hf-border-2);
      border-radius: 12px;
      box-shadow: var(--hf-shadow-lg);
      color: var(--hf-text);
      box-sizing: border-box;
    }
    /* Sticky header so the title + close stay reachable while the body
       scrolls. */
    .config-modal-header {
      position: sticky;
      top: 0;
      z-index: 1;
      display: flex;
      align-items: center;
      gap: 12px;
      padding: 18px 20px;
      background: var(--hf-surface-2);
      border-bottom: 1px solid var(--hf-border);
    }
    .config-modal-header .icon {
      width: 32px;
      height: 32px;
    }
    .config-modal-title {
      flex: 1;
      min-width: 0;
      font-size: 16px;
      font-weight: 600;
      letter-spacing: -0.01em;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .config-modal-close {
      flex-shrink: 0;
      width: 30px;
      height: 30px;
      display: grid;
      place-items: center;
      padding: 0;
      font-size: 18px;
      line-height: 1;
      color: var(--hf-text-muted);
      background: var(--hf-surface);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      cursor: pointer;
      transition: background 0.15s, border-color 0.15s, color 0.15s;
    }
    .config-modal-close:hover {
      background: var(--hf-surface-3);
      border-color: var(--hf-accent);
      color: var(--hf-text);
    }
    .config-modal-body {
      padding: 4px 0 8px;
    }

    @keyframes pulse {
      0%, 100% {
        opacity: 1;
      }
      50% {
        opacity: 0.5;
      }
    }

    @keyframes pulse {
      0%, 100% {
        opacity: 1;
      }
      50% {
        opacity: 0.5;
      }
    }

    /* ---- Systemd units list (inside the "Details & Config" expander) --
       The per-unit health that used to crowd the card face now lives
       here: one row per unit, a small status dot + the unit name. */
    .systemd-units {
      display: flex;
      flex-direction: column;
      gap: 6px;
    }
    .systemd-unit {
      display: flex;
      align-items: center;
      gap: 8px;
      font-size: 12px;
      font-family: 'SF Mono', Monaco, 'Courier New', monospace;
      color: var(--hf-text-muted);
    }
    .unit-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      flex-shrink: 0;
      background: var(--hf-border-2);
    }
    .unit-dot.unit-ok       { background: var(--hf-ok); }
    .unit-dot.unit-bad      { background: var(--hf-err); }
    .unit-dot.unit-starting { background: var(--hf-warn); animation: pulse 1.5s ease-in-out infinite; }
    /* A blue/green standby unit being inactive is its expected steady
       state, not an error — render it muted, like an unknown unit. */
    .unit-dot.unit-standby,
    .unit-dot.unit-unknown  { background: var(--hf-text-subtle); }

    /* Each toggle is a compact label+switch widget that lives inline
       in the card header alongside the status badge. The label and
       switch sit shoulder-to-shoulder with a fixed gap so the widget
       reads as one unit regardless of how wide the card is — on a
       one-card-per-row layout the row is the full content width
       (1200px+ on a desktop) and any margin-left:auto here would fling
       the label and switch to opposite edges of the card. */
    .toggle-container {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      flex-shrink: 0;
      /* Every toggle carries the pill's padding + a transparent border,
         even when off, so the public-on tint only changes COLOUR
         and never the box size. Otherwise toggling Exposed widened the
         chip and knocked the header controls out of alignment with the
         neighbouring cards. */
      padding: 4px 10px;
      border: 1px solid transparent;
      border-radius: 999px;
    }
    /* When the service is exposed to the internet the chip gets a
       blue 'external' tint so the security-relevant state is obvious
       at a glance, reusing the same hue as status-badge.external
       (which already means 'reachable from outside' in this module).
       Why not amber: amber is reserved throughout the admin UI for
       pending unbuilt changes (--hf-warn-soft on undeployed rows /
       instance groups), so an amber Exposed chip read as "this toggle
       has unsaved changes" instead of "this service is publicly
       exposed". Why not red: red is the failed/error state and made
       the exposed chip read as a fault condition. Blue is semantically
       'external' and carries neither overload. Opacity/border slightly
       lifted vs. the 0.13 status-badge fills so the chip is legible
       against the card header. Same box size as the off state
       (see above). */
    .toggle-container.public-on {
      background: rgba(96,165,250,0.18);
      border-color: rgba(96,165,250,0.5);
      color: #60a5fa;
    }
    .toggle-container.public-on .toggle-label {
      /* Colour alone signals the exposed state (plus the blue pill bg).
         No font-weight change: a bolder label is physically wider than
         the normal-weight OFF label, which made ON toggles wider than OFF
         and broke header alignment across cards. */
      color: #60a5fa;
    }

    /* Invisible stand-in for the absent Exposed toggle on a DISABLED app,
       so its Enabled toggle lines up with enabled cards. Same markup as a
       real toggle, so its width matches exactly; just non-interactive and
       not painted. Collapsed on mobile (the header stacks there, so no
       reservation is needed). */
    .toggle-spacer {
      visibility: hidden;
      pointer-events: none;
    }

    .toggle-label {
      font-size: 13px;
      color: var(--hf-text-muted);
    }

    .toggle-switch {
      position: relative;
      width: 44px;
      height: 24px;
    }

    .toggle-switch input {
      opacity: 0;
      width: 0;
      height: 0;
    }

    .toggle-slider {
      position: absolute;
      cursor: pointer;
      top: 0;
      left: 0;
      right: 0;
      bottom: 0;
      background-color: var(--hf-border-2);
      transition: 0.3s;
      border-radius: 24px;
    }

    .toggle-slider:before {
      position: absolute;
      content: "";
      height: 18px;
      width: 18px;
      left: 3px;
      bottom: 3px;
      background-color: var(--hf-text);
      transition: 0.3s;
      border-radius: 50%;
    }

    input:checked + .toggle-slider {
      background-color: var(--hf-accent);
    }

    input:checked + .toggle-slider:before {
      transform: translateX(20px);
    }

    input:disabled + .toggle-slider {
      opacity: 0.5;
      cursor: not-allowed;
    }

    /* ---- Mobile header layout --------------------------------------
       On a phone-width card the header strip (which app-card has already
       wrapped to its own line below the title) is too cramped to keep
       the status badge, lifecycle buttons and both toggles on one
       right-aligned row — they spill and look ragged. At <=600px we
       stack the header cluster left-justified instead:
         line 1: status badge + start/restart/stop buttons
         line 2: Enabled toggle, on its own full-width line
         line 3: Exposed-to-internet toggle, on its own full-width line
       Each toggle is reversed so the switch sits at the left edge and
       its label reads to the right of it. */
    @media (max-width: 600px) {
      .card-head {
        justify-content: flex-start;
      }
      /* First line shares the lifecycle buttons (left) and the
         Details/Config buttons (right). The flex 'order' property pulls
         .head-buttons up beside .icon-actions ahead of the toggles, and
         margin-left:auto right-aligns it on that line; the toggles
         (higher order, full width) wrap to their own lines below. */
      .icon-actions { order: 0; }
      .head-buttons {
        order: 1;
        margin-left: auto;
      }
      .toggle-container {
        order: 2;
        flex: 0 0 100%;
        /* Switch on the left, label to its right, both packed left. */
        flex-direction: row-reverse;
        justify-content: flex-end;
      }
      /* No need to reserve the absent Exposed toggle on mobile — the
         header stacks full-width, so there is nothing to line up. */
      .toggle-spacer {
        display: none;
      }
      /* The exposed-to-internet pill would otherwise stretch full-width
         with a lot of dead tint to the right; shrink it back to hug its
         contents while still starting its own line via the wrap above. */
      .toggle-container.public-on {
        flex-basis: auto;
      }
      /* Instance-group header: let its actions wrap left-justified below
         the name instead of clinging to the right edge. */
      .instance-group-actions {
        margin-left: 0;
        flex-wrap: wrap;
        width: 100%;
        justify-content: flex-start;
      }
      /* The config modal goes near-fullscreen on a phone: a thin gutter,
         rounded a little less, using the full available height. */
      .config-modal-overlay {
        padding: 12px;
        align-items: stretch;
      }
      .config-modal {
        max-height: calc(100vh - 24px);
        border-radius: 10px;
      }
      .config-modal-header {
        padding: 14px 16px;
      }
    }

    .secrets-section {
      padding: 16px;
    }

    .secrets-header {
      font-size: 14px;
      font-weight: 500;
      color: var(--hf-accent);
      margin-bottom: 12px;
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .secrets-content {
      padding-left: 24px;
    }

    .loading-spinner {
      text-align: center;
      padding: 40px;
      color: var(--hf-text-muted);
    }

    .error-box {
      background: rgba(59, 130, 246, 0.08);
      border-left: 4px solid var(--hf-err);
      border-radius: 8px;
      padding: 14px 18px;
      margin-bottom: 20px;
      font-size: 13px;
      line-height: 1.5;
      color: var(--hf-text-muted);
    }
    .error-box strong { color: var(--hf-text); }

    .no-results {
      text-align: center;
      padding: 40px;
      color: var(--hf-text-muted);
    }

    .refresh-button {
      background: var(--hf-accent);
      color: #06281c;
      border: none;
      padding: 8px 16px;
      border-radius: 6px;
      font-size: 13px;
      cursor: pointer;
      margin-left: 12px;
      transition: background 0.2s;
    }

    .refresh-button:hover {
      background: var(--hf-accent-hover);
    }

    .refresh-button:disabled {
      background: var(--hf-border-2);
      cursor: not-allowed;
    }

    /* ---- Instance group box -----------------------------------------
       MediaWiki / Minecraft etc. have no units of their own — the units
       live on each child instance. Rather than a button-less, misleading
       parent card, the parent is a group BOX (same width as a normal
       card) that frames its instance cards: a header (icon + name +
       enable toggle + optional parent Config) and the child <app-card>s
       nested inside. The children are ordinary cards, so their inner
       elements line up with the single-service cards in the list. */
    .instance-group {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border);
      border-radius: 12px;
      padding: 11px 14px;
      box-sizing: border-box;
    }
    .instance-group.enabled {
      background: var(--hf-surface-2);
    }
    .instance-group-head {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: 10px 12px;
    }
    .instance-group-head .icon {
      width: 40px;
      height: 40px;
      flex-shrink: 0;
      border-radius: 9px;
      background: rgba(255, 255, 255, 0.06);
      display: grid;
      place-items: center;
      overflow: hidden;
    }
    .instance-group-head .icon img {
      width: 78%;
      height: 78%;
      object-fit: contain;
    }
    .instance-group-title {
      flex: 1;
      min-width: 140px;
      display: flex;
      align-items: baseline;
      flex-wrap: wrap;
      column-gap: 8px;
    }
    .instance-group-name {
      font-weight: 600;
      font-size: 0.96rem;
      letter-spacing: -0.01em;
      color: var(--hf-text);
    }
    .instance-group-count {
      font-size: 0.78rem;
      color: var(--hf-text-subtle);
    }
    .instance-group-actions {
      margin-left: auto;
      display: flex;
      align-items: center;
      gap: 6px 10px;
      flex-shrink: 0;
    }
    /* The instance cards, inset under the group header with a rail so the
       grouping reads clearly. Each child is a full <app-card>. */
    .instance-group-children {
      margin-top: 10px;
      padding-left: 14px;
      border-left: 2px solid var(--hf-border);
      display: flex;
      flex-direction: column;
      gap: 10px;
    }
    .instance-group-empty {
      margin-top: 10px;
      padding-left: 14px;
      font-size: 13px;
      color: var(--hf-text-subtle);
    }

    /* "+ Add Instance" — the site's canonical add affordance, matching
       .add-row-btn in shared/table-editor.js and users-module.js: a
       full-width footer button, surface-2 background with green CENTERED
       text and a top-border separator — NOT a bright-green slab, and
       centered like the add buttons on the other list pages. */
    .add-row-btn {
      display: block;
      width: 100%;
      margin-top: 10px;
      padding: 11px;
      background: var(--hf-surface-2);
      border: none;
      border-top: 1px solid var(--hf-border);
      color: var(--hf-accent);
      font-size: 13px;
      font-weight: 500;
      font-family: inherit;
      text-align: center;
      cursor: pointer;
      transition: background 0.15s;
    }
    .add-row-btn:hover {
      background: var(--hf-surface-3);
    }

    /* Row/secondary buttons — the site's canonical bordered style
       (matches .btn-row in shared/table-editor.js). The .delete variant
       is the standard bordered-red danger button (transparent bg, red
       text + faint red border), used for "Remove instance". */
    .btn-row {
      background: var(--hf-surface-2);
      border: 1px solid var(--hf-border-2);
      color: var(--hf-text);
      cursor: pointer;
      padding: 5px 12px;
      border-radius: 6px;
      font-size: 12px;
      font-weight: 500;
      font-family: inherit;
      transition: all 0.15s;
    }
    .btn-row:hover {
      background: var(--hf-surface-3);
      border-color: var(--hf-text-subtle);
    }
    .btn-row.delete {
      color: var(--hf-err);
      border-color: color-mix(in srgb, var(--hf-err) 45%, transparent);
    }
    .btn-row.delete:hover {
      background: color-mix(in srgb, var(--hf-err) 14%, transparent);
      border-color: var(--hf-err);
    }

    /* A failed lifecycle action surfaces its error under the toggle
       footer (the icon-buttons themselves are too small to caption). */
    .action-error {
      color: var(--hf-err);
      font-size: 11px;
      margin-top: 8px;
      word-break: break-word;
    }

    /* The card grid is responsive on its own (auto-fill minmax) — it
       collapses to one column on narrow screens with no extra rules. */
  `;

  constructor() {
    super();
    this.services = [];
    this.serverConfig = null;
    this.pendingConfig = {};
    this.loading = true;
    this.error = null;
    this.searchQuery = '';
    this.sortKey = 'name';
    this.sortDir = 'asc';
    this.apiUnavailable = false;
    this.pollInterval = null;
    this.pollIntervalMs = 5000; // Poll every 5 seconds
    this.secretsSchema = {};
    this.secretsStatus = {};
    this.optionsSchema = {};
    this.hasAuthorizedKeys = false;
    this.undeployedPaths = new Set();
    this.appliedConfig = null;
    this.openModal = null;
    this.pendingActions = {};
    this.actionErrors = {};
  }

  async connectedCallback() {
    super.connectedCallback();

    // CRITICAL: Stop polling before page unload to prevent connection limit race condition
    this.beforeUnloadHandler = () => {
      this.stopPolling();
    };
    window.addEventListener('beforeunload', this.beforeUnloadHandler);

    // Escape closes any open config modal (matches the site's modals).
    this.keydownHandler = (e) => {
      if (e.key === 'Escape' && this.openModal) {
        this.openModal = null;
      }
    };
    window.addEventListener('keydown', this.keydownHandler);

    await Promise.all([
      this.loadServices(),
      this.loadSecretsData(),
      this.loadOptionsSchema()
    ]);
    this.startPolling();
  }

  disconnectedCallback() {
    super.disconnectedCallback();

    // Remove beforeunload listener
    if (this.beforeUnloadHandler) {
      window.removeEventListener('beforeunload', this.beforeUnloadHandler);
    }
    if (this.keydownHandler) {
      window.removeEventListener('keydown', this.keydownHandler);
    }

    this.stopPolling();
  }

  startPolling() {
    // Clear any existing interval
    this.stopPolling();

    // Start polling for service status updates
    this.pollInterval = setInterval(async () => {
      await this.loadServices(false); // Don't show loading spinner on polls
    }, this.pollIntervalMs);
  }

  stopPolling() {
    if (this.pollInterval) {
      clearInterval(this.pollInterval);
      this.pollInterval = null;
    }
  }

  async loadServices(showLoadingSpinner = true) {
    // Only show loading spinner on initial load, not on polling updates
    if (showLoadingSpinner && this.services.length === 0) {
      this.loading = true;
    }
    // Don't clear error on retry - let it persist until successful load
    // this.error = null;

    try {
      const services = await getServices();

      // Clear error and API unavailable flag on successful load
      this.error = null;
      this.apiUnavailable = false;

      // Merge server services with pending changes for display
      // Pending changes from parent override server state
      this.services = services.map(service => {
        const pendingService = this.pendingConfig?.services?.[service.label];
        if (pendingService) {
          // Use pending values for enabled/public, but keep runtime status from server
          return {
            ...service,
            enabled: pendingService.enable,
            public: pendingService.public
          };
        }
        // No pending changes for this service, use server data
        return service;
      });
    } catch (error) {
      console.error('Error loading services:', error);
      // Only show error if we have no services to display (first load failed)
      // Otherwise, keep showing stale data during temporary API unavailability
      if (this.services.length === 0) {
        this.error = error.message || 'Failed to load services';
        this.apiUnavailable = false;
      } else {
        // Mark API as temporarily unavailable but keep showing cached data
        this.apiUnavailable = true;
        console.warn('API temporarily unavailable, showing cached service list');
      }
    } finally {
      this.loading = false;
    }
  }

  async loadSecretsData() {
    try {
      // Load secrets schema
      const schemaResponse = await fetch('/api/secrets/schema');
      if (schemaResponse.ok) {
        const schemaData = await schemaResponse.json();
        this.secretsSchema = schemaData.schema || {};
      }

      // Load secrets status
      const statusResponse = await fetch('/api/secrets/status');
      if (statusResponse.ok) {
        const statusData = await statusResponse.json();
        this.secretsStatus = statusData.secrets || {};
      }

      // Note: hasAuthorizedKeys is now passed from parent (admin-app)
    } catch (error) {
      console.error('Error loading secrets data:', error);
      // Non-fatal - secrets UI will show appropriate disabled state
    }
  }

  async loadOptionsSchema() {
    try {
      const response = await fetch('/api/services/options/schema');
      if (response.ok) {
        const data = await response.json();
        this.optionsSchema = data.schema || {};
      }
    } catch (error) {
      console.error('Error loading service options schema:', error);
      // Non-fatal - options will just not display if schema fails to load
    }
  }

  // Open the Details (read-only info) or Config (editable) modal for a
  // service. Clicking the same button again closes it; only one modal is
  // open at a time.
  openConfigModal(expandId, view) {
    if (this.openModal && this.openModal.id === expandId && this.openModal.view === view) {
      this.openModal = null;
    } else {
      this.openModal = { id: expandId, view };
    }
  }

  closeConfigModal() {
    this.openModal = null;
  }

  async handleSecretUpdated(event) {
    // Reload secrets status after a secret is updated
    await this.loadSecretsData();
  }

  handleServiceToggle(serviceLabel, enabled) {
    // Update local services array for immediate UI feedback
    this.services = this.services.map(s =>
      s.label === serviceLabel ? { ...s, enabled } : s
    );

    // Emit action event to parent - parent manages state
    this.dispatchEvent(new CustomEvent('service-toggle', {
      detail: { serviceLabel, enabled },
      bubbles: true,
      composed: true
    }));
  }

  handlePublicToggle(serviceLabel, isPublic) {
    // Update local services array for immediate UI feedback
    this.services = this.services.map(s =>
      s.label === serviceLabel ? { ...s, public: isPublic } : s
    );

    // Emit action event to parent - parent manages state
    this.dispatchEvent(new CustomEvent('service-public-toggle', {
      detail: { serviceLabel, isPublic },
      bubbles: true,
      composed: true
    }));
  }

  // External-proxy services (no systemd units) carry their enable/public in
  // their service-config entry, not services.<label>. Route the toggle there
  // so it actually takes effect (and doesn't write dead config that the
  // catalog ignores). admin-app updates the matching service-config[] row.
  _emitExternalToggle(label, field, value) {
    // Optimistic local update so the toggle reflects immediately.
    this.services = this.services.map(s =>
      s.label === label ? { ...s, [field === 'enable' ? 'enabled' : 'public']: value } : s
    );
    this.dispatchEvent(new CustomEvent('external-proxy-toggle', {
      detail: { label, field, value },
      bubbles: true,
      composed: true,
    }));
  }

  handleInstanceToggle(parentLabel, instanceLabel, enabled) {
    // Update local services array for immediate UI feedback
    this.services = this.services.map(s =>
      s.label === instanceLabel ? { ...s, enabled } : s
    );

    // Emit action event to parent - parent manages state
    this.dispatchEvent(new CustomEvent('instance-toggle', {
      detail: { parentLabel, instanceLabel, enabled },
      bubbles: true,
      composed: true
    }));
  }

  handleInstancePublicToggle(parentLabel, instanceLabel, isPublic) {
    // Update local services array for immediate UI feedback
    this.services = this.services.map(s =>
      s.label === instanceLabel ? { ...s, public: isPublic } : s
    );

    // Emit action event to parent - parent manages state
    this.dispatchEvent(new CustomEvent('instance-public-toggle', {
      detail: { parentLabel, instanceLabel, isPublic },
      bubbles: true,
      composed: true
    }));
  }

  handleOptionChanged(serviceLabel, optionKey, value) {
    // Emit action event to parent - parent manages all config state
    this.dispatchEvent(new CustomEvent('service-option-changed', {
      detail: { serviceLabel, optionKey, value },
      bubbles: true,
      composed: true
    }));
  }

  handleInstanceFieldChanged(parentLabel, instanceIndex, fieldKey, value) {
    // Emit action event to parent - parent manages all config state
    this.dispatchEvent(new CustomEvent('instance-field-changed', {
      detail: { parentLabel, instanceIndex, fieldKey, value },
      bubbles: true,
      composed: true
    }));
  }

  handleAddInstanceClick(parentLabel) {
    console.log('[handleAddInstanceClick] Called with parentLabel:', parentLabel);
    // Emit action event to parent - parent manages state
    this.dispatchEvent(new CustomEvent('instance-add', {
      detail: { parentLabel },
      bubbles: true,
      composed: true
    }));
    console.log('[handleAddInstanceClick] Event dispatched');
  }

  handleInstanceDeleteClick(parentLabel, instanceIndex) {
    // Emit action event to parent - parent manages state
    this.dispatchEvent(new CustomEvent('instance-delete', {
      detail: { parentLabel, instanceIndex },
      bubbles: true,
      composed: true
    }));
  }

  handleSearch(e) {
    this.searchQuery = e.target.value.toLowerCase();
  }

  handleSortClick(key) {
    if (this.sortKey === key) {
      this.sortDir = this.sortDir === 'asc' ? 'desc' : 'asc';
    } else {
      this.sortKey = key;
      this.sortDir = 'asc';
    }
  }

  renderSortBtn(key, label) {
    const active = this.sortKey === key;
    const arrow = !active ? '↕' : (this.sortDir === 'asc' ? '▲' : '▼');
    return html`
      <button
        class="sort-btn ${active ? 'active' : ''}"
        aria-pressed=${active ? 'true' : 'false'}
        @click=${() => this.handleSortClick(key)}
      >${label} <span class="sort-arrow">${arrow}</span></button>
    `;
  }

  async handleRefresh() {
    await this.loadServices();
  }

  async handleServiceAction(label, action) {
    if (action === 'stop') {
      const ok = await confirmDialog({
        title: 'Stop service?',
        message: `Stop ${label}? The service will not auto-restart until you start it manually or rebuild.`,
        confirmText: 'Stop',
        variant: 'danger',
      });
      if (!ok) return;
    }
    this.pendingActions = { ...this.pendingActions, [label]: action };
    this.actionErrors = { ...this.actionErrors, [label]: null };
    try {
      const res = await postServiceAction(label, action);
      if (!res || res.ok === false) {
        const firstErr = (res?.results || []).find(r => r.returncode !== 0);
        throw new Error(firstErr?.stderr || 'systemctl returned non-zero');
      }
      // Kick a status refresh so the UI catches up faster than the poll
      await this.loadServices(false);
    } catch (err) {
      console.error(`[handleServiceAction] ${action} ${label} failed:`, err);
      this.actionErrors = {
        ...this.actionErrors,
        [label]: err.message || `${action} failed`,
      };
    } finally {
      const next = { ...this.pendingActions };
      delete next[label];
      this.pendingActions = next;
    }
  }

  getStatusClass(activeState, subState, partial = false) {
    if (activeState === 'active' && subState === 'running') {
      return 'running';  // Green - includes partial
    } else if (activeState === 'active' && subState === 'degraded') {
      return 'degraded';  // Yellow - some units up, some down
    } else if (activeState === 'failed') {
      return 'failed';  // Red - all-failed case
    } else if (activeState === 'activating' || subState === 'start') {
      return 'starting';  // Orange
    } else if (activeState === 'inactive' || subState === 'dead') {
      return 'stopped';  // Grey
    }
    return 'unknown';  // Grey
  }

  getStatusText(activeState, subState, enabled, partial = false) {
    if (!enabled) {
      return 'Disabled';
    }
    if (activeState === 'active' && subState === 'running') {
      return partial ? 'Running (partial)' : 'Running';
    } else if (activeState === 'active' && subState === 'degraded') {
      return 'Degraded';  // Some units up, some not
    } else if (activeState === 'failed') {
      return 'Failed';  // All units failed
    } else if (activeState === 'activating') {
      return 'Starting';
    } else if (activeState === 'inactive' && subState === 'dead') {
      return 'Stopped';
    } else if (activeState === 'reloading') {
      return 'Reloading';
    }
    return `${activeState} (${subState})`;
  }

  getChildServices(parentLabel) {
    // Get child services from backend
    const backendChildren = this.services.filter(s => s.parent === parentLabel);

    // Get instances from pending config, falling back to server config
    const pendingInstances = this.pendingConfig?.services?.[parentLabel]?.instances ||
                            this.serverConfig?.services?.[parentLabel]?.instances ||
                            [];

    if (pendingInstances.length === 0) {
      return backendChildren;
    }

    // Create child service objects for pending instances not yet in backend
    const pendingChildren = pendingInstances.map((inst, index) => {
      const instanceId = `${parentLabel}_${inst.subdomain}`;

      // Check if already exists in backend children
      const existingChild = backendChildren.find(child => child.label === instanceId);
      if (existingChild) {
        // Update existing child with pending config values
        return {
          ...existingChild,
          enabled: inst.enable ?? existingChild.enabled,
          public: inst.public ?? existingChild.public,
          instanceIndex: index  // Add stable instance index
        };
      }

      // Create synthetic child service for pending instance not yet in backend
      return {
        label: instanceId,
        name: `${parentLabel.charAt(0).toUpperCase() + parentLabel.slice(1)} - ${inst.name}`,
        project_name: parentLabel.charAt(0).toUpperCase() + parentLabel.slice(1),
        enabled: inst.enable ?? true,
        public: inst.public ?? false,
        active_state: 'inactive',
        sub_state: 'dead',
        systemd_services: [],
        url: null,
        parent: parentLabel,
        instanceIndex: index  // Add stable instance index
      };
    });

    return pendingChildren;
  }

  /* An "instance service" (e.g. MediaWiki, Minecraft) has no units of its
     own — the systemd units live on each child instance. Instead of a
     misleading button-less parent card, these render as a group BOX that
     wraps the instance cards (see renderInstanceGroup). A service counts
     as an instance parent if it already has children or its schema
     declares an `instances` listOf option. */
  isInstanceParent(service) {
    if (service.parent) return false;
    if (this.getChildServices(service.label).length > 0) return true;
    const opt = (this.optionsSchema[service.label] || {})['instances'];
    return !!opt && (opt.type === 'listOf submodule' || (opt.type || '').includes('listOf'));
  }

  /* The group box for an instance service: same width as a normal card,
     a header (icon + name + enable toggle + parent Config + Add Instance)
     and the child instance cards nested inside. The children are ordinary
     <app-card>s rendered by renderServiceCard, so their inner elements
     (status pill, lifecycle buttons, toggles, Details/Config) line up
     with the single-service cards in the list. */
  // True when any undeployed change lives under this service's subtree
  // (services.<label>.* incl. enable/public/options/instances). Drives the
  // card-level amber dot so changes show on the card face — not just in nav.
  // Instance children live in the parent's `instances` array, so attribute
  // them to the parent.
  _serviceUndeployed(service) {
    // External proxies keep their config in service-config (not
    // services.<label>), so compare this entry against the deployed snapshot.
    if (service.external) return this._externalEntryChanged(service);
    const paths = this.undeployedPaths;
    if (!paths || !paths.size) return false;
    const prefix = `services.${service.parent || service.label}`;
    for (const p of paths) {
      if (p === prefix || p.startsWith(prefix + '.')) return true;
    }
    return false;
  }

  // True when an external proxy's service-config entry differs from the
  // deployed snapshot (by label). Used for the card highlight, since external
  // changes land in service-config and the array is diffed whole-value.
  _externalEntryChanged(service) {
    if (!this.appliedConfig || !Object.keys(this.appliedConfig).length) return false;
    const byLabel = (cfg) => ((cfg && cfg['service-config']) || [])
      .find(e => e && e.label === service.label);
    const cur = byLabel(this.pendingConfig) || byLabel(this.serverConfig);
    const dep = byLabel(this.appliedConfig);
    const stable = (o) => o === undefined ? undefined : JSON.stringify(o, (k, v) =>
      (v && typeof v === 'object' && !Array.isArray(v))
        ? Object.keys(v).sort().reduce((a, kk) => { a[kk] = v[kk]; return a; }, {})
        : v);
    return stable(cur) !== stable(dep);
  }

  // True when an exact dotted config path holds an undeployed change — used to
  // flag the specific changed option inside the config modal.
  _pathChanged(path) {
    return this.undeployedPaths?.has(path) || false;
  }

  // True when a service has a changed-but-unapplied CONFIG OPTION — a change
  // that lives INSIDE the gear/Config modal, as opposed to the enable/public
  // toggles or the instances list. Drives the gear-button highlight so you can
  // tell which service's config modal to open.
  _serviceConfigChanged(service) {
    const paths = this.undeployedPaths;
    if (!paths || !paths.size) return false;
    const prefix = `services.${service.label}.`;
    for (const p of paths) {
      if (!p.startsWith(prefix)) continue;
      const sub = p.slice(prefix.length).split('.')[0];
      if (sub && sub !== 'enable' && sub !== 'public' && sub !== 'instances') {
        return true;
      }
    }
    return false;
  }

  renderInstanceGroup(service) {
    const childServices = this.getChildServices(service.label);
    const isEnabled = service.enabled;
    const expandId = service.label;
    const configOpen = !!this.openModal && this.openModal.id === expandId && this.openModal.view === 'config';

    // Parent-level editable config (options / secrets), distinct from the
    // per-instance config each child carries.
    const hasSecrets = this.secretsSchema[service.label] && Object.keys(this.secretsSchema[service.label]).length > 0;
    const serviceOptions = this.optionsSchema[service.label] || {};
    const hasExtraOptions = Object.keys(serviceOptions).some(key =>
      key !== 'enable' && key !== 'public' && key !== 'instances' &&
      !serviceOptions[key]['sops-managed']
    );
    const hasParentConfig = hasSecrets || hasExtraOptions;

    const instancesOption = serviceOptions['instances'];
    const hasInstancesOption = !!instancesOption &&
      (instancesOption.type === 'listOf submodule' || (instancesOption.type || '').includes('listOf'));

    return html`
      <div class="instance-group ${isEnabled ? 'enabled' : ''}"
           style=${this._serviceUndeployed(service)
             ? 'background:var(--hf-warn-soft);box-shadow:inset 3px 0 0 0 var(--hf-warn);'
             : ''}>
        <div class="instance-group-head">
          <div class="icon">
            <img src="/icons/${service.label}.svg" alt="" @error=${(e) => { e.target.style.display = 'none'; }} />
          </div>
          <div class="instance-group-title">
            <span class="instance-group-name">${service.name || service.label}</span>
            <span class="instance-group-count">${childServices.length} instance${childServices.length === 1 ? '' : 's'}</span>
          </div>
          <div class="instance-group-actions">
            <div class="toggle-container">
              <span class="toggle-label">Enabled</span>
              <label class="toggle-switch">
                <input
                  type="checkbox"
                  .checked=${isEnabled}
                  @change=${(e) => this.handleServiceToggle(service.label, e.target.checked)}
                />
                <span class="toggle-slider"></span>
              </label>
            </div>
            ${hasParentConfig ? html`
              <button
                class="hf-btn hf-btn-icon ${this._serviceConfigChanged(service) ? 'config-changed' : ''}"
                title="Config"
                aria-label="${service.name} config"
                aria-haspopup="dialog"
                aria-expanded=${configOpen ? 'true' : 'false'}
                @click=${() => this.openConfigModal(expandId, 'config')}
              >
                ${actionIcon('settings')}
              </button>
            ` : ''}
          </div>
        </div>

        ${childServices.length > 0 ? html`
          <div class="instance-group-children">
            ${childServices.map(child => this.renderServiceCard(child))}
          </div>
        ` : html`
          <div class="instance-group-empty">No instances yet.</div>
        `}

        ${hasInstancesOption ? html`
          <button
            class="add-row-btn"
            @click=${(e) => { e.stopPropagation(); this.handleAddInstanceClick(service.label); }}
          >
            + Add Instance
          </button>
        ` : ''}
      </div>

      ${configOpen ? this.renderConfigModal(service, expandId, 'config') : ''}
    `;
  }

  renderServiceCard(service) {
    const isEnabled = service.enabled;
    const isPublic = service.public;

    // Check if this service has child instances
    const childServices = this.getChildServices(service.label);
    const hasChildren = childServices.length > 0;

    // An "external service" is an enabled top-level entry with no systemd
    // units and no child instances — a reverse-proxy / static-path vhost
    // configured on the External Proxies page, pointing off-box. It has
    // no local run-state (systemd reports unknown), so instead of a
    // meaningless "Unknown" pill we label it "External".
    const hasUnitsLive = service.systemd_services && service.systemd_services.length > 0;
    const isExternal = isEnabled && !service.parent && !hasUnitsLive && !hasChildren;

    const statusClass = isExternal
      ? 'external'
      : this.getStatusClass(service.active_state, service.sub_state, service.partial);
    const statusText = isExternal
      ? 'External'
      : this.getStatusText(service.active_state, service.sub_state, service.enabled, service.partial);

    // Admin service can't be disabled (no enable toggle)
    const cannotDisable = service.label === 'admin' || service.label === 'admin-api';
    const isAdminApi = service.label === 'admin-api';

    // Check if service has configuration options (secrets, options)
    const hasSecrets = this.secretsSchema[service.label] && Object.keys(this.secretsSchema[service.label]).length > 0;
    const serviceOptions = this.optionsSchema[service.label] || {};
    // Filter out standard enable/public options, sops-managed options, and instances (handled as child services)
    const extraOptions = Object.keys(serviceOptions).filter(key =>
      key !== 'enable' &&
      key !== 'public' &&
      key !== 'instances' &&
      !serviceOptions[key]['sops-managed']
    );
    const hasExtraOptions = extraOptions.length > 0;
    // The per-unit systemd list and SSO posture are read-only INFO — they
    // belong in the Details modal, not the editable Config modal. Units
    // apply to children too (a MediaWiki/Minecraft instance has its own
    // systemd units), so this is NOT gated on !parent. SSO posture stays
    // parent-only — an instance has no SSO surface distinct from its
    // parent, and showing one would be misleading.
    const hasUnits = isEnabled &&
      service.systemd_services && service.systemd_services.length > 0;
    const hasSso = !service.parent && (service.sso_kind || 'none') !== 'infra';

    // Two distinct modals, two distinct buttons:
    //   Details  — read-only info: SSO posture + systemd unit health.
    //   Config   — editable: options, secrets, child instances (or, for
    //              a child, its own instance config).
    let hasDetails = hasUnits || hasSso;
    let hasConfigEditable = hasSecrets || hasExtraOptions || hasChildren;

    // For child services (instances), the editable surface is the
    // parent's instance-config fields.
    if (service.parent) {
      const parentOptions = this.optionsSchema[service.parent] || {};
      const instancesOption = parentOptions['instances'];
      if (instancesOption && instancesOption['submodule-fields']) {
        const configFields = instancesOption['submodule-fields'].filter(f =>
          f.path !== 'enable' && f.path !== 'public'
        );
        if (configFields.length > 0) {
          hasConfigEditable = true;
        }
      }
    }

    // Stable identifier for modal state (instance index for children, label for parents)
    const expandId = service.instanceIndex !== undefined
      ? `${service.parent}:instance:${service.instanceIndex}`
      : service.label;
    const open = this.openModal;
    const detailsOpen = !!open && open.id === expandId && open.view === 'details';
    const configOpen = !!open && open.id === expandId && open.view === 'config';

    // The whole service is one <app-card>:
    //   - header slot: status badge + lifecycle icon-buttons + Enabled
    //     / Exposed-to-internet toggles, pinned beside the icon/title.
    //     The whole cluster wraps below the title on a narrow / mobile
    //     card; chips inside wrap to a second line too if needed.
    //   - subtitle slot: the service URL on its own line below the
    //     name (consistent whether or not a project subtitle exists).
    //   - default slot: a one-line "system service" note (system
    //     services only) plus any action-error text.
    // The read-only info (Details) and the editable config (Config) each
    // open in a section-width modal via their own header button. That
    // modal is rendered as a SIBLING of <app-card> (see below), so it
    // never grows the card taller or reflows the grid.
    const actionErr = this.actionErrors[service.label];

    return html`
      <app-card
        ?enabled=${isEnabled}
        ?undeployed=${this._serviceUndeployed(service)}
        .label=${service.parent || service.label}
        .name=${service.name}
        .subtitle=${service.project_name || ''}
      >
        ${service.url && isEnabled ? html`
          <a slot="subtitle"
             class="title-url"
             href="${service.url}"
             target="_blank"
             rel="noopener"
             title="${service.url}">
            <span>${service.url.replace(/^https?:\/\//, '')}</span>
            ${actionIcon('external-link')}
          </a>
        ` : ''}

        <span slot="status" class="status-badge ${statusClass}" title="${statusText}">
          ${statusText}
        </span>

        <div slot="header" class="card-head">
          ${this.renderIconActions(service)}
          ${cannotDisable ? '' : html`
            <div class="toggle-container">
              <span class="toggle-label">Enabled</span>
              <label class="toggle-switch">
                <input
                  type="checkbox"
                  .checked=${isEnabled}
                  @change=${(e) => {
                    if (service.external) {
                      this._emitExternalToggle(service.label, 'enable', e.target.checked);
                    } else if (service.parent) {
                      this.handleInstanceToggle(service.parent, service.label, e.target.checked);
                    } else {
                      this.handleServiceToggle(service.label, e.target.checked);
                    }
                  }}
                />
                <span class="toggle-slider"></span>
              </label>
            </div>
            ${isEnabled ? html`
              <div class="toggle-container ${isPublic ? 'public-on' : ''}">
                <span class="toggle-label">Exposed to internet</span>
                <label class="toggle-switch">
                  <input
                    type="checkbox"
                    .checked=${isPublic}
                    @change=${(e) => {
                      if (service.external) {
                        this._emitExternalToggle(service.label, 'public', e.target.checked);
                      } else if (service.parent) {
                        this.handleInstancePublicToggle(service.parent, service.label, e.target.checked);
                      } else {
                        this.handlePublicToggle(service.label, e.target.checked);
                      }
                    }}
                  />
                  <span class="toggle-slider"></span>
                </label>
              </div>
            ` : html`
              <!-- Disabled apps have no Exposed toggle. Reserve its exact
                   width with an invisible copy so the Enabled toggle (and
                   the rest of the header) lines up with enabled cards.
                   Hidden entirely on mobile, where the header stacks. -->
              <div class="toggle-container toggle-spacer" aria-hidden="true">
                <span class="toggle-label">Exposed to internet</span>
                <label class="toggle-switch"><span class="toggle-slider"></span></label>
              </div>
            `}
          `}
          <!-- Config first, then Details: with the buttons right-aligned,
               an absent button's spacer falls on the LEFT (tucked next to
               the toggles) rather than leaving a jarring trailing gap at
               the card's right edge. -->
          <div class="head-buttons">
            ${hasConfigEditable ? html`
              <button
                class="hf-btn hf-btn-icon ${this._serviceConfigChanged(service) ? 'config-changed' : ''}"
                title="Config"
                aria-label="Config"
                aria-haspopup="dialog"
                aria-expanded=${configOpen ? 'true' : 'false'}
                @click=${() => this.openConfigModal(expandId, 'config')}
              >
                ${actionIcon('settings')}
              </button>
            ` : html`<span class="hf-btn-spacer hf-btn-icon" aria-hidden="true"></span>`}
            ${hasDetails ? html`
              <button
                class="hf-btn hf-btn-icon"
                title="Details"
                aria-label="Details"
                aria-haspopup="dialog"
                aria-expanded=${detailsOpen ? 'true' : 'false'}
                @click=${() => this.openConfigModal(expandId, 'details')}
              >
                ${actionIcon('info')}
              </button>
            ` : html`<span class="hf-btn-spacer hf-btn-icon" aria-hidden="true"></span>`}
          </div>
        </div>

        ${cannotDisable ? html`
          <div class="system-note">
            ${isAdminApi ? 'System service' : 'System service — always enabled'}
          </div>
        ` : ''}

        ${actionErr ? html`<div class="action-error">${actionErr}</div>` : ''}
      </app-card>

      <!-- The modal is a sibling of <app-card>, not slotted into it: a
           fixed-positioned overlay slotted into the card's default slot
           would still trip app-card's "_hasBody" margin and leave a gap
           under the card while open. -->
      ${detailsOpen ? this.renderConfigModal(service, expandId, 'details') : ''}
      ${configOpen ? this.renderConfigModal(service, expandId, 'config') : ''}
    `;
  }

  /* The SSO posture as a section inside the Details modal. It used to
     sit on the always-visible card face as coloured text that read like
     the URL link; rendering it here as a pill — beside the systemd unit
     list — keeps it distinct and groups all of a service's status in
     one place.
     Backend (resolvers/services.py) supplies sso_kind, sso_provisioned
     and sso_applicable. Returns '' for 'infra' services (Zitadel,
     oauth2-proxy) — they are the bridge itself, not a consumer — and for
     child instances, whose SSO posture is the parent's, not their own
     (rendering one per instance would be misleading). */
  renderSsoSection(service) {
    if (service.parent) return '';
    const kind = service.sso_kind || 'none';
    if (kind === 'infra') return '';

    const typeLabel = ({
      native_oidc: 'Native OIDC',
      caddy_gated: 'Caddy oauth2-proxy',
      basic_auth: 'Caddy + Basic-Auth bridge',
    })[kind];

    let pill;
    if (kind === 'none') {
      // sso_applicable distinguishes a deliberate "not applicable"
      // posture (false) from an integration that is simply pending
      // (true). The reasoning lives in a code comment beside each
      // service's sso block, not in the UI.
      pill = service.sso_applicable === false
        ? html`<span class="sso-pill disabled">Not applicable</span>`
        : html`<span class="sso-pill disabled">Not yet implemented</span>`;
    } else {
      pill = service.sso_provisioned
        ? html`<span class="sso-pill ok">${typeLabel}</span>`
        : html`<span class="sso-pill warn">${typeLabel} (pending)</span>`;
    }

    return html`
      <div class="secrets-section">
        <div class="secrets-header">
          <span>Single sign-on</span>
        </div>
        <div class="secrets-content">${pill}</div>
      </div>
    `;
  }

  /* Compact play / restart / stop icon-buttons for the card header.
     Renders no *buttons* for:
     - the admin-api / admin services themselves (acting on them would
       cut the request that issued the action; backend also refuses)
     - services with no backing systemd units (external vhosts,
       synthetic pending instances not yet realized)
     - a disabled service — enable it via the toggle + rebuild first;
       showing buttons would lie about what they do (the unit may not
       even exist while disabled).
     In those cases it returns an invisible same-size PLACEHOLDER (not
     ''), so a button-less card keeps the exact header width of a card
     with the 3 buttons — that is what lines the status pills up into a
     column across the right-packed header strip. */
  renderIconActions(service) {
    const placeholder = html`
      <div class="icon-actions" aria-hidden="true">
        <span class="icon-action-spacer"></span>
        <span class="icon-action-spacer"></span>
        <span class="icon-action-spacer"></span>
      </div>
    `;
    if (service.label === 'admin' || service.label === 'admin-api') return placeholder;
    if (!service.systemd_services || service.systemd_services.length === 0) return placeholder;
    if (!service.enabled) return placeholder;

    const pending = this.pendingActions[service.label];
    const cls = this.getStatusClass(service.active_state, service.sub_state, service.partial);
    const isRunning = cls === 'running' || cls === 'degraded';
    const isStopped = cls === 'stopped' || cls === 'failed';

    const btn = (action, glyph, danger, disabled, verb) => html`
      <button
        class="icon-action ${danger ? 'danger' : ''} ${pending === action ? 'busy' : ''}"
        ?disabled=${!!pending || disabled}
        title="${pending === action ? `${verb}…` : verb}"
        aria-label="${verb}"
        @click=${() => this.handleServiceAction(service.label, action)}
      >
        ${actionIcon(glyph)}
      </button>
    `;

    return html`
      <div class="icon-actions">
        ${btn('start', 'play', false, isRunning, 'Start')}
        ${btn('restart', 'restart', false, isStopped, 'Restart')}
        ${btn('stop', 'stop', true, isStopped, 'Stop')}
      </div>
    `;
  }

  /* The per-unit systemd health list — one row per unit, a small status
     dot + the unit name. Lives inside the Details modal; it used to
     crowd the card face as a monospace comma list. */
  renderSystemdSection(service) {
    // Children (instances) DO have their own units, so no !parent guard
    // here — a MediaWiki/Minecraft instance's Details modal shows its own
    // unit health. A synthetic pending instance has no units yet and is
    // filtered by the length check below.
    if (!service.enabled) return '';
    if (!service.systemd_services || service.systemd_services.length === 0) return '';

    const units = (service.unit_states && service.unit_states.length > 0)
      ? service.unit_states
      : service.systemd_services.map(n => ({
          name: n,
          active_state: 'unknown',
          sub_state: 'unknown',
        }));

    return html`
      <div class="secrets-section">
        <div class="secrets-header">
          <span>Systemd units (${units.length})</span>
        </div>
        <div class="secrets-content">
          <div class="systemd-units">
            ${units.map(u => {
              const healthy  = u.active_state === 'active' && u.sub_state === 'running';
              // A blue/green standby unit being inactive is its expected
              // steady state, so it is NOT an error.
              const standby  = u.bg_role === 'standby';
              const unknown  = u.active_state === 'unknown';
              const starting = u.active_state === 'activating'
                            || u.active_state === 'reloading'
                            || u.sub_state === 'start';
              const cls = healthy  ? 'unit-ok'
                        : standby  ? 'unit-standby'
                        : unknown  ? 'unit-unknown'
                        : starting ? 'unit-starting'
                        :            'unit-bad';
              const tip = healthy
                ? `${u.active_state} (${u.sub_state})`
                : standby
                  ? `${u.active_state} (${u.sub_state}) — standby (blue/green)`
                  : unknown
                    ? 'status unknown'
                    : starting
                      ? `${u.active_state} (${u.sub_state}) — starting`
                      : `${u.active_state} (${u.sub_state}) — not healthy`;
              return html`
                <div class="systemd-unit" title="${tip}">
                  <span class="unit-dot ${cls}"></span>
                  <span>${u.name}</span>
                </div>
              `;
            })}
          </div>
        </div>
      </div>
    `;
  }

  /* The Details / Config buttons live in the card header — this renders
     the modal that one of them opens. The overlay is fixed-positioned,
     so although it is rendered as a sibling of <app-card> its layout
     escapes the card. It is section-width (capped at --hf-content-max)
     and scrolls vertically; dismissed by clicking the backdrop, the ×
     button, or Escape.
       view 'details' — read-only: SSO posture + systemd unit health.
       view 'config'  — editable: options + secrets (or, for a child row,
                        its own instance config). Child instances of an
                        instance parent are NOT here — they live in the
                        group box on the main list. */
  renderConfigModal(service, expandId, view) {
    const iconLabel = service.parent || service.label;
    const name = service.name || service.label;
    const title = view === 'details' ? `${name} — Details` : `${name} — Config`;

    // Config body: a child shows its own instance config; a normal or
    // instance-parent service shows its options + secrets. Child
    // instances are NOT listed here — for an instance parent they live
    // in the group box on the main list, not in this modal.
    const body = view === 'details'
      ? html`
          ${this.renderSsoSection(service)}
          ${this.renderSystemdSection(service)}
        `
      : (service.parent
          ? this.renderInstanceConfig(service)
          : html`
              ${this.renderOptionsSection(service)}
              ${this.renderSecretsSection(service)}
            `);

    return html`
      <div
        class="config-modal-overlay"
        role="presentation"
        @click=${() => this.closeConfigModal()}
      >
        <div
          class="config-modal"
          role="dialog"
          aria-modal="true"
          aria-label="${title}"
          @click=${(e) => e.stopPropagation()}
        >
          <div class="config-modal-header">
            <div class="icon">
              <img src="/icons/${iconLabel}.svg" alt="" @error=${(e) => { e.target.style.display = 'none'; }} />
            </div>
            <div class="config-modal-title">${title}</div>
            ${service.parent && service.instanceIndex !== undefined ? html`
              <button
                class="btn-row delete"
                @click=${() => this.handleInstanceDeleteClick(service.parent, service.instanceIndex)}
              >
                Remove instance
              </button>
            ` : ''}
            <button
              class="config-modal-close"
              aria-label="Close"
              @click=${() => this.closeConfigModal()}
            >×</button>
          </div>
          <div class="config-modal-body">${body}</div>
        </div>
      </div>
    `;
  }

  renderInstanceConfig(instance) {
    // Get parent service label and instance index
    const parentLabel = instance.parent;
    const instanceIndex = instance.instanceIndex;

    if (!parentLabel || instanceIndex === undefined) return '';

    // Get parent service options schema to access instances submodule definition
    const parentOptions = this.optionsSchema[parentLabel] || {};
    const instancesOption = parentOptions['instances'];
    if (!instancesOption || !instancesOption.type?.includes('listOf')) {
      console.warn('[renderInstanceConfig] No instances option found for parent:', parentLabel, instancesOption);
      return ''; // No instances configuration available
    }

    // Get the submodule fields that define instance configuration
    const instanceFields = instancesOption['submodule-fields'] || [];

    // Get current instances array from config
    const currentInstances = this.pendingConfig.services?.[parentLabel]?.instances ||
                            this.serverConfig?.services?.[parentLabel]?.instances ||
                            [];

    const currentInstance = currentInstances[instanceIndex];

    if (!currentInstance) {
      console.warn('[renderInstanceConfig] Instance not found at index:', instanceIndex);
      return '';
    }

    return html`
      <div class="secrets-section">
        <div class="secrets-header">
          <span>Instance Configuration</span>
        </div>

        <div class="secrets-content">
          ${instanceFields.map(field => {
            // Skip enable and public - they're handled by toggles
            if (field.path === 'enable' || field.path === 'public') {
              return '';
            }

            const currentValue = currentInstance?.[field.path];
            const label = field.path
              .split('-')
              .map(word => word.charAt(0).toUpperCase() + word.slice(1))
              .join(' ');

            return html`
              <service-option-input
                .optionKey=${field.path}
                .label=${label}
                .description=${field.description || ''}
                .type=${field.type}
                .defaultValue=${field.default}
                .currentValue=${currentValue}
                .submoduleFields=${field['submodule-fields'] || []}
                .enumValues=${field['enum-values'] || []}
                .uiHint=${field['ui-hint'] || null}
                .nullable=${field.nullable || false}
                .required=${field.required || false}
                @option-changed=${(e) => this.handleInstanceFieldChanged(parentLabel, instanceIndex, e.detail.optionKey, e.detail.value)}
              ></service-option-input>
            `;
          })}
        </div>
      </div>
    `;
  }

  renderOptionsSection(service) {
    const serviceOptions = this.optionsSchema[service.label] || {};
    // Filter out standard enable/public options, sops-managed options, and instances (handled as child services)
    const extraOptions = Object.keys(serviceOptions).filter(key =>
      key !== 'enable' &&
      key !== 'public' &&
      key !== 'instances' &&
      !serviceOptions[key]['sops-managed']
    );

    if (extraOptions.length === 0) {
      return ''; // No extra options for this service
    }

    return html`
      <div class="secrets-section">
        <div class="secrets-header">
          <span>Configuration Options</span>
        </div>

        <div class="secrets-content">
          ${extraOptions.map(optionKey => {
            const optionDef = serviceOptions[optionKey];
            const currentValue = this.pendingConfig.services?.[service.label]?.[optionKey]
              ?? this.serverConfig?.services?.[service.label]?.[optionKey];
            const label = optionKey
              .split('-')
              .map(word => word.charAt(0).toUpperCase() + word.slice(1))
              .join(' ');

            return html`
              <service-option-input
                .optionKey=${optionKey}
                .label=${label}
                .description=${optionDef.description || ''}
                .type=${optionDef.type}
                .defaultValue=${optionDef.default}
                .currentValue=${currentValue}
                .submoduleFields=${optionDef['submodule-fields'] || []}
                .enumValues=${optionDef['enum-values'] || []}
                .uiHint=${optionDef['ui-hint'] || null}
                ?undeployed=${this._pathChanged(`services.${service.label}.${optionKey}`)}
                @option-changed=${(e) => this.handleOptionChanged(service.label, e.detail.optionKey, e.detail.value)}
              ></service-option-input>
            `;
          })}
        </div>
      </div>
    `;
  }

  renderSecretsSection(service) {
    const secrets = this.secretsSchema[service.label];
    if (!secrets || Object.keys(secrets).length === 0) {
      return ''; // No secrets for this service
    }

    const secretsCount = Object.keys(secrets).length;
    const statusObj = this.secretsStatus[service.label] || {};
    const setCount = Object.values(statusObj).filter(v => v).length;

    return html`
      <div class="secrets-section">
        <div class="secrets-header">
          <span>Secrets (${setCount}/${secretsCount} configured)</span>
          ${!this.hasAuthorizedKeys ? html`
            <span style="color: var(--hf-err); font-size: 12px;">⚠️ SSH key required</span>
          ` : ''}
        </div>

        <div class="secrets-content">
          ${Object.entries(secrets).map(([secretKey, secretInfo]) => {
            const exists = statusObj[secretKey] || false;
            return html`
              <secrets-input
                .serviceLabel=${service.label}
                .secretKey=${secretKey}
                .label=${secretKey.replace(/([A-Z])/g, ' $1').replace(/^./, str => str.toUpperCase())}
                .description=${secretInfo.description || ''}
                .required=${secretInfo.required || false}
                .disabled=${!this.hasAuthorizedKeys}
                .exists=${exists}
                @secret-updated=${this.handleSecretUpdated}
              ></secrets-input>
            `;
          })}
        </div>
      </div>
    `;
  }

  render() {
    if (this.loading) {
      return html`
        <div class="module-container">
          <div class="loading-spinner">
            Loading apps...
          </div>
        </div>
      `;
    }

    if (this.error) {
      return html`
        <div class="module-container">
          <div class="error-box">
            <strong>Error loading services:</strong> ${this.error}
            <button class="refresh-button" @click=${this.handleRefresh}>
              Retry
            </button>
          </div>
        </div>
      `;
    }

    // Filter out child services (those with parent field) — they render
    // inside their parent's group box. Also hide the HomeFree Admin
    // itself: it is the surface you are looking at, not a manageable app.
    const HIDDEN_LABELS = new Set(['admin', 'admin-api']);
    // Infrastructure services (Zitadel, oauth2-proxy, ntfy, etc. —
    // anything tagged sso.kind="infra" in module.nix) are system
    // wiring, not user-managed apps. Same posture the SSO admin page
    // already uses for these (services-module.js line 1566). Without
    // this filter they appear on App Configuration with a checkbox
    // wired to homefree.services.<label>.enable, and the act of
    // rendering the row + saving can pollute homefree-config.json
    // with an inadvertent `enable: false` that then beats the
    // alerts-module's auto-enable on the next rebuild.
    const parentServices = this.services.filter(
      service => !service.parent
        && !HIDDEN_LABELS.has(service.label)
        && service.sso_kind !== 'infra'
    );

    // Sort against the LAST-APPLIED server state, not the merged
    // `this.services` view. Pending enable/exposed toggles flow through
    // `loadServices` and overwrite the in-memory `enabled` / `public`
    // fields (services-module.js loadServices) so that the card's
    // toggle reflects the user's intent immediately — but using those
    // overwritten fields as the sort key would yank the card to a new
    // position the instant the user clicks. Reading from
    // `this.serverConfig.services[label]` keeps positions frozen
    // until the next poll after "Apply changes" lands a fresh
    // serverConfig.
    const serverServices = this.serverConfig?.services || {};
    const serverEnabled = (s) => {
      const cfg = serverServices[s.label];
      return cfg ? !!cfg.enable : !!s.enabled;
    };
    const serverPublic = (s) => {
      const cfg = serverServices[s.label];
      return cfg ? !!cfg.public : !!s.public;
    };
    const statusPriority = {
      failed: 0,
      degraded: 1,
      stopped: 2,
      starting: 3,
      running: 4,
      unknown: 5,
      disabled: 6,
    };
    const statusRank = (s) => {
      if (!serverEnabled(s)) return statusPriority.disabled;
      const cls = this.getStatusClass(s.active_state, s.sub_state, s.partial);
      return statusPriority[cls] ?? statusPriority.unknown;
    };
    const nameOf = (s) => (s.name || s.label).toLowerCase();

    // Boolean sorts: "true first" is ascending — flipping direction
    // brings the off/disabled rows to the top.
    const boolCmp = (av, bv) => (av === bv) ? 0 : (av ? -1 : 1);

    const cmp = (a, b) => {
      let d = 0;
      switch (this.sortKey) {
        case 'name':    d = nameOf(a).localeCompare(nameOf(b)); break;
        case 'exposed': d = boolCmp(serverPublic(a), serverPublic(b)); break;
        case 'enabled': d = boolCmp(serverEnabled(a), serverEnabled(b)); break;
        case 'status':  d = statusRank(a) - statusRank(b); break;
        default:        d = nameOf(a).localeCompare(nameOf(b));
      }
      if (d === 0 && this.sortKey !== 'name') {
        d = nameOf(a).localeCompare(nameOf(b));
      }
      return this.sortDir === 'desc' ? -d : d;
    };
    const sortedParents = [...parentServices].sort(cmp);

    // Filter services based on search query
    const filteredServices = sortedParents.filter(service => {
      const searchLower = this.searchQuery.toLowerCase();
      return (
        service.name.toLowerCase().includes(searchLower) ||
        service.project_name.toLowerCase().includes(searchLower) ||
        service.label.toLowerCase().includes(searchLower)
      );
    });

    // Header counts must describe the cards actually on screen, i.e.
    // top-level parents (`parentServices`) — child instances render
    // nested inside their parent and must not be counted separately.
    //
    // A parent with no backing systemd units AND no child instances is
    // an "external" entry: a reverse-proxy / static-path vhost that
    // points off-box (or has no local process). It has no run-state to
    // report, so it can never be "running" — it gets its own bucket
    // instead of silently dragging down the running count.
    let runningCount = 0;
    let disabledCount = 0;
    let externalCount = 0;
    for (const service of parentServices) {
      if (service.enabled) {
        const hasUnits = service.systemd_services && service.systemd_services.length > 0;
        const hasChildren = this.getChildServices(service.label).length > 0;
        if (!hasUnits && !hasChildren) {
          externalCount++;
        } else if (service.active_state === 'active' && service.sub_state === 'running') {
          runningCount++;
        }
      } else {
        disabledCount++;
      }
    }
    const totalCount = parentServices.length;

    return html`
      <div class="module-container">
        ${this.apiUnavailable ? html`
          <div class="warning-box">
            API temporarily unavailable (possibly due to system rebuild). Showing cached service list. Status updates will resume automatically.
          </div>
        ` : ''}

        <div class="info-box">
          <div class="info-text">
            <strong>${runningCount} running${externalCount > 0 ? html` / ${externalCount} external` : ''}${disabledCount > 0 ? html` / ${disabledCount} disabled` : ''} / ${totalCount} total apps</strong>
            <div style="margin-top: 8px; font-size: 13px;">
              Enable/disable apps and configure public WAN access.
            </div>
          </div>
          <button
            class="refresh-button"
            @click=${this.handleRefresh}
            ?disabled=${this.loading}
          >
            Refresh
          </button>
        </div>

        <div class="filter-bar">
          <div class="sort-group" role="group" aria-label="Sort apps">
            ${this.renderSortBtn('name',    'Name')}
            ${this.renderSortBtn('exposed', 'Exposed to Internet')}
            ${this.renderSortBtn('enabled', 'Enabled')}
            ${this.renderSortBtn('status',  'Status')}
          </div>
          <input
            class="filter-input"
            type="text"
            placeholder="Filter"
            .value=${this.searchQuery}
            @input=${this.handleSearch}
          />
        </div>

        <div class="service-grid">
          ${filteredServices.map(service => this.isInstanceParent(service)
            ? this.renderInstanceGroup(service)
            : this.renderServiceCard(service))}
        </div>

        ${filteredServices.length === 0 ? html`
          <div class="no-results">
            No apps match "${this.searchQuery}"
          </div>
        ` : ''}
      </div>
    `;
  }
}

customElements.define('services-module', ServicesModule);
