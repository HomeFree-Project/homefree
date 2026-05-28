import { LitElement, html, css } from 'lit';
import '../../shared/config-section.js';
import '../../shared/form-field.js';

/**
 * Alerts module — System section.
 *
 * Edits `homefree.alerts.*` (engine enable, poll interval, channels,
 * per-source thresholds). Edits flow through the standard
 * config-change event so the Apply gate and undeployed-change diff
 * indicators work automatically — the page does NOT POST to a write
 * endpoint of its own.
 *
 * Live state (per-source firing / peak / message) and event history
 * come from the read-only /api/alerts/sources and /api/alerts/history
 * endpoints, fetched once on mount.
 *
 * Backing config path: homefree.alerts. admin-app.getMergedConfig is
 * updated to shallow-merge `alerts` so an edit here survives Save /
 * Apply (without that merge, edits live only in pendingConfig and
 * vanish on save).
 *
 * Lit gotcha note: NEVER use backtick template literals inside the
 * html or css template bodies of this file (the repeat-failure
 * gotcha). Path strings are precomputed with `+` concatenation
 * outside the template.
 */
class AlertsModule extends LitElement {
  static properties = {
    config: { type: Object },
    appliedConfig: { attribute: false },
    undeployedPaths: { attribute: false },
    // URL sub-route from admin-app (e.g. '/alerts/configuration').
    // Mirrors backups-module's pattern so a refresh on the Configuration
    // tab restores the right tab; admin-app updates this when the URL
    // changes and we sync it INTO activeTab via updated().
    subRoute: { type: String },
    activeTab: { state: true },
    _sources: { state: true },
    _history: { state: true },
    _loading: { state: true },
    _ntfyInfo: { state: true },
    _testing: { state: true },
    _testResult: { state: true },
  };

  // Sub-route names the Configuration tab uses. The Active tab uses
  // the bare module URL with no sub-route so a fresh visit lands
  // there by default.
  static SUB_ROUTE_CONFIGURATION = 'configuration';

