import { LitElement, html, css, svg } from 'lit';
import {
  getHardwareOverview,
  getDriveTempHistory,
} from '../../../api/client.js';

/**
 * Hardware module — per-drive SMART + sensor monitoring.
 *
 * Mirrors the Dashboard module's polling/rendering pattern: an overview
 * snapshot every 5s, history every 60s (matches the sampler tick — no
 * point polling faster than new rows can land).
 *
 * Three sections today:
 *   1. Sensors (CPU / memory / NVMe / GPU temperatures from hwmon)
 *   2. Physical Drives table (model, class, size, temp, PoH, wear, SMART)
 *   3. Drive Temperature History chart (multi-line, one drive per line)
 *
 * Room to grow: fan RPMs, ACPI thermal zones, per-NVMe throttle state,
 * CPU/memory temperature history charts (sensor sampler would be the
 * next sampler service).
 */
class HardwareModule extends LitElement {
  static properties = {
    overview: { type: Object, state: true },
    tempHistory: { type: Object, state: true },
    loading: { type: Boolean, state: true },
    error: { type: String, state: true },
  };

  static styles = css`
    :host { display: block; }
    .module-container { width: 100%; }

    h2 {
      font-size: 18px;
      font-weight: 600;
      color: var(--hf-text);
      margin: 28px 0 12px;
    }
    h2:first-child { margin-top: 0; }

    .cards {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(var(--hf-card-min-sm), 1fr));
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
    th.num, td.num { text-align: right; }
    td.num { font-variant-numeric: tabular-nums; }

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
    .dot.idle { background: var(--hf-text-muted); }

    /* Per-drive temperature mini-chart grid. Each chart sits in its
       own panel with its own thresholds drawn at the right values for
       that drive's class. Auto-fits as wide as the viewport allows; a
       single drive will fill the row, multiple drives wrap into a
       responsive grid. */
    .temp-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(360px, 1fr));
      gap: 16px;
    }
    .temp-panel {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border);
      border-radius: 10px;
      padding: 14px 16px;
      overflow: hidden;
    }
    .temp-panel-title {
      font-size: 13px;
      font-weight: 600;
      color: var(--hf-text);
      margin-bottom: 4px;
      display: flex;
      justify-content: space-between;
      align-items: baseline;
      gap: 8px;
    }
    .temp-panel-title .hint {
      font-size: 11px;
      font-weight: 400;
      color: var(--hf-text-muted);
    }
    .temp-panel-sub {
      font-size: 11px;
      color: var(--hf-text-muted);
      margin-bottom: 8px;
    }

    .chart-svg { width: 100%; height: auto; display: block; }
    .axis-label {
      fill: var(--hf-text-muted);
      font-size: 10px;
      font-family: inherit;
    }
    .chart-empty {
      font-size: 12px;
      color: var(--hf-text-muted);
      padding: 48px 0;
      text-align: center;
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
    .loading { color: var(--hf-text-muted); font-size: 13px; padding: 24px 0; }
  `;

  constructor() {
    super();
    this.overview = null;
    this.tempHistory = null;
    this.loading = true;
    this.error = '';
    this._overviewPoll = null;
    this._historyPoll = null;
  }

