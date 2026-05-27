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
    _sources: { state: true },
    _history: { state: true },
    _loading: { state: true },
    _ntfyInfo: { state: true },
    _testing: { state: true },
    _testResult: { state: true },
  };

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
    }
    .state-badge.firing {
      background: var(--hf-err-soft, #fde7e7);
      color: var(--hf-err, #c62828);
    }
    .state-badge.clear {
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
    .source-header {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 12px;
      margin-bottom: 14px;
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
  `;

  constructor() {
    super();
    this.config = {};
    this.appliedConfig = null;
    this.undeployedPaths = new Set();
    this._sources = [];
    this._history = [];
    this._loading = true;
    this._ntfyInfo = null;
    this._testing = false;
    this._testResult = null; // { ok: bool, message: str }
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
  }

  async _loadState() {
    this._loading = true;
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
      this._loading = false;
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

  _renderSourceRow(src) {
    const cfg = (this.config?.alerts?.sources && this.config.alerts.sources[src.id]) || {};
    const state = src.state || {};
    const firing = state.firing === true;
    // Precompute the dotted paths used inside the template so we
    // never construct a backtick string literal there (Lit gotcha).
    const cfgPathPrefix = 'sources.' + src.id + '.';
    const tagPathPrefix = 'alerts.sources.' + src.id + '.';

    const enableVal = cfg.enable !== false; // defaults to true for known sources
    const cfgHysteresis = (cfg['hysteresis-c'] !== undefined) ? cfg['hysteresis-c'] : 4;

    const peakSuffix = (firing && state.peak_value != null)
      ? ' — peak ' + Math.round(state.peak_value) + '°C'
      : '';

    return html`
      <div class="source-row">
        <div class="source-header">
          <div>
            <div class="source-title">${src.label}</div>
            ${state.message ? html`<div class="source-message">${state.message}</div>` : ''}
          </div>
          <span class="state-badge ${firing ? 'firing' : 'clear'}">
            ${firing ? 'FIRING' : 'OK'}${peakSuffix}
          </span>
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
  // down) return null and just render the enable toggle above.
  _renderSourceFields(src, cfg, cfgPathPrefix, tagPathPrefix, cfgHysteresis) {
    switch (src.id) {
      case 'disk-temperature':
        return this._renderDiskTempFields(cfg, cfgPathPrefix, tagPathPrefix, cfgHysteresis);
      case 'disk-space':
        return this._renderDiskSpaceFields(cfg, cfgPathPrefix, tagPathPrefix);
      case 'sensor-temperature':
        return this._renderSensorTempFields(cfg, cfgPathPrefix, tagPathPrefix, cfgHysteresis);
      case 'smart':
      case 'services-down':
        // No further config for v1 — just enable + (implicit) channels.
        return '';
      default:
        return '';
    }
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

  _renderSensorTempFields(cfg, cfgPathPrefix, tagPathPrefix, cfgHysteresis) {
    const t = cfg.thresholds || {};
    const cpu  = (t['cpu-c']  !== undefined) ? t['cpu-c']  : 80;
    const nvme = (t['nvme-c'] !== undefined) ? t['nvme-c'] : 70;
    const gpu  = (t['gpu-c']  !== undefined) ? t['gpu-c']  : 80;
    const pCpu  = cfgPathPrefix + 'thresholds.cpu-c';
    const pNvme = cfgPathPrefix + 'thresholds.nvme-c';
    const pGpu  = cfgPathPrefix + 'thresholds.gpu-c';
    const tCpu  = tagPathPrefix + 'thresholds.cpu-c';
    const tNvme = tagPathPrefix + 'thresholds.nvme-c';
    const tGpu  = tagPathPrefix + 'thresholds.gpu-c';
    const pHys = cfgPathPrefix + 'hysteresis-c';
    const tHys = tagPathPrefix + 'hysteresis-c';
    return html`
      <div class="hint" style="margin: 0 0 10px 0">
        Per-silicon-class thresholds for CPU / NVMe controller / GPU
        sensors from hwmon (same sensors shown on the Hardware page).
        The NVMe controller temperature is distinct from the NVMe
        media temperature monitored under Disk temperature.
      </div>
      <div class="field-grid">
        <form-field
          label="CPU threshold (°C)"
          type="number"
          .value=${cpu}
          help="Fire when any CPU sensor reaches this temperature."
          ?undeployed=${this._undeployed(tCpu)}
          @field-change=${(e) => this._setField(pCpu, parseInt(e.detail.value, 10) || 80)}
        ></form-field>
        <form-field
          label="NVMe controller threshold (°C)"
          type="number"
          .value=${nvme}
          help="Fire when any NVMe controller sensor reaches this temperature."
          ?undeployed=${this._undeployed(tNvme)}
          @field-change=${(e) => this._setField(pNvme, parseInt(e.detail.value, 10) || 70)}
        ></form-field>
        <form-field
          label="GPU threshold (°C)"
          type="number"
          .value=${gpu}
          help="Fire when any GPU sensor reaches this temperature."
          ?undeployed=${this._undeployed(tGpu)}
          @field-change=${(e) => this._setField(pGpu, parseInt(e.detail.value, 10) || 80)}
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
    const t = cfg.thresholds || {};
    const hdd  = (t['hdd-c']  !== undefined) ? t['hdd-c']  : 45;
    const ssd  = (t['ssd-c']  !== undefined) ? t['ssd-c']  : 60;
    const nvme = (t['nvme-c'] !== undefined) ? t['nvme-c'] : 70;
    // Path strings precomputed — see Lit gotcha note at the top.
    const pHdd  = cfgPathPrefix + 'thresholds.hdd-c';
    const pSsd  = cfgPathPrefix + 'thresholds.ssd-c';
    const pNvme = cfgPathPrefix + 'thresholds.nvme-c';
    const tHdd  = tagPathPrefix + 'thresholds.hdd-c';
    const tSsd  = tagPathPrefix + 'thresholds.ssd-c';
    const tNvme = tagPathPrefix + 'thresholds.nvme-c';
    const pHys  = cfgPathPrefix + 'hysteresis-c';
    const tHys  = tagPathPrefix + 'hysteresis-c';
    return html`
      <div class="hint" style="margin: 0 0 10px 0">
        Per-class thresholds: spinning platters fail earlier than flash,
        so each drive class has its own warn level. Defaults match the
        Hardware page's warn colour.
      </div>
      <div class="field-grid">
        <form-field
          label="HDD threshold (°C)"
          type="number"
          .value=${hdd}
          help="Fire when any platter drive reaches this temperature."
          ?undeployed=${this._undeployed(tHdd)}
          @field-change=${(e) => this._setField(pHdd, parseInt(e.detail.value, 10) || 45)}
        ></form-field>
        <form-field
          label="SSD threshold (°C)"
          type="number"
          .value=${ssd}
          help="Fire when any SATA SSD reaches this temperature."
          ?undeployed=${this._undeployed(tSsd)}
          @field-change=${(e) => this._setField(pSsd, parseInt(e.detail.value, 10) || 60)}
        ></form-field>
        <form-field
          label="NVMe threshold (°C)"
          type="number"
          .value=${nvme}
          help="Fire when any NVMe drive reaches this temperature."
          ?undeployed=${this._undeployed(tNvme)}
          @field-change=${(e) => this._setField(pNvme, parseInt(e.detail.value, 10) || 70)}
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

  render() {
    const alerts = this.config?.alerts || {};
    const ntfy = (alerts.channels && alerts.channels.ntfy) || {};
    const masterOff = alerts.enable !== true;
    return html`
      <div class="module-container">
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
              Changes on this page are saved, but nothing fires until the
              engine is enabled — no sources are evaluated and no
              notifications are sent.
            </div>
            <button class="btn btn-action btn-sm"
                    @click=${() => this._setField('enable', true)}>
              Enable now
            </button>
          </div>
        ` : ''}

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
            : this._sources.map((s) => this._renderSourceRow(s))}
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
                    <th>Opened</th>
                    <th>Closed</th>
                    <th>Peak</th>
                    <th>Message</th>
                  </tr>
                </thead>
                <tbody>
                  ${this._history.map((ev) => html`
                    <tr>
                      <td>${this._friendlySourceId(ev.source_id)}</td>
                      <td>${this._fmtTime(ev.started_ts)}</td>
                      <td>${ev.ended_ts
                        ? this._fmtTime(ev.ended_ts)
                        : html`<span class="state-badge firing">open</span>`}</td>
                      <td>${ev.peak_value != null ? Math.round(ev.peak_value) : '—'}</td>
                      <td class="history-msg">${ev.close_message || ev.open_message || ''}</td>
                    </tr>
                  `)}
                </tbody>
              </table>
            `}
        </config-section>
      </div>
    `;
  }
}

customElements.define('alerts-module', AlertsModule);