  static styles = css`
    :host { display: block; }

    .module-container {
      width: 100%;
      max-width: var(--hf-content-max, 900px);
    }

    .state-badge {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 2px 10px;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 600;
      letter-spacing: 0.02em;
      flex-shrink: 0;
      white-space: nowrap;
    }
    /* Three severity styles. The .firing class is now the err-level
       red (kept for legacy markup); .warn is the new yellow-amber
       middle tier; .clear is green. The class assignment in the
       template maps from state.severity. (Avoid backticks here — Lit
       gotcha; closing the css template breaks the whole file.) */
    .state-badge.firing,
    .state-badge.err {
      background: var(--hf-err-soft, #fde7e7);
      color: var(--hf-err, #c62828);
    }
    .state-badge.warn {
      background: var(--hf-warn-soft, #fff7e0);
      color: var(--hf-warn, #b35900);
    }
    .state-badge.clear,
    .state-badge.ok {
      background: var(--hf-ok-soft, #e6f5e6);
      color: var(--hf-ok, #2e7d32);
    }

    .source-row {
      padding: 16px;
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      margin-bottom: 14px;
      background: var(--hf-surface, transparent);
    }
    /* Collapsible Status-tab cards. The <details>/<summary> primitive
       handles open-state and accessibility for free (Space/Enter
       toggles, focus-visible outline). We restyle the summary as a
       full-width header strip and replace the default disclosure
       triangle with our own chevron so it sits beside the badge
       cleanly. Cards are open-by-default only when firing (set by
       the host on the <details> element); rule 10 still applies —
       a closed card is not a hidden bug, the summary always shows
       the badge so OK/FIRING is visible without expanding. */
    details.source-row > summary {
      cursor: pointer;
      list-style: none;
    }
    details.source-row > summary::-webkit-details-marker { display: none; }
    details.source-row > summary > .source-header {
      margin-bottom: 0;
    }
    details.source-row > summary .summary-chevron {
      flex-shrink: 0;
      width: 16px;
      height: 16px;
      transition: transform 0.15s;
      color: var(--hf-text-muted);
    }
    details.source-row[open] > summary .summary-chevron {
      transform: rotate(90deg);
    }
    details.source-row > .source-body {
      margin-top: 12px;
      padding-top: 12px;
      border-top: 1px solid var(--hf-border-2);
    }

    /* Range-bar visualization for scalar sources. Shows the source's
       peak value as a fill from left, with a vertical threshold mark
       at the threshold position. Fill turns red when firing, green
       otherwise. tls-cert reverses the direction (lower = worse).
       Sources without a clean scalar threshold (binary sources;
       per-class temperature sources) skip the meter. */
    .meter-row {
      margin-top: 10px;
    }
    .meter-track {
      position: relative;
      width: 100%;
      height: 10px;
      background: var(--hf-surface-2);
      border-radius: 5px;
      overflow: hidden;
    }
    .meter-fill {
      height: 100%;
      transition: width 0.2s;
    }
    .meter-fill.clear,
    .meter-fill.ok { background: var(--hf-ok); }
    .meter-fill.warn { background: var(--hf-warn); }
    .meter-fill.err,
    .meter-fill.firing { background: var(--hf-err); }
    /* Two markers per bar — warn (yellow) and err (red) — mirroring
       the Hardware page's two-tier visual. .meter-threshold without
       a variant class is the legacy single-marker style (kept for
       sources we haven't tiered yet). */
    .meter-threshold {
      position: absolute;
      top: -2px;
      bottom: -2px;
      width: 2px;
      background: var(--hf-text-muted);
      border-radius: 1px;
    }
    .meter-threshold.warn { background: var(--hf-warn); }
    .meter-threshold.err  { background: var(--hf-err); }
    /* Tick labels for the threshold lines on per-item bars. Sit
       directly below the track; clamped near the edges via
       text-anchor-style transforms so they don't fall off the
       container at left=0% or left=100%. */
    .meter-axis {
      position: relative;
      height: 14px;
      margin-top: 2px;
      pointer-events: none;
    }
    .meter-threshold-label {
      position: absolute;
      top: 0;
      transform: translateX(-50%);
      font-size: 10px;
      line-height: 14px;
      font-variant-numeric: tabular-nums;
      white-space: nowrap;
    }
    .meter-threshold-label.warn { color: var(--hf-warn); }
    .meter-threshold-label.err  { color: var(--hf-err);  }
    /* Edge anchoring: labels within ~10% of the bar edges shift to
       the inside so the digits stay on-screen. */
    .meter-threshold-label.at-left  { transform: translateX(0); }
    .meter-threshold-label.at-right { transform: translateX(-100%); }

    /* Per-item bar row: stacked label-track-no-numbers shape so the
       Status-tab card can list several drives / mounts / sensors
       compactly. */
    .item-bars {
      margin-top: 10px;
      display: flex;
      flex-direction: column;
      gap: 8px;
    }
    .item-bar {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      column-gap: 12px;
      row-gap: 4px;
      align-items: center;
    }
    .item-bar-name {
      font-size: 12px;
      color: var(--hf-text);
      font-family: var(--hf-font-mono, monospace);
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .item-bar-name .class-chip {
      display: inline-block;
      margin-left: 6px;
      padding: 0 6px;
      border-radius: 4px;
      background: var(--hf-surface-2);
      color: var(--hf-text-muted);
      font-size: 11px;
      font-family: inherit;
    }
    .item-bar-value {
      font-size: 12px;
      font-variant-numeric: tabular-nums;
      color: var(--hf-text);
    }
    .item-bar-value.warn { color: var(--hf-warn); font-weight: 600; }
    .item-bar-value.err  { color: var(--hf-err);  font-weight: 700; }
    .item-bar .meter-track {
      grid-column: 1 / -1;
    }
    .item-bar .meter-axis {
      grid-column: 1 / -1;
    }
    .meter-labels {
      display: flex;
      justify-content: space-between;
      margin-top: 6px;
      font-size: 12px;
      color: var(--hf-text-muted);
      font-variant-numeric: tabular-nums;
    }
    .meter-labels strong {
      color: var(--hf-text);
      font-weight: 600;
    }
    .meter-no-reading {
      font-style: italic;
    }
    .source-header {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 12px;
      margin-bottom: 14px;
      /* On narrow widths the badge drops to its own row below the
         title rather than fighting the title for space. With the
         badge pinned to flex-shrink:0 (above), no-wrap would have
         pushed it past the row edge and clipped. */
      flex-wrap: wrap;
    }
    .source-title {
      font-size: 15px;
      font-weight: 600;
      color: var(--hf-text);
    }
    .source-message {
      font-size: 12px;
      color: var(--hf-text-muted);
      margin-top: 4px;
      word-break: break-word;
    }

    .field-grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 14px;
    }
    @media (max-width: 600px) {
      .field-grid { grid-template-columns: 1fr; }
    }

    .history-table {
      width: 100%;
      border-collapse: collapse;
      margin-top: 8px;
      font-size: 13px;
    }
    .history-table th,
    .history-table td {
      padding: 8px 10px;
      border-bottom: 1px solid var(--hf-border-2);
      text-align: left;
      vertical-align: top;
    }
    .history-table th {
      font-weight: 600;
      color: var(--hf-text-muted);
      font-size: 12px;
      background: var(--hf-surface-2);
    }
    .history-msg {
      color: var(--hf-text-muted);
      word-break: break-word;
    }

    .hint {
      color: var(--hf-text-muted);
      font-size: 12px;
      line-height: 1.5;
    }
    .empty {
      color: var(--hf-text-muted);
      font-style: italic;
      padding: 14px;
      text-align: center;
    }

    /* ── Phone-pairing block under the ntfy toggle. */
    .pairing-block {
      margin-top: 14px;
      padding: 14px;
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      background: var(--hf-surface-2, transparent);
    }
    .pairing-title {
      font-size: 13px;
      font-weight: 600;
      color: var(--hf-text);
      margin: 0 0 8px 0;
    }
    .pairing-field {
      margin: 12px 0;
    }
    .pairing-field-label {
      font-size: 12px;
      font-weight: 600;
      color: var(--hf-text-muted);
      letter-spacing: 0.02em;
      margin-bottom: 4px;
      text-transform: uppercase;
    }
    .pairing-url-row {
      display: flex;
      gap: 8px;
      align-items: center;
    }
    .pairing-url {
      flex: 1;
      font-family: var(--hf-font-mono, monospace);
      font-size: 12px;
      padding: 8px 10px;
      background: var(--hf-bg);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      color: var(--hf-text);
      overflow-x: auto;
      white-space: nowrap;
      user-select: all;
    }
    .copy-btn {
      padding: 8px 14px;
      font-size: 12px;
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      background: var(--hf-bg);
      color: var(--hf-text);
      cursor: pointer;
      font-family: inherit;
      transition: background 0.15s;
    }
    .copy-btn:hover { background: var(--hf-surface); }
    .copy-btn.copied { background: var(--hf-ok-soft, #e6f5e6); color: var(--hf-ok, #2e7d32); }

    /* Canonical button system, mirrored from backups-module / system-
       module. Lit per-component style isolation means each module
       redeclares these locally — that is the established pattern. */
    .btn {
      padding: 10px 20px;
      border-radius: 8px;
      border: none;
      font-size: 14px;
      font-weight: 500;
      cursor: pointer;
      transition: background 0.15s, opacity 0.15s;
      display: inline-flex;
      align-items: center;
      gap: 8px;
      font-family: inherit;
    }
    .btn:disabled { opacity: 0.5; cursor: not-allowed; }
    .btn-secondary {
      background: var(--hf-surface-2);
      color: var(--hf-text);
      border: 1px solid var(--hf-border-2);
    }
    .btn-secondary:hover:not(:disabled) { background: var(--hf-surface-3); }
    /* .btn-action — outlined action button. Sits between secondary
       (calm / disable-feeling) and primary (bright fill). Used for
       buttons that perform a live side-effect (POST to an endpoint,
       trigger a flow, toggle live state) rather than edit config.
       Accent-coloured border + text, transparent fill; hover fills
       with the accent-soft tint.
       NOTE: do not wrap the class name in backticks here — backticks
       inside css() / html() template bodies close the tagged template
       and the rest of the file reparses as JS (the Lit gotcha). */
    .btn-action {
      background: transparent;
      color: var(--hf-accent);
      border: 1px solid var(--hf-accent);
    }
    .btn-action:hover:not(:disabled) { background: var(--hf-accent-soft); }
    .btn-sm { padding: 6px 12px; font-size: 13px; }

    /* Test-push action row — separate row under the steps so it
       reads as an explicit verification step rather than buried with
       the URL chips. */
    .test-push-row {
      display: flex;
      align-items: center;
      gap: 10px;
      margin-top: 14px;
      padding-top: 12px;
      border-top: 1px solid var(--hf-border-2);
    }
    .test-push-status {
      font-size: 12px;
      color: var(--hf-text-muted);
    }
    .test-push-status.ok { color: var(--hf-ok, #2e7d32); }
    .test-push-status.err { color: var(--hf-err, #c62828); }
    ol.pairing-steps {
      margin: 8px 0 0 0;
      padding-left: 22px;
      font-size: 13px;
      line-height: 1.6;
      color: var(--hf-text);
    }
    ol.pairing-steps li { margin-bottom: 2px; }
    /* Canonical "notice" treatment used across the admin UI
       (network-module / backups-module): faint blue surface with a
       4px left-border accent, no full perimeter border. The accent
       colour carries the severity. Mirrors the existing pattern so
       Alerts page notices look the same as everywhere else. */
    .warn-box {
      background: rgba(59, 130, 246, 0.08);
      border-left: 4px solid var(--hf-warn);
      padding: 14px 18px;
      border-radius: 8px;
      margin-top: 14px;
      color: var(--hf-text-muted);
      font-size: 13px;
      line-height: 1.5;
    }
    .warn-box strong { color: var(--hf-text); }

    /* Top-of-page banner shown when the master engine toggle is off.
       Same left-border treatment as the rest of the admin UI; the
       "Enable now" CTA on the right is what makes this banner
       actionable (the user can fix the problem from the banner
       itself, not just be told about it). */
    .disabled-banner {
      display: flex;
      align-items: center;
      gap: 14px;
      margin-bottom: 18px;
      padding: 14px 18px;
      background: rgba(59, 130, 246, 0.08);
      border-left: 4px solid var(--hf-warn);
      border-radius: 8px;
      color: var(--hf-text-muted);
      font-size: 13px;
      line-height: 1.5;
    }
    .disabled-banner-icon {
      flex-shrink: 0;
      width: 22px;
      height: 22px;
      color: var(--hf-warn);
    }
    .disabled-banner-text {
      flex: 1;
    }
    .disabled-banner-text strong {
      display: block;
      color: var(--hf-text);
      font-size: 14px;
      margin-bottom: 2px;
    }
    @media (max-width: 600px) {
      .disabled-banner { flex-direction: column; align-items: stretch; }
    }

    /* All-clear banner shown on the Status tab when the engine is
       enabled but nothing is firing. Same left-border treatment as
       the other notice boxes (network-module / backups-module
       canonical pattern), but accent color = --hf-ok. */
    .ok-banner {
      display: flex;
      align-items: center;
      gap: 14px;
      margin-bottom: 18px;
      padding: 14px 18px;
      background: rgba(59, 130, 246, 0.08);
      border-left: 4px solid var(--hf-ok);
      border-radius: 8px;
      color: var(--hf-text-muted);
      font-size: 13px;
      line-height: 1.5;
    }
    .ok-banner-icon {
      flex-shrink: 0;
      width: 22px;
      height: 22px;
      color: var(--hf-ok);
    }
    .ok-banner-text {
      flex: 1;
    }
    .ok-banner-text strong {
      display: block;
      color: var(--hf-text);
      font-size: 14px;
      margin-bottom: 2px;
    }
    /* Firing summary on the Status tab — symmetric to .ok-banner but
       in --hf-err. Shown when engine is on and at least one source
       is firing; the per-source cards below carry the detail. */
    .firing-banner {
      display: flex;
      align-items: center;
      gap: 14px;
      margin-bottom: 18px;
      padding: 14px 18px;
      background: rgba(59, 130, 246, 0.08);
      border-left: 4px solid var(--hf-err);
      border-radius: 8px;
      color: var(--hf-text-muted);
      font-size: 13px;
      line-height: 1.5;
    }
    .firing-banner-icon {
      flex-shrink: 0;
      width: 22px;
      height: 22px;
      color: var(--hf-err);
    }
    .firing-banner-text { flex: 1; }
    .firing-banner-text strong {
      display: block;
      color: var(--hf-text);
      font-size: 14px;
      margin-bottom: 2px;
    }

    /* Tabs. Sticky-bar variant copied from backups-module so the
       Alerts page reads consistently with Backups (the other multi-
       tab page in the admin shell). See backups-module.js for the
       rationale behind the negative-top + matching-padding offset:
       admin-app's .content-area gutter pushes the tab strip down
       and the sticky bar must reach back to the scrollport edge. */
    .tabs {
      position: sticky;
      top: 0;
      z-index: 5;
      display: flex;
      gap: 8px;
      margin-top: -24px;
      padding-top: 24px;
      margin-bottom: 24px;
      background: var(--hf-bg);
      border-bottom: 2px solid var(--hf-border);
    }
    .tab {
      padding: 12px 24px;
      background: none;
      border: none;
      border-bottom: 3px solid transparent;
      cursor: pointer;
      font-size: 15px;
      font-weight: 500;
      color: var(--hf-text-muted);
      transition: color 0.2s, border-color 0.2s;
      margin-bottom: -2px;
      font-family: inherit;
    }
    .tab:hover { color: var(--hf-text); }
    .tab.active {
      color: var(--hf-accent);
      border-bottom-color: var(--hf-accent);
    }
    /* Fixed circle, no horizontal padding — matches the top-bar
       alerts-bell-badge shape so the two count chips read as the
       same element. min-width + padding gave a pill stretch on
       two-digit / "9+" values; this stays round. */
    .tab-count {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 18px;
      height: 18px;
      margin-left: 8px;
      border-radius: 50%;
      background: var(--hf-err, #c62828);
      color: #fff;
      font-size: 10px;
      font-weight: 700;
      line-height: 1;
      box-sizing: content-box;
    }
    @media (max-width: 600px) {
      .tab { padding: 10px 14px; font-size: 14px; }
    }
  `;

