import { LitElement, html, css, svg } from 'lit';
import {
  getDashboardOverview,
  getDashboardHistory,
} from '../../../api/client.js';

/**
 * Dashboard module — the admin landing page.
 *
 * At-a-glance health for the box: connectivity, public IPs, gateway,
 * per-interface throughput, CPU / memory / disk utilisation, and the
 * LAN client count. Time-series charts are backed by the standalone
 * homefree-dashboard-sampler service, which writes a SQLite history DB
 * read by the admin-api. That sampler runs independently of admin-api,
 * so the ~24h of history survives admin-api restarts and blue/green
 * flips — the charts are populated immediately after a rebuild.
 *
 * Owns its own polling: overview every 5s, history every 15s (the
 * sampler only produces a new point every 10s, so 15s is plenty).
 * Polling stops on disconnect.
 */
class DashboardModule extends LitElement {
  static properties = {
    overview: { type: Object, state: true },
    history: { type: Object, state: true },
    loading: { type: Boolean, state: true },
    error: { type: String, state: true },
  };

  static styles = css`
    :host { display: block; }
    /* Width cap + centering is applied once, app-wide, on
       admin-app.js's .content-area > * — no per-module max-width. */
    .module-container { width: 100%; }

    h2 {
      font-size: 18px;
      font-weight: 600;
      color: var(--hf-text);
      margin: 28px 0 12px;
    }
    h2:first-child { margin-top: 0; }

    /* Summary cards auto-fill: column count grows on wide screens and
       collapses to one on a phone — no fixed count, no breakpoint. */
    .cards {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(var(--hf-card-min-sm), 1fr));
      gap: 12px;
      margin-bottom: 16px;
    }
    /* The three summary cards line up 3-up directly above the History
       charts — identical column count, gap and 900px fold — so
       Connectivity / CPU / Memory each sit exactly above their chart.
       Each card is then ⅓ of the container, wide enough that the
       subtitles no longer wrap, so the row height never changes. */
    .summary-cards {
      grid-template-columns: repeat(3, 1fr);
      gap: 16px;
    }
    @media (max-width: 900px) {
      .summary-cards { grid-template-columns: 1fr; }
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
    .card-value.ok   { color: var(--hf-ok); }
    .card-value.err  { color: var(--hf-err); }
    .card-value.warn { color: var(--hf-warn); }
    .card-sub {
      font-size: 12px;
      color: var(--hf-text-muted);
      margin-top: 4px;
      word-break: break-all;
    }

    .panel {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border);
      border-radius: 10px;
      padding: 14px 16px;
      margin-bottom: 16px;
      overflow-x: auto;
    }
    .panel-title {
      font-size: 13px;
      font-weight: 600;
      color: var(--hf-text);
      margin-bottom: 10px;
      display: flex;
      justify-content: space-between;
      align-items: baseline;
      gap: 12px;
    }
    .panel-title .hint {
      font-size: 11px;
      font-weight: 400;
      color: var(--hf-text-muted);
    }

    .charts {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
      gap: 16px;
    }

    /* History charts — fixed 3-up so they line up under the summary
       cards above. Collapses to 1-up on narrow viewports. */
    .chart-grid {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      gap: 16px;
    }
    @media (max-width: 900px) {
      .chart-grid { grid-template-columns: 1fr; }
    }

    table { width: 100%; border-collapse: collapse; font-size: 13px; }
    th, td {
      text-align: left;
      padding: 8px 12px;
      border-bottom: 1px solid var(--hf-border);
    }
    th {
      font-size: 11px;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      color: var(--hf-text-muted);
      font-weight: 600;
    }
    tr:last-child td { border-bottom: none; }
    /* Numeric columns are right-aligned — the header cell must match
       the value cells below it, so .num applies to th as well as td. */
    th.num, td.num { text-align: right; }
    td.num { font-variant-numeric: tabular-nums; }

    /* Usage meter — disk / memory bars */
    .meter {
      height: 8px;
      border-radius: 4px;
      background: var(--hf-border);
      overflow: hidden;
      margin-top: 6px;
    }
    .meter-fill {
      height: 100%;
      background: var(--hf-accent);
      transition: width 0.4s ease;
    }
    .meter-fill.warn { background: var(--hf-warn); }
    .meter-fill.err  { background: var(--hf-err); }

    .dot {
      display: inline-block;
      width: 8px;
      height: 8px;
      border-radius: 50%;
      margin-right: 6px;
      vertical-align: middle;
    }
    .dot.up   { background: var(--hf-ok); }
    .dot.down { background: var(--hf-err); }
    /* Neutral state — not running, but not a fault (e.g. a mount the
       admin has intentionally disabled). Muted gray so the row doesn't
       read as an error. */
    .dot.idle { background: var(--hf-text-muted); }

    .chart-svg { width: 100%; height: auto; display: block; }
    .axis-label {
      fill: var(--hf-text-muted);
      font-size: 10px;
      font-family: inherit;
    }
    /* Placeholder occupies the *same* box the chart will, so swapping
       placeholder → SVG causes no reflow. The line/area charts use a
       600×150 viewBox (rendered height = width ÷ 4); the connectivity
       strip is shorter (600×50). aspect-ratio reserves that height
       responsively at every width. */
    .chart-empty {
      font-size: 12px;
      color: var(--hf-text-muted);
      text-align: center;
      width: 100%;
      aspect-ratio: 600 / 150;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .chart-empty.strip { aspect-ratio: 600 / 50; }
    .legend {
      display: flex;
      gap: 16px;
      font-size: 11px;
      color: var(--hf-text-muted);
      margin-top: 6px;
    }
    .legend span::before {
      content: '';
      display: inline-block;
      width: 10px;
      height: 3px;
      border-radius: 2px;
      margin-right: 5px;
      vertical-align: middle;
    }
    .legend .rx::before { background: var(--hf-accent); }
    .legend .tx::before { background: var(--hf-warn); }
    /* Square swatches for the binary up/down strip legend. */
    .legend .up::before,
    .legend .down::before { width: 10px; height: 10px; border-radius: 2px; }
    .legend .up::before   { background: var(--hf-ok); }
    .legend .down::before { background: var(--hf-err); }

    .uptime-svg {
      width: 100%;
      height: auto;
      display: block;
    }
    /* The uptime strip is far shorter than the line charts it shares a
       grid row with, so its panel gets stretched tall to match. Make
       this panel a flex column and let the strip wrapper grow + center
       so the strip sits in the middle of the box, not pinned to top. */
    .panel-uptime {
      display: flex;
      flex-direction: column;
    }
    .uptime-wrap {
      flex: 1;
      display: flex;
      align-items: center;
    }

    .error-message {
      background: color-mix(in srgb, var(--hf-err) 12%, transparent);
      border: 1px solid var(--hf-err);
      color: var(--hf-err);
      border-radius: 8px;
      padding: 10px 14px;
      font-size: 13px;
      margin-bottom: 16px;
    }

    /* Skeleton placeholders shown on first load while overview data is
       still null. Same shimmer the Network Traffic / Hardware pages use
       so all admin skeletons look identical. */
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
    .skeleton-title       { width: 180px; height: 15px; }
    .skeleton-sub         { width: 110px; height: 11px; margin-top: 6px; }
    .skeleton-cell        { width: 60px;  height: 13px; }
    .skeleton-card-value  { width: 48px;  height: 26px; }
    .skeleton-meter       { width: 100%;  height: 8px;  border-radius: 4px; }
    /* In-card bars must leave the card the exact height it will be once
       filled, or the card shrinks on load. Keep each bar a fraction of
       its line's font-size so it sits *within* the real text line-box
       (never inflating it), and drop the sub bar's standalone top margin
       since .card-sub already spaces it (else it double-counts). */
    .card-value .skeleton-card-value { height: 0.8em; }
    .card-sub   .skeleton-sub        { height: 0.8em; margin-top: 0; }
    @keyframes shimmer {
      from { background-position: 100% 0; }
      to   { background-position: 0 0; }
    }
  `;

