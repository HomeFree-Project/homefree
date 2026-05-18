import { LitElement, html, css, svg } from 'lit';
import {
  getAbuseBlockingStatus,
  getAbuseBlockingBanned,
  getAbuseBlockingCounters,
  getAbuseBlockingTopTrafficSources,
  postAbuseBlockingUnban,
} from '../../../api/client.js';
import { WORLD_LAND_PATH, WORLD_VIEWBOX } from './world-map-path.js';

/**
 * Network Traffic module (sidebar label; id/route/files remain
 * "abuse-blocking" — renaming those is churn with no user benefit).
 *
 * Observability + tactical control for the three abuse-mitigation layers:
 *   1. fail2ban (three jails defined in modules/abuse-blocking.nix)
 *   2. nftables sets: abusive_nets4 (static), f2b_banned4 / f2b_banned6
 *   3. Caddy per-service access logs at /var/log/caddy/access-*.log
 *
 * Read-only for fail2ban status, banned IPs, drop counters, and the
 * top-N traffic-source list (parsed from logs). The static block
 * list is editable via homefree.network.abuseBlockCidrs — a list of
 * { cidr, enabled, comment } records; edits land in pendingConfig and
 * flow through the standard Save/Apply path.
 *
 * Own polling (5s for status/banned/counters, 30s for top-attackers)
 * so refresh doesn't depend on the parent. Stops on disconnect.
 */
class AbuseBlockingModule extends LitElement {
  static properties = {
    serverConfig: { type: Object },
    pendingConfig: { type: Object },
    status: { type: Object, state: true },
    banned: { type: Object, state: true },
    counters: { type: Object, state: true },
    topTraffic: { type: Object, state: true },
    topFilter: { type: String, state: true },
    includeInternal: { type: Boolean, state: true },
    expandedUris: { state: true },  // Set of source IPs whose URL cell is expanded
    loading: { type: Boolean, state: true },
    error: { type: String, state: true },
    pendingUnban: { type: Object, state: true },  // {ip: true} while in-flight
    newCidrInput: { type: String, state: true },
    newCidrComment: { type: String, state: true },
    cidrError: { type: String, state: true },
    mapTooltip: { type: Object, state: true },  // {bucket, x, y} | null
  };