  constructor() {
    super();
    this.config = {};
    this.appliedConfig = null;
    this.undeployedPaths = new Set();
    this.subRoute = '';
    this.activeTab = 'status';
    this._sources = [];
    this._history = [];
    this._loading = true;
    this._ntfyInfo = null;
    this._testing = false;
    this._testResult = null; // { ok: bool, message: str }
  }

  updated(changedProps) {
    // Sync admin-app's URL sub-route INTO our activeTab. Initial mount
    // and back/forward navigation both flow through this. Bare URL
    // (subRoute === '') maps to the Active tab; everything else maps
    // by name. Backups uses the same pattern.
    if (changedProps.has('subRoute')) {
      const target = this.subRoute === AlertsModule.SUB_ROUTE_CONFIGURATION
        ? 'configuration'
        : 'status';
      if (target !== this.activeTab) {
        this._setTab(target, { silent: true });
      }
    }
  }

  _setTab(tab, { silent = false } = {}) {
    this.activeTab = tab;
    if (!silent) {
      // Emit so admin-app updates window.location.hash. `silent` is
      // the URL→state direction (avoid the feedback round-trip).
      const subRoute = tab === 'configuration'
        ? AlertsModule.SUB_ROUTE_CONFIGURATION
        : '';
      this.dispatchEvent(new CustomEvent('sub-route-change', {
        detail: { subRoute },
        bubbles: true,
        composed: true,
      }));
    }
  }

  async _sendTestPush() {
    if (this._testing) return;
    this._testing = true;
    this._testResult = null;
    try {
      const res = await fetch('/api/alerts/channels/ntfy/test', { method: 'POST' });
      if (res.ok) {
        const body = await res.json().catch(() => ({}));
        this._testResult = {
          ok: true,
          message: body.message || 'Test push sent. Check your phone.',
        };
        // Refetch history so the new test row appears at the top of
        // the table without a manual reload. Sources / ntfy info are
        // unchanged by a test, so we don't refetch those.
        try {
          const h = await fetch('/api/alerts/history?limit=50');
          if (h.ok) this._history = (await h.json()).events || [];
        } catch { /* not fatal — the user can refresh manually. */ }
      } else {
        // FastAPI HTTPException renders as {detail: "..."}; surface
        // the body so the user sees WHY it failed (ntfy not running,
        // POST refused, etc.).
        const body = await res.json().catch(() => null);
        const detail = (body && (body.detail || body.message)) || (res.statusText || ('HTTP ' + res.status));
        this._testResult = { ok: false, message: 'Failed: ' + detail };
      }
    } catch (e) {
      this._testResult = { ok: false, message: 'Network error: ' + (e?.message || e) };
    } finally {
      this._testing = false;
      this.requestUpdate();
    }
  }

  // Render-time mapping from raw `source_id` (stored verbatim in the
  // SQLite events table) to a human label. Real sources have their
  // `label` in REGISTRY (loaded into this._sources from
  // /api/alerts/sources); synthetic meta-events like the manual
  // test push use a leading underscore + explicit handling here.
  _friendlySourceId(id) {
    if (!id) return '';
    if (id === '_test-ntfy') return 'Manual test (ntfy)';
    const known = (this._sources || []).find((s) => s.id === id);
    return known ? known.label : id;
  }