  constructor() {
    super();
    this.overview = null;
    this.history = null;
    this.loading = true;
    this.error = '';
    this._overviewPoll = null;
    this._historyPoll = null;
  }

  connectedCallback() {
    super.connectedCallback();
    this._refreshOverview();
    this._refreshHistory();
    this._overviewPoll = setInterval(() => this._refreshOverview(), 5000);
    this._historyPoll = setInterval(() => this._refreshHistory(), 15000);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this._overviewPoll) { clearInterval(this._overviewPoll); this._overviewPoll = null; }
    if (this._historyPoll) { clearInterval(this._historyPoll); this._historyPoll = null; }
  }

  async _refreshOverview() {
    try {
      this.overview = await getDashboardOverview();
      this.error = '';
    } catch (e) {
      // Keep the last good snapshot on screen; only surface the error
      // if we never managed a first load.
      if (!this.overview) this.error = e.message || 'Failed to load dashboard';
    } finally {
      this.loading = false;
    }
  }

  async _refreshHistory() {
    try {
      this.history = await getDashboardHistory();
    } catch (e) {
      /* charts just keep the last data; non-fatal */
    }
  }

  // --- formatting helpers ------------------------------------------------

  _fmtBytes(n) {
    if (n == null) return '—';
    const u = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    let i = 0;
    let v = n;
    while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
    return `${v.toFixed(v >= 100 || i === 0 ? 0 : 1)} ${u[i]}`;
  }

  _fmtBits(bps) {
    if (bps == null) return '—';
    const u = ['bps', 'Kbps', 'Mbps', 'Gbps'];
    let i = 0;
    let v = bps;
    while (v >= 1000 && i < u.length - 1) { v /= 1000; i++; }
    return `${v.toFixed(v >= 100 || i === 0 ? 0 : 1)} ${u[i]}`;
  }

  _fmtUptime(sec) {
    if (sec == null) return '—';
    const d = Math.floor(sec / 86400);
    const h = Math.floor((sec % 86400) / 3600);
    const m = Math.floor((sec % 3600) / 60);
    if (d > 0) return `${d}d ${h}h`;
    if (h > 0) return `${h}h ${m}m`;
    return `${m}m`;
  }

  _meterClass(pct) {
    if (pct >= 90) return 'err';
    if (pct >= 75) return 'warn';
    return '';
  }

  // Skeleton table rows for first-load placeholders. nCols = number of
  // cells per row; nRows = how many placeholder rows to show.
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

  // --- SVG line/area chart ----------------------------------------------

  /**
   * Pick a small set of wall-clock-hour ticks inside the chart's time
   * span. Step size shrinks as the span shrinks so a 24h chart gets
   * 4-hour ticks while a 2h chart gets 30-minute ticks. Endpoints are
   * filtered out so ticks don't collide with the 'last Xh' / 'now'
   * labels the chart already renders at each edge.
   */
  _pickTimeTicks(nowTs, spanSec) {
    if (spanSec < 60) return [];
    const HOUR = 3600, MIN = 60;
    const step =
      spanSec >= 18 * HOUR ? 4 * HOUR :
      spanSec >=  9 * HOUR ? 2 * HOUR :
      spanSec >=  4 * HOUR ?     HOUR :
      spanSec >=  2 * HOUR ? 30 * MIN :
      spanSec >=      HOUR ? 15 * MIN :
      spanSec >= 30 * MIN  ?  5 * MIN :
                              MIN;
    // Snap to a step boundary in local wall-clock time so ticks land on
    // round hours rather than '17 minutes ago'. Date.setHours respects
    // DST automatically.
    const d = new Date(nowTs * 1000);
    d.setSeconds(0, 0);
    if (step >= HOUR) {
      d.setMinutes(0);
      d.setHours(Math.floor(d.getHours() / (step / HOUR)) * (step / HOUR));
    } else {
      d.setMinutes(Math.floor(d.getMinutes() / (step / MIN)) * (step / MIN));
    }
    const leftTs = nowTs - spanSec;
    const minMarginFrac = 0.06;
    const ticks = [];
    let t = Math.floor(d.getTime() / 1000);
    while (t > leftTs) {
      const frac = (t - leftTs) / spanSec;
      if (frac > minMarginFrac && frac < 1 - minMarginFrac) {
        ticks.push({ ts: t, label: this._fmtHourLabel(t, step) });
      }
      t -= step;
    }
    return ticks;
  }

  _fmtHourLabel(ts, step) {
    const d = new Date(ts * 1000);
    const hh = String(d.getHours()).padStart(2, '0');
    if (step >= 3600) return `${hh}:00`;
    const mm = String(d.getMinutes()).padStart(2, '0');
    return `${hh}:${mm}`;
  }

  /**
   * Render a multi-series line/area chart with labelled axes.
   *
   * series:  [{ values: number[], color: string, fill?: boolean }]
   *          all series share the sample timeline (x = sample index).
   * opts.yMax:    fixed number, or 'auto' to scale to the data.
   * opts.formatY: fn(value) -> string for the Y-axis tick labels.
   * opts.spanSec: total time the samples cover, for the X-axis label.
   *
   * Uses a fixed pixel coordinate space (no preserveAspectRatio="none")
   * so axis text isn't stretched. The SVG scales as a whole via CSS.
   */
  _renderChart(series, { yMax = 'auto', formatY = (v) => String(v), spanSec = 0 } = {}) {
    const W = 600;
    const H = 150;
    const ML = 56;   // left margin — room for Y tick labels
    const MR = 8;
    const MT = 8;
    const MB = 22;   // bottom margin — room for the X label
    const plotW = W - ML - MR;
    const plotH = H - MT - MB;

    const valid = series.filter(s => s.values && s.values.length > 1);
    if (valid.length === 0) {
      return html`<div class="chart-empty">Collecting data…</div>`;
    }
    const n = Math.max(...valid.map(s => s.values.length));
    let max = yMax === 'auto'
      ? Math.max(1, ...valid.flatMap(s => s.values))
      : yMax;
    // Headroom so the peak doesn't touch the top edge.
    if (yMax === 'auto') max *= 1.15;

    const x = (i) => ML + (i / (n - 1)) * plotW;
    const y = (v) => MT + plotH - (Math.min(Math.max(v, 0), max) / max) * plotH;

    // Four horizontal gridlines + Y tick labels.
    const ticks = [0, 0.25, 0.5, 0.75, 1].map(f => f * max);

    const spanLabel = spanSec >= 3600
      ? `last ${(spanSec / 3600).toFixed(1)} h`
      : spanSec >= 60
        ? `last ${Math.round(spanSec / 60)} min`
        : 'live';

    const nowTs = Math.floor(Date.now() / 1000);
    const timeTicks = this._pickTimeTicks(nowTs, spanSec);
    const xForTs = (ts) =>
      ML + plotW * (1 - (nowTs - ts) / Math.max(spanSec, 1));

    return html`
      <svg class="chart-svg" viewBox="0 0 ${W} ${H}">
        ${ticks.map(t => svg`
          <line x1="${ML}" y1="${y(t)}" x2="${W - MR}" y2="${y(t)}"
                stroke="var(--hf-border)" stroke-width="1" />
          <text x="${ML - 6}" y="${y(t) + 3}" text-anchor="end"
                class="axis-label">${formatY(t)}</text>
        `)}
        ${valid.map(s => {
          const pts = s.values.map((v, i) => `${x(i)},${y(v)}`).join(' ');
          if (s.fill) {
            const area =
              `${x(0)},${MT + plotH} ${pts} ${x(s.values.length - 1)},${MT + plotH}`;
            return svg`
              <polygon points="${area}" fill="${s.color}" fill-opacity="0.15" />
              <polyline points="${pts}" fill="none" stroke="${s.color}"
                        stroke-width="1.5" stroke-linejoin="round" />
            `;
          }
          return svg`
            <polyline points="${pts}" fill="none" stroke="${s.color}"
                      stroke-width="1.5" stroke-linejoin="round" />
          `;
        })}
        ${timeTicks.map(tt => svg`
          <line x1="${xForTs(tt.ts)}" y1="${MT + plotH}"
                x2="${xForTs(tt.ts)}" y2="${MT + plotH + 3}"
                stroke="var(--hf-border)" stroke-width="1" />
          <text x="${xForTs(tt.ts)}" y="${H - 6}" text-anchor="middle"
                class="axis-label">${tt.label}</text>
        `)}
        <text x="${ML}" y="${H - 6}" text-anchor="start"
              class="axis-label">${spanLabel} ←</text>
        <text x="${W - MR}" y="${H - 6}" text-anchor="end"
              class="axis-label">now</text>
      </svg>
    `;
  }

  // --- uptime status strip ----------------------------------------------

  /**
   * Render a binary state-over-time strip — the right idiom for an
   * up/down signal. One colored segment per sample: green = online,
   * red = offline. A flat green bar reads "solid" at a glance; any red
   * notch is a visible dropout. Far clearer than a 2-level line chart.
   *
   * samples: the raw history samples (each has .connected and .ts).
   */
  _renderUptimeBar(samples, spanSec) {
    if (samples.length < 2) {
      return html`<div class="chart-empty strip">Collecting data…</div>`;
    }
    const W = 600;
    const H = 34;
    const seg = W / samples.length;
    const spanLabel = spanSec >= 3600
      ? `last ${(spanSec / 3600).toFixed(1)} h`
      : spanSec >= 60
        ? `last ${Math.round(spanSec / 60)} min`
        : 'live';

    const nowTs = Math.floor(Date.now() / 1000);
    const timeTicks = this._pickTimeTicks(nowTs, spanSec);
    const xForTs = (ts) => W * (1 - (nowTs - ts) / Math.max(spanSec, 1));

    return html`
      <svg class="uptime-svg" viewBox="0 0 ${W} ${H + 16}">
        ${samples.map((s, i) => svg`
          <rect x="${i * seg}" y="0" width="${seg + 0.6}" height="${H}"
                fill="${s.connected ? 'var(--hf-ok)' : 'var(--hf-err)'}">
            <title>${new Date(s.ts * 1000).toLocaleTimeString()} — ${
              s.connected ? 'online' : 'offline'}${
              s.latency_ms != null ? ` (${s.latency_ms} ms)` : ''}</title>
          </rect>
        `)}
        ${timeTicks.map(tt => svg`
          <line x1="${xForTs(tt.ts)}" y1="${H}"
                x2="${xForTs(tt.ts)}" y2="${H + 3}"
                stroke="var(--hf-border)" stroke-width="1" />
          <text x="${xForTs(tt.ts)}" y="${H + 12}" text-anchor="middle"
                class="axis-label">${tt.label}</text>
        `)}
        <text x="0" y="${H + 12}" text-anchor="start"
              class="axis-label">${spanLabel} ←</text>
        <text x="${W}" y="${H + 12}" text-anchor="end"
              class="axis-label">now</text>
      </svg>
    `;
  }

  // --- render sections ---------------------------------------------------

  _renderSummaryCards() {
    if (this.overview == null) {
      const labels = ['Connectivity', 'CPU', 'Memory'];
      return html`
        <div class="cards summary-cards">
          ${labels.map(label => html`
            <div class="card">
              <div class="card-label">${label}</div>
              <div class="card-value"><span class="skeleton skeleton-card-value"></span></div>
              <div class="card-sub"><span class="skeleton skeleton-sub"></span></div>
            </div>
          `)}
        </div>
      `;
    }
    const o = this.overview;
    const conn = o.connectivity || {};
    const connected = conn.connected;
    const uptimeRatio = conn.uptime_ratio;
    const cpu = o.cpu || {};
    const mem = o.memory || {};

    return html`
      <div class="cards summary-cards">
        <div class="card">
          <div class="card-label">Connectivity</div>
          <div class="card-value ${connected === false ? 'err' : connected ? 'ok' : ''}">
            <span class="dot ${connected ? 'up' : 'down'}"></span>
            ${connected == null ? 'Unknown' : connected ? 'Online' : 'Offline'}
          </div>
          <div class="card-sub">
            ${conn.latency_ms != null ? `${conn.latency_ms} ms` : 'no latency data'}${
              uptimeRatio != null
                ? ` · ${(uptimeRatio * 100).toFixed(1)}% uptime (${conn.samples} samples)`
                : ''}
          </div>
        </div>

        <div class="card">
          <div class="card-label">CPU</div>
          <div class="card-value ${this._meterClass(cpu.percent || 0)}">
            ${(cpu.percent ?? 0).toFixed(0)}%
          </div>
          <div class="card-sub">
            ${cpu.count || '?'} cores · load ${
              (o.load_average || []).map(l => l.toFixed(2)).join(' ')}${
              o.hostname ? ` · ${o.hostname}` : ''} · up ${
              this._fmtUptime(o.uptime_seconds)}
          </div>
        </div>

        <div class="card">
          <div class="card-label">Memory</div>
          <div class="card-value ${this._meterClass(mem.percent || 0)}">
            ${(mem.percent ?? 0).toFixed(0)}%
          </div>
          <div class="card-sub">
            ${this._fmtBytes(mem.used)} / ${this._fmtBytes(mem.total)}${
              mem.swap_total ? ` · swap ${mem.swap_percent.toFixed(0)}%` : ''}
          </div>
        </div>
      </div>
    `;
  }

  _renderNetworkInfo() {
    if (this.overview == null) {
      const labels = [
        'WAN interface', 'Public IPv4', 'Public IPv6', 'Gateway (IPv4)',
        'Gateway (IPv6)', 'LAN interface', 'LAN IPv4', 'LAN IPv6',
      ];
      return html`
        <div class="panel">
          <div class="panel-title">Network</div>
          <table>
            <tbody>
              ${labels.map(label => html`
                <tr>
                  <th>${label}</th>
                  <td><span class="skeleton skeleton-cell"></span></td>
                </tr>
              `)}
            </tbody>
          </table>
        </div>
      `;
    }
    const o = this.overview;
    const addrs = o.addresses || {};
    const wan = addrs.wan;
    const lan = addrs.lan;
    const gw = o.gateway || {};

    return html`
      <div class="panel">
        <div class="panel-title">Network</div>
        <table>
          <tbody>
            <tr>
              <th>WAN interface</th>
              <td>${wan ? wan.interface : '—'}</td>
            </tr>
            <tr>
              <th>Public IPv4</th>
              <td>${wan && wan.ipv4.length ? wan.ipv4.join(', ') : '—'}</td>
            </tr>
            <tr>
              <th>Public IPv6</th>
              <td>${wan && wan.ipv6.length ? wan.ipv6.join(', ') : '—'}</td>
            </tr>
            <tr>
              <th>Gateway (IPv4)</th>
              <td>${gw.ipv4 ? `${gw.ipv4}${gw.ipv4_interface ? ` (${gw.ipv4_interface})` : ''}` : '—'}</td>
            </tr>
            <tr>
              <th>Gateway (IPv6)</th>
              <td>${gw.ipv6 ? `${gw.ipv6}${gw.ipv6_interface ? ` (${gw.ipv6_interface})` : ''}` : '—'}</td>
            </tr>
            <tr>
              <th>LAN interface</th>
              <td>${lan ? lan.interface : '—'}</td>
            </tr>
            <tr>
              <th>LAN IPv4</th>
              <td>${lan && lan.ipv4.length ? lan.ipv4.join(', ') : '—'}${
                lan && lan.subnet ? ` · subnet ${lan.subnet}` : ''}</td>
            </tr>
            <tr>
              <th>LAN IPv6</th>
              <td>${lan && lan.ipv6.length ? lan.ipv6.join(', ') : '—'}</td>
            </tr>
          </tbody>
        </table>
      </div>
    `;
  }

  _renderSystemCards() {
    if (this.overview == null) {
      return html`
        <div class="cards">
          <div class="card">
            <div class="card-label">LAN Clients</div>
            <div class="card-value"><span class="skeleton skeleton-card-value"></span></div>
            <div class="card-sub"><span class="skeleton skeleton-sub"></span></div>
          </div>
        </div>
      `;
    }
    const o = this.overview;
    return html`
      <div class="cards">
        <div class="card">
          <div class="card-label">LAN Clients</div>
          <div class="card-value">${o.clients_count ?? '—'}</div>
          <div class="card-sub">devices on the local network</div>
        </div>
      </div>
    `;
  }

  _renderInterfaceThroughput() {
    // Only the WAN and LAN interfaces matter here — other NICs (bridges,
    // veths, etc.) just clutter the view.
    const loading = this.overview == null;
    const ifaces = loading ? [] : (this.overview.interfaces || [])
      .filter(i => i.role === 'wan' || i.role === 'lan');
    if (!loading && ifaces.length === 0) return '';
    return html`
      <div class="panel">
        <div class="panel-title">
          Throughput
          <span class="hint">live</span>
        </div>
        <table>
          <thead>
            <tr>
              <th>Interface</th>
              <th>Link</th>
              <th class="num">↓ Down</th>
              <th class="num">↑ Up</th>
            </tr>
          </thead>
          <tbody>
            ${loading ? this._renderSkeletonRows(4, 2) : ifaces.map(i => html`
              <tr>
                <td>${i.role.toUpperCase()} (${i.name})</td>
                <td>
                  <span class="dot ${i.is_up ? 'up' : 'down'}"></span>
                  ${i.is_up ? 'up' : 'down'}${
                    i.speed_mbps ? ` · ${i.speed_mbps} Mbps` : ''}
                </td>
                <td class="num">${this._fmtBits(i.rx_bps)}</td>
                <td class="num">${this._fmtBits(i.tx_bps)}</td>
              </tr>
            `)}
          </tbody>
        </table>
      </div>
    `;
  }

  _renderDisks() {
    const loading = this.overview == null;
    const disks = loading ? [] : (this.overview.disks || []);
    if (!loading && disks.length === 0) return '';
    return html`
      <div class="panel">
        <div class="panel-title">Disk Usage</div>
        <table>
          <thead>
            <tr>
              <th>Mount</th>
              <th>Filesystem</th>
              <th class="num">Used</th>
              <th class="num">Total</th>
              <th style="width:30%">Usage</th>
            </tr>
          </thead>
          <tbody>
            ${loading ? Array.from({ length: 3 }).map(() => html`
              <tr>
                <td><span class="skeleton skeleton-cell"></span></td>
                <td><span class="skeleton skeleton-cell"></span></td>
                <td class="num"><span class="skeleton skeleton-cell"></span></td>
                <td class="num"><span class="skeleton skeleton-cell"></span></td>
                <td>
                  <span class="skeleton skeleton-meter"></span>
                  <div class="card-sub"><span class="skeleton skeleton-sub"></span></div>
                </td>
              </tr>
            `) : disks.map(d => html`
              <tr>
                <td>${d.mountpoint}</td>
                <td>${d.fstype}</td>
                <td class="num">${this._fmtBytes(d.used)}</td>
                <td class="num">${this._fmtBytes(d.total)}</td>
                <td>
                  <div class="meter">
                    <div class="meter-fill ${this._meterClass(d.percent)}"
                         style="width:${d.percent}%"></div>
                  </div>
                  <div class="card-sub">${d.percent.toFixed(0)}%</div>
                </td>
              </tr>
            `)}
          </tbody>
        </table>
      </div>
    `;
  }

  _renderNetworkMounts() {
    // Network mounts are an optional panel — empty on most boxes. Render
    // nothing (no skeleton) until overview loads, so a box without mounts
    // never flashes a skeleton that then collapses. With real mounts the
    // panel appears at the bottom, growing downward with no upward shift.
    if (this.overview == null) return '';
    const mounts = this.overview.network_mounts || [];
    if (mounts.length === 0) return '';
    return html`
      <div class="panel">
        <div class="panel-title">
          Network Mounts
          <span class="hint">NFS / CIFS shares</span>
        </div>
        <table>
          <thead>
            <tr>
              <th>Mount</th>
              <th>Source</th>
              <th>Status</th>
              <th class="num">Used</th>
              <th class="num">Total</th>
              <th style="width:24%">Usage</th>
            </tr>
          </thead>
          <tbody>
            ${mounts.map(m => html`
              <tr>
                <td>${m.mountpoint}</td>
                <td class="card-sub" style="margin:0">${m.device || '—'}</td>
                <td>
                  <span class="dot ${
                    m.enabled === false ? 'idle'
                    : m.mounted ? 'up'
                    : 'down'
                  }"></span>
                  ${m.status}${m.automount && !m.mounted && m.enabled !== false ? ' (automount)' : ''}
                </td>
                <td class="num">${m.used != null ? this._fmtBytes(m.used) : '—'}</td>
                <td class="num">${m.total != null ? this._fmtBytes(m.total) : '—'}</td>
                <td>
                  ${m.percent != null
                    ? html`
                        <div class="meter">
                          <div class="meter-fill ${this._meterClass(m.percent)}"
                               style="width:${m.percent}%"></div>
                        </div>
                        <div class="card-sub">${m.percent.toFixed(0)}%</div>
                      `
                    : html`<span class="card-sub" style="margin:0">—</span>`}
                </td>
              </tr>
            `)}
          </tbody>
        </table>
      </div>
    `;
  }

  _renderCharts() {
    const samples = (this.history && this.history.samples) || [];
    // How much wall-clock time the retained samples actually span —
    // drives the "last N min/h" label on each chart's X-axis.
    const spanSec = samples.length > 1
      ? samples[samples.length - 1].ts - samples[0].ts
      : 0;

    // Connectivity is binary state over time — rendered as a status
    // strip (_renderUptimeBar) rather than a line chart.
    const downCount = samples.filter(s => !s.connected).length;

    // Latency where we have it; gaps (offline) carry the last value
    // forward so the line stays continuous rather than spiking to 0.
    let lastLat = 0;
    const latValues = samples.map(s => {
      if (s.latency_ms != null) { lastLat = s.latency_ms; }
      return lastLat;
    });

    // Per-interface throughput series, keyed off the WAN/LAN interface
    // names from the overview so each chart shows one real interface.
    const loading = this.overview == null;
    const ifaces = (this.overview && this.overview.interfaces) || [];
    const wanName = (ifaces.find(i => i.role === 'wan') || {}).name;
    const lanName = (ifaces.find(i => i.role === 'lan') || {}).name;
    const rxFor = (name) => samples.map(s => ((s.rates || {})[name] || {}).rx_bps || 0);
    const txFor = (name) => samples.map(s => ((s.rates || {})[name] || {}).tx_bps || 0);

    const cpuValues = samples.map(s => s.cpu_percent || 0);
    const memValues = samples.map(s => s.memory_percent || 0);

    const accent = 'var(--hf-accent)';
    const warn = 'var(--hf-warn)';

    // Y-axis tick formatters give each chart its units.
    const fmtBits = (v) => this._fmtBits(v);
    const fmtPct = (v) => `${Math.round(v)}%`;
    const fmtMs = (v) => `${Math.round(v)} ms`;

    const throughputChart = (name, role) => html`
      <div class="panel">
        <div class="panel-title">
          ${role} Throughput
          <span class="hint">${name || 'no interface'}</span>
        </div>
        ${name
          ? this._renderChart(
              [
                { values: rxFor(name), color: accent, fill: true },
                { values: txFor(name), color: warn },
              ],
              { formatY: fmtBits, spanSec },
            )
          : html`<div class="chart-empty">${
              loading ? 'Collecting data…' : `No ${role} interface configured`}</div>`}
        <div class="legend">
          <span class="rx">Download</span>
          <span class="tx">Upload</span>
        </div>
      </div>
    `;

    // First chart row lines up under the summary cards: Connectivity,
    // CPU, Memory each sit directly below their card. (The LAN Clients
    // card has no time-series, so that column is left empty.) Latency
    // and the WAN/LAN throughput charts flow into the next 3-up row.
    return html`
      <h2>History</h2>
      <div class="chart-grid">
        <div class="panel panel-uptime">
          <div class="panel-title">
            Connectivity
            <span class="hint">${
              downCount === 0
                ? 'no dropouts — probes 1.1.1.1'
                : `${downCount} dropout${downCount === 1 ? '' : 's'} in window`}</span>
          </div>
          <div class="uptime-wrap">
            ${this._renderUptimeBar(samples, spanSec)}
          </div>
          <div class="legend">
            <span class="up">Online</span>
            <span class="down">Offline</span>
          </div>
        </div>

        <div class="panel">
          <div class="panel-title">
            CPU
            <span class="hint">utilisation</span>
          </div>
          ${this._renderChart(
            [{ values: cpuValues, color: accent, fill: true }],
            { yMax: 100, formatY: fmtPct, spanSec },
          )}
        </div>

        <div class="panel">
          <div class="panel-title">
            Memory
            <span class="hint">utilisation</span>
          </div>
          ${this._renderChart(
            [{ values: memValues, color: accent, fill: true }],
            { yMax: 100, formatY: fmtPct, spanSec },
          )}
        </div>

        <div class="panel">
          <div class="panel-title">
            Latency
            <span class="hint">round-trip to 1.1.1.1</span>
          </div>
          ${this._renderChart(
            [{ values: latValues, color: accent }],
            { formatY: fmtMs, spanSec },
          )}
        </div>

        ${throughputChart(wanName, 'WAN')}
        ${throughputChart(lanName, 'LAN')}
      </div>
    `;
  }

  render() {
    // The shell paints immediately; each section renders skeleton
    // placeholders while overview is null (matching the Network Traffic
    // and Hardware pages). Only a *failed* first load short-circuits to
    // the error box rather than leaving skeletons up forever.
    if (this.error && !this.overview) {
      return html`<div class="module-container">
        <div class="error-message"><strong>Error:</strong> ${this.error}</div>
      </div>`;
    }

    return html`
      <div class="module-container">
        ${this._renderSummaryCards()}
        ${this._renderCharts()}
        <h2>System</h2>
        ${this._renderSystemCards()}
        <div class="charts">
          ${this._renderNetworkInfo()}
          ${this._renderInterfaceThroughput()}
        </div>
        ${this._renderDisks()}
        ${this._renderNetworkMounts()}
      </div>
    `;
  }
}

customElements.define('dashboard-module', DashboardModule);