  static styles = css`
    :host {
      display: block;
    }
    /* No max-width cap — the abuse-blocking tables (IP + rDNS +
       Location + URI columns) are wide and benefit from all the
       horizontal room a wide monitor gives. */
    .module-container { width: 100%; }

    h2 {
      font-size: 18px;
      font-weight: 600;
      color: var(--hf-text);
      margin: 28px 0 12px;
    }
    h2:first-child { margin-top: 0; }

    .summary-cards {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 12px;
      margin-bottom: 16px;
    }
    .card {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border);
      border-radius: 10px;
      padding: 14px 16px;
    }
    .card-label {
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      color: var(--hf-text-muted);
      margin-bottom: 6px;
    }
    .card-value {
      font-size: 22px;
      font-weight: 600;
      color: var(--hf-text);
    }
    .card-value.ok    { color: var(--hf-ok); }
    .card-value.err   { color: var(--hf-err); }
    .card-value.warn  { color: var(--hf-warn); }
    .card-sub {
      font-size: 12px;
      color: var(--hf-text-muted);
      margin-top: 4px;
    }

    .panel {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border);
      border-radius: 10px;
      padding: 14px 16px;
      margin-bottom: 16px;
      /* The panel never scrolls — it holds the filter bar / map too.
         Wide tables get their own .table-scroll wrapper instead. */
      min-width: 0;
    }

    /* Per-table horizontal scroll: a wide table scrolls INSIDE this
       box, never widening the panel or the page. */
    .table-scroll {
      overflow-x: auto;
      max-width: 100%;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 13px;
    }
    th, td {
      text-align: left;
      padding: 8px 12px;
      border-bottom: 1px solid var(--hf-border);
    }
    th {
      font-weight: 600;
      color: var(--hf-text-muted);
      font-size: 11px;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }
    td.mono { font-family: 'SF Mono', Monaco, 'Courier New', monospace; }
    /* Location / Domain should stay on one line — they're short-ish
       and wrapping them looks broken. The Sample URI column is the
       flexible one that absorbs leftover width and truncates. */
    td.nowrap, th.nowrap { white-space: nowrap; }
    /* The URI column is the flexible one: it takes all leftover width
       (width: 100% on a table cell = "as wide as possible") and
       truncates with an ellipsis, so adding fixed columns like Action
       shrinks the URI rather than widening the whole table. */
    td.uri {
      width: 100%;
      max-width: 0;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      cursor: pointer;
    }
    td.uri:hover { color: var(--hf-text) !important; }
    td.uri-expanded {
      white-space: normal;
      overflow-wrap: anywhere;   /* break long unbroken query strings */
      text-overflow: clip;
    }
    .uri-caret {
      margin-left: 6px;
      opacity: 0.6;
      font-size: 11px;
      user-select: none;
    }
    .row-empty {
      color: var(--hf-text-muted);
      padding: 16px;
      text-align: center;
      font-style: italic;
    }

    .pill {
      display: inline-block;
      padding: 2px 8px;
      border-radius: 999px;
      font-size: 11px;
      font-weight: 500;
    }
    .pill.static     { background: rgba(245, 158, 11, 0.12); color: var(--hf-warn); }
    .pill.fail2ban   { background: rgba(99, 102, 241, 0.15); color: #a5b4fc; }
    .pill.jail       { background: var(--hf-surface-2); color: var(--hf-text-muted); }

    .action-button {
      background: var(--hf-surface-2);
      color: var(--hf-text);
      border: 1px solid var(--hf-border-2);
      padding: 4px 10px;
      border-radius: 6px;
      font-size: 12px;
      cursor: pointer;
    }
    .action-button:hover:not(:disabled) {
      background: var(--hf-surface-3);
      border-color: var(--hf-accent);
    }
    .action-button:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }

    .filter-bar {
      display: flex;
      gap: 8px;
      align-items: center;
      margin-bottom: 12px;
    }
    .filter-bar select {
      padding: 6px 10px;
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      background: var(--hf-surface);
      color: var(--hf-text);
      font-size: 13px;
    }

    .cidr-input-row {
      display: flex;
      gap: 8px;
      margin-bottom: 8px;
    }
    .cidr-input-row input {
      flex: 1;
      padding: 8px 12px;
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      background: var(--hf-surface);
      color: var(--hf-text);
      font-size: 13px;
      font-family: 'SF Mono', Monaco, monospace;
    }
    .cidr-input-row input:focus {
      outline: none;
      border-color: var(--hf-accent);
    }

    /* Per-row comment field in the block-list table. Borderless
       until focused so the table stays calm at a glance. */
    .cidr-comment-input {
      width: 100%;
      box-sizing: border-box;
      padding: 4px 6px;
      border: 1px solid transparent;
      border-radius: 4px;
      background: transparent;
      color: var(--hf-text);
      font-size: 12px;
      font-family: inherit;
    }
    .cidr-comment-input:hover {
      border-color: var(--hf-border);
    }
    .cidr-comment-input:focus {
      outline: none;
      border-color: var(--hf-accent);
      background: var(--hf-surface);
    }
    .cidr-comment-input::placeholder {
      color: var(--hf-text-muted);
      font-style: italic;
    }

    .cidr-error {
      color: var(--hf-err);
      font-size: 12px;
      margin-bottom: 8px;
    }

    .help-text {
      font-size: 12px;
      color: var(--hf-text-muted);
      line-height: 1.5;
      margin-bottom: 12px;
    }

    .error-box {
      background: rgba(239, 68, 68, 0.1);
      border: 1px solid var(--hf-err);
      border-radius: 8px;
      padding: 12px 16px;
      color: var(--hf-err);
      font-size: 13px;
      margin-bottom: 16px;
    }

    .down-banner {
      background: rgba(245, 158, 11, 0.1);
      border: 1px solid var(--hf-warn);
      border-radius: 8px;
      padding: 12px 16px;
      color: var(--hf-warn);
      font-size: 13px;
      margin-bottom: 16px;
    }

    .map-wrap {
      width: 100%;
      background: var(--hf-surface-2);
      border-radius: 8px;
      overflow: hidden;
    }
    .map-wrap svg {
      display: block;
      width: 100%;
      height: auto;
    }
    .map-land {
      fill: var(--hf-surface-3);
      stroke: var(--hf-border-2);
      stroke-width: 0.5;
    }
    .map-dot {
      fill: var(--hf-err);
      fill-opacity: 0.55;
      stroke: var(--hf-err);
      stroke-width: 0.75;
    }
    .map-empty {
      text-align: center;
      color: var(--hf-text-muted);
      font-style: italic;
      padding: 24px;
    }
    /* The map needs to be the positioning context for the absolutely
       positioned hover card. */
    .map-wrap { position: relative; }
    .map-dot { cursor: pointer; }
    .map-dot:hover, .map-dot:focus {
      fill-opacity: 0.8;
      stroke-width: 1.5;
      outline: none;
    }
    .map-tooltip {
      position: absolute;
      z-index: 20;
      pointer-events: none;       /* never eat the mouse from the map */
      background: var(--hf-surface);
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      box-shadow: 0 6px 24px rgba(0, 0, 0, 0.25);
      padding: 10px 12px;
      font-size: 12px;
      color: var(--hf-text);
      max-width: 340px;
      transform: translate(-50%, calc(-100% - 12px));
    }
    .map-tooltip .tt-title {
      font-weight: 600;
      margin-bottom: 2px;
    }
    .map-tooltip .tt-sub {
      color: var(--hf-text-muted);
      margin-bottom: 6px;
    }
    .map-tooltip table {
      font-size: 11px;
      width: 100%;
    }
    .map-tooltip th, .map-tooltip td {
      padding: 2px 6px 2px 0;
      border-bottom: none;
      white-space: nowrap;
    }
    .map-tooltip td.tt-ip { font-family: 'SF Mono', Monaco, monospace; }
    .map-tooltip .tt-more {
      color: var(--hf-text-muted);
      font-style: italic;
      padding-top: 2px;
    }

    /* Skeleton placeholders shown on first load while each section's
       data is still null. Shimmer copied from backups-module.js so
       all admin skeletons look identical. */
    .skeleton {
      display: inline-block;
      border-radius: 4px;
      background: linear-gradient(90deg,
        var(--hf-surface-3) 25%,
        var(--hf-border-2) 37%,
        var(--hf-surface-3) 63%);
      background-size: 400% 100%;
      animation: shimmer 1.4s ease infinite;
      vertical-align: middle;
    }
    .skeleton-title { width: 180px; height: 15px; }
    .skeleton-sub   { width: 110px; height: 11px; margin-top: 6px; }
    .skeleton-badge { width: 70px; height: 16px; border-radius: 999px; }
    .skeleton-cell  { width: 60px; height: 13px; }
    .skeleton-card-value { width: 48px; height: 26px; }
    @keyframes shimmer {
      from { background-position: 100% 0; }
      to   { background-position: 0 0; }
    }
  `;

