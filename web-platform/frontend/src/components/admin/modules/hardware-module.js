import { LitElement, html, css, svg } from 'lit';
import {
  getHardwareOverview,
  getDriveTempHistory,
  getSensorTempHistory,
  refreshFirmwareMetadata,
  updateFirmware,
  getFirmwareUpdateStatus,
  rebootSystem,
  powerOffSystem,
} from '../../../api/client.js';
import { confirmDialog } from '../../shared/confirm-dialog.js';
import { actionIcon } from '../../../shared/icons.js';

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
    sensorHistory: { type: Object, state: true },
    loading: { type: Boolean, state: true },
    error: { type: String, state: true },
    // Firmware action state — `busy` flags drive the per-button spinner
    // / disabled state; `updateStatus` holds the live job state from
    // /api/firmware/update-status (running flag + accumulated log).
    refreshBusy: { type: Boolean, state: true },
    updateStatus: { type: Object, state: true },
    actionBusy: { type: String, state: true }, // '' | 'reboot' | 'poweroff'
    // Up-to-date firmware devices are collapsed by default since most
    // boxes have ~15+ with nothing actionable; this toggles the
    // secondary table's visibility.
    showUpToDateFirmware: { type: Boolean, state: true },
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

    /* Page-header row — page title + compact power buttons aligned to
       the right. */
    .page-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      margin-bottom: 8px;
    }
    .page-header h1 {
      font-size: 22px;
      font-weight: 600;
      color: var(--hf-text);
      margin: 0;
    }
    .header-actions {
      display: flex;
      gap: 8px;
      align-items: center;
    }
    /* Compact icon-button — mirrors .icon-action in services-module.js so
       the visual language stays consistent (28px square, hover halo,
       danger variant, busy spinner). */
    .icon-action {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 30px;
      height: 30px;
      padding: 0;
      background: var(--hf-surface);
      border: 1px solid var(--hf-border);
      border-radius: 6px;
      color: var(--hf-text-muted);
      cursor: pointer;
      transition: background-color 0.15s, border-color 0.15s, color 0.15s;
    }
    .icon-action:hover:not(:disabled) {
      background: var(--hf-surface);
      border-color: var(--hf-accent);
      color: var(--hf-text);
    }
    .icon-action.danger:hover:not(:disabled) {
      border-color: var(--hf-err);
      color: var(--hf-err);
    }
    .icon-action.busy {
      border-color: var(--hf-accent);
      color: var(--hf-accent);
    }
    .icon-action:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }
    .icon-action svg {
      width: 16px;
      height: 16px;
    }

    /* Firmware panel — uses the existing .panel / table styles for the
       device list; this just lays out the action row above the table. */
    .firmware-actions {
      display: flex;
      gap: 8px;
      align-items: center;
      margin-bottom: 12px;
      flex-wrap: wrap;
    }
    button.text-button {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border);
      border-radius: 6px;
      color: var(--hf-text);
      cursor: pointer;
      font-size: 13px;
      padding: 6px 12px;
      transition: background-color 0.15s, border-color 0.15s, color 0.15s;
    }
    button.text-button:hover:not(:disabled) {
      border-color: var(--hf-accent);
    }
    button.text-button.primary {
      border-color: var(--hf-accent);
      color: var(--hf-accent);
    }
    button.text-button.primary:hover:not(:disabled) {
      background: color-mix(in srgb, var(--hf-accent) 8%, transparent);
    }
    button.text-button:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }

    /* Section subhead inside the firmware panel — distinguishes the
       "Updates available" group from the collapsed "Up to date" group. */
    .firmware-subhead {
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      color: var(--hf-text-muted);
      font-weight: 600;
      margin: 16px 0 6px;
    }
    .firmware-subhead:first-child { margin-top: 0; }

    /* Disclosure toggle for the up-to-date device list. Styled as
       muted text rather than a button so it doesn't compete with the
       Update buttons for attention. */
    .disclosure-toggle {
      background: none;
      border: none;
      color: var(--hf-text-muted);
      cursor: pointer;
      padding: 0;
      font: inherit;
      font-size: 12px;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      margin: 16px 0 0;
    }
    .disclosure-toggle:hover { color: var(--hf-text); }
    .disclosure-toggle .chev {
      display: inline-block;
      width: 8px;
      height: 8px;
      border-right: 1.5px solid currentColor;
      border-bottom: 1.5px solid currentColor;
      transform: rotate(-45deg);
      transition: transform 0.15s;
      margin-right: 2px;
    }
    .disclosure-toggle.open .chev { transform: rotate(45deg); }

    /* "Firmware is up to date" callout — shown when fwupd reports no
       available updates for any device. Uses the OK-green border to
       read as a positive confirmation rather than a neutral status. */
    .ok-banner {
      background: color-mix(in srgb, var(--hf-ok) 10%, transparent);
      border: 1px solid var(--hf-ok);
      color: var(--hf-text);
      border-radius: 8px;
      padding: 10px 14px;
      font-size: 13px;
      margin-bottom: 12px;
      display: flex;
      align-items: center;
      gap: 10px;
    }
    .ok-banner strong { color: var(--hf-ok); }
    .ok-banner .check {
      flex-shrink: 0;
      width: 16px;
      height: 16px;
      color: var(--hf-ok);
    }

    /* Pending-reboot banner — fwupd's signal that a previously-applied
       update needs the box restarted to activate. */
    .reboot-banner {
      background: color-mix(in srgb, var(--hf-warn) 14%, transparent);
      border: 1px solid var(--hf-warn);
      color: var(--hf-text);
      border-radius: 8px;
      padding: 10px 14px;
      font-size: 13px;
      margin-bottom: 12px;
      display: flex;
      align-items: center;
      gap: 10px;
    }
    .reboot-banner strong { color: var(--hf-warn); }

    /* Live log panel during a running firmware update. Same monospace +
       scrollable pattern as the rebuild log viewer elsewhere. */
    .log-panel {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border);
      border-radius: 8px;
      padding: 10px 12px;
      margin-top: 12px;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 12px;
      color: var(--hf-text);
      max-height: 280px;
      overflow-y: auto;
      white-space: pre-wrap;
      word-break: break-word;
    }
    .log-empty {
      color: var(--hf-text-muted);
      font-style: italic;
    }
  `;

  constructor() {
    super();
    this.overview = null;
    this.tempHistory = null;
    this.sensorHistory = null;
    this.loading = true;
    this.error = '';
    this.refreshBusy = false;
    // updateStatus: { running: bool, output: string, exit_code: int|null,
    //                 device_ids: [string], finished_at: int|null }
    this.updateStatus = { running: false, output: '', exit_code: null, device_ids: [] };
    this.actionBusy = '';
    this.showUpToDateFirmware = false;
    this._overviewPoll = null;
    this._historyPoll = null;
    this._firmwarePoll = null;
    // Cumulative log text. The backend returns *incremental* output
    // (bytes since the last call), so we accumulate here for display.
    this._firmwareLog = '';
  }

  connectedCallback() {
    super.connectedCallback();
    this._refreshOverview();
    this._refreshHistory();
    // One immediate poll to reattach to any in-flight firmware update
    // (the unit is independent of admin-api / this page's lifecycle).
    this._pollFirmwareStatus();
    // Overview is cached server-side for 60s, but poll on the same 5s
    // cadence as the dashboard so the table updates promptly when the
    // user lands on the page just after a fresh sampler tick.
    this._overviewPoll = setInterval(() => this._refreshOverview(), 5000);
    // History matches the slower sampler cadence (drive=60s, sensors=10s
    // via the dashboard sampler) — 30s is a sensible middle ground.
    this._historyPoll = setInterval(() => this._refreshHistory(), 30000);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this._overviewPoll) { clearInterval(this._overviewPoll); this._overviewPoll = null; }
    if (this._historyPoll)  { clearInterval(this._historyPoll);  this._historyPoll  = null; }
    if (this._firmwarePoll) { clearInterval(this._firmwarePoll); this._firmwarePoll = null; }
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
    // Fetch both histories in parallel — they target different DBs
    // and one failing should not block the other from updating.
    const [tempRes, sensorRes] = await Promise.allSettled([
      getDriveTempHistory(),
      getSensorTempHistory(),
    ]);
    if (tempRes.status === 'fulfilled')   this.tempHistory   = tempRes.value;
    if (sensorRes.status === 'fulfilled') this.sensorHistory = sensorRes.value;
    /* failures non-fatal — charts keep the last good data */
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
    // Drive charts come from the dedicated drive-temp DB; sensor charts
    // come from the dashboard sampler DB. Render them in one unified
    // grid so the whole thermal picture flows together: drives first
    // (the user's primary concern), then motherboard sensors.
    const driveHist = this.tempHistory;
    const sensorHist = this.sensorHistory;
    const drives = (this.overview && this.overview.physical_drives) || [];
    const liveSensors = (this.overview && this.overview.sensors) || [];

    const byDevice = (driveHist && driveHist.by_device) || {};
    const bySensor = (sensorHist && sensorHist.by_sensor) || {};
    const sensorKinds = (sensorHist && sensorHist.kinds) || {};

    const deviceList = Object.keys(byDevice).sort();
    const sensorList = Object.keys(bySensor).sort();

    if (deviceList.length === 0 && sensorList.length === 0) {
      return html`
        <h2>Temperature history</h2>
        <div class="panel">
          <div class="chart-empty">
            Collecting data… the samplers tick every 10–60s; charts
            populate within a few minutes of first boot.
          </div>
        </div>
      `;
    }

    // Span = whichever history we have, prefer the drive window since
    // that's what the user explicitly asked us to start with; both
    // stores keep the same 24h window today anyway.
    const spanSec = (driveHist && driveHist.window_seconds)
                 || (sensorHist && sensorHist.window_seconds)
                 || 0;
    const spanLabel = spanSec >= 3600
      ? `last ${(spanSec / 3600).toFixed(0)} h`
      : `last ${Math.round(spanSec / 60)} min`;

    // --- per-drive charts ---------------------------------------------
    const driveCharts = deviceList.map(device => {
      const meta = drives.find(d => d.device === device);
      const className = meta
        ? (meta.drive_class === 'nvme' ? 'NVMe' : meta.drive_class === 'ssd' ? 'SSD' : 'HDD')
        : '';
      return this._renderTempChart({
        title: device,
        hint: className,
        subtitle: meta ? meta.model : '',
        samples: byDevice[device],
        warnC: meta ? meta.temp_warn_c : 45,
        errC:  meta ? meta.temp_err_c  : 50,
        spanSec, spanLabel,
      });
    });

    // --- per-sensor charts --------------------------------------------
    // Thresholds match the sensor-card heuristics in _renderSensors:
    // CPU 80/90, memory 70/80, NVMe 70/80, GPU 80/90, other 70/80.
    const sensorThresholds = (kind) => {
      switch (kind) {
        case 'cpu':    return { warnC: 80, errC: 90 };
        case 'memory': return { warnC: 70, errC: 80 };
        case 'nvme':   return { warnC: 70, errC: 80 };
        case 'gpu':    return { warnC: 80, errC: 90 };
        default:       return { warnC: 70, errC: 80 };
      }
    };
    const sensorKindLabel = (kind) => ({
      cpu: 'CPU', memory: 'Memory', nvme: 'NVMe controller', gpu: 'GPU',
    })[kind] || 'Sensor';

    // Live sensor lookup keyed by the same persisted key the sampler
    // uses — `hwmon.scan()` returns it on every reading. Lets us pull
    // the friendly display name for the chart title.
    const liveByKey = {};
    for (const s of liveSensors) {
      if (s.key) liveByKey[s.key] = s;
    }

    const sensorCharts = sensorList.map(key => {
      const kind = sensorKinds[key] || 'other';
      const { warnC, errC } = sensorThresholds(kind);
      const live = liveByKey[key];
      // Persisted key shape: "<driverWithMaybeInstance>:<labelOrSlot>".
      const [driverWithInst, ...rest] = key.split(':');
      const labelOrSlot = rest.join(':');
      const title = live && live.label ? live.label : labelOrSlot || driverWithInst;
      const subtitle = live ? live.name : driverWithInst;
      return this._renderTempChart({
        title,
        hint: sensorKindLabel(kind),
        subtitle: subtitle !== title ? subtitle : '',
        samples: bySensor[key],
        warnC, errC,
        spanSec, spanLabel,
      });
    });

    return html`
      <h2>Temperature history</h2>
      <div class="temp-grid">
        ${driveCharts}
        ${sensorCharts}
      </div>
    `;
  }

  /**
   * One mini-chart for a single time-series of temperatures. Used for
   * both drives and sensors — the inputs (title, thresholds, samples)
   * are the only thing that differs between the two cases.
   *
   * Geometry follows the dashboard module's chart coordinate space so
   * the visual language stays consistent across pages.
   */
  _renderTempChart({ title, hint, subtitle, samples, warnC, errC, spanSec, spanLabel }) {
    const validSamples = (samples || []).filter(s => s.temp_c != null);

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
          ${title}
          ${hint ? html`<span class="hint">${hint}</span>` : ''}
        </div>
        ${subtitle ? html`<div class="temp-panel-sub">${subtitle}</div>` : ''}
        ${chartBody}
      </div>
    `;
  }

  // --- page header (title + power buttons) ----------------------------

  async _onRebootClick() {
    if (this.actionBusy) return;
    const ok = await confirmDialog({
      title: 'Restart the system?',
      message:
        'This will reboot the host immediately. All running services will be ' +
        'interrupted; the connection to the admin UI will drop until the ' +
        'box comes back up.',
      confirmText: 'Restart',
      cancelText: 'Cancel',
      variant: 'danger',
    });
    if (!ok) return;
    this.actionBusy = 'reboot';
    try {
      await rebootSystem();
    } catch (e) {
      // The connection often drops mid-response — that's success, not
      // failure. Only surface a real client-side error.
      if (e && e.status && e.status >= 400) {
        this.error = e.message || 'Reboot request failed';
      }
    }
    // Leave actionBusy set; the page is about to lose its connection.
  }

  async _onPowerOffClick() {
    if (this.actionBusy) return;
    const ok = await confirmDialog({
      title: 'Power off the system?',
      message:
        'This will shut the host down immediately. Someone will need to ' +
        'physically power it back on. The admin UI will be unreachable ' +
        'until then.',
      confirmText: 'Power off',
      cancelText: 'Cancel',
      variant: 'danger',
    });
    if (!ok) return;
    this.actionBusy = 'poweroff';
    try {
      await powerOffSystem();
    } catch (e) {
      if (e && e.status && e.status >= 400) {
        this.error = e.message || 'Power-off request failed';
      }
    }
  }

  _renderHeader() {
    const restartBusy  = this.actionBusy === 'reboot';
    const poweroffBusy = this.actionBusy === 'poweroff';
    return html`
      <div class="page-header">
        <h1>Hardware</h1>
        <div class="header-actions">
          <button
            class="icon-action ${restartBusy ? 'busy' : ''}"
            title="Restart"
            aria-label="Restart"
            ?disabled=${!!this.actionBusy}
            @click=${() => this._onRebootClick()}
          >
            ${actionIcon('restart')}
          </button>
          <button
            class="icon-action danger ${poweroffBusy ? 'busy' : ''}"
            title="Power off"
            aria-label="Power off"
            ?disabled=${!!this.actionBusy}
            @click=${() => this._onPowerOffClick()}
          >
            ${actionIcon('poweroff')}
          </button>
        </div>
      </div>
    `;
  }

  // --- firmware -------------------------------------------------------

  async _pollFirmwareStatus() {
    let status;
    try {
      status = await getFirmwareUpdateStatus();
    } catch {
      return;
    }
    // Append the incremental output to our cumulative log buffer.
    if (status && status.output) {
      this._firmwareLog += status.output;
    }
    this.updateStatus = status || this.updateStatus;
    // Start polling if we discovered a running job; stop when it finishes.
    if (status && status.running) {
      if (!this._firmwarePoll) {
        this._firmwarePoll = setInterval(() => this._pollFirmwareStatus(), 1500);
      }
    } else if (this._firmwarePoll) {
      clearInterval(this._firmwarePoll);
      this._firmwarePoll = null;
      // Final refresh of the device table (versions just changed).
      this._refreshOverview();
    }
  }

  async _onCheckUpdatesClick() {
    if (this.refreshBusy) return;
    this.refreshBusy = true;
    try {
      await refreshFirmwareMetadata();
      // The resolver invalidates its 60s cache on refresh, but the
      // dashboard overview also caches; force a refetch so the table
      // reflects new upgrade availability immediately.
      await this._refreshOverview();
    } catch (e) {
      this.error = e.message || 'Failed to refresh firmware metadata';
    } finally {
      this.refreshBusy = false;
    }
  }

  async _startFirmwareUpdate(deviceIds, confirmMessage) {
    if (this.updateStatus && this.updateStatus.running) return;
    const ok = await confirmDialog({
      title: 'Apply firmware update?',
      message: confirmMessage,
      confirmText: 'Update',
      cancelText: 'Cancel',
      variant: 'danger',
    });
    if (!ok) return;
    // Reset the log buffer for the new run.
    this._firmwareLog = '';
    this.updateStatus = { running: true, output: '', exit_code: null, device_ids: deviceIds };
    try {
      const res = await updateFirmware(deviceIds);
      if (!res || res.success === false) {
        this.error = (res && res.message) || 'Failed to start firmware update';
        this.updateStatus = { running: false, output: '', exit_code: null, device_ids: [] };
        return;
      }
    } catch (e) {
      this.error = e.message || 'Failed to start firmware update';
      this.updateStatus = { running: false, output: '', exit_code: null, device_ids: [] };
      return;
    }
    // Kick off the status poll loop.
    this._pollFirmwareStatus();
  }

  _renderFirmware() {
    const fw = (this.overview && this.overview.firmware) || null;
    if (!fw) return '';

    if (!fw.available) {
      return html`
        <div class="panel">
          <div class="panel-title">Firmware</div>
          <div class="error-message">
            <strong>fwupd unavailable:</strong> ${fw.error || 'unknown error'}
          </div>
        </div>
      `;
    }

    const devices = fw.devices || [];
    const updatable = devices.filter(d => d.update_available);
    const upToDate = devices.filter(d => !d.update_available);
    const updating = this.updateStatus && this.updateStatus.running;
    const activeIds = new Set((this.updateStatus && this.updateStatus.device_ids) || []);

    // Shared safety preamble shown before every firmware-update confirm.
    // Firmware flashes are not safe to interrupt: a power loss or hard
    // shutdown midway can leave a device unbootable. fwupd does its best
    // (atomic capsule updates on UEFI, dual-image on NVMe / network cards)
    // but the warning belongs in front of the user every time.
    const safetyPreamble =
      'Do not power off, reboot, or unplug the system while the update runs. ' +
      'A laptop should be plugged in; a desktop/server should not be on a UPS ' +
      'that\'s about to switch over. An interrupted firmware update can leave ' +
      'a device unbootable.\n\n';

    const updateAllConfirm = () => {
      const lines = updatable.map(d => `• ${d.name}: ${d.version} → ${d.update_version}`).join('\n');
      const anyReboot = updatable.some(d => d.update_needs_reboot);
      return safetyPreamble +
             `Apply ${updatable.length} firmware update${updatable.length === 1 ? '' : 's'}? ` +
             `Updates run sequentially.\n\n${lines}` +
             (anyReboot
               ? '\n\nOne or more of these will require a reboot to finish installing. ' +
                 'You\'ll see a "Reboot required" banner here when that\'s the case.'
               : '');
    };

    // Row renderer shared between the updates-available and up-to-date
    // tables — same columns so the visual rhythm is consistent.
    const renderRow = (d) => {
      const thisActive = updating && activeIds.has(d.device_id);
      return html`
        <tr>
          <td>
            ${d.name}
            ${d.vendor ? html`<div class="card-sub" style="margin:0">${d.vendor}</div>` : ''}
          </td>
          <td>${d.version}</td>
          <td>
            ${d.update_available
              ? html`
                  <span class="card-value" style="font-size:13px;font-weight:600;color:var(--hf-accent)">
                    ${d.update_version}
                  </span>
                  ${d.update_summary
                    ? html`<div class="card-sub" style="margin:0">${d.update_summary}</div>`
                    : ''}
                  ${d.update_needs_reboot
                    ? html`<div class="card-sub" style="margin:0">requires reboot</div>`
                    : ''}
                `
              : html`<span class="card-sub" style="margin:0">—</span>`}
          </td>
          <td style="text-align:right">
            ${d.update_available ? html`
              <button
                class="text-button ${thisActive ? 'primary' : ''}"
                ?disabled=${updating}
                @click=${() => this._startFirmwareUpdate(
                  [d.device_id],
                  safetyPreamble +
                  `Apply firmware update for ${d.name}?\n\n` +
                  `${d.version} → ${d.update_version}` +
                  (d.update_needs_reboot
                    ? '\n\nA reboot will be required to finish installing.'
                    : ''),
                )}
              >${thisActive ? 'Updating…' : 'Update'}</button>
            ` : ''}
          </td>
        </tr>
      `;
    };

    const tableHead = html`
      <thead>
        <tr>
          <th>Device</th>
          <th>Current</th>
          <th>Update</th>
          <th></th>
        </tr>
      </thead>
    `;

    return html`
      <h2>Firmware</h2>

      ${fw.pending_reboot ? html`
        <div class="reboot-banner">
          <strong>Reboot required.</strong>
          A previously-applied firmware update is staged. Restart the host
          to finish installing it.
        </div>
      ` : ''}

      ${!fw.pending_reboot && updatable.length === 0 && devices.length > 0 ? html`
        <div class="ok-banner">
          <svg class="check" viewBox="0 0 24 24" fill="none" stroke="currentColor"
               stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"
               aria-hidden="true">
            <polyline points="20 6 9 17 4 12"></polyline>
          </svg>
          <div>
            <strong>Firmware is up to date.</strong>
            All ${devices.length} device${devices.length === 1 ? '' : 's'} fwupd
            tracks on this host are at the latest version offered by the
            configured remotes.
          </div>
        </div>
      ` : ''}

      <div class="panel">
        <div class="firmware-actions">
          <button
            class="text-button"
            ?disabled=${this.refreshBusy || updating}
            @click=${() => this._onCheckUpdatesClick()}
          >${this.refreshBusy ? 'Checking…' : 'Check for updates'}</button>

          ${updatable.length > 0 ? html`
            <button
              class="text-button primary"
              ?disabled=${updating}
              @click=${() => this._startFirmwareUpdate(
                updatable.map(d => d.device_id),
                updateAllConfirm(),
              )}
            >Update all (${updatable.length})</button>
          ` : ''}

        </div>

        ${updatable.length > 0 ? html`
          <div class="firmware-subhead">Updates available (${updatable.length})</div>
          <table>
            ${tableHead}
            <tbody>${updatable.map(renderRow)}</tbody>
          </table>
        ` : ''}

        ${upToDate.length > 0 ? html`
          <button
            class="disclosure-toggle ${this.showUpToDateFirmware ? 'open' : ''}"
            @click=${() => { this.showUpToDateFirmware = !this.showUpToDateFirmware; }}
            aria-expanded=${this.showUpToDateFirmware ? 'true' : 'false'}
          >
            <span class="chev"></span>
            ${this.showUpToDateFirmware ? 'Hide' : 'Show'} up-to-date devices (${upToDate.length})
          </button>
          ${this.showUpToDateFirmware ? html`
            <table style="margin-top:8px">
              ${tableHead}
              <tbody>${upToDate.map(renderRow)}</tbody>
            </table>
          ` : ''}
        ` : ''}

        ${updating || this._firmwareLog ? html`
          <div class="log-panel">${this._firmwareLog
            ? this._firmwareLog
            : html`<span class="log-empty">Starting update…</span>`}</div>
        ` : ''}

        ${this.updateStatus && !this.updateStatus.running
            && this.updateStatus.exit_code != null
            && this.updateStatus.exit_code !== 0 ? html`
          <div class="error-message" style="margin-top:12px">
            Last update exited with code ${this.updateStatus.exit_code}.
          </div>
        ` : ''}
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
        ${this._renderHeader()}
        ${this._renderFirmware()}
        ${this._renderSensors()}
        ${this._renderPhysicalDrives()}
        ${this._renderTempHistory()}
      </div>
    `;
  }
}

customElements.define('hardware-module', HardwareModule);
