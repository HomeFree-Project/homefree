import { LitElement, html, css } from 'lit';
import {
  startSpeedTest,
  getSpeedTestStatus,
  cancelSpeedTest,
} from '../../../api/client.js';

/**
 * Speed Test module — on-demand WAN measurement.
 *
 * Runs server-side from the HomeFree box against Cloudflare's public
 * speed.cloudflare.com endpoints, so the result reflects the home's
 * actual link regardless of where the admin is connecting from (works
 * correctly over Tailscale too). The backend is single-slot: clicking
 * Run while a test is in flight cancels the prior one.
 *
 * Polls /status every 500 ms while a test runs, then stops. Navigating
 * away cancels the in-flight test in disconnectedCallback so we don't
 * keep saturating the WAN for a user who's no longer looking.
 */
class SpeedTestModule extends LitElement {
  static properties = {
    status: { type: String, state: true },     // 'idle' | 'running' | 'done' | 'error' | 'cancelled'
    phase: { type: String, state: true },
    progress: { type: Number, state: true },
    partial: { type: Object, state: true },
    results: { type: Object, state: true },
    error: { type: String, state: true },
    server: { type: Object, state: true },
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

    .intro {
      color: var(--hf-text-muted);
      font-size: 13px;
      margin-bottom: 16px;
      max-width: 720px;
      line-height: 1.5;
    }

    .controls {
      display: flex;
      align-items: center;
      gap: 12px;
      margin-bottom: 16px;
    }
    button.primary {
      background: var(--hf-accent);
      color: var(--hf-on-accent, #fff);
      border: 1px solid var(--hf-accent);
      border-radius: 8px;
      padding: 10px 20px;
      font-size: 14px;
      font-weight: 600;
      cursor: pointer;
    }
    button.primary:hover { filter: brightness(1.08); }
    button.primary:disabled { opacity: 0.5; cursor: not-allowed; }
    button.danger {
      background: transparent;
      color: var(--hf-err);
      border: 1px solid var(--hf-err);
      border-radius: 8px;
      padding: 10px 20px;
      font-size: 14px;
      font-weight: 600;
      cursor: pointer;
    }
    button.danger:hover { background: color-mix(in srgb, var(--hf-err) 10%, transparent); }

    .progress {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border);
      border-radius: 10px;
      padding: 14px 16px;
      margin-bottom: 16px;
    }
    .progress-label {
      font-size: 12px;
      color: var(--hf-text-muted);
      margin-bottom: 8px;
      display: flex;
      justify-content: space-between;
    }
    .meter {
      height: 10px;
      border-radius: 5px;
      background: var(--hf-border);
      overflow: hidden;
    }
    .meter-fill {
      height: 100%;
      background: var(--hf-accent);
      transition: width 0.3s ease;
    }

    .summary-cards {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      gap: 16px;
      margin-bottom: 16px;
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
      font-size: 28px;
      font-weight: 600;
      color: var(--hf-text);
      font-variant-numeric: tabular-nums;
    }
    .card-value.ok   { color: var(--hf-ok); }
    .card-value.err  { color: var(--hf-err); }
    .card-value.warn { color: var(--hf-warn); }
    .card-sub {
      font-size: 12px;
      color: var(--hf-text-muted);
      margin-top: 4px;
    }
    .card-unit {
      font-size: 14px;
      font-weight: 400;
      color: var(--hf-text-muted);
      margin-left: 4px;
    }

    .panel {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border);
      border-radius: 10px;
      padding: 14px 16px;
      margin-bottom: 16px;
    }
    .panel-title {
      font-size: 13px;
      font-weight: 600;
      color: var(--hf-text);
      margin-bottom: 10px;
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
    td.num { text-align: right; font-variant-numeric: tabular-nums; }

    .error-message {
      background: color-mix(in srgb, var(--hf-err) 12%, transparent);
      border: 1px solid var(--hf-err);
      color: var(--hf-err);
      border-radius: 8px;
      padding: 10px 14px;
      font-size: 13px;
      margin-bottom: 16px;
    }
  `;

  constructor() {
    super();
    this.status = 'idle';
    this.phase = 'idle';
    this.progress = 0;
    this.partial = {};
    this.results = null;
    this.error = '';
    this.server = null;
    this._poll = null;
  }

  connectedCallback() {
    super.connectedCallback();
    // If a test was already running when we mounted (e.g. user navigated
    // back during a long test), pick up where it is rather than starting fresh.
    this._refresh();
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    this._stopPolling();
    // Don't keep saturating the WAN for a user who isn't watching.
    if (this.status === 'running') {
      cancelSpeedTest().catch(() => { /* best-effort */ });
    }
  }

  _stopPolling() {
    if (this._poll) {
      clearInterval(this._poll);
      this._poll = null;
    }
  }

  _startPolling() {
    this._stopPolling();
    this._poll = setInterval(() => this._refresh(), 500);
  }

  async _refresh() {
    try {
      const s = await getSpeedTestStatus();
      this.phase = s.phase || 'idle';
      this.progress = s.progress || 0;
      this.partial = s.partial || {};
      this.results = s.results || null;
      this.error = s.error || '';

      if (this.phase === 'done') {
        this.status = 'done';
        this._stopPolling();
      } else if (this.phase === 'error') {
        this.status = 'error';
        this._stopPolling();
      } else if (this.phase === 'cancelled') {
        this.status = 'cancelled';
        this._stopPolling();
      } else if (this.phase === 'idle') {
        this.status = 'idle';
        this._stopPolling();
      } else {
        this.status = 'running';
      }
    } catch (e) {
      this.error = e.message || 'Failed to read speed-test status';
      this.status = 'error';
      this._stopPolling();
    }
  }

  async _run() {
    this.error = '';
    this.results = null;
    this.partial = {};
    this.status = 'running';
    this.phase = 'starting';
    this.progress = 0;
    try {
      await startSpeedTest();
      this._startPolling();
    } catch (e) {
      this.status = 'error';
      this.error = e.message || 'Failed to start speed test';
    }
  }

  async _cancel() {
    try {
      await cancelSpeedTest();
    } catch (e) {
      /* the next status poll will reflect either cancellation or completion */
    }
  }

  // --- formatting helpers ------------------------------------------------

  _phaseLabel(phase) {
    switch (phase) {
      case 'starting':            return 'Starting…';
      case 'latency_idle':        return 'Measuring idle latency';
      case 'download':            return 'Measuring download speed';
      case 'latency_loaded_down': return 'Measuring latency under download (bufferbloat)';
      case 'upload':              return 'Measuring upload speed';
      case 'latency_loaded_up':   return 'Measuring latency under upload (bufferbloat)';
      case 'done':                return 'Complete';
      case 'cancelled':           return 'Cancelled';
      case 'error':               return 'Error';
      default:                    return phase || '';
    }
  }

  _gradeClass(grade) {
    if (!grade) return '';
    if (grade === 'A+' || grade === 'A') return 'ok';
    if (grade === 'B' || grade === 'C') return 'warn';
    return 'err';
  }

  _fmtMs(v) {
    if (v == null || Number.isNaN(v)) return '—';
    return `${v.toFixed(1)} ms`;
  }

  _fmtMbps(v) {
    if (v == null || Number.isNaN(v)) return '—';
    return v.toFixed(1);
  }

  render() {
    const live = (() => {
      // Prefer final results when present; fall back to partial values
      // that have already been filled in by completed phases.
      if (this.results) return this.results;
      const p = this.partial || {};
      return {
        download_mbps: p.download_mbps,
        upload_mbps: p.upload_mbps,
        latency: p.latency || {},
        bufferbloat: null,
        server: p.server,
      };
    })();

    const running = this.status === 'running';
    const grade = live.bufferbloat?.grade;
    const gradeClass = this._gradeClass(grade);

    return html`
      <div class="module-container">
        <h2>Speed Test</h2>
        <div class="intro">
          Measures your WAN connection from the HomeFree box itself
          against Cloudflare's edge — so the result reflects your home's
          actual internet link, not the device you're using to view this
          page. Takes 30–45 seconds and uses real bandwidth, so other
          household traffic may briefly slow down while it runs.
        </div>

        <div class="controls">
          ${running
            ? html`<button class="danger" @click=${this._cancel}>Cancel</button>`
            : html`<button class="primary" @click=${this._run}>
                ${this.results || this.status === 'cancelled' || this.status === 'error'
                  ? 'Run Again'
                  : 'Run Speed Test'}
              </button>`
          }
        </div>

        ${this.error && this.status === 'error'
          ? html`<div class="error-message">Speed test failed: ${this.error}</div>`
          : ''
        }

        ${running
          ? html`
            <div class="progress">
              <div class="progress-label">
                <span>${this._phaseLabel(this.phase)}</span>
                <span>${this.progress}%</span>
              </div>
              <div class="meter">
                <div class="meter-fill" style="width: ${this.progress}%"></div>
              </div>
            </div>
          `
          : ''
        }

        <div class="summary-cards">
          <div class="card">
            <div class="card-label">Download</div>
            <div class="card-value">
              ${this._fmtMbps(live.download_mbps)}<span class="card-unit">Mbps</span>
            </div>
            <div class="card-sub">${live.download_mbps != null ? 'from Cloudflare' : 'awaiting test'}</div>
          </div>
          <div class="card">
            <div class="card-label">Upload</div>
            <div class="card-value">
              ${this._fmtMbps(live.upload_mbps)}<span class="card-unit">Mbps</span>
            </div>
            <div class="card-sub">${live.upload_mbps != null ? 'to Cloudflare' : 'awaiting test'}</div>
          </div>
          <div class="card">
            <div class="card-label">Bufferbloat</div>
            <div class="card-value ${gradeClass}">${grade || '—'}</div>
            <div class="card-sub">
              ${live.bufferbloat?.added_ms != null
                ? html`+${live.bufferbloat.added_ms.toFixed(1)} ms under load`
                : 'awaiting test'}
            </div>
          </div>
        </div>

        <div class="panel">
          <div class="panel-title">Latency detail</div>
          <table>
            <tbody>
              <tr>
                <td>Idle latency</td>
                <td class="num">${this._fmtMs(live.latency?.idle_ms)}</td>
              </tr>
              <tr>
                <td>Jitter (idle IQR)</td>
                <td class="num">${this._fmtMs(live.latency?.jitter_ms)}</td>
              </tr>
              <tr>
                <td>Latency under download load</td>
                <td class="num">${this._fmtMs(live.latency?.loaded_down_ms)}</td>
              </tr>
              <tr>
                <td>Latency under upload load</td>
                <td class="num">${this._fmtMs(live.latency?.loaded_up_ms)}</td>
              </tr>
            </tbody>
          </table>
        </div>

        ${this._renderStreamDiag('Download streams', this.partial?.download_streams)}
        ${this._renderStreamDiag('Upload streams', this.partial?.upload_streams)}

        ${live.server
          ? html`
            <div class="panel">
              <div class="panel-title">Test server</div>
              <table>
                <tbody>
                  <tr>
                    <td>Cloudflare edge</td>
                    <td class="num">
                      ${live.server.city || 'unknown'}${live.server.iata ? ` (${live.server.iata})` : ''}
                    </td>
                  </tr>
                  ${live.server.ip
                    ? html`<tr><td>Your public IP (as seen)</td><td class="num">${live.server.ip}</td></tr>`
                    : ''}
                </tbody>
              </table>
            </div>
          `
          : ''}
      </div>
    `;
  }

  // Per-stream diagnostics — only shown when at least one worker errored.
  // On a clean run this panel is hidden; on a partial/total failure it
  // surfaces the HTTP status and exception message that caused it.
  _renderStreamDiag(title, d) {
    if (!d || !d.per_stream || !d.per_stream.length) return '';
    if (!d.errors_total) return '';
    const fmtBytes = (n) => {
      if (n == null) return '—';
      const u = ['B', 'KB', 'MB', 'GB'];
      let i = 0; let v = n;
      while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
      return `${v.toFixed(v >= 100 || i === 0 ? 0 : 1)} ${u[i]}`;
    };
    return html`
      <div class="panel">
        <div class="panel-title">
          ${title} — ${d.streams} workers, ${fmtBytes(d.bytes_total)} total,
          ${d.errors_total} error${d.errors_total === 1 ? '' : 's'}
        </div>
        <table>
          <thead>
            <tr>
              <th>#</th>
              <th class="num">Bytes</th>
              <th class="num">Errors</th>
              <th class="num">Last status</th>
              <th>Last error</th>
            </tr>
          </thead>
          <tbody>
            ${d.per_stream.map((s, i) => html`
              <tr>
                <td>${i}</td>
                <td class="num">${fmtBytes(s.bytes)}</td>
                <td class="num">${s.errors}</td>
                <td class="num">${s.last_status ?? '—'}</td>
                <td>${s.last_error || '—'}</td>
              </tr>
            `)}
          </tbody>
        </table>
      </div>
    `;
  }
}

customElements.define('speed-test-module', SpeedTestModule);