  constructor() {
    super();
    this.serverConfig = null;
    this.pendingConfig = {};
    this.status = null;
    this.banned = null;
    this.counters = null;
    this.topTraffic = null;
    this.topFilter = 'all';
    this.includeInternal = false;
    this.expandedUris = new Set();
    this.loading = true;
    this.error = null;
    this.pendingUnban = {};
    this.newCidrInput = '';
    this.newCidrComment = '';
    this.cidrError = null;
    this.mapTooltip = null;
    this._fastPoll = null;
    this._slowPoll = null;
  }

  connectedCallback() {
    super.connectedCallback();
    this._beforeUnloadHandler = () => this._stopPolling();
    window.addEventListener('beforeunload', this._beforeUnloadHandler);
    this._refreshAll();
    this._startPolling();
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this._beforeUnloadHandler) {
      window.removeEventListener('beforeunload', this._beforeUnloadHandler);
    }
    this._stopPolling();
  }

  _startPolling() {
    this._stopPolling();
    this._fastPoll = setInterval(() => this._refreshFast(), 5000);
    this._slowPoll = setInterval(() => this._refreshTop(), 30000);
  }

  _stopPolling() {
    if (this._fastPoll) { clearInterval(this._fastPoll); this._fastPoll = null; }
    if (this._slowPoll) { clearInterval(this._slowPoll); this._slowPoll = null; }
  }

  async _refreshAll() {
    this.loading = true;
    await Promise.all([this._refreshFast(), this._refreshTop()]);
    this.loading = false;
  }

  async _refreshFast() {
    try {
      const [status, banned, counters] = await Promise.all([
        getAbuseBlockingStatus(),
        getAbuseBlockingBanned(),
        getAbuseBlockingCounters(),
      ]);
      this.status = status;
      this.banned = banned;
      this.counters = counters;
      this.error = null;
    } catch (err) {
      console.error('[abuse-blocking] refresh failed:', err);
      this.error = err.message || 'failed to load abuse-blocking state';
    }
  }

  async _refreshTop() {
    try {
      this.topTraffic = await getAbuseBlockingTopTrafficSources(
        3600, this.topFilter, 20, this.includeInternal,
      );
      // Drop expansion state — the ranked IP list may have changed.
      this.expandedUris = new Set();
    } catch (err) {
      console.error('[abuse-blocking] top-traffic-sources refresh failed:', err);
    }
  }

  async _handleUnban(jail, ip) {
    if (!window.confirm(`Unban ${ip} from ${jail}?`)) return;
    this.pendingUnban = { ...this.pendingUnban, [ip]: true };
    try {
      const res = await postAbuseBlockingUnban(jail, ip);
      if (!res.ok) throw new Error(res.message || 'unban failed');
      await this._refreshFast();
    } catch (err) {
      console.error('[abuse-blocking] unban failed:', err);
      this.error = err.message || `unban ${ip} failed`;
    } finally {
      const next = { ...this.pendingUnban };
      delete next[ip];
      this.pendingUnban = next;
    }
  }

  _handleFilterChange(e) {
    this.topFilter = e.target.value;
    this._refreshTop();
  }

  _toggleUri(ip) {
    const next = new Set(this.expandedUris);
    next.has(ip) ? next.delete(ip) : next.add(ip);
    this.expandedUris = next;  // new Set ref so Lit re-renders
  }

  _handleIncludeInternalChange(e) {
    this.includeInternal = e.target.checked;
    this._refreshTop();
  }

  // CIDR editor: edits land in pendingConfig.network.abuseBlockCidrs.
  // Each entry is a record { cidr, enabled, comment }. Parent
  // handleConfigChange merges this into pendingConfig and the existing
  // Save/Apply UI takes care of writing + rebuild.
  //
  // Returns a normalised array of records. Tolerates an older
  // plain-string list shape (pre-migration config) by coercing each
  // string to an enabled record.
  _getCidrList() {
    const raw = this.pendingConfig?.network?.abuseBlockCidrs
             ?? this.serverConfig?.network?.abuseBlockCidrs;
    if (!Array.isArray(raw)) return [];
    return raw.map(e =>
      typeof e === 'string'
        ? { cidr: e, enabled: true, comment: '' }
        : { cidr: e.cidr, enabled: e.enabled !== false, comment: e.comment || '' }
    );
  }

  _emitCidrUpdate(newList) {
    // Build a minimal config patch — the parent merges into pendingConfig.
    const newConfig = {
      ...(this.pendingConfig || {}),
      network: {
        ...((this.pendingConfig && this.pendingConfig.network) || {}),
        abuseBlockCidrs: newList,
      },
    };
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { config: newConfig, module: 'abuse-blocking' },
      bubbles: true,
      composed: true,
    }));
  }

  _addCidr() {
    const raw = (this.newCidrInput || '').trim();
    if (!raw) {
      this.cidrError = 'enter a CIDR like 203.0.113.0/24 or 198.51.100.5/32';
      return;
    }
    if (!this._looksLikeCidr(raw)) {
      this.cidrError = `not a valid IPv4 CIDR: ${raw}`;
      return;
    }
    const list = this._getCidrList();
    if (list.some(e => e.cidr === raw)) {
      this.cidrError = `already in the list: ${raw}`;
      return;
    }
    this._emitCidrUpdate([
      ...list,
      { cidr: raw, enabled: true, comment: (this.newCidrComment || '').trim() },
    ]);
    this.newCidrInput = '';
    this.newCidrComment = '';
    this.cidrError = null;
  }

  _removeCidr(cidr) {
    this._emitCidrUpdate(this._getCidrList().filter(e => e.cidr !== cidr));
  }

  // Host CIDR for a single traffic-source IP: /32 for IPv4, /128 for
  // IPv6 (an IPv6 literal contains a colon).
  _hostCidr(ip) {
    return ip.includes(':') ? `${ip}/128` : `${ip}/32`;
  }

  // Add a traffic-source IP to the static block list as a host CIDR.
  // Reuses the same _emitCidrUpdate / config-change flow as the manual
  // "Add" in the CIDR editor — the Save/Apply bar then persists it.
  _blockIp(ip) {
    const cidr = this._hostCidr(ip);
    const list = this._getCidrList();
    if (list.some(e => e.cidr === cidr)) return;  // already blocked
    this._emitCidrUpdate([
      ...list,
      { cidr, enabled: true, comment: 'Blocked from traffic view' },
    ]);
  }

  // Block button for a traffic row. Disabled with a "Blocked" label
  // once the host CIDR is already in the static list, so the click
  // visibly takes effect.
  _renderBlockButton(ip) {
    const cidr = this._hostCidr(ip);
    const alreadyBlocked = this._getCidrList().some(e => e.cidr === cidr);
    return html`
      <button
        class="action-button"
        ?disabled=${alreadyBlocked}
        title=${alreadyBlocked
          ? `${cidr} is already in the static block list`
          : `Add ${cidr} to the static block list`}
        @click=${() => this._blockIp(ip)}
      >
        ${alreadyBlocked ? 'Blocked' : 'Block'}
      </button>
    `;
  }

  _toggleCidrEnabled(cidr, enabled) {
    this._emitCidrUpdate(this._getCidrList().map(e =>
      e.cidr === cidr ? { ...e, enabled } : e
    ));
  }

  _updateCidrComment(cidr, comment) {
    this._emitCidrUpdate(this._getCidrList().map(e =>
      e.cidr === cidr ? { ...e, comment } : e
    ));
  }

  // Lightweight CIDR-shape check. The Nix activation does the real
  // validation; this is just a UX-side filter so an obvious typo
  // doesn't get into homefree-config.json.
  _looksLikeCidr(s) {
    const m = s.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\/(\d{1,2})$/);
    if (!m) return false;
    for (let i = 1; i <= 4; i++) {
      const v = parseInt(m[i], 10);
      if (v < 0 || v > 255) return false;
    }
    const len = parseInt(m[5], 10);
    if (len < 0 || len > 32) return false;
    return true;
  }

  // ── Renderers ─────────────────────────────────────────────────────

  // Render `nRows` placeholder table rows of `nCols` skeleton cells.
  // Used while a section's data is still null on first load so the
  // page shell paints immediately instead of blocking on a spinner.
  _renderSkeletonRows(nCols, nRows) {
    const cols = Array.from({ length: nCols });
    const rows = Array.from({ length: nRows });
    return rows.map(() => html`
      <tr>
        ${cols.map(() => html`
          <td><span class="skeleton skeleton-cell"></span></td>
        `)}
      </tr>
    `);
  }

  render() {
    // The page shell renders immediately; each section shows skeleton
    // placeholders while its data field is still null (first load).
    // Background polls just swap data in — no skeleton flicker.
    return html`
      <div class="module-container">
        ${this.error ? html`<div class="error-box">${this.error}</div>` : ''}
        ${this._renderSummary()}
        ${this._renderJailStatus()}
        ${/* Blocking controls grouped together: runtime bans (dynamic,
             fail2ban-managed) directly above the static block list
             (declarative config). Traffic observability follows. */ ''}
        ${this._renderBannedTable()}
        ${this._renderCidrEditor()}
        ${this._renderTopTrafficSources()}
      </div>
    `;
  }

  _renderSummary() {
    // First load: status not yet fetched — show the four cards with
    // their static labels and skeleton values so the layout is final
    // before the data lands.
    if (this.status == null) {
      const labels = [
        'fail2ban', 'Currently banned', 'Static blocks', 'Packets dropped',
      ];
      return html`
        <div class="summary-cards">
          ${labels.map(label => html`
            <div class="card">
              <div class="card-label">${label}</div>
              <div class="card-value">
                <span class="skeleton skeleton-card-value"></span>
              </div>
              <div class="card-sub">
                <span class="skeleton skeleton-sub"></span>
              </div>
            </div>
          `)}
        </div>
      `;
    }
    const serverUp = this.status?.server_up;
    const dynBanCount = (this.banned?.entries || []).filter(
      e => e.source !== 'static'
    ).length;
    const staticBanCount = (this.banned?.entries || []).filter(
      e => e.source === 'static'
    ).length;
    const staticPkts = this.counters?.static?.packets ?? 0;
    const f2bPkts = (this.counters?.fail2ban_v4?.packets ?? 0)
                  + (this.counters?.fail2ban_v6?.packets ?? 0);
    return html`
      ${!serverUp ? html`
        <div class="down-banner">
          fail2ban is not running. Dynamic-ban data is unavailable;
          static blocks are still in effect via nftables.
          ${this.status?.error ? html`<div class="help-text">${this.status.error}</div>` : ''}
        </div>
      ` : ''}
      <div class="summary-cards">
        <div class="card">
          <div class="card-label">fail2ban</div>
          <div class="card-value ${serverUp ? 'ok' : 'err'}">
            ${serverUp ? 'Up' : 'Down'}
          </div>
          <div class="card-sub">
            ${this.status?.jails?.length ?? 0} jails configured
          </div>
        </div>
        <div class="card">
          <div class="card-label">Currently banned</div>
          <div class="card-value">${dynBanCount}</div>
          <div class="card-sub">dynamic (fail2ban)</div>
        </div>
        <div class="card">
          <div class="card-label">Static blocks</div>
          <div class="card-value">${staticBanCount}</div>
          <div class="card-sub">CIDR ranges in nftables set</div>
        </div>
        <div class="card">
          <div class="card-label">Packets dropped</div>
          <div class="card-value">${_fmtNum(staticPkts + f2bPkts)}</div>
          <div class="card-sub">
            since boot — static ${_fmtNum(staticPkts)}, fail2ban ${_fmtNum(f2bPkts)}
          </div>
        </div>
      </div>
    `;
  }

  _renderJailStatus() {
    // First load: show the table with skeleton rows. Once status has
    // loaded, an empty jail list collapses the section as before.
    const loading = this.status == null;
    const jails = this.status?.jails || [];
    if (!loading && !jails.length) return '';
    return html`
      <h2>Jails</h2>
      <div class="panel">
        <div class="table-scroll">
        <table>
          <thead>
            <tr>
              <th>Jail</th>
              <th>Currently failed</th>
              <th>Currently banned</th>
              <th>Total banned</th>
              <th>Total failed</th>
            </tr>
          </thead>
          <tbody>
            ${loading ? this._renderSkeletonRows(5, 3) : jails.map(j => html`
              <tr>
                <td class="mono">${j.name}</td>
                <td>${j.available === false ? '—' : j.currently_failed}</td>
                <td>${j.available === false ? '—' : j.currently_banned}</td>
                <td>${j.available === false ? '—' : j.total_banned}</td>
                <td>${j.available === false ? '—' : j.total_failed}</td>
              </tr>
            `)}
          </tbody>
        </table>
        </div>
      </div>
    `;
  }

  _renderBannedTable() {
    const loading = this.banned == null;
    const entries = this.banned?.entries || [];
    return html`
      <h2>Currently banned</h2>
      <div class="panel">
        ${loading ? html`
          <div class="table-scroll">
          <table>
            <thead>
              <tr>
                <th>Address</th>
                <th>Source</th>
                <th>Jail</th>
                <th>Remaining</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              ${this._renderSkeletonRows(5, 3)}
            </tbody>
          </table>
          </div>
        ` : entries.length === 0 ? html`
          <div class="row-empty">No active bans.</div>
        ` : html`
          <div class="table-scroll">
          <table>
            <thead>
              <tr>
                <th>Address</th>
                <th>Source</th>
                <th>Jail</th>
                <th>Remaining</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              ${entries.map(e => this._renderBannedRow(e))}
            </tbody>
          </table>
          </div>
        `}
      </div>
    `;
  }

  _renderBannedRow(entry) {
    const isStatic = entry.source === 'static';
    const sourcePill = isStatic
      ? html`<span class="pill static">static</span>`
      : html`<span class="pill fail2ban">${entry.source.replace('fail2ban_', 'fail2ban ')}</span>`;
    const jail = entry.jail
      ? html`<span class="pill jail">${entry.jail}</span>`
      : html`<span style="color: var(--hf-text-muted)">—</span>`;
    const remaining = entry.remaining_seconds == null
      ? (isStatic ? html`<span style="color: var(--hf-text-muted)">permanent</span>` : '—')
      : _fmtDuration(entry.remaining_seconds);
    const pending = !!this.pendingUnban[entry.address];
    return html`
      <tr>
        <td class="mono">${entry.address}</td>
        <td>${sourcePill}</td>
        <td>${jail}</td>
        <td>${remaining}</td>
        <td>
          ${isStatic ? html`
            <span style="color: var(--hf-text-muted); font-size: 12px;">
              edit list below
            </span>
          ` : html`
            <button
              class="action-button"
              ?disabled=${pending || !entry.jail}
              title=${!entry.jail ? 'jail attribution missing; cannot target unban' : ''}
              @click=${() => this._handleUnban(entry.jail, entry.address)}
            >
              ${pending ? 'Unbanning…' : 'Unban'}
            </button>
          `}
        </td>
      </tr>
    `;
  }

  // World map of traffic sources. Aggregates sources that share a
  // geo location into one circle; circle radius is logarithmic in the
  // aggregated hit count, clamped to [MIN, MAX] px so a single huge
  // talker doesn't swallow the map and tiny ones stay visible.
  _renderTrafficMap(sources) {
    const { width: W, height: H } = WORLD_VIEWBOX;

    // Equirectangular projection — must match world-map-path.js.
    const projectLatLon = (lat, lon) => ({
      x: ((lon + 180) / 360) * W,
      y: ((90 - lat) / 180) * H,
    });

    // Bucket sources by rounded lat/lon (~0.1° ≈ 11 km) so many IPs
    // in one city collapse to a single dot. Each bucket keeps the
    // list of its underlying sources so the hover card can show a
    // per-IP breakdown.
    const buckets = new Map();
    for (const s of sources) {
      if (typeof s.lat !== 'number' || typeof s.lon !== 'number') continue;
      const key = `${s.lat.toFixed(1)},${s.lon.toFixed(1)}`;
      const b = buckets.get(key);
      if (b) {
        b.count += s.count;
        b.sources.push(s);
      } else {
        buckets.set(key, {
          key,
          lat: s.lat, lon: s.lon, count: s.count,
          label: _fmtLocation(s),
          sources: [s],
        });
      }
    }
    const points = [...buckets.values()];

    if (points.length === 0) {
      return html`
        <div class="map-wrap">
          <div class="map-empty">
            No traffic in this view has a known geographic location.
          </div>
        </div>
      `;
    }

    // Logarithmic radius. log(count+1) keeps count=1 non-zero;
    // normalise against the busiest bucket so the scale adapts to
    // whatever's currently on screen, then clamp.
    const R_MIN = 2.5;
    const R_MAX = 26;
    const maxLog = Math.max(...points.map(p => Math.log(p.count + 1)), 1);
    const radiusFor = (count) => {
      const r = R_MIN + (Math.log(count + 1) / maxLog) * (R_MAX - R_MIN);
      return Math.max(R_MIN, Math.min(R_MAX, r));
    };

    // Draw largest circles first so small ones layer on top and stay
    // clickable / hoverable.
    const ordered = [...points].sort((a, b) => b.count - a.count);

    return html`
      <div class="map-wrap"
           @mousemove=${this._onMapMouseMove}
           @mouseleave=${() => { this.mapTooltip = null; }}>
        <svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="xMidYMid meet"
             role="img" aria-label="World map of traffic source locations">
          <path class="map-land" d=${WORLD_LAND_PATH}></path>
          ${ordered.map(p => {
            const { x, y } = projectLatLon(p.lat, p.lon);
            const r = radiusFor(p.count);
            // tabindex so the card is reachable by keyboard too.
            return svg`
              <circle class="map-dot" cx=${x} cy=${y} r=${r}
                      tabindex="0" role="button"
                      aria-label=${`${p.label || 'Unknown'}, ${_fmtNum(p.count)} hits`}
                      @mouseenter=${(e) => this._showMapTooltip(p, e)}
                      @focus=${(e) => this._showMapTooltip(p, e)}
                      @blur=${() => { this.mapTooltip = null; }}></circle>
            `;
          })}
        </svg>
        ${this._renderMapTooltip()}
      </div>
    `;
  }

  // Position the hover card. We track the cursor over the whole map
  // so the card follows the mouse; on keyboard focus we anchor it to
  // the focused circle's centre instead.
  _showMapTooltip(bucket, ev) {
    const wrap = this.renderRoot.querySelector('.map-wrap');
    if (!wrap) return;
    const rect = wrap.getBoundingClientRect();
    let x, y;
    if (ev && ev.type === 'focus') {
      const c = ev.target.getBoundingClientRect();
      x = c.left + c.width / 2 - rect.left;
      y = c.top - rect.top;
    } else if (ev && typeof ev.clientX === 'number') {
      x = ev.clientX - rect.left;
      y = ev.clientY - rect.top;
    } else {
      x = rect.width / 2;
      y = rect.height / 2;
    }
    this.mapTooltip = { bucket, x, y };
  }

  _onMapMouseMove(ev) {
    // Keep the card glued to the cursor while hovering, but only if a
    // circle is currently the hover target (mouseenter set the bucket).
    if (!this.mapTooltip) return;
    const wrap = this.renderRoot.querySelector('.map-wrap');
    if (!wrap) return;
    const rect = wrap.getBoundingClientRect();
    this.mapTooltip = {
      bucket: this.mapTooltip.bucket,
      x: ev.clientX - rect.left,
      y: ev.clientY - rect.top,
    };
  }

  _renderMapTooltip() {
    const t = this.mapTooltip;
    if (!t) return '';
    const b = t.bucket;
    // Show the heaviest IPs first; cap the list so a huge bucket
    // doesn't produce a giant card.
    const MAX_ROWS = 8;
    const rows = [...b.sources].sort((a, c) => c.count - a.count);
    const shown = rows.slice(0, MAX_ROWS);
    const extra = rows.length - shown.length;
    return html`
      <div class="map-tooltip" style="left: ${t.x}px; top: ${t.y}px;">
        <div class="tt-title">${b.label || 'Unknown location'}</div>
        <div class="tt-sub">
          ${_fmtNum(b.count)} hits from ${rows.length} IP${rows.length === 1 ? '' : 's'}
        </div>
        <table>
          <thead>
            <tr><th>IP</th><th>Domain</th><th>Hits</th></tr>
          </thead>
          <tbody>
            ${shown.map(s => html`
              <tr>
                <td class="tt-ip">${s.ip}</td>
                <td>${s.rdns || '—'}</td>
                <td>${_fmtNum(s.count)}</td>
              </tr>
            `)}
          </tbody>
        </table>
        ${extra > 0 ? html`
          <div class="tt-more">+ ${extra} more IP${extra === 1 ? '' : 's'}…</div>
        ` : ''}
      </div>
    `;
  }

  _renderTopTrafficSources() {
    const data = this.topTraffic;
    const sources = data?.sources || [];
    const suppressed = data?.internal_suppressed ?? 0;
    // Show the Location column (and the legally-required DB-IP
    // attribution) only when geo data is actually available — i.e.
    // GeoIP is enabled AND the database has been downloaded. When
    // off, the column is dropped entirely rather than shown full of
    // dashes.
    const showGeo = data?.geo_available === true;
    return html`
      <h2>Top traffic sources (last hour)</h2>
      <div class="panel">
        <div class="filter-bar">
          <label for="filter">Filter:</label>
          <select id="filter" .value=${this.topFilter} @change=${this._handleFilterChange}>
            <option value="all">All requests</option>
            <option value="oauth">OAuth-start hits (/user/oauth2/*)</option>
            <option value="4xx">4xx responses</option>
            <option value="5xx">5xx responses</option>
          </select>

          <label style="display: flex; align-items: center; gap: 6px; font-size: 13px; color: var(--hf-text-muted); cursor: pointer; margin-left: 12px;">
            <input
              type="checkbox"
              .checked=${this.includeInternal}
              @change=${this._handleIncludeInternalChange}
            />
            Include LAN / internal networks
          </label>

          ${data ? html`
            <span style="color: var(--hf-text-muted); font-size: 12px; margin-left: auto;">
              ${_fmtNum(data.total_requests)} requests matched${suppressed > 0 && !this.includeInternal ? html` · ${_fmtNum(suppressed)} internal hidden` : ''}
            </span>
          ` : ''}
        </div>
        ${showGeo && sources.length > 0 ? this._renderTrafficMap(sources) : ''}
        ${data == null ? html`
          <div class="table-scroll">
          <table>
            <thead>
              <tr>
                <th class="nowrap">IP</th>
                <th class="nowrap">Domain</th>
                <th>Hits</th>
                <th>Sample URL</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              ${this._renderSkeletonRows(5, 6)}
            </tbody>
          </table>
          </div>
        ` : !this.includeInternal && suppressed > 0 && sources.length === 0 ? html`
          <div class="row-empty">
            No external traffic in the last hour — ${_fmtNum(suppressed)} requests
            from LAN / internal networks were suppressed. Toggle "Include LAN"
            above to see them.
          </div>
        ` : sources.length === 0 ? html`
          <div class="row-empty">No matching traffic in the last hour.</div>
        ` : html`
          <div class="table-scroll">
          <table>
            <thead>
              <tr>
                <th class="nowrap">IP</th>
                <th class="nowrap">Domain</th>
                ${showGeo ? html`<th class="nowrap">Location</th>` : ''}
                <th>Hits</th>
                <th>Sample URL</th>
                <th class="nowrap">Action</th>
              </tr>
            </thead>
            <tbody>
              ${sources.map(s => html`
                <tr>
                  <td class="mono nowrap">
                    ${s.ip}
                    ${s.internal ? html`<span class="pill jail" style="margin-left: 6px;">LAN</span>` : ''}
                  </td>
                  <td class="mono nowrap" style="font-size: 12px;">
                    ${s.rdns
                      ? html`<span title=${s.rdns}>${s.rdns}</span>`
                      : html`<span style="color: var(--hf-text-muted)">—</span>`}
                  </td>
                  ${showGeo ? html`
                    <td class="nowrap" style="font-size: 12px; ${(s.city || s.country) ? '' : 'color: var(--hf-text-muted)'}">
                      ${_fmtLocation(s)}
                    </td>
                  ` : ''}
                  <td>${_fmtNum(s.count)}</td>
                  ${(() => {
                    const uri = s.sample_uri || '';
                    if (!uri) {
                      return html`<td class="mono uri" style="color: var(--hf-text-muted); font-size: 12px; cursor: default;">—</td>`;
                    }
                    const expanded = this.expandedUris.has(s.ip);
                    return html`
                      <td class="mono uri ${expanded ? 'uri-expanded' : ''}"
                          style="color: var(--hf-text-muted); font-size: 12px;"
                          title=${expanded ? '' : uri}
                          @click=${() => this._toggleUri(s.ip)}>
                        <span class="uri-text">${uri}</span>
                        <span class="uri-caret">${expanded ? '▾' : '▸'}</span>
                      </td>`;
                  })()}
                  <td class="nowrap">${this._renderBlockButton(s.ip)}</td>
                </tr>
              `)}
            </tbody>
          </table>
          </div>
        `}
        ${showGeo ? html`
          <div class="help-text" style="margin-top: 10px; margin-bottom: 0;">
            <a href="https://db-ip.com" target="_blank" rel="noopener">IP Geolocation by DB-IP</a>
          </div>
        ` : ''}
      </div>
    `;
  }

  _renderCidrEditor() {
    const list = this._getCidrList();
    const activeCount = list.filter(e => e.enabled).length;
    return html`
      <h2>Static block list</h2>
      <div class="panel">
        <div class="help-text">
          IPv4 CIDR ranges dropped at the firewall. On a fresh install
          this is seeded with known abusive scraper networks (Alibaba
          Cloud); after that it is yours to manage. Disable an entry to
          keep it for reference without enforcing it, or remove it
          entirely. Changes are saved with the rest of your config and
          take effect after the next rebuild.
          ${list.length > 0 ? html`
            <div style="margin-top: 4px;">
              ${activeCount} of ${list.length} range${list.length === 1 ? '' : 's'} active.
            </div>
          ` : ''}
        </div>

        <div class="cidr-input-row">
          <input
            type="text"
            placeholder="CIDR — e.g. 203.0.113.0/24 or 198.51.100.42/32"
            .value=${this.newCidrInput}
            @input=${e => { this.newCidrInput = e.target.value; this.cidrError = null; }}
            @keydown=${e => { if (e.key === 'Enter') this._addCidr(); }}
          />
          <input
            type="text"
            placeholder="Comment (optional) — why is this blocked?"
            .value=${this.newCidrComment}
            @input=${e => { this.newCidrComment = e.target.value; }}
            @keydown=${e => { if (e.key === 'Enter') this._addCidr(); }}
          />
          <button class="action-button" @click=${() => this._addCidr()}>Add</button>
        </div>
        ${this.cidrError ? html`<div class="cidr-error">${this.cidrError}</div>` : ''}

        ${list.length === 0 ? html`
          <div class="row-empty">No blocked ranges configured.</div>
        ` : html`
          <div class="table-scroll">
          <table>
            <thead>
              <tr>
                <th class="nowrap">Enabled</th>
                <th class="nowrap">CIDR</th>
                <th>Comment</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              ${list.map(e => html`
                <tr style=${e.enabled ? '' : 'opacity: 0.55;'}>
                  <td class="nowrap">
                    <input
                      type="checkbox"
                      .checked=${e.enabled}
                      title=${e.enabled ? 'Enforced — uncheck to disable' : 'Disabled — check to enforce'}
                      @change=${ev => this._toggleCidrEnabled(e.cidr, ev.target.checked)}
                    />
                  </td>
                  <td class="mono nowrap">${e.cidr}</td>
                  <td>
                    <input
                      class="cidr-comment-input"
                      type="text"
                      placeholder="(no comment)"
                      .value=${e.comment}
                      @change=${ev => this._updateCidrComment(e.cidr, ev.target.value)}
                    />
                  </td>
                  <td class="nowrap">
                    <button class="action-button" @click=${() => this._removeCidr(e.cidr)}>
                      Remove
                    </button>
                  </td>
                </tr>
              `)}
            </tbody>
          </table>
          </div>
        `}
      </div>
    `;
  }
}

// ── Small formatting helpers ────────────────────────────────────────

function _fmtNum(n) {
  if (n == null) return '—';
  if (n < 1000) return String(n);
  if (n < 1_000_000) return (n / 1000).toFixed(1) + 'k';
  return (n / 1_000_000).toFixed(2) + 'M';
}

// Render a source's geo as "City, Country" — gracefully collapsing
// when the DB only resolved one or neither field.
function _fmtLocation(s) {
  const city = s.city;
  const country = s.country;
  if (city && country) return `${city}, ${country}`;
  if (country) return country;
  if (city) return city;
  return '—';
}

function _fmtDuration(seconds) {
  if (seconds == null) return '—';
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
  return `${Math.floor(seconds / 86400)}d ${Math.floor((seconds % 86400) / 3600)}h`;
}

customElements.define('abuse-blocking-module', AbuseBlockingModule);