  connectedCallback() {
    super.connectedCallback();
    this._loadState();
    // Live-refresh source state, recent history, ntfy info while the
    // page is mounted. Same 30s cadence as the top-bar bell badge —
    // the alerts engine ticks at 60s by default so polling faster
    // would not give fresher data. Quiet=true skips the loading
    // spinner so the page doesn't flash on every tick.
    this._pollInterval = setInterval(
      () => this._loadState({ quiet: true }), 30000,
    );
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this._pollInterval) {
      clearInterval(this._pollInterval);
      this._pollInterval = null;
    }
  }

  async _loadState({ quiet = false } = {}) {
    if (!quiet) this._loading = true;
    try {
      const [s, h, n] = await Promise.all([
        fetch('/api/alerts/sources').then((r) => r.ok ? r.json() : { sources: [] }),
        fetch('/api/alerts/history?limit=50').then((r) => r.ok ? r.json() : { events: [] }),
        fetch('/api/alerts/channels/ntfy').then((r) => r.ok ? r.json() : null),
      ]);
      this._sources = s.sources || [];
      this._history = h.events || [];
      this._ntfyInfo = n;
    } catch (e) {
      console.warn('alerts: load failed', e);
    } finally {
      if (!quiet) this._loading = false;
    }
  }

  async _copyToClipboard(text) {
    try {
      await navigator.clipboard.writeText(text);
    } catch (e) {
      // Some browsers gate clipboard.write on a recent user gesture
      // OR on https. Fall back to a hidden textarea + execCommand
      // (still works in older Chromes / on http://homefree.lan).
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.style.position = 'absolute';
      ta.style.left = '-9999px';
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand('copy'); }
      finally { document.body.removeChild(ta); }
    }
    this._copiedAt = Date.now();
    this.requestUpdate();
    setTimeout(() => { this.requestUpdate(); }, 1500);
  }

  // True when `path` (dotted, rooted at the config: e.g.
  // 'alerts.sources.disk-temperature.threshold-c') has a change the
  // Apply step has not yet deployed. Used to amber-dot the field.
  _undeployed(path) {
    return this.undeployedPaths?.has(path) || false;
  }

  // Emit the WHOLE alerts subtree with one field changed. The
  // shallow per-key merge in admin-app.getMergedConfig means we
  // MUST send the full subtree — sending just the changed leaf
  // would shallow-replace the alerts object and drop sibling
  // edits. Mirrors the storage / mounts / proxied-domains pattern.
  _setField(dottedPath, value) {
    const alerts = this._cloneAlerts();
    this._writePath(alerts, dottedPath, value);
    // Auto-promote: enabling a channel implicitly enables the engine.
    // services/alerts/default.nix gates the entire alerts subsystem
    // (ntfy auto-enable, prepare-secrets, engine timer) behind
    // `homefree.alerts.enable`, so flipping a channel alone is a
    // no-op — ntfy never starts, no topic file ever gets generated,
    // and the pairing block sits forever on "Topic not yet provisioned".
    // Promoting here makes the obvious user gesture do the obvious
    // thing. The reverse (disabling the engine) intentionally does
    // NOT touch channel state, so re-enabling preserves the user's
    // last channel choices.
    if (value === true && dottedPath.startsWith('channels.')
        && dottedPath.endsWith('.enable')
        && alerts.enable !== true) {
      alerts.enable = true;
    }
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { config: { alerts }, module: 'alerts' },
      bubbles: true,
      composed: true,
    }));
  }

  _writePath(root, dottedPath, value) {
    const parts = dottedPath.split('.');
    let cur = root;
    for (let i = 0; i < parts.length - 1; i++) {
      const next = (cur[parts[i]] && typeof cur[parts[i]] === 'object')
        ? { ...cur[parts[i]] } : {};
      cur[parts[i]] = next;
      cur = next;
    }
    cur[parts[parts.length - 1]] = value;
  }

  _cloneAlerts() {
    // Deep clone to avoid mutating a shared reference handed to
    // us by admin-app. JSON round-trip is fine here — the alerts
    // tree is plain data (no Date, no Maps).
    return JSON.parse(JSON.stringify(this.config?.alerts || {}));
  }

  _fmtTime(ts) {
    if (!ts) return '—';
    return new Date(ts * 1000).toLocaleString();
  }

  // Status-tab card — title + live state badge always visible
  // (summary), with details (message + per-item bars) collapsed by
  // default unless the source is firing. Click summary to toggle.
  // tuning lives on the Configuration tab.
  _renderSourceStateRow(src) {
    const state = src.state || {};
    const severity = state.severity || (state.firing ? 'warn' : 'clear');
    const firing = severity !== 'clear';
    const cfg = (this.config?.alerts?.sources && this.config.alerts.sources[src.id]) || {};
    const peakSuffix = this._peakSuffix(src);
    const readings = state.readings || null;
    const meter = readings ? null : this._meterForSource(src, cfg);
    const badgeLabel = severity === 'err' ? 'ERR'
                     : severity === 'warn' ? 'WARN'
                     : 'OK';
    return html`
      <details class="source-row" ?open=${firing}>
        <summary>
          <div class="source-header">
            <svg class="summary-chevron" viewBox="0 0 24 24" fill="none"
                 stroke="currentColor" stroke-width="2.5"
                 stroke-linecap="round" stroke-linejoin="round"
                 aria-hidden="true">
              <polyline points="9 18 15 12 9 6"/>
            </svg>
            <div style="flex:1; min-width:0">
              <div class="source-title">${src.label}</div>
            </div>
            <span class="state-badge ${severity}">
              ${badgeLabel}${peakSuffix}
            </span>
          </div>
        </summary>
        <div class="source-body">
          ${state.message
            ? html`<div class="source-message">${state.message}</div>`
            : html`<div class="hint">Waiting for the first engine tick — the source's status will appear here on the next poll.</div>`}
          ${readings && readings.length
            ? this._renderReadingsBars(readings, src)
            : this._renderMeter(meter)}
        </div>
      </details>
    `;
  }

  // Per-item bars from the source's `state.readings` list. Each
  // reading has `name`, `value`, `warn`, `err`, `severity`, and
  // optional `class` (for the per-class temperature sources). The
  // track shows BOTH warn and err markers. Sources whose readings
  // carry only a single threshold key still work — the missing
  // marker just isn't drawn.
  _renderReadingsBars(readings, src) {
    const unit = this._unitForSource(src);
    const maxAcross = readings.reduce((m, r) => {
      const cand = Math.max(r.err || 0, r.warn || 0, r.value || 0);
      return Math.max(m, cand);
    }, 0);
    // Round up to a nice round number for axis stability.
    const max = Math.max(1, Math.ceil(maxAcross * 1.1));
    return html`
      <div class="item-bars">
        ${readings.map((r) => {
          const value = (r.value == null) ? null : Number(r.value);
          const warn = r.warn;
          const err = r.err;
          const sev = r.severity || 'clear';
          const fillPct = value == null ? 0 : Math.max(0, Math.min(100, (value / max) * 100));
          const warnPct = warn == null ? null : Math.max(0, Math.min(100, (warn / max) * 100));
          const errPct = err == null ? null : Math.max(0, Math.min(100, (err / max) * 100));
          // Edge-anchor class so the leftmost/rightmost label sits
          // inside the bar instead of overflowing the container.
          const edgeCls = (pct) =>
            pct == null ? '' : pct <= 6 ? 'at-left' : pct >= 94 ? 'at-right' : '';
          return html`
            <div class="item-bar">
              <div class="item-bar-name">
                ${r.name}
                ${r.class ? html`<span class="class-chip">${r.class}</span>` : ''}
              </div>
              <div class="item-bar-value ${sev}">
                ${value == null ? '—' : Math.round(value) + unit}
              </div>
              <div class="meter-track">
                ${value != null ? html`
                  <div class="meter-fill ${sev}" style="width: ${fillPct}%"></div>
                ` : ''}
                ${warnPct != null ? html`
                  <div class="meter-threshold warn"
                       style="left: ${warnPct}%"
                       title="warn ${warn}${unit}"></div>
                ` : ''}
                ${errPct != null ? html`
                  <div class="meter-threshold err"
                       style="left: ${errPct}%"
                       title="err ${err}${unit}"></div>
                ` : ''}
              </div>
              ${(warnPct != null || errPct != null) ? html`
                <div class="meter-axis">
                  ${warnPct != null ? html`
                    <span class="meter-threshold-label warn ${edgeCls(warnPct)}"
                          style="left: ${warnPct}%">${warn}${unit}</span>
                  ` : ''}
                  ${errPct != null ? html`
                    <span class="meter-threshold-label err ${edgeCls(errPct)}"
                          style="left: ${errPct}%">${err}${unit}</span>
                  ` : ''}
                </div>
              ` : ''}
            </div>
          `;
        })}
      </div>
    `;
  }

  _unitForSource(src) {
    switch (src.id) {
      case 'disk-temperature':
      case 'sensor-temperature':
        return '°C';
      case 'disk-space':
        return '%';
      case 'tls-cert':
        return 'd';
      default:
        return '';
    }
  }

  // Human-readable suffix appended to the FIRING/OK pill, e.g.
  // " — peak 46°C" for temperature sources. Returns empty string
  // for sources where the bare badge is more informative.
  _peakSuffix(src) {
    const state = src.state || {};
    if (state.peak_value == null) return '';
    const v = state.peak_value;
    switch (src.id) {
      case 'disk-temperature':
      case 'sensor-temperature':
        return ' — peak ' + Math.round(v) + '°C';
      case 'disk-space':
        return ' — peak ' + Math.round(v) + '%';
      case 'attacks':
        return ' — ' + Math.round(v) + ' banned';
      case 'tls-cert':
        // value here is days-until-earliest-expiry (can be negative
        // for expired). Bare days reads cleaner than "peak N".
        if (v < 0) return ' — expired ' + Math.round(-v) + 'd ago';
        return ' — ' + Math.round(v) + 'd left';
      default:
        return '';
    }
  }

  // Compute a meter spec for sources where a scalar threshold visual
  // is meaningful. Returns null to skip the meter for that source.
  // - Per-class temperature sources (disk-temp / sensor-temp) skip the
  //   meter because the threshold depends on which class hit the peak,
  //   and exposing that requires structured per-class state the engine
  //   doesn't write today. The message line carries the same info.
  // - Binary sources (smart, services-down, backup-failures, wan-,
  //   headscale-) skip the meter — they have no scalar threshold.
  //
  // The `current` field is null when the engine has not yet observed
  // a value (typical on a fresh box for the first tick or two). The
  // bar still renders so the user can see where the threshold sits;
  // the labels swap to a "no reading yet" notice.
  _meterForSource(src, cfg) {
    const state = src.state || {};
    const raw = state.peak_value;
    const current = (raw == null || raw === '') ? null : raw;
    switch (src.id) {
      case 'disk-space': {
        const thr = (cfg['threshold-percent'] !== undefined) ? cfg['threshold-percent'] : 90;
        return { current, threshold: thr, max: 100, unit: '%', reverse: false };
      }
      case 'attacks': {
        const thr = (cfg['threshold-bans'] !== undefined) ? cfg['threshold-bans'] : 5;
        return { current, threshold: thr, max: Math.max(thr * 2, 10), unit: '', reverse: false };
      }
      case 'tls-cert': {
        const warn = (cfg['warn-days'] !== undefined) ? cfg['warn-days'] : 14;
        // Reverse direction: fire when remaining days < warn. Negative
        // current values (expired) clamp to 0 for the fill width.
        return {
          current: current == null ? null : Math.max(0, current),
          threshold: warn,
          max: Math.max(warn * 3, 90),
          unit: 'd',
          reverse: true,
        };
      }
      default:
        return null;
    }
  }

  _renderMeter(meter) {
    if (!meter) return '';
    const max = Math.max(meter.max, 1);
    const thresholdPct = Math.max(0, Math.min(100, (meter.threshold / max) * 100));
    const hasReading = meter.current != null;
    const fillPct = hasReading
      ? Math.max(0, Math.min(100, (meter.current / max) * 100))
      : 0;
    const firing = hasReading
      ? (meter.reverse
          ? meter.current < meter.threshold
          : meter.current >= meter.threshold)
      : false;
    return html`
      <div class="meter-row">
        <div class="meter-track">
          ${hasReading ? html`
            <div class="meter-fill ${firing ? 'firing' : 'ok'}"
                 style="width: ${fillPct}%"></div>
          ` : ''}
          <div class="meter-threshold"
               style="left: ${thresholdPct}%"
               title="threshold"></div>
        </div>
        <div class="meter-labels">
          ${hasReading
            ? html`<span><strong>${Math.round(meter.current)}${meter.unit}</strong> now</span>`
            : html`<span class="meter-no-reading">no reading yet</span>`}
          <span>threshold ${meter.threshold}${meter.unit}</span>
        </div>
      </div>
    `;
  }

  // Configuration-tab card — enable toggle + source-specific fields.
  // No live state badge; live state lives on the Active tab.
  _renderSourceConfigRow(src) {
    const cfg = (this.config?.alerts?.sources && this.config.alerts.sources[src.id]) || {};
    // Precompute the dotted paths used inside the template so we
    // never construct a backtick string literal there (Lit gotcha).
    const cfgPathPrefix = 'sources.' + src.id + '.';
    const tagPathPrefix = 'alerts.sources.' + src.id + '.';
    const enableVal = cfg.enable !== false; // defaults to true for known sources
    const cfgHysteresis = (cfg['hysteresis-c'] !== undefined) ? cfg['hysteresis-c'] : 4;
    return html`
      <div class="source-row">
        <div class="source-header">
          <div class="source-title">${src.label}</div>
        </div>

        <form-field
          label="Enable"
          type="boolean"
          .value=${enableVal}
          help="Run this source on every alerts engine tick."
          ?undeployed=${this._undeployed(tagPathPrefix + 'enable')}
          @field-change=${(e) => this._setField(cfgPathPrefix + 'enable', e.detail.value)}
        ></form-field>

        ${this._renderSourceFields(src, cfg, cfgPathPrefix, tagPathPrefix, cfgHysteresis)}
      </div>
    `;
  }

  // Per-source-id dispatcher for the source-specific config fields.
  // Sources with no config beyond enable+channels (smart, services-
  // down, backup-failures) return null and just render the enable
  // toggle above.
  _renderSourceFields(src, cfg, cfgPathPrefix, tagPathPrefix, cfgHysteresis) {
    switch (src.id) {
      case 'disk-temperature':
        return this._renderDiskTempFields(cfg, cfgPathPrefix, tagPathPrefix, cfgHysteresis);
      case 'disk-space':
        return this._renderDiskSpaceFields(cfg, cfgPathPrefix, tagPathPrefix);
      case 'sensor-temperature':
        return this._renderSensorTempFields(src, cfg, cfgPathPrefix, tagPathPrefix, cfgHysteresis);
      case 'attacks':
        return this._renderAttacksFields(cfg, cfgPathPrefix, tagPathPrefix);
      case 'tls-cert':
        return this._renderTlsCertFields(cfg, cfgPathPrefix, tagPathPrefix);
      case 'wan-accessibility':
        return this._renderWanAccessibilityFields(cfg, cfgPathPrefix, tagPathPrefix);
      case 'smart':
      case 'services-down':
      case 'backup-failures':
      case 'headscale-accessibility':
        // No further config for v1 — just enable + (implicit) channels.
        return '';
      default:
        return '';
    }
  }

  _renderWanAccessibilityFields(cfg, cfgPathPrefix, tagPathPrefix) {
    const defaultIp = 'https://ipinfo.io/ip';
    const defaultDoh = 'https://cloudflare-dns.com/dns-query';
    const ip = (cfg['public-ip-url'] !== undefined)
      ? cfg['public-ip-url'] : defaultIp;
    const doh = (cfg['doh-url'] !== undefined)
      ? cfg['doh-url'] : defaultDoh;
    const pIp = cfgPathPrefix + 'public-ip-url';
    const pDoh = cfgPathPrefix + 'doh-url';
    const tIp = tagPathPrefix + 'public-ip-url';
    const tDoh = tagPathPrefix + 'doh-url';
    return html`
      <div class="hint" style="margin: 0 0 10px 0">
        Cross-checks your box's egress IP (from ipinfo) against the
        public DNS A record for your domain (via DoH, bypassing
        local unbound). Fires on a mismatch — the DDNS-misroute
        case. Auto-skips when nothing is WAN-public. Doesn't catch
        firewall / ISP blocks (those produce other symptoms
        services-down picks up).
      </div>
      <div class="field-grid">
        <form-field
          label="Public IP endpoint"
          type="text"
          .value=${ip}
          help="Returns the box's egress IP as plain text. Default: ipinfo.io."
          ?undeployed=${this._undeployed(tIp)}
          @field-change=${(e) => this._setField(pIp, e.detail.value || defaultIp)}
        ></form-field>
        <form-field
          label="DoH endpoint"
          type="text"
          .value=${doh}
          help="DNS-over-HTTPS JSON endpoint. Default: cloudflare-dns.com."
          ?undeployed=${this._undeployed(tDoh)}
          @field-change=${(e) => this._setField(pDoh, e.detail.value || defaultDoh)}
        ></form-field>
      </div>
    `;
  }

  _renderAttacksFields(cfg, cfgPathPrefix, tagPathPrefix) {
    const threshold = (cfg['threshold-bans'] !== undefined)
      ? cfg['threshold-bans'] : 5;
    const hysteresis = (cfg['hysteresis-bans'] !== undefined)
      ? cfg['hysteresis-bans'] : 2;
    const pThr = cfgPathPrefix + 'threshold-bans';
    const pHys = cfgPathPrefix + 'hysteresis-bans';
    const tThr = tagPathPrefix + 'threshold-bans';
    const tHys = tagPathPrefix + 'hysteresis-bans';
    return html`
      <div class="hint" style="margin: 0 0 10px 0">
        Reads fail2ban currently-banned counts across all jails (same
        data shown on the Abuse Blocking page). Fires when the total
        crosses the threshold — filtering out the constant background
        of single-IP scanner bans every internet-facing host sees.
      </div>
      <div class="field-grid">
        <form-field
          label="Threshold (banned IPs)"
          type="number"
          .value=${threshold}
          help="Fire when this many IPs are currently banned across all jails."
          ?undeployed=${this._undeployed(tThr)}
          @field-change=${(e) => this._setField(pThr, parseInt(e.detail.value, 10) || 5)}
        ></form-field>
        <form-field
          label="Hysteresis (bans)"
          type="number"
          .value=${hysteresis}
          help="Number of bans below threshold before clearing — prevents flap."
          ?undeployed=${this._undeployed(tHys)}
          @field-change=${(e) => this._setField(pHys, parseInt(e.detail.value, 10) || 2)}
        ></form-field>
      </div>
    `;
  }

  _renderTlsCertFields(cfg, cfgPathPrefix, tagPathPrefix) {
    const warnDays = (cfg['warn-days'] !== undefined)
      ? cfg['warn-days'] : 14;
    const pWarn = cfgPathPrefix + 'warn-days';
    const tWarn = tagPathPrefix + 'warn-days';
    return html`
      <div class="hint" style="margin: 0 0 10px 0">
        Walks Caddy's certificate storage and reads each cert's
        expiry. Fires when any cert is expiring within the warn
        window, or already expired. Lets-Encrypt issues 90-day
        certs and Caddy renews at 30 days remaining; 14 leaves 16
        days of background retries to recover before alerting.
      </div>
      <div class="field-grid">
        <form-field
          label="Warn days before expiry"
          type="number"
          .value=${warnDays}
          help="Alert when any cert is closer to expiry than this many days."
          ?undeployed=${this._undeployed(tWarn)}
          @field-change=${(e) => this._setField(pWarn, parseInt(e.detail.value, 10) || 14)}
        ></form-field>
      </div>
    `;
  }

  _renderDiskSpaceFields(cfg, cfgPathPrefix, tagPathPrefix) {
    const threshold = (cfg['threshold-percent'] !== undefined)
      ? cfg['threshold-percent'] : 90;
    const hysteresis = (cfg['hysteresis-percent'] !== undefined)
      ? cfg['hysteresis-percent'] : 3;
    const pThr = cfgPathPrefix + 'threshold-percent';
    const pHys = cfgPathPrefix + 'hysteresis-percent';
    const tThr = tagPathPrefix + 'threshold-percent';
    const tHys = tagPathPrefix + 'hysteresis-percent';
    return html`
      <div class="hint" style="margin: 0 0 10px 0">
        Walks every locally-mounted filesystem and fires when any one
        crosses the threshold. Kernel virtual filesystems and container
        layer storage are skipped automatically (see fs-types and
        skip-mount-prefixes in the JSON Config for overrides).
      </div>
      <div class="field-grid">
        <form-field
          label="Threshold (% full)"
          type="number"
          .value=${threshold}
          help="Fire when any filesystem reaches this percent used."
          ?undeployed=${this._undeployed(tThr)}
          @field-change=${(e) => this._setField(pThr, parseInt(e.detail.value, 10) || 90)}
        ></form-field>
        <form-field
          label="Hysteresis (%)"
          type="number"
          .value=${hysteresis}
          help="Percent below threshold before clearing."
          ?undeployed=${this._undeployed(tHys)}
          @field-change=${(e) => this._setField(pHys, parseInt(e.detail.value, 10) || 3)}
        ></form-field>
      </div>
    `;
  }

  _renderSensorTempFields(src, cfg, cfgPathPrefix, tagPathPrefix, cfgHysteresis) {
    const t = cfg.thresholds || {};
    // Per-class warn / err overrides. Each may be null / undefined,
    // which signals 'let the backend infer'. The form-field renders
    // empty + placeholder in that case; clearing a field emits null
    // from form-field's number handler, which flows back through to
    // the JSON as null and re-enables inference on the next apply.
    const cpuWarn  = t['cpu-warn-c'];
    const cpuErr   = t['cpu-err-c'];
    const nvmeWarn = t['nvme-warn-c'];
    const nvmeErr  = t['nvme-err-c'];
    const gpuWarn  = t['gpu-warn-c'];
    const gpuErr   = t['gpu-err-c'];
    // Live readings (when present) carry the resolved warn / err the
    // backend used on the last tick. When no user override is set
    // they ARE the inferred values, so we can surface them as the
    // placeholder. We take the max across readings of the same class
    // — a class with two NVMe drives wants to show the strictest
    // inferred threshold so the user sees the line that would fire.
    const readings = (src && src.state && src.state.readings) || [];
    const inferFor = (klass, key) => {
      let best = null;
      for (const r of readings) {
        if (r && r.class === klass && typeof r[key] === 'number') {
          if (best === null || r[key] > best) best = r[key];
        }
      }
      return best === null ? 'inferred' : String(best);
    };
    const phCpuW  = inferFor('cpu',  'warn');
    const phCpuE  = inferFor('cpu',  'err');
    const phNvmeW = inferFor('nvme', 'warn');
    const phNvmeE = inferFor('nvme', 'err');
    const phGpuW  = inferFor('gpu',  'warn');
    const phGpuE  = inferFor('gpu',  'err');
    const pCpuW   = cfgPathPrefix + 'thresholds.cpu-warn-c';
    const pCpuE   = cfgPathPrefix + 'thresholds.cpu-err-c';
    const pNvmeW  = cfgPathPrefix + 'thresholds.nvme-warn-c';
    const pNvmeE  = cfgPathPrefix + 'thresholds.nvme-err-c';
    const pGpuW   = cfgPathPrefix + 'thresholds.gpu-warn-c';
    const pGpuE   = cfgPathPrefix + 'thresholds.gpu-err-c';
    const tCpuW   = tagPathPrefix + 'thresholds.cpu-warn-c';
    const tCpuE   = tagPathPrefix + 'thresholds.cpu-err-c';
    const tNvmeW  = tagPathPrefix + 'thresholds.nvme-warn-c';
    const tNvmeE  = tagPathPrefix + 'thresholds.nvme-err-c';
    const tGpuW   = tagPathPrefix + 'thresholds.gpu-warn-c';
    const tGpuE   = tagPathPrefix + 'thresholds.gpu-err-c';
    const pHys = cfgPathPrefix + 'hysteresis-c';
    const tHys = tagPathPrefix + 'hysteresis-c';
    // form-field number handler: empty string -> null, non-empty ->
    // parseInt. We accept null and integers verbatim, drop NaN.
    const writeNum = (path) => (e) => {
      const v = e.detail.value;
      const out = (typeof v === 'number' && !isNaN(v)) ? v : null;
      this._setField(path, out);
    };
    return html`
      <div class="hint" style="margin: 0 0 10px 0">
        Per-silicon-class warn / err thresholds for CPU / NVMe
        controller / GPU sensors from hwmon (same sensors shown on
        the Hardware page). Leave a field blank to infer from your
        hardware — the backend reads each driver's reported limit
        when available (Intel coretemp, NVMe controllers, discrete
        GPUs), and falls back to a CPUID-family or PCI-vendor bucket
        for AMD CPUs and integrated GPUs that don't expose Tjmax.
        Set an explicit number to override. The NVMe controller
        sensor is distinct from the NVMe media temperature monitored
        under Disk temperature.
      </div>
      <div class="field-grid">
        <form-field
          label="CPU warn (°C)"
          type="number"
          placeholder=${phCpuW}
          .value=${cpuWarn ?? ''}
          help="Fire WARN when any CPU sensor reaches this. Blank = inferred from hardware."
          ?undeployed=${this._undeployed(tCpuW)}
          @field-change=${writeNum(pCpuW)}
        ></form-field>
        <form-field
          label="CPU err (°C)"
          type="number"
          placeholder=${phCpuE}
          .value=${cpuErr ?? ''}
          help="Fire ERR when any CPU sensor reaches this. Blank = inferred."
          ?undeployed=${this._undeployed(tCpuE)}
          @field-change=${writeNum(pCpuE)}
        ></form-field>
        <form-field
          label="NVMe ctlr warn (°C)"
          type="number"
          placeholder=${phNvmeW}
          .value=${nvmeWarn ?? ''}
          help="Fire WARN on NVMe controller temp. Blank = inferred from the controller's reported limits."
          ?undeployed=${this._undeployed(tNvmeW)}
          @field-change=${writeNum(pNvmeW)}
        ></form-field>
        <form-field
          label="NVMe ctlr err (°C)"
          type="number"
          placeholder=${phNvmeE}
          .value=${nvmeErr ?? ''}
          help="Fire ERR on NVMe controller temp. Blank = inferred."
          ?undeployed=${this._undeployed(tNvmeE)}
          @field-change=${writeNum(pNvmeE)}
        ></form-field>
        <form-field
          label="GPU warn (°C)"
          type="number"
          placeholder=${phGpuW}
          .value=${gpuWarn ?? ''}
          help="Fire WARN on GPU temp. Blank = inferred (discrete cards read driver limits, integrated GPUs use a class default)."
          ?undeployed=${this._undeployed(tGpuW)}
          @field-change=${writeNum(pGpuW)}
        ></form-field>
        <form-field
          label="GPU err (°C)"
          type="number"
          placeholder=${phGpuE}
          .value=${gpuErr ?? ''}
          help="Fire ERR on GPU temp. Blank = inferred."
          ?undeployed=${this._undeployed(tGpuE)}
          @field-change=${writeNum(pGpuE)}
        ></form-field>
        <form-field
          label="Hysteresis (°C)"
          type="number"
          .value=${cfgHysteresis}
          help="Degrees below threshold before clearing — prevents flap. Applies to every class."
          ?undeployed=${this._undeployed(tHys)}
          @field-change=${(e) => this._setField(pHys, parseInt(e.detail.value, 10) || 4)}
        ></form-field>
      </div>
    `;
  }

  _renderDiskTempFields(cfg, cfgPathPrefix, tagPathPrefix, cfgHysteresis) {
    const pHys  = cfgPathPrefix + 'hysteresis-c';
    const tHys  = tagPathPrefix + 'hysteresis-c';
    return html`
      <div class="hint" style="margin: 0 0 10px 0">
        Thresholds are read from each drive's own SMART data — the SCT
        Temperature Status log for SATA drives, controller identify for
        NVMe. A Seagate IronWolf 12TB reports about 60°C / 70°C; a
        24/28TB helium drive reports tighter, around 55°C / 60°C. See
        the Hardware page for per-drive numbers. A class default
        (HDD 50/60, SSD 60/70, NVMe 70/80) covers drives that don't
        report — typically older USB-bridged units.
      </div>
      <div class="field-grid">
        <form-field
          label="Hysteresis (°C)"
          type="number"
          .value=${cfgHysteresis}
          help="Degrees below threshold before clearing — prevents flap. Applies to every drive."
          ?undeployed=${this._undeployed(tHys)}
          @field-change=${(e) => this._setField(pHys, parseInt(e.detail.value, 10) || 4)}
        ></form-field>
      </div>
    `;
  }

  _renderNtfyPairing() {
    const info = this._ntfyInfo;
    if (!info) {
      // Endpoint hasn't responded yet, OR responded with a non-OK status
      // (e.g. router not yet deployed). Show a benign placeholder
      // instead of blowing up.
      return html`
        <div class="pairing-block">
          <p class="hint">Loading pairing info…</p>
        </div>
      `;
    }
    if (!info.provisioned || !info.topic || !info.base_url) {
      return html`
        <div class="pairing-block">
          <div class="pairing-title">Pair your phone</div>
          <p class="hint">
            Topic not yet provisioned. After the next Apply / rebuild,
            this page will show the server URL and topic to add to your
            ntfy app.
          </p>
        </div>
      `;
    }
    // Two-field copy state — each chip remembers its own "Copied"
    // flash so copying one doesn't toggle the other.
    const recently = (key) => this._copiedKey === key && this._copiedAt
      && (Date.now() - this._copiedAt < 1500);
    const copy = (key, value) => () => {
      this._copiedKey = key;
      this._copyToClipboard(value);
    };
    return html`
      <div class="pairing-block">
        <div class="pairing-title">Pair your phone</div>
        <p class="hint">
          Install the
          <strong>ntfy</strong>
          app (Google Play / F-Droid / App Store), then add a new
          subscription using the server URL and topic below. The ntfy
          app takes the two separately — it does NOT accept a combined
          URL pasted into the topic field.
        </p>

        <div class="pairing-field">
          <div class="pairing-field-label">Server URL</div>
          <div class="pairing-url-row">
            <div class="pairing-url">${info.base_url}</div>
            <button class="copy-btn ${recently('server') ? 'copied' : ''}"
                    @click=${copy('server', info.base_url)}>
              ${recently('server') ? 'Copied' : 'Copy'}
            </button>
          </div>
        </div>

        <div class="pairing-field">
          <div class="pairing-field-label">Topic</div>
          <div class="pairing-url-row">
            <div class="pairing-url">${info.topic}</div>
            <button class="copy-btn ${recently('topic') ? 'copied' : ''}"
                    @click=${copy('topic', info.topic)}>
              ${recently('topic') ? 'Copied' : 'Copy'}
            </button>
          </div>
        </div>

        <ol class="pairing-steps">
          <li>Open the ntfy app and tap the + (Add subscription) button.</li>
          <li>Check the "Use another server" box.</li>
          <li>Paste the Server URL above into the server field.</li>
          <li>Paste the Topic above into the topic field, then tap Subscribe.</li>
          <li>Click "Send test notification" below to verify your phone is paired.</li>
        </ol>

        <div class="test-push-row">
          <button class="btn btn-action btn-sm"
                  ?disabled=${this._testing}
                  @click=${() => this._sendTestPush()}>
            ${this._testing ? 'Sending…' : 'Send test notification'}
          </button>
          ${this._testResult ? html`
            <span class="test-push-status ${this._testResult.ok ? 'ok' : 'err'}">
              ${this._testResult.message}
            </span>
          ` : ''}
        </div>

        ${!info.public ? html`
          <div class="warn-box">
            <strong>LAN-only:</strong> ntfy is not exposed to the WAN, so
            your phone must be on the home Wi-Fi to receive pushes. To
            allow off-network pushes, enable
            <code>homefree.services.ntfy.public</code> in the JSON Config,
            or reach the server via a VPN.
          </div>
        ` : ''}

        <p class="hint" style="margin-top:10px">
          The topic IS the password — anyone who knows it can read your
          alerts and publish to it. Don't paste it into chat or post it
          in a screenshot.
        </p>
      </div>
    `;
  }

  _renderStatusTab() {
    const alerts = this.config?.alerts || {};
    const masterOff = alerts.enable !== true;
    const sources = this._sources || [];
    let warnCount = 0;
    let errCount = 0;
    for (const s of sources) {
      const sev = s.state && s.state.severity;
      if (sev === 'err') errCount++;
      else if (sev === 'warn') warnCount++;
    }
    const firingCount = warnCount + errCount;
    const sourcesLoaded = sources.length > 0;
    // Three top-banner states: engine-off, all-clear, firing.
    // engine-off takes priority — the rest of the page is irrelevant
    // until the engine is on.
    const showAllClear =
      !masterOff && sourcesLoaded && firingCount === 0;
    const showFiring =
      !masterOff && firingCount > 0;
    return html`
      ${masterOff ? html`
        <div class="disabled-banner" role="status">
          <svg class="disabled-banner-icon" viewBox="0 0 24 24" fill="none"
               stroke="currentColor" stroke-width="2"
               stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z"/>
            <line x1="12" y1="9" x2="12" y2="13"/>
            <line x1="12" y1="17" x2="12.01" y2="17"/>
          </svg>
          <div class="disabled-banner-text">
            <strong>Alerts engine is off.</strong>
            Nothing fires until the engine is enabled — no sources are
            evaluated and no notifications are sent. Configure thresholds
            on the Configuration tab.
          </div>
          <button class="btn btn-action btn-sm"
                  @click=${() => this._setField('enable', true)}>
            Enable now
          </button>
        </div>
      ` : ''}

      ${showAllClear ? html`
        <div class="ok-banner" role="status">
          <svg class="ok-banner-icon" viewBox="0 0 24 24" fill="none"
               stroke="currentColor" stroke-width="2"
               stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <circle cx="12" cy="12" r="10"/>
            <path d="m9 12 2 2 4-4"/>
          </svg>
          <div class="ok-banner-text">
            <strong>All clear.</strong>
            ${sources.length} source${sources.length === 1 ? '' : 's'}
            reporting OK.
          </div>
        </div>
      ` : ''}

      ${showFiring ? html`
        <div class="firing-banner" role="alert">
          <svg class="firing-banner-icon" viewBox="0 0 24 24" fill="none"
               stroke="currentColor" stroke-width="2"
               stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z"/>
            <line x1="12" y1="9" x2="12" y2="13"/>
            <line x1="12" y1="17" x2="12.01" y2="17"/>
          </svg>
          <div class="firing-banner-text">
            <strong>
              ${firingCount} source${firingCount === 1 ? '' : 's'} firing
              ${errCount > 0 && warnCount > 0
                ? html` (${errCount} err, ${warnCount} warn).`
                : errCount > 0
                  ? html` at ERR.`
                  : html` at WARN.`}
            </strong>
            Detail in the source cards below; full history at the
            bottom of the page.
          </div>
        </div>
      ` : ''}

      <config-section title="Sources"
        description="Current state of each source. FIRING means an alert is currently open; OK means under threshold.">
        ${this._sources.length === 0
          ? html`<div class="empty">No sources loaded yet.</div>`
          : this._sources.map((s) => this._renderSourceStateRow(s))}
      </config-section>

      <config-section title="History"
        description="Past alert events, newest first. Empty until the engine has fired.">
        ${this._history.length === 0
          ? html`<div class="empty">No alerts in history.</div>`
          : html`
            <table class="history-table">
              <thead>
                <tr>
                  <th>Source</th>
                  <th>Severity</th>
                  <th>Opened</th>
                  <th>Closed</th>
                  <th>Peak</th>
                  <th>Message</th>
                </tr>
              </thead>
              <tbody>
                ${this._history.map((ev) => {
                  const sev = ev.severity || 'warn';
                  const sevLabel = sev === 'err' ? 'ERR'
                                  : sev === 'warn' ? 'WARN'
                                  : sev.toUpperCase();
                  return html`
                  <tr>
                    <td>${this._friendlySourceId(ev.source_id)}</td>
                    <td><span class="state-badge ${sev}">${sevLabel}</span></td>
                    <td>${this._fmtTime(ev.started_ts)}</td>
                    <td>${ev.ended_ts
                      ? this._fmtTime(ev.ended_ts)
                      : html`<span class="state-badge ${sev}">open</span>`}</td>
                    <td>${ev.peak_value != null ? Math.round(ev.peak_value) : '—'}</td>
                    <td class="history-msg">${ev.close_message || ev.open_message || ''}</td>
                  </tr>
                  `;
                })}
              </tbody>
            </table>
          `}
      </config-section>
    `;
  }

  _renderConfigTab() {
    const alerts = this.config?.alerts || {};
    const ntfy = (alerts.channels && alerts.channels.ntfy) || {};
    return html`
      <config-section title="Alerts"
        description="Get notified when disk temperatures or other system conditions cross a threshold.">

        <form-field
          label="Enable alerts engine"
          type="boolean"
          .value=${alerts.enable === true}
          help="Master toggle. When off, no sources are evaluated and no notifications are sent."
          ?undeployed=${this._undeployed('alerts.enable')}
          @field-change=${(e) => this._setField('enable', e.detail.value)}
        ></form-field>

        <form-field
          label="Poll interval"
          type="text"
          .value=${alerts.interval || '1min'}
          placeholder="1min"
          help="systemd OnUnitInactiveSec syntax. Examples: 30s, 1min, 5min, 1h."
          ?undeployed=${this._undeployed('alerts.interval')}
          @field-change=${(e) => this._setField('interval', e.detail.value)}
        ></form-field>
      </config-section>

      <config-section title="Channels"
        description="Where alerts get sent. ntfy pushes to a paired phone running the ntfy app.">
        <form-field
          label="ntfy push"
          type="boolean"
          .value=${ntfy.enable === true}
          help="Enables the self-hosted ntfy server and dispatches alert events to it."
          ?undeployed=${this._undeployed('alerts.channels.ntfy.enable')}
          @field-change=${(e) => this._setField('channels.ntfy.enable', e.detail.value)}
        ></form-field>
        ${ntfy.enable === true ? this._renderNtfyPairing() : ''}
      </config-section>

      <config-section title="Sources"
        description="Each source is independently configurable. Disabled sources are skipped on every tick.">
        ${this._sources.length === 0
          ? html`<div class="empty">No sources loaded yet.</div>`
          : this._sources.map((s) => this._renderSourceConfigRow(s))}
      </config-section>
    `;
  }

  render() {
    // Count of currently-non-clear sources by severity. The Status
    // tab's chip shows the total; the firing-banner breaks it down.
    let warnCount = 0;
    let errCount = 0;
    for (const s of (this._sources || [])) {
      const sev = s.state && s.state.severity;
      if (sev === 'err') errCount++;
      else if (sev === 'warn') warnCount++;
    }
    const firingCount = warnCount + errCount;
    return html`
      <div class="module-container">
        <div class="tabs" role="tablist">
          <button
            class="tab ${this.activeTab === 'status' ? 'active' : ''}"
            role="tab"
            aria-selected=${this.activeTab === 'status' ? 'true' : 'false'}
            @click=${() => this._setTab('status')}
          >
            Status
            ${firingCount > 0 ? html`<span class="tab-count">${firingCount > 9 ? '9+' : firingCount}</span>` : ''}
          </button>
          <button
            class="tab ${this.activeTab === 'configuration' ? 'active' : ''}"
            role="tab"
            aria-selected=${this.activeTab === 'configuration' ? 'true' : 'false'}
            @click=${() => this._setTab('configuration')}
          >Configuration</button>
        </div>

        ${this.activeTab === 'configuration'
          ? this._renderConfigTab()
          : this._renderStatusTab()}
      </div>
    `;
  }
}

customElements.define('alerts-module', AlertsModule);