  connectedCallback() {
    super.connectedCallback();
    this._refreshOverview();
    this._refreshHistory();
    // Overview is cached server-side for 60s, but poll on the same 5s
    // cadence as the dashboard so the table updates promptly when the
    // user lands on the page just after a fresh sampler tick.
    this._overviewPoll = setInterval(() => this._refreshOverview(), 5000);
    // History matches sampler cadence (60s) — no point fetching faster.
    this._historyPoll = setInterval(() => this._refreshHistory(), 60000);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this._overviewPoll) { clearInterval(this._overviewPoll); this._overviewPoll = null; }
    if (this._historyPoll)  { clearInterval(this._historyPoll);  this._historyPoll  = null; }
  }

  async _refreshOverview() {
    try {
      this.overview = await getHardwareOverview();
      this.error = '';
    } catch (e) {
      if (!this.overview) this.error = e.message || 'Failed to load hardware overview';
    } finally {
      this.loading = false;
    }
  }

  async _refreshHistory() {
    try {
      this.tempHistory = await getDriveTempHistory();
    } catch (e) {
      /* chart just keeps the last good data; non-fatal */
    }
  }

  // --- formatting helpers --------------------------------------------

  _fmtBytes(n) {
    if (n == null) return '—';
    const u = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    let i = 0;
    let v = n;
    while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
    return `${v.toFixed(v >= 100 || i === 0 ? 0 : 1)} ${u[i]}`;
  }

  _fmtHours(h) {
    if (h == null) return '—';
    if (h < 1000) return `${h} h`;
    const days = Math.floor(h / 24);
    if (days < 365) return `${days} d`;
    const years = (days / 365).toFixed(1);
    return `${years} y`;
  }

  // --- sensors panel -------------------------------------------------

  _renderSensors() {
    const sensors = (this.overview && this.overview.sensors) || [];
    if (sensors.length === 0) return '';

    // Group by kind for the card grid. We pick a representative number
    // per kind (max across sensors of that kind) so the card reads at a
    // glance — full detail is in the table below.
    const byKind = {};
    for (const s of sensors) {
      (byKind[s.kind] ||= []).push(s);
    }
    // Two label sets: cards advertise that they're temperatures
    // (the card-value is a bare number), the table doesn't (the
    // Temperature column header already says so).
    const cardLabels = {
      cpu: 'CPU Temp',
      memory: 'Memory Temp',
      nvme: 'NVMe Controller Temp',
      gpu: 'GPU Temp',
      other: 'Other Temp',
    };
    const kindLabels = {
      cpu: 'CPU',
      memory: 'Memory',
      nvme: 'NVMe controller',
      gpu: 'GPU',
      other: 'Other',
    };
    // Threshold heuristics per sensor kind. Same spirit as the
    // per-drive-class table thresholds but for solid-state silicon.
    const sensorClass = (kind, t) => {
      if (kind === 'cpu')    return t >= 90 ? 'err' : t >= 80 ? 'warn' : '';
      if (kind === 'memory') return t >= 80 ? 'err' : t >= 70 ? 'warn' : '';
      if (kind === 'nvme')   return t >= 80 ? 'err' : t >= 70 ? 'warn' : '';
      if (kind === 'gpu')    return t >= 90 ? 'err' : t >= 80 ? 'warn' : '';
      return '';
    };

    const orderedKinds = ['cpu', 'memory', 'nvme', 'gpu', 'other']
      .filter(k => byKind[k]);

    return html`
      <h2>Sensors</h2>
      <div class="cards">
        ${orderedKinds.map(kind => {
          const list = byKind[kind];
          const max = list.reduce((m, s) => Math.max(m, s.temp_c), 0);
          const cls = sensorClass(kind, max);
          return html`
            <div class="card">
              <div class="card-label">${cardLabels[kind]}</div>
              <div class="card-value ${cls}">${max.toFixed(1)}°C</div>
              <div class="card-sub">
                ${list.length === 1
                  ? list[0].label || list[0].name
                  : `max of ${list.length} sensors`}
              </div>
            </div>
          `;
        })}
      </div>

      <div class="panel">
        <div class="panel-title">All sensors <span class="hint">live · /sys/class/hwmon</span></div>
        <table>
          <thead>
            <tr>
              <th>Driver</th>
              <th>Label</th>
              <th>Kind</th>
              <th class="num">Temperature</th>
            </tr>
          </thead>
          <tbody>
            ${sensors.map(s => html`
              <tr>
                <td>${s.name}</td>
                <td>${s.label || '—'}</td>
                <td>${kindLabels[s.kind] || s.kind}</td>
                <td class="num ${
                  sensorClass(s.kind, s.temp_c) === 'err' ? 'card-value err'
                  : sensorClass(s.kind, s.temp_c) === 'warn' ? 'card-value warn'
                  : ''}" style="font-weight:400">${s.temp_c.toFixed(1)}°C</td>
              </tr>
            `)}
          </tbody>
        </table>
      </div>
    `;
  }

  // --- physical drives table -----------------------------------------

  _renderPhysicalDrives() {
    const drives = (this.overview && this.overview.physical_drives) || [];
    if (drives.length === 0) {
      return html`
        <h2>Physical Drives</h2>
        <div class="panel"><div class="card-sub" style="margin:0">No drives detected.</div></div>
      `;
    }

    const statusClass = (s) => s === 'err' ? 'err' : s === 'warn' ? 'warn' : '';
    const smartDot = (d) => {
      if (!d.smart_available) return 'idle';
      if (d.smart_passed === false) return 'down';
      if (d.smart_passed === true) return 'up';
      return 'idle';
    };
    const smartLabel = (d) => {
      if (!d.smart_available) return 'unavailable';
      if (d.smart_passed === false) return 'FAILING';
      if (d.smart_passed === true) return 'PASSED';
      return 'unknown';
    };
    const classLabel = (c) => c === 'nvme' ? 'NVMe' : c === 'ssd' ? 'SSD' : 'HDD';

    const tempCell = (d) => {
      if (d.temp_c == null) {
        return html`<span class="card-sub" style="margin:0">—</span>`;
      }
      const pct = Math.min(100, Math.round((d.temp_c / d.temp_err_c) * 100));
      return html`
        <div>
          ${d.temp_c}°C
          <span class="card-sub" style="margin-left:6px">
            warn ${d.temp_warn_c}° / err ${d.temp_err_c}°
          </span>
        </div>
        <div class="meter">
          <div class="meter-fill ${statusClass(d.temp_status)}"
               style="width:${pct}%"></div>
        </div>
      `;
    };

    const wearCell = (d) => {
      if (d.drive_class === 'hdd') {
        const r = d.reallocated_sectors;
        const p = d.pending_sectors;
        if (r == null && p == null) {
          return html`<span class="card-sub" style="margin:0">—</span>`;
        }
        const cls = statusClass(d.wear_status);
        return html`
          <span class="${cls === 'err' ? 'card-value err' : cls === 'warn' ? 'card-value warn' : ''}"
                style="font-size:13px;font-weight:400">
            ${r ?? 0} reallocated · ${p ?? 0} pending
          </span>
        `;
      }
      const used = d.life_used_percent;
      if (used == null) {
        return html`<span class="card-sub" style="margin:0">—</span>`;
      }
      return html`
        <div>${used}% used${
          d.available_spare_percent != null
            ? html`<span class="card-sub" style="margin-left:6px">spare ${d.available_spare_percent}%</span>`
            : ''}
        </div>
        <div class="meter">
          <div class="meter-fill ${statusClass(d.wear_status)}"
               style="width:${Math.min(100, used)}%"></div>
        </div>
      `;
    };

    return html`
      <h2>Physical Drives</h2>
      <div class="panel">
        <div class="panel-title">
          SMART overview <span class="hint">cached 60s</span>
        </div>
        <table>
          <thead>
            <tr>
              <th>Device</th>
              <th>Model</th>
              <th>Class</th>
              <th class="num">Size</th>
              <th style="width:22%">Temperature</th>
              <th class="num">Power-on</th>
              <th style="width:22%">Wear / Health</th>
              <th>SMART</th>
            </tr>
          </thead>
          <tbody>
            ${drives.map(d => html`
              <tr>
                <td>${d.device}</td>
                <td>
                  ${d.model || '—'}
                  ${d.vendor ? html`<div class="card-sub" style="margin:0">${d.vendor}</div>` : ''}
                </td>
                <td>${classLabel(d.drive_class)}${
                  d.transport === 'usb' ? html`<span class="card-sub" style="margin-left:6px">USB</span>` : ''}</td>
                <td class="num">${this._fmtBytes(d.size_bytes)}</td>
                <td>${tempCell(d)}</td>
                <td class="num">${this._fmtHours(d.power_on_hours)}</td>
                <td>${wearCell(d)}</td>
                <td>
                  <span class="dot ${smartDot(d)}"></span>
                  ${smartLabel(d)}
                  ${d.smart_error
                    ? html`<div class="card-sub" style="margin:0">${d.smart_error}</div>`
                    : ''}
                </td>
              </tr>
            `)}
          </tbody>
        </table>
      </div>
    `;
  }

  // --- drive-temperature history chart -------------------------------

  /**
   * Render one mini-chart per drive. Each chart draws this drive's own
   * warn/err threshold lines (HDD 45/50, SSD 60/70, NVMe 70/80 — the
   * resolver returns the right pair as temp_warn_c/temp_err_c per drive)
   * so the chart's red/yellow lines are always relevant to what you're
   * looking at. Mixing classes on one chart made the threshold lines
   * ambiguous and the Y range was dominated by the hottest class.
   */
  _renderTempHistory() {
    const hist = this.tempHistory;
    const drives = (this.overview && this.overview.physical_drives) || [];
    const byDevice = (hist && hist.by_device) || {};
    const deviceList = Object.keys(byDevice).sort();
    const spanSec = hist ? hist.window_seconds : 0;

    if (deviceList.length === 0) {
      return html`
        <h2>Temperature history</h2>
        <div class="panel">
          <div class="chart-empty">
            Collecting data… the sampler ticks once per minute, so the
            chart populates within a few minutes of first boot.
          </div>
        </div>
      `;
    }

    const spanLabel = spanSec >= 3600
      ? `last ${(spanSec / 3600).toFixed(0)} h`
      : `last ${Math.round(spanSec / 60)} min`;

    return html`
      <h2>Temperature history</h2>
      <div class="temp-grid">
        ${deviceList.map(device => this._renderDriveTempChart(
          device, byDevice[device], drives.find(d => d.device === device), spanSec, spanLabel
        ))}
      </div>
    `;
  }

  /**
   * One drive's mini-chart. `meta` is the matching overview row (gives
   * us model + per-class thresholds); may be undefined if the drive
   * has history rows but no current overview entry (e.g. just hot-
   * unplugged) — in which case we fall back to generic defaults.
   */
  _renderDriveTempChart(device, samples, meta, spanSec, spanLabel) {
    const validSamples = (samples || []).filter(s => s.temp_c != null);

    // Per-class thresholds from the resolver. Fall back to HDD's
    // 45/50 when the drive isn't in the current overview — same set
    // we'd use for an unknown rotating disk, and explicit enough
    // that it's obvious if/when it's wrong.
    const warnC = meta ? meta.temp_warn_c : 45;
    const errC  = meta ? meta.temp_err_c  : 50;
    const className = meta
      ? (meta.drive_class === 'nvme' ? 'NVMe' : meta.drive_class === 'ssd' ? 'SSD' : 'HDD')
      : '';
    const modelLine = meta ? meta.model : '';

    // Geometry — same coordinate-space conventions as the dashboard
    // module's charts so the visual language stays consistent.
    const W = 600;
    const H = 180;
    const ML = 44, MR = 12, MT = 12, MB = 22;
    const plotW = W - ML - MR;
    const plotH = H - MT - MB;

    // Anchor Y range on thresholds + observed extremes. Floor at 20°C
    // (room temp); ceiling at max(err_threshold + 5°, observed_max + 5°)
    // — guarantees both threshold lines and the data are visible.
    let minTemp = 20;
    let maxTemp = errC + 5;
    for (const s of validSamples) {
      if (s.temp_c < minTemp) minTemp = s.temp_c;
      if (s.temp_c + 5 > maxTemp) maxTemp = s.temp_c + 5;
    }
    minTemp = Math.floor(minTemp / 5) * 5;
    maxTemp = Math.ceil(maxTemp / 5) * 5;

    const nowTs = Math.floor(Date.now() / 1000);
    const x = (ts) => {
      const offset = (nowTs - ts) / Math.max(spanSec, 1);
      return ML + plotW * (1 - offset);
    };
    const y = (t) => MT + plotH - ((t - minTemp) / (maxTemp - minTemp)) * plotH;

    // Y tick lines every 10°C.
    const ticks = [];
    for (let t = Math.ceil(minTemp / 10) * 10; t <= maxTemp; t += 10) {
      ticks.push(t);
    }

    const chartBody = validSamples.length < 2
      ? html`<div class="chart-empty">Collecting data…</div>`
      : svg`
          <svg class="chart-svg" viewBox="0 0 ${W} ${H}">
            ${ticks.map(t => svg`
              <line x1="${ML}" y1="${y(t)}" x2="${W - MR}" y2="${y(t)}"
                    stroke="var(--hf-border)" stroke-width="1" />
              <text x="${ML - 6}" y="${y(t) + 3}" text-anchor="end"
                    class="axis-label">${t}°</text>
            `)}
            <line x1="${ML}" y1="${y(warnC)}" x2="${W - MR}" y2="${y(warnC)}"
                  stroke="var(--hf-warn)" stroke-width="1"
                  stroke-dasharray="4 3" opacity="0.85" />
            <text x="${W - MR - 2}" y="${y(warnC) - 3}" text-anchor="end"
                  class="axis-label" style="fill:var(--hf-warn)">warn ${warnC}°</text>
            <line x1="${ML}" y1="${y(errC)}" x2="${W - MR}" y2="${y(errC)}"
                  stroke="var(--hf-err)" stroke-width="1"
                  stroke-dasharray="4 3" opacity="0.85" />
            <text x="${W - MR - 2}" y="${y(errC) - 3}" text-anchor="end"
                  class="axis-label" style="fill:var(--hf-err)">err ${errC}°</text>
            <polyline points="${validSamples.map(s => `${x(s.ts)},${y(s.temp_c)}`).join(' ')}"
                      fill="none" stroke="var(--hf-accent)"
                      stroke-width="1.5" stroke-linejoin="round" />
            <text x="${ML}" y="${H - 6}" text-anchor="start"
                  class="axis-label">${spanLabel} ←</text>
            <text x="${W - MR}" y="${H - 6}" text-anchor="end"
                  class="axis-label">now</text>
          </svg>
        `;

    return html`
      <div class="temp-panel">
        <div class="temp-panel-title">
          ${device}
          <span class="hint">${className}</span>
        </div>
        ${modelLine ? html`<div class="temp-panel-sub">${modelLine}</div>` : ''}
        ${chartBody}
      </div>
    `;
  }

  render() {
    if (this.loading && !this.overview) {
      return html`<div class="module-container">
        <div class="loading">Loading hardware…</div>
      </div>`;
    }
    if (this.error && !this.overview) {
      return html`<div class="module-container">
        <div class="error-message"><strong>Error:</strong> ${this.error}</div>
      </div>`;
    }

    return html`
      <div class="module-container">
        ${this._renderSensors()}
        ${this._renderPhysicalDrives()}
        ${this._renderTempHistory()}
      </div>
    `;
  }
}

customElements.define('hardware-module', HardwareModule);
