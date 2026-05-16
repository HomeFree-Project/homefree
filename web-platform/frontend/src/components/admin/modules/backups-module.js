import { LitElement, html, css } from 'lit';
import '../../shared/config-section.js';
import '../../shared/form-field.js';
import '../../shared/list-input.js';
import '../../shared/progress-modal.js';
import '../secrets-input.js';

/**
 * Backups configuration module.
 *
 * Handles local backups, Backblaze B2 cloud backups, and restore
 * operations. Long-running operations (restore, restore-all, trigger,
 * sync) are modelled as backend "jobs": the module kicks one off, then
 * a single poller watches /api/backups/jobs/current and tails the job
 * log, rendering a live progress overlay with a per-repository
 * checklist. The Restore tab renders its repository list immediately;
 * per-repository paths and snapshots load lazily on demand.
 */
class BackupsModule extends LitElement {
  static properties = {
    config: { type: Object },
    modified: { type: Boolean },
    activeTab: { type: String },
    secretsStatus: { type: Object },
    backupConfigStatus: { type: Object },
    hasAuthorizedKeys: { type: Boolean },

    // Backup canary self-test status
    canaryStatus: { type: Object },
    canaryStarting: { type: Boolean },

    // Scheduled-backup health (last run + success per source)
    backupHealth: { type: Object },

    // Restore tab repository lists
    localServices: { type: Array },
    localSystemConfig: { type: Array },
    localExtraPaths: { type: Array },
    backblazeServices: { type: Array },
    backblazeSystemConfig: { type: Array },
    backblazeExtraPaths: { type: Array },
    repoListLoading: { type: Boolean },
    repoListError: { type: String },
    lastServicesRefresh: { type: Number },

    // Per-repository backup-root paths, keyed "source:repo".
    // Filled progressively by a background warm; pathsReady flips true
    // when every repo is resolved. pathsProgress drives a progress bar.
    repositoryPaths: { type: Object },
    pathsReady: { type: Boolean },
    pathsProgress: { type: Object },

    // Snapshot picker (expanded repo)
    expandedRepo: { type: String },     // repo name currently expanded
    expandedSource: { type: String },   // 'local' | 'backblaze' shown in card
    snapshots: { type: Array },
    snapshotsLoading: { type: Boolean },
    selectedSnapshot: { type: String },

    includeSystemConfig: { type: Boolean },

    // The single active backend job, polled live
    currentJob: { type: Object },
    jobLog: { type: String },
    jobOverlayOpen: { type: Boolean }
  };

  static styles = css`
    :host { display: block; }

    .module-container { width: 100%; }

    /* ---- tabs ---- */
    .tabs {
      display: flex;
      gap: 8px;
      margin-bottom: 24px;
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
    }
    .tab:hover { color: var(--hf-text); }
    .tab.active {
      color: var(--hf-accent);
      border-bottom-color: var(--hf-accent);
    }

    /* ---- generic boxes ---- */
    .info-box {
      background: var(--hf-accent-soft);
      border-left: 4px solid var(--hf-accent);
      padding: 16px;
      border-radius: 8px;
      margin-bottom: 20px;
      color: var(--hf-accent);
      font-size: 14px;
    }
    .info-box strong { display: block; margin-bottom: 8px; }
    .info-box ul { margin: 8px 0 0 20px; padding: 0; }

    .warn-box {
      background: rgba(245, 158, 11, 0.1);
      border-left: 4px solid var(--hf-warn);
      color: var(--hf-warn);
    }

    .status-line {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 10px 14px;
      border-radius: 8px;
      font-size: 14px;
      margin-bottom: 16px;
    }
    .status-line.ok  { background: rgba(16,185,129,.12); color: var(--hf-ok); }
    .status-line.err { background: rgba(239,68,68,.10);  color: var(--hf-err); }
    .status-line.muted {
      background: var(--hf-surface-2); color: var(--hf-text-muted);
    }

    /* Backup Health rows */
    .health-row {
      padding: 12px 14px;
      border-radius: 8px;
      background: var(--hf-surface-2);
      border-left: 4px solid var(--hf-border-2);
      margin-bottom: 10px;
    }
    .health-row:last-child { margin-bottom: 0; }
    .health-row.ok  { border-left-color: var(--hf-ok); }
    .health-row.err { border-left-color: var(--hf-err); }
    .health-name {
      font-weight: 600;
      font-size: 14px;
      display: flex;
      align-items: center;
      gap: 10px;
    }
    .health-detail {
      font-size: 13px;
      color: var(--hf-text-muted);
      margin-top: 3px;
    }
    .health-failed {
      font-size: 13px;
      color: var(--hf-err);
      margin-top: 6px;
      word-break: break-word;
    }
    .health-badge {
      font-size: 12px;
      font-weight: 600;
      padding: 2px 8px;
      border-radius: 999px;
    }
    .health-badge.ok  {
      background: rgba(16,185,129,.15); color: var(--hf-ok);
    }
    .health-badge.err {
      background: rgba(239,68,68,.15); color: var(--hf-err);
    }

    /* Self-test status row: fixed minimum height and an always-present
       detail line, so the section does not jump as state changes. */
    .selftest-status {
      min-height: 54px;
      box-sizing: border-box;
    }
    .selftest-detail {
      font-size: 13px;
      margin-top: 2px;
      min-height: 1.2em;   /* reserve space even when empty */
    }

    /* ---- buttons ---- */
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
    }
    .btn:disabled { opacity: 0.5; cursor: not-allowed; }
    .btn-primary   { background: var(--hf-accent); color: var(--hf-text); }
    .btn-primary:hover:not(:disabled) { background: var(--hf-accent-hover); }
    .btn-secondary {
      background: var(--hf-surface-2);
      color: var(--hf-text);
      border: 1px solid var(--hf-border-2);
    }
    .btn-secondary:hover:not(:disabled) { background: var(--hf-surface-3); }
    .btn-danger  { background: var(--hf-err); color: #fff; }
    .btn-danger:hover:not(:disabled) { background: #dc2626; }
    .btn-row { display: flex; gap: 12px; flex-wrap: wrap; margin-top: 16px; }

    .spinner {
      display: inline-block;
      width: 14px; height: 14px;
      border: 2px solid currentColor;
      border-top-color: transparent;
      border-radius: 50%;
      animation: spin 1s linear infinite;
      flex-shrink: 0;
    }
    .spinner.lg { width: 18px; height: 18px; }
    @keyframes spin { to { transform: rotate(360deg); } }

    /* ---- active-job banner ---- */
    .job-banner {
      display: flex;
      align-items: center;
      gap: 12px;
      padding: 14px 16px;
      border-radius: 8px;
      margin-bottom: 20px;
      cursor: pointer;
      border-left: 4px solid var(--hf-accent);
      background: var(--hf-accent-soft);
      color: var(--hf-accent);
    }
    .job-banner.restore { border-left-color: var(--hf-warn);
      background: rgba(245,158,11,.1); color: var(--hf-warn); }
    .job-banner.done { border-left-color: var(--hf-ok);
      background: rgba(16,185,129,.12); color: var(--hf-ok); }
    .job-banner.failed { border-left-color: var(--hf-err);
      background: rgba(239,68,68,.10); color: var(--hf-err); }
    .job-banner .grow { flex: 1; }
    .job-banner .title { font-weight: 600; }
    .job-banner .sub { font-size: 13px; opacity: 0.9; }
    .job-banner .view { font-size: 13px; text-decoration: underline; }

    /* ---- repository list ---- */
    .repo-group {
      margin-bottom: 24px;
      padding: 16px;
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
    }
    .repo-group.system {
      border: 2px solid var(--hf-warn);
      background: rgba(245,158,11,.06);
    }
    .repo-group h4 {
      font-size: 15px; font-weight: 600; margin: 0 0 4px 0;
    }
    .repo-group .desc {
      font-size: 13px; color: var(--hf-text-muted); margin: 0 0 12px 0;
    }
    .repo-list { display: grid; gap: 8px; }

    .repo-row {
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      overflow: hidden;
    }
    .repo-head {
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 12px 14px;
      cursor: pointer;
      background: var(--hf-surface-2);
      transition: background 0.15s;
    }
    .repo-head:hover { background: var(--hf-surface-3); }
    .repo-head.disabled { cursor: not-allowed; opacity: 0.6; }
    .repo-head .grow { flex: 1; min-width: 0; }
    .repo-name { font-weight: 600; word-break: break-all; }

    /* skeleton placeholders shown while the batch path load resolves */
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
    @keyframes shimmer {
      from { background-position: 100% 0; }
      to   { background-position: 0 0; }
    }
    .repo-tag {
      font-size: 11px;
      padding: 2px 6px;
      border-radius: 4px;
      background: var(--hf-surface-3);
      color: var(--hf-text-muted);
    }
    .repo-tag.bb { background: var(--hf-accent-soft); color: var(--hf-accent); }
    .repo-paths {
      font-size: 12px;
      color: var(--hf-text-muted);
      margin-top: 4px;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .chevron { transition: transform 0.15s; color: var(--hf-text-muted); }
    .chevron.open { transform: rotate(90deg); }

    .repo-body {
      padding: 14px;
      border-top: 1px solid var(--hf-border);
      background: var(--hf-surface);
    }

    /* ---- source toggle (Local / Backblaze) inside an expanded card ---- */
    .source-toggle {
      display: inline-flex;
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      overflow: hidden;
      margin-bottom: 14px;
    }
    .source-toggle-btn {
      padding: 7px 16px;
      background: var(--hf-surface-2);
      border: none;
      border-right: 1px solid var(--hf-border-2);
      font-size: 13px;
      font-weight: 500;
      color: var(--hf-text-muted);
      cursor: pointer;
      transition: background 0.15s, color 0.15s;
    }
    .source-toggle-btn:last-child { border-right: none; }
    .source-toggle-btn:hover { color: var(--hf-text); }
    .source-toggle-btn.active {
      background: var(--hf-accent);
      color: #fff;
    }

    /* ---- snapshot list ---- */
    .snapshots {
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      max-height: 320px;
      overflow-y: auto;
      margin-bottom: 12px;
    }
    .snapshot {
      padding: 10px 14px;
      border-bottom: 1px solid var(--hf-border);
      cursor: pointer;
      transition: background 0.15s;
    }
    .snapshot:last-child { border-bottom: none; }
    .snapshot:hover { background: var(--hf-surface-2); }
    .snapshot.selected {
      background: var(--hf-accent-soft);
      border-left: 4px solid var(--hf-accent);
    }
    .snapshot .time { font-size: 14px; font-weight: 500; }
    .snapshot .meta {
      font-family: monospace; font-size: 12px; color: var(--hf-text-muted);
    }

    .restore-targets {
      background: rgba(245, 158, 11, 0.08);
      border: 1px solid var(--hf-warn);
      border-radius: 8px;
      padding: 10px 14px;
      margin-bottom: 12px;
    }
    .restore-targets-label {
      font-size: 13px;
      font-weight: 600;
      color: var(--hf-warn);
      margin-bottom: 6px;
    }
    .restore-targets ul {
      margin: 0;
      padding-left: 18px;
    }
    .restore-targets li {
      font-size: 13px;
      color: var(--hf-text);
      word-break: break-all;
    }

    /* ---- job progress overlay ---- */
    .overlay {
      position: fixed;
      inset: 0;
      background: rgba(0,0,0,.7);
      backdrop-filter: blur(4px);
      display: flex;
      align-items: center;
      justify-content: center;
      z-index: 10000;
    }
    .job-panel {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border);
      border-radius: 12px;
      width: 90%;
      max-width: 680px;
      max-height: 85vh;
      display: flex;
      flex-direction: column;
      box-shadow: var(--hf-shadow-lg);
      color: var(--hf-text);
    }
    .job-panel-head {
      padding: 20px 24px;
      border-bottom: 1px solid var(--hf-border);
      display: flex;
      align-items: center;
      gap: 12px;
    }
    .job-panel-head .title { font-size: 18px; font-weight: 600; flex: 1; }
    .job-panel-body { padding: 20px 24px; overflow-y: auto; }
    .job-panel-foot {
      padding: 16px 24px;
      border-top: 1px solid var(--hf-border);
      display: flex;
      justify-content: space-between;
      align-items: center;
    }
    .job-summary { font-size: 14px; color: var(--hf-text-muted); }

    .repo-progress { display: grid; gap: 4px; margin-bottom: 16px; }
    .progress-row {
      display: flex;
      align-items: center;
      gap: 8px;
      font-size: 13px;
      padding: 4px 0;
    }
    .progress-row .ico { width: 16px; text-align: center; flex-shrink: 0; }
    .progress-row.pending { color: var(--hf-text-subtle); }
    .progress-row.running { color: var(--hf-accent); font-weight: 600; }
    .progress-row.done    { color: var(--hf-ok); }
    .progress-row.failed  { color: var(--hf-err); }
    .progress-row .err {
      font-size: 12px; color: var(--hf-err); margin-left: auto;
    }

    .log-view {
      background: #0b0e14;
      color: #c9d1d9;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 12px;
      line-height: 1.5;
      padding: 12px;
      border-radius: 8px;
      max-height: 280px;
      overflow-y: auto;
      white-space: pre-wrap;
      word-break: break-word;
    }
    .progress-bar {
      height: 6px;
      background: var(--hf-surface-3);
      border-radius: 3px;
      overflow: hidden;
      margin: 8px 0 16px;
    }
    .progress-bar > div {
      height: 100%;
      background: var(--hf-accent);
      transition: width 0.3s;
    }

    /* path-warm progress indicator above the repository list */
    .paths-progress {
      background: var(--hf-surface-2);
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      padding: 12px 14px;
      margin-bottom: 16px;
    }
    .paths-progress-head {
      display: flex;
      align-items: center;
      gap: 8px;
      font-size: 14px;
      color: var(--hf-text-muted);
    }
    .paths-progress-head strong { color: var(--hf-text); }
    .paths-progress-pct {
      margin-left: auto;
      font-variant-numeric: tabular-nums;
      font-weight: 600;
      color: var(--hf-accent);
    }
    .paths-progress .progress-bar { margin: 10px 0 0; }

    /* ---- type-to-confirm ---- */
    .confirm-input {
      width: 100%;
      padding: 10px 12px;
      font-size: 14px;
      font-family: monospace;
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      background: var(--hf-surface);
      color: var(--hf-text);
      margin-top: 8px;
      box-sizing: border-box;
    }

    @media (max-width: 768px) {
      .tab { padding: 10px 14px; font-size: 14px; }
      .job-panel { width: 96%; }
    }
  `;

  /** Repos the restore worker stops backup timers for; sentinel for "type to confirm". */
  static RESTORE_ALL_CONFIRM = 'RESTORE';

  constructor() {
    super();
    this.config = {
      backups: {
        enable: false,
        'to-path': '',
        'extra-from-paths': [],
        'backblaze-enable': false,
        'backblaze-bucket': ''
      }
    };
    this.modified = false;
    this.activeTab = 'status';
    this.secretsStatus = null;
    this.backupConfigStatus = null;
    this.hasAuthorizedKeys = false;
    this.canaryStatus = null;
    this.canaryStarting = false;
    this.backupHealth = null;

    this.localServices = [];
    this.localSystemConfig = [];
    this.localExtraPaths = [];
    this.backblazeServices = [];
    this.backblazeSystemConfig = [];
    this.backblazeExtraPaths = [];
    this.repoListLoading = false;
    this.repoListError = '';
    this.lastServicesRefresh = null;

    this.repositoryPaths = {};
    this.pathsReady = false;
    this.pathsProgress = { done: 0, total: 0, state: 'idle' };

    this.expandedRepo = null;
    this.expandedSource = null;
    this.snapshots = [];
    this.snapshotsLoading = false;
    this.selectedSnapshot = null;

    this.includeSystemConfig = false;

    this.currentJob = null;
    this.jobLog = '';
    this.jobOverlayOpen = false;

    // internal (non-reactive)
    this._jobPollTimer = null;
    this._pathsPollTimer = null;
    this._canaryPollTimer = null;
    this._jobLogOffset = 0;
    this._restoreAllConfirmText = '';
    this._servicesLoadedOnce = false;
  }

  // ----------------------------------------------------------- lifecycle

  async connectedCallback() {
    super.connectedCallback();
    // Stop polling before navigation to avoid leaking connections.
    this._beforeUnload = () => this.stopJobPolling();
    window.addEventListener('beforeunload', this._beforeUnload);

    await Promise.all([
      this.loadSecretsStatus(),
      this.loadBackupConfigStatus(),
      this.loadCanaryStatus(),
      this.loadBackupHealth(),
      this.refreshCurrentJob()
    ]);
    // If a job is already running, attach the live poller.
    if (this.isJobActive(this.currentJob)) {
      this.startJobPolling();
    }
    // If a self-test is running, poll until it finishes.
    if (this.canaryStatus?.running) {
      this.startCanaryPolling();
    }
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this._beforeUnload) {
      window.removeEventListener('beforeunload', this._beforeUnload);
    }
    this.stopJobPolling();
    this.stopCanaryPolling();
    if (this._pathsPollTimer) {
      clearTimeout(this._pathsPollTimer);
      this._pathsPollTimer = null;
    }
  }

  // ----------------------------------------------------------- job model

  isJobActive(job) {
    return !!job && (job.state === 'queued' || job.state === 'running');
  }

  async refreshCurrentJob() {
    try {
      const res = await fetch('/api/backups/jobs/current');
      if (!res.ok) return;
      const data = await res.json();
      const prev = this.currentJob;
      this.currentJob = data.job || null;

      // A new job appeared or the tracked job changed: reset the log tail.
      if (this.currentJob && (!prev || prev.id !== this.currentJob.id)) {
        this._jobLogOffset = 0;
        this.jobLog = '';
      }
      if (this.currentJob) {
        await this.fetchJobLog(this.currentJob.id);
      }

      // Job just finished: stop polling, refresh derived data.
      if (prev && this.isJobActive(prev) && !this.isJobActive(this.currentJob)) {
        this.onJobFinished(this.currentJob || prev);
      }
    } catch (e) {
      console.error('Error refreshing current job:', e);
    }
  }

  async fetchJobLog(jobId) {
    try {
      const res = await fetch(
        `/api/backups/jobs/${encodeURIComponent(jobId)}/log` +
        `?offset=${this._jobLogOffset}`);
      if (!res.ok) return;
      const data = await res.json();
      if (data.lines) {
        this.jobLog += data.lines;
        this._jobLogOffset = data.offset;
        // Keep the log panel scrolled to the newest output.
        this.updateComplete.then(() => {
          const el = this.renderRoot.querySelector('.log-view');
          if (el) el.scrollTop = el.scrollHeight;
        });
      }
    } catch (e) {
      console.error('Error fetching job log:', e);
    }
  }

  startJobPolling() {
    if (this._jobPollTimer) return;
    this._jobPollTimer = setInterval(() => {
      this.refreshCurrentJob().then(() => {
        if (!this.isJobActive(this.currentJob)) this.stopJobPolling();
      });
    }, 2000);
  }

  stopJobPolling() {
    if (this._jobPollTimer) {
      clearInterval(this._jobPollTimer);
      this._jobPollTimer = null;
    }
  }

  onJobFinished(job) {
    this.stopJobPolling();
    const kind = job?.kind;
    if (job?.state === 'failed') {
      this.showNotification(
        `${this.jobKindLabel(kind)} failed: ${job.error || 'see log'}`,
        'error');
    } else {
      this.showNotification(
        `${this.jobKindLabel(kind)} completed successfully`, 'success');
    }
    // A restore changed on-disk data; refresh repo lists/paths.
    if (kind === 'restore' || kind === 'restore-all') {
      this.loadServices(true);
    }
    // A backup/sync run changes last-run health - refresh the panel.
    if (kind === 'backup' || kind === 'sync') {
      this.loadBackupHealth();
    }
  }

  jobKindLabel(kind) {
    return {
      'restore': 'Restore',
      'restore-all': 'Full-system restore',
      'backup': 'Local backup',
      'sync': 'Backblaze backup'
    }[kind] || 'Operation';
  }

  /**
   * POST a job-starting endpoint, handling the 409 "busy" response.
   * Returns the job object on success, or null (notification shown).
   */
  async startJob(url, body) {
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: body ? JSON.stringify(body) : undefined
      });
      if (res.status === 409) {
        const data = await res.json().catch(() => ({}));
        const detail = data.detail || {};
        this.showNotification(
          detail.message ||
          'The backup subsystem is busy. Try again once it is idle.',
          'error');
        // Refresh so the banner reflects whatever is actually running.
        await this.refreshCurrentJob();
        if (this.isJobActive(this.currentJob)) this.startJobPolling();
        return null;
      }
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        this.showNotification(
          `Failed to start: ${this.describeError(data.detail)}`, 'error');
        return null;
      }
      const data = await res.json();
      this.currentJob = data.job || null;
      this._jobLogOffset = 0;
      this.jobLog = '';
      this.jobOverlayOpen = true;
      this.startJobPolling();
      return data.job;
    } catch (e) {
      console.error('Error starting job:', e);
      this.showNotification(`Error: ${e.message}`, 'error');
      return null;
    }
  }

  describeError(detail) {
    if (!detail) return 'Unknown error';
    if (typeof detail === 'string') return detail;
    return detail.message || detail.error || JSON.stringify(detail);
  }

  // -------------------------------------------------------- data loading

  async loadSecretsStatus() {
    try {
      const res = await fetch('/api/secrets/status');
      if (res.ok) {
        const data = await res.json();
        this.secretsStatus = data.secrets?.backup || {};
      }
    } catch (e) {
      console.error('Error loading secrets status:', e);
    }
  }

  async loadBackupConfigStatus() {
    try {
      const res = await fetch('/api/backups/config/status');
      if (res.ok) this.backupConfigStatus = await res.json();
    } catch (e) {
      console.error('Error loading backup config status:', e);
    }
  }

  async loadCanaryStatus() {
    try {
      const res = await fetch('/api/backups/canary');
      if (res.ok) this.canaryStatus = await res.json();
    } catch (e) {
      console.error('Error loading canary status:', e);
    }
  }

  async loadBackupHealth() {
    try {
      const res = await fetch('/api/backups/health');
      if (res.ok) this.backupHealth = await res.json();
    } catch (e) {
      console.error('Error loading backup health:', e);
    }
  }

  startCanaryPolling() {
    if (this._canaryPollTimer) return;
    this._canaryPollTimer = setInterval(async () => {
      await this.loadCanaryStatus();
      if (!this.canaryStatus?.running) this.stopCanaryPolling();
    }, 3000);
  }

  stopCanaryPolling() {
    if (this._canaryPollTimer) {
      clearInterval(this._canaryPollTimer);
      this._canaryPollTimer = null;
    }
  }

  /** Start an on-demand backup self-test via the canary. */
  async handleRunCanary() {
    this.canaryStarting = true;
    try {
      const res = await fetch('/api/backups/canary/run', { method: 'POST' });
      if (res.ok) {
        this.showNotification(
          'Backup self-test started — this runs a real backup and '
          + 'restore of the test data and may take a few minutes.', 'info');
        await this.loadCanaryStatus();
        this.startCanaryPolling();
      } else {
        const data = await res.json().catch(() => ({}));
        this.showNotification(
          `Could not start self-test: ${this.describeError(data.detail)}`,
          'error');
      }
    } catch (e) {
      console.error('Error running self-test:', e);
      this.showNotification(`Error: ${e.message}`, 'error');
    } finally {
      this.canaryStarting = false;
    }
  }

  /**
   * Load the repository list for the Restore tab. This is cheap (no
   * restic): paths are NOT fetched here - they load lazily per repo.
   */
  async loadServices(force = false) {
    this.repoListLoading = true;
    this.repoListError = '';
    try {
      const forceParam = force ? '&force=true' : '';
      const [localRes, bbRes] = await Promise.all([
        fetch(`/api/backups/services?source=local${forceParam}`),
        fetch(`/api/backups/services?source=backblaze${forceParam}`)
      ]);

      if (localRes.ok) {
        const d = await localRes.json();
        this.localServices = d.services || [];
        this.localSystemConfig = d.system_config || [];
        this.localExtraPaths = d.extra_paths || [];
      } else {
        this.localServices = [];
        this.localSystemConfig = [];
        this.localExtraPaths = [];
      }

      if (bbRes.ok) {
        const d = await bbRes.json();
        this.backblazeServices = d.services || [];
        this.backblazeSystemConfig = d.system_config || [];
        this.backblazeExtraPaths = d.extra_paths || [];
      } else {
        this.backblazeServices = [];
        this.backblazeSystemConfig = [];
        this.backblazeExtraPaths = [];
      }

      if (force) {
        // A forced refresh invalidates cached path summaries too.
        this.repositoryPaths = {};
        this.pathsReady = false;
      }
      this.lastServicesRefresh = Date.now();
      this._servicesLoadedOnce = true;
      // Fill every repo's path summary in one batch call (skeletons
      // show until it resolves). Fire-and-forget.
      this.loadAllPaths(force);
    } catch (e) {
      console.error('Error loading services:', e);
      this.repoListError = e.message || 'Failed to load repositories';
    } finally {
      this.repoListLoading = false;
    }
  }

  /**
   * Fetch backup-root paths for ALL repositories in one request. On a
   * cold cache the backend replies `ready:false` and warms in the
   * background; we poll until it's ready. Repo rows show skeletons
   * meanwhile - never a stale/guessed path.
   */
  async loadAllPaths(force = false, sources = ['local', 'backblaze']) {
    if (this._pathsPollTimer) {
      clearTimeout(this._pathsPollTimer);
      this._pathsPollTimer = null;
    }
    let allReady = true;
    let anyError = false;
    // Aggregate progress across sources, for a single progress bar.
    let aggDone = 0, aggTotal = 0;
    try {
      for (const source of sources) {
        const forceParam = force ? '&force=true' : '';
        const res = await fetch(
          `/api/backups/paths?source=${source}${forceParam}`);
        if (!res.ok) { allReady = false; anyError = true; continue; }
        const data = await res.json();

        // Merge whatever paths are resolved so far - rows fill in
        // progressively as the warm streams repos in.
        if (data.paths) {
          const merged = { ...this.repositoryPaths };
          for (const [repo, paths] of Object.entries(data.paths)) {
            merged[`${source}:${repo}`] = paths || [];
          }
          this.repositoryPaths = merged;
        }

        const p = data.progress || {};
        aggDone += p.done || 0;
        aggTotal += p.total || 0;
        if (p.state === 'error') anyError = true;
        if (!data.ready) allReady = false;
      }
    } catch (e) {
      console.error('Error loading all paths:', e);
      allReady = false;
      anyError = true;
    }

    this.pathsReady = allReady;
    this.pathsProgress = {
      done: aggDone,
      total: aggTotal,
      state: anyError ? 'error' : (allReady ? 'ready' : 'running')
    };

    if (!allReady && !anyError) {
      // Keep polling while the warm streams; 1.5s keeps the bar lively.
      this._pathsPollTimer = setTimeout(
        () => this.loadAllPaths(false, sources), 1500);
    }
  }

  async loadSnapshots(repo, source) {
    this.snapshotsLoading = true;
    this.snapshots = [];
    this.selectedSnapshot = null;
    try {
      const res = await fetch(
        `/api/backups/services/${encodeURIComponent(repo)}` +
        `/snapshots?source=${source}`);
      if (res.ok) {
        const data = await res.json();
        // restic returns oldest-first; show newest first.
        this.snapshots = (data.snapshots || []).slice().reverse();
        if (this.snapshots.length > 0) {
          this.selectedSnapshot = this.snapshots[0].id;
        }
      }
    } catch (e) {
      console.error('Error loading snapshots:', e);
    } finally {
      this.snapshotsLoading = false;
    }
  }

  // --------------------------------------------------------- interaction

  async handleTabChange(tab) {
    this.activeTab = tab;
    if (tab === 'restore' && !this._servicesLoadedOnce) {
      // Fire-and-forget: the tab renders immediately, the list fills in.
      this.loadServices();
    }
  }

  /** Which sources have a backup for this repo, in display order. */
  sourcesForRepo(repo) {
    const sources = [];
    if (this.localServices.includes(repo)
        || this.localSystemConfig.includes(repo)
        || this.localExtraPaths.includes(repo)) {
      sources.push('local');
    }
    if (this.backblazeServices.includes(repo)
        || this.backblazeSystemConfig.includes(repo)
        || this.backblazeExtraPaths.includes(repo)) {
      sources.push('backblaze');
    }
    return sources;
  }

  /** Expand/collapse a service card. On expand, default to local if it
   *  has a local backup, otherwise the first available source. */
  async toggleRepo(repo) {
    if (this.expandedRepo === repo) {
      this.expandedRepo = null;
      this.expandedSource = null;
      return;
    }
    const sources = this.sourcesForRepo(repo);
    const source = sources[0] || 'local';
    this.expandedRepo = repo;
    this.expandedSource = source;
    await this.loadSnapshots(repo, source);
  }

  /** Switch the source shown inside an already-expanded card. */
  async selectRepoSource(repo, source) {
    if (this.expandedSource === source) return;
    this.expandedSource = source;
    await this.loadSnapshots(repo, source);
  }

  handleFieldChange(field, value) {
    const newConfig = { ...this.config };
    const path = field.split('.');
    let cur = newConfig;
    for (let i = 0; i < path.length - 1; i++) cur = cur[path[i]];
    cur[path[path.length - 1]] = value;
    this.config = newConfig;
    this.modified = true;
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { config: newConfig }, bubbles: true, composed: true
    }));
  }

  handleSecretUpdated() {
    this.loadSecretsStatus();
    this.loadBackupConfigStatus();
  }

  showNotification(message, type = 'info') {
    this.dispatchEvent(new CustomEvent('show-toast', {
      detail: { message, type }, bubbles: true, composed: true
    }));
  }

  // ------------------------------------------------------ restore actions

  confirmModal() {
    return this.renderRoot.querySelector('progress-modal');
  }

  /** Single-repository restore: plain confirm, then start the job. */
  handleRestore(repo, source, snapshotId) {
    const snapDesc = snapshotId
      ? `snapshot ${snapshotId.substring(0, 8)}` : 'the latest snapshot';
    this.confirmModal().show(
      'Confirm Restore',
      `Restore ${repo} from ${snapDesc}?`,
      'confirm',
      {
        confirmText: 'Restore',
        cancelText: 'Cancel',
        confirmVariant: 'danger',
        details: [
          { message: `${repo}'s service will be stopped during the restore`,
            type: 'warning' },
          { message: 'Current data and database contents will be OVERWRITTEN '
              + 'with the backup', type: 'warning' },
          { message: 'The service is restarted automatically when done',
            type: 'warning' }
        ],
        confirmCallback: () => this.performRestore(repo, source, snapshotId)
      }
    );
  }

  async performRestore(repo, source, snapshotId) {
    await this.startJob(
      `/api/backups/services/${encodeURIComponent(repo)}/restore`,
      {
        snapshot_id: snapshotId || null,
        source: source || 'auto',
        dry_run: false,
        create_snapshot: false
      });
  }

  /** Full-system restore: type-to-confirm because it is wide and destructive. */
  handleRestoreAll() {
    const count = this.repoCount();
    this._restoreAllConfirmText = '';
    this.confirmModal().show(
      'Restore Entire System',
      `This restores ALL ${count} backup repositories from their latest ` +
      `snapshots. To confirm, type ${BackupsModule.RESTORE_ALL_CONFIRM} below.`,
      'confirm',
      {
        confirmText: `Restore ${count} Repositories`,
        cancelText: 'Cancel',
        confirmVariant: 'danger',
        details: [
          { message: 'ALL current service data and databases will be '
              + 'OVERWRITTEN', type: 'warning' },
          { message: this.includeSystemConfig
              ? 'System configuration (/etc/nixos) IS included'
              : 'System configuration (/etc/nixos) is NOT included',
            type: 'warning' },
          { message: 'Scheduled backups are paused while the restore runs',
            type: 'warning' },
          { message: 'This may take several minutes', type: 'warning' }
        ],
        confirmCallback: () => {
          // The shared modal has no input; gate on a window.prompt instead
          // so the confirm action is deliberate.
          const typed = window.prompt(
            `Type ${BackupsModule.RESTORE_ALL_CONFIRM} to confirm a ` +
            `full-system restore of ${count} repositories:`);
          if (typed !== BackupsModule.RESTORE_ALL_CONFIRM) {
            this.showNotification('Full-system restore cancelled', 'info');
            return;
          }
          this.performRestoreAll();
        }
      }
    );
  }

  async performRestoreAll() {
    await this.startJob('/api/backups/restore-all', {
      snapshot_id: null,
      source: 'auto',
      dry_run: false,
      include_system_config: this.includeSystemConfig
    });
  }

  // ------------------------------------------------------ backup actions

  handleTriggerBackups() {
    this.confirmModal().show(
      'Run Backups Now',
      'Immediately start backup jobs for all enabled services.',
      'confirm',
      {
        confirmText: 'Run Backup Now',
        cancelText: 'Cancel',
        confirmVariant: 'primary',
        details: [
          { message: 'All enabled backup repositories will be backed up',
            type: 'info' },
          { message: 'Backups run in the background; you can leave this page',
            type: 'info' }
        ],
        confirmCallback: () => this.startJob('/api/backups/trigger', null)
      }
    );
  }

  handleBackupBackblaze() {
    this.confirmModal().show(
      'Back Up to Backblaze',
      'Run the offsite Backblaze B2 backups now.',
      'confirm',
      {
        confirmText: 'Back Up to Backblaze',
        cancelText: 'Cancel',
        confirmVariant: 'primary',
        details: [
          { message: 'Each service is backed up directly to its B2 '
              + 'repository', type: 'info' },
          { message: 'B2 backups also run automatically on a daily timer',
            type: 'info' },
          { message: 'Duration depends on how much data changed',
            type: 'info' }
        ],
        confirmCallback: () => this.startJob('/api/backups/backup-backblaze',
          null)
      }
    );
  }

  // -------------------------------------------------------------- helpers

  repoCount() {
    return new Set([
      ...this.localServices, ...this.backblazeServices,
      ...this.localSystemConfig, ...this.backblazeSystemConfig,
      ...this.localExtraPaths, ...this.backblazeExtraPaths
    ]).size;
  }

  formatTimestamp(ts) {
    if (!ts) return '';
    const date = new Date(ts);
    const mins = Math.floor((Date.now() - date) / 60000);
    if (mins < 1) return 'just now';
    if (mins < 60) return `${mins} minute${mins !== 1 ? 's' : ''} ago`;
    const hrs = Math.floor(mins / 60);
    if (hrs < 24) return `${hrs} hour${hrs !== 1 ? 's' : ''} ago`;
    return date.toLocaleString();
  }

  /** Relative time for a future timestamp ("in 6 hours"). */
  formatFuture(ts) {
    if (!ts) return '';
    const date = new Date(ts);
    const mins = Math.floor((date - Date.now()) / 60000);
    if (mins < 1) return 'shortly';
    if (mins < 60) return `in ${mins} minute${mins !== 1 ? 's' : ''}`;
    const hrs = Math.floor(mins / 60);
    if (hrs < 24) return `in ${hrs} hour${hrs !== 1 ? 's' : ''}`;
    const days = Math.floor(hrs / 24);
    return `in ${days} day${days !== 1 ? 's' : ''}`;
  }

  /** Is a repository action blocked because a job is running? */
  get actionsLocked() {
    return this.isJobActive(this.currentJob);
  }

  // --------------------------------------------------------- render: job

  renderJobBanner() {
    const job = this.currentJob;
    if (!job) return '';
    const active = this.isJobActive(job);
    const isRestore = job.kind === 'restore' || job.kind === 'restore-all';
    let cls = 'job-banner';
    if (active && isRestore) cls += ' restore';
    else if (!active) cls += (job.state === 'failed' ? ' failed' : ' done');

    const done = job.repos.filter(r => r.state === 'done').length;
    const failed = job.repos.filter(r => r.state === 'failed').length;
    const total = job.repos.length;

    let sub;
    if (active) {
      sub = job.current_repo
        ? `Working on ${job.current_repo} — ${done}/${total} done`
        : `${done}/${total} done`;
    } else if (job.state === 'failed') {
      sub = job.error || `${failed} repositor${failed === 1 ? 'y' : 'ies'} failed`;
    } else {
      sub = `${done}/${total} repositories completed`;
    }

    return html`
      <div class=${cls} @click=${() => { this.jobOverlayOpen = true; }}>
        ${active ? html`<span class="spinner lg"></span>`
                 : html`<span>${job.state === 'failed' ? '✕' : '✓'}</span>`}
        <div class="grow">
          <div class="title">${this.jobKindLabel(job.kind)}
            ${active ? 'in progress' : (job.state === 'failed'
              ? 'failed' : 'complete')}</div>
          <div class="sub">${sub}</div>
        </div>
        <span class="view">View details</span>
      </div>
    `;
  }

  renderJobOverlay() {
    if (!this.jobOverlayOpen || !this.currentJob) return '';
    const job = this.currentJob;
    const active = this.isJobActive(job);
    const done = job.repos.filter(r => r.state === 'done').length;
    const failed = job.repos.filter(r => r.state === 'failed').length;
    const total = job.repos.length;
    const pct = total ? Math.round((done + failed) / total * 100) : 0;
    const showChecklist = total > 1;

    return html`
      <div class="overlay" @click=${() => this.closeOverlayIfDone()}>
        <div class="job-panel" @click=${(e) => e.stopPropagation()}>
          <div class="job-panel-head">
            ${active ? html`<span class="spinner lg"></span>`
                     : html`<span style="font-size:20px;">
                         ${job.state === 'failed' ? '✕' : '✓'}</span>`}
            <span class="title">
              ${this.jobKindLabel(job.kind)}
              ${active ? 'in progress'
                       : (job.state === 'failed' ? '— failed' : '— complete')}
            </span>
          </div>

          <div class="job-panel-body">
            ${showChecklist ? html`
              <div class="progress-bar"><div style="width:${pct}%"></div></div>
              <div class="repo-progress">
                ${job.repos.map(r => html`
                  <div class="progress-row ${r.state}">
                    <span class="ico">${this.repoStateIcon(r.state)}</span>
                    <span>${r.name}</span>
                    ${r.error ? html`<span class="err">${r.error}</span>` : ''}
                  </div>
                `)}
              </div>
            ` : ''}

            <div style="font-size:13px;color:var(--hf-text-muted);
                        margin-bottom:6px;">Live log</div>
            <div class="log-view">${this.jobLog ||
              (active ? 'Waiting for output…' : '(no output)')}</div>

            ${job.state === 'failed' && job.error ? html`
              <div class="status-line err" style="margin-top:16px;">
                ${job.error}
              </div>` : ''}
          </div>

          <div class="job-panel-foot">
            <span class="job-summary">
              ${active
                ? `${done}/${total} done${failed ? `, ${failed} failed` : ''}`
                : (job.state === 'failed'
                    ? `${failed} failed, ${done} succeeded`
                    : `All ${total} completed`)}
            </span>
            <button class="btn ${active ? 'btn-secondary' : 'btn-primary'}"
                    @click=${() => { this.jobOverlayOpen = false; }}>
              ${active ? 'Run in background' : 'Close'}
            </button>
          </div>
        </div>
      </div>
    `;
  }

  closeOverlayIfDone() {
    if (!this.isJobActive(this.currentJob)) this.jobOverlayOpen = false;
  }

  repoStateIcon(state) {
    return { pending: '·', running: '⟳', done: '✓', failed: '✕' }[state]
      || '·';
  }

  // ----------------------------------------------------- render: config

  /**
   * Status tab - the landing view. Answers "are my backups OK?" first:
   * the live job banner, the per-source Backup Health panel, and the
   * Backup Self-Test.
   */
  renderStatusTab() {
    return html`
      ${this.renderJobBanner()}
      ${this.renderBackupHealth()}
      ${this.renderCanarySection()}
    `;
  }

  renderConfigurationTab() {
    const { backups } = this.config;
    // Single source of truth for "is restic configured", shared with the
    // Restore tab: the backend actually stats the password file.
    const resticReady = !!this.backupConfigStatus?.restic_password_configured;

    return html`
      ${this.renderJobBanner()}

      <config-section
        title="Local Backups"
        description="Automatic encrypted backups to a local storage device using Restic"
      >
        <form-field
          label="Enable Local Backups"
          type="boolean"
          .value=${backups.enable}
          help="Enable automatic backups of service data"
          @field-change=${(e) =>
            this.handleFieldChange('backups.enable', e.detail.value)}
        ></form-field>

        <form-field
          label="Backup Directory"
          type="text"
          .value=${backups['to-path']}
          placeholder="/var/lib/backups"
          help="Path to local backup storage. To target an NFS share, add it in the Mounts module first."
          @field-change=${(e) =>
            this.handleFieldChange('backups.to-path', e.detail.value)}
        ></form-field>

        <list-input
          label="Extra Backup Paths"
          itemType="path"
          .value=${backups['extra-from-paths'] || []}
          description="Additional directories to include in backups. HomeFree service data is backed up automatically; use this for user files (Documents, Photos, etc.)."
          placeholder="/mnt/ellis/Documents"
          @list-changed=${(e) =>
            this.handleFieldChange('backups.extra-from-paths', e.detail.value)}
        ></list-input>

        ${backups.enable ? html`
          <div class="info-box">
            <strong>ℹ️ Backup Information</strong>
            <div>HomeFree uses Restic for encrypted, deduplicated backups.
              Local backups run automatically after 2 AM daily (staggered);
              ${backups['backblaze-enable']
                ? 'offsite Backblaze B2 backups run after 4 AM. '
                : ''}each service is a separate restic repository with
              7-daily / 5-weekly / 10-yearly retention.</div>
          </div>

          <div class="btn-row">
            <button
              class="btn btn-primary"
              @click=${() => this.handleTriggerBackups()}
              ?disabled=${this.actionsLocked || !resticReady}
            >▶️ Run Backup Now</button>

            ${backups['backblaze-enable'] ? html`
              <button
                class="btn btn-primary"
                @click=${() => this.handleBackupBackblaze()}
                ?disabled=${this.actionsLocked || !resticReady}
              >☁️ Back Up to Backblaze</button>
            ` : ''}
          </div>

          ${!resticReady ? html`
            <p style="font-size:13px;color:var(--hf-text-muted);
                      margin-top:8px;">
              ⚠️ Configure the Restic password below before running backups
            </p>` : ''}
          ${this.actionsLocked ? html`
            <p style="font-size:13px;color:var(--hf-text-muted);
                      margin-top:8px;">
              A ${this.jobKindLabel(this.currentJob.kind).toLowerCase()} is
              currently running — see the banner above.
            </p>` : ''}
        ` : ''}
      </config-section>

      <config-section
        title="Backup Secrets"
        description="Encryption password and cloud storage credentials"
      >
        ${!this.hasAuthorizedKeys ? html`
          <div class="info-box warn-box">
            <strong>⚠️ SSH Key Required</strong>
            <div>Before you can manage secrets, add an SSH authorized key in
              the <a href="#/system"
                style="color:var(--hf-warn);text-decoration:underline;">
                System settings</a>.</div>
          </div>` : ''}

        <secrets-input
          serviceLabel="backup"
          secretKey="restic-password"
          label="Restic Password"
          description="Encryption password for backup repositories (required for backups and restores)"
          .exists=${this.secretsStatus?.['restic-password'] || false}
          ?disabled=${!this.hasAuthorizedKeys}
          @secret-updated=${() => this.handleSecretUpdated()}
        ></secrets-input>

        ${backups['backblaze-enable'] ? html`
          <secrets-input
            serviceLabel="backup"
            secretKey="backblaze-id"
            label="Backblaze Account ID"
            description="Your Backblaze B2 account ID"
            .exists=${this.secretsStatus?.['backblaze-id'] || false}
            ?disabled=${!this.hasAuthorizedKeys}
            @secret-updated=${() => this.handleSecretUpdated()}
          ></secrets-input>
          <secrets-input
            serviceLabel="backup"
            secretKey="backblaze-key"
            label="Backblaze Application Key"
            description="Your Backblaze B2 application key"
            .exists=${this.secretsStatus?.['backblaze-key'] || false}
            ?disabled=${!this.hasAuthorizedKeys}
            @secret-updated=${() => this.handleSecretUpdated()}
          ></secrets-input>
        ` : ''}
      </config-section>

      <config-section
        title="Backblaze B2 Cloud Backups"
        description="Off-site encrypted backups to Backblaze B2 cloud storage"
      >
        <form-field
          label="Enable Backblaze Backups"
          type="boolean"
          .value=${backups['backblaze-enable']}
          help="Send encrypted backups to Backblaze B2 cloud storage"
          @field-change=${(e) =>
            this.handleFieldChange('backups.backblaze-enable', e.detail.value)}
        ></form-field>
        <form-field
          label="Backblaze Bucket Name"
          type="text"
          .value=${backups['backblaze-bucket']}
          placeholder="my-homefree-backups"
          help="B2 bucket name for storing backups"
          @field-change=${(e) =>
            this.handleFieldChange('backups.backblaze-bucket', e.detail.value)}
        ></form-field>

        ${backups['backblaze-enable'] ? html`
          <div class="info-box">
            <strong>ℹ️ Backblaze Configuration</strong>
            <div>To use Backblaze B2:
              <ul>
                <li>Create a B2 account at backblaze.com</li>
                <li>Create a bucket for your backups</li>
                <li>Generate application keys with read/write access</li>
                <li>Configure credentials above in Backup Secrets</li>
              </ul>
            </div>
          </div>` : ''}
      </config-section>
    `;
  }

  /**
   * Pending (config) enabled state of the Backup Self-Test - i.e. what
   * the toggle reflects. This is the merged config value, which may
   * differ from what is actually deployed until the user applies.
   */
  get selfTestEnabledPending() {
    return !!this.config?.services?.['backup-canary']?.enable;
  }

  /** Deployed state - whether the self-test service actually exists. */
  get selfTestEnabledDeployed() {
    return !!this.canaryStatus?.enabled;
  }

  /**
   * Toggle the Backup Self-Test on/off. Writes the pending value into
   * config via the same service-toggle event the Services module uses;
   * it does NOT take effect until the user applies (rebuilds). The
   * toggle itself reflects the pending value, so the UI stays consistent
   * before apply.
   */
  handleSelfTestToggle(enabled) {
    this.dispatchEvent(new CustomEvent('service-toggle', {
      detail: { serviceLabel: 'backup-canary', enabled },
      bubbles: true,
      composed: true
    }));
  }

  /** Pending value of which backup source the self-test exercises. */
  get selfTestSourcePending() {
    return this.config?.services?.['backup-canary']?.['selftest-source']
      || 'local';
  }

  /**
   * Change which backup source the self-test verifies (local / backblaze
   * / both). Writes to pending config via service-option-changed; takes
   * effect on apply.
   */
  handleSelfTestSourceChange(value) {
    this.dispatchEvent(new CustomEvent('service-option-changed', {
      detail: {
        serviceLabel: 'backup-canary',
        optionKey: 'selftest-source',
        value
      },
      bubbles: true,
      composed: true
    }));
  }

  /**
   * Backup Health panel: at a glance, did the most recent scheduled
   * backups succeed, when did they run, and when do they run next -
   * per source (Local / Backblaze).
   */
  renderBackupHealth() {
    const h = this.backupHealth;
    // The section renders immediately - while health is still loading
    // it shows skeleton rows rather than popping in seconds later.
    const loading = !h;

    return html`
      <config-section
        title="Backup Health"
        description="Whether your most recent scheduled backups succeeded"
      >
        ${loading || !h.success
          ? html`
            ${this.renderHealthRowSkeleton('Local backups')}
            ${this.renderHealthRowSkeleton('Backblaze backups')}
          `
          : html`
            ${this.renderHealthRow('Local backups', h.local)}
            ${h.backblaze
              ? this.renderHealthRow('Backblaze backups', h.backblaze)
              : html`
                <div class="health-row">
                  <div class="health-name">Backblaze backups</div>
                  <div class="health-detail"
                    style="color:var(--hf-text-muted);">
                    Not configured — offsite backups are off.
                  </div>
                </div>`}
          `}
      </config-section>
    `;
  }

  /** Placeholder health row shown while backup health is loading. */
  renderHealthRowSkeleton(label) {
    return html`
      <div class="health-row">
        <div class="health-name">
          ${label}
          <span class="skeleton skeleton-badge"></span>
        </div>
        <div class="health-detail">
          <span class="skeleton skeleton-sub"></span>
        </div>
      </div>
    `;
  }

  /** One source's health line. `data` = {total, ok, failed, ...}. */
  renderHealthRow(label, data) {
    if (!data || data.total === 0) {
      return html`
        <div class="health-row">
          <div class="health-name">${label}</div>
          <div class="health-detail" style="color:var(--hf-text-muted);">
            No backup jobs found.
          </div>
        </div>`;
    }

    const healthy = data.failed === 0;
    const cls = healthy ? 'ok' : 'err';
    const summary = healthy
      ? html`<span class="health-badge ok">✓ Healthy</span>`
      : html`<span class="health-badge err">✗ ${data.failed}
          failed</span>`;

    return html`
      <div class="health-row ${cls}">
        <div class="health-name">
          ${label} ${summary}
        </div>
        <div class="health-detail">
          ${data.ok} of ${data.total} succeeded
          ${data.last_run
            ? html` · last run ${this.formatTimestamp(data.last_run)}`
            : ''}
          ${data.next_run
            ? html` · next ${this.formatFuture(data.next_run)}`
            : ''}
        </div>
        ${!healthy && data.failed_services?.length ? html`
          <div class="health-failed">
            Failed: ${data.failed_services.join(', ')}
          </div>` : ''}
      </div>
    `;
  }

  /**
   * Backup Self-Test section. The self-test is a small service that
   * backs up, changes and restores its own throwaway data on a
   * schedule, proving the backup/restore pipeline actually works.
   * "Backup Self-Test" is the user-facing name; the underlying service
   * is `backup-canary`.
   */
  renderCanarySection() {
    const pending = this.selfTestEnabledPending;
    const deployed = this.selfTestEnabledDeployed;
    // Config changed but not yet applied.
    const dirty = pending !== deployed;

    const c = this.canaryStatus;
    const r = c?.result;
    const running = !!c?.running;

    // Layout-stable: the structure below never changes between renders -
    // the status row and the action row are always present, only their
    // content/state changes. This avoids the section jumping around as
    // a self-test progresses.
    const { cls, text, detail } = this._selfTestStatusParts(
      { dirty, pending, deployed, result: r, running });

    return html`
      <config-section
        title="Backup Self-Test"
        description="Ongoing proof that your backups can actually be restored"
      >
        <p style="font-size:14px;color:var(--hf-text-muted);
                  margin-top:0;">
          When enabled, the system automatically backs up a small piece
          of test data every day, changes it, restores it from the
          backup, and confirms it came back correctly — giving you
          ongoing proof that your backups can actually be restored. It
          never touches any real data.
        </p>

        <form-field
          label="Enable Backup Self-Test"
          type="boolean"
          .value=${pending}
          help="Adds a small test service that verifies backups daily"
          @field-change=${(e) =>
            this.handleSelfTestToggle(e.detail.value)}
        ></form-field>

        ${pending ? this.renderSelfTestSource() : ''}

        <!-- Always-present status row; only its content changes. -->
        <div class="status-line ${cls} selftest-status">
          ${running ? html`<span class="spinner"></span>` : ''}
          <div>
            <div style="font-weight:600;">${text}</div>
            <div class="selftest-detail">${detail}</div>
          </div>
        </div>

        <!-- Always-present action row; the button is just disabled when
             a run is not possible, rather than removed. -->
        <div class="btn-row">
          <button
            class="btn btn-secondary"
            @click=${() => this.handleRunCanary()}
            ?disabled=${!deployed || dirty || running
              || this.canaryStarting}
          >${running
            ? html`<span class="spinner"></span> Running…`
            : (this.canaryStarting ? 'Starting…' : '🔬 Run Check Now')}
          </button>
        </div>
      </config-section>
    `;
  }

  /**
   * Compute the self-test status row's class / text / detail for the
   * current state. Always returns all three (detail may be '') so the
   * rendered structure stays constant - no layout shift.
   */
  _selfTestStatusParts({ dirty, pending, deployed, result, running }) {
    if (dirty) {
      return {
        cls: 'muted',
        text: `⏳ Backup Self-Test will be ${pending
          ? 'enabled' : 'disabled'} when you apply your changes.`,
        detail: '',
      };
    }
    if (!deployed) {
      return {
        cls: 'muted',
        text: 'Backup Self-Test is off.',
        detail: 'Turn it on above to start automatic daily backup checks.',
      };
    }
    if (running) {
      return {
        cls: 'muted',
        text: 'Backup self-test in progress…',
        detail: 'Backing up, changing and restoring the test data.',
      };
    }
    if (!result) {
      return {
        cls: 'muted',
        text: 'No self-test has run yet.',
        detail: 'It runs automatically each day, or run one now below.',
      };
    }
    if (result.result === 'pass') {
      return {
        cls: 'ok',
        text: `Last check: PASSED — ${result.finished_at || ''}`,
        detail: `Backup and restore verified (${result.source}).`,
      };
    }
    return {
      cls: 'err',
      text: `Last check: FAILED — ${result.finished_at || ''}`,
      detail: result.detail || 'Open the test page for details.',
    };
  }

  /**
   * The "which source does the self-test verify" selector. Backblaze
   * options require B2 to be configured; if it is not, only Local is
   * offered and a hint explains why.
   */
  renderSelfTestSource() {
    const b2Ready = !!this.backupConfigStatus?.backblaze_available;
    const current = this.selfTestSourcePending;

    const options = [
      { value: 'local',
        label: 'Local backups only' },
      { value: 'backblaze',
        label: 'Backblaze (offsite) only' },
      { value: 'both',
        label: 'Both local and Backblaze' },
    ];

    return html`
      <form-field
        label="What the self-test verifies"
        type="select"
        .value=${current}
        .options=${b2Ready ? options : options.slice(0, 1)}
        help="Which backup source the daily self-test backs up and restores"
        @field-change=${(e) =>
          this.handleSelfTestSourceChange(e.detail.value)}
      ></form-field>
      ${!b2Ready ? html`
        <p style="font-size:13px;color:var(--hf-text-muted);
                  margin-top:-8px;">
          Configure Backblaze B2 above to also verify offsite backups.
        </p>` : ''}
      ${b2Ready && current !== 'local' ? html`
        <p style="font-size:13px;color:var(--hf-text-muted);
                  margin-top:-8px;">
          Verifying Backblaze runs a real backup and restore against B2 —
          it uses some B2 transactions and takes a little longer.
        </p>` : ''}
    `;
  }

  // ---------------------------------------------------- render: restore

  renderRestoreTab() {
    const ready = this.backupConfigStatus?.restic_password_configured;
    if (!ready) {
      return html`
        ${this.renderJobBanner()}
        <config-section title="Restore from Backup"
          description="Restore data from backup repositories">
          <div class="status-line err">
            ⚠️ Restic password not configured. Configure it in the
            Configuration tab before restoring.
          </div>
        </config-section>
      `;
    }

    return html`
      ${this.renderJobBanner()}
      <config-section
        title="Restore from Backup"
        description="Restore data from backup repositories"
      >
        ${this.renderRestoreSources()}
        ${this.renderRefreshRow()}
        ${this.renderRestoreAllCard()}

        <h3 style="font-size:16px;font-weight:600;margin:24px 0 12px;">
          Restore individual repositories
        </h3>
        ${this.repoListLoading && !this._servicesLoadedOnce ? html`
          <div class="status-line muted">
            <span class="spinner"></span>
            Loading backup repositories…
          </div>
        ` : this.repoListError ? html`
          <div class="status-line err">${this.repoListError}</div>
        ` : html`
          ${this.renderPathsProgress()}
          ${this.renderRepoGroup('📦 Services',
              'Service data, databases, and application configuration',
              this.localServices, this.backblazeServices, false)}
          ${this.renderRepoGroup('📁 Extra Paths',
              'User-defined custom paths (e.g. NAS folders)',
              this.localExtraPaths, this.backblazeExtraPaths, false)}
          ${this.renderRepoGroup('⚙️ System Configuration',
              'Restoring this overwrites /etc/nixos — network and service '
              + 'configuration.',
              this.localSystemConfig, this.backblazeSystemConfig, true)}
          ${this.repoCount() === 0 ? html`
            <div class="status-line muted">
              No backup repositories found.
            </div>` : ''}
        `}

        <div class="info-box warn-box" style="margin-top:24px;">
          <strong>⚠️ What happens during a restore</strong>
          <ul>
            <li>The target service is stopped, its data overwritten, then
              restarted automatically</li>
            <li>Database contents are replaced with the backup's contents</li>
            <li>Scheduled backups for affected repositories are paused for
              the duration, so a backup cannot collide with the restore</li>
            <li>Only one restore, backup, or sync runs at a time</li>
          </ul>
        </div>
      </config-section>
    `;
  }

  renderRestoreSources() {
    const s = this.backupConfigStatus || {};
    return html`
      <div class="status-line ok">
        <div>
          <strong>✓ Restore is ready.</strong>
          ${s.local_backups_available
            ? html` Local backups available at
                <code>${s.local_backup_path}</code>.` : ''}
          ${s.backblaze_available
            ? html` Backblaze B2 is configured (offsite restore available).`
            : ''}
          ${!s.local_backups_available && !s.backblaze_available
            ? html` <span style="color:var(--hf-warn);">No backup sources
                found.</span>` : ''}
        </div>
      </div>
    `;
  }

  renderRefreshRow() {
    return html`
      <div style="display:flex;align-items:center;justify-content:space-between;
                  padding:12px;background:var(--hf-surface-2);
                  border-radius:8px;margin-bottom:16px;">
        <span style="font-size:13px;color:var(--hf-text-muted);">
          ${this.lastServicesRefresh
            ? html`<strong>Last refreshed:</strong>
                ${this.formatTimestamp(this.lastServicesRefresh)}`
            : html`<strong>Loading repository list…</strong>`}
        </span>
        <button class="btn btn-secondary" style="padding:8px 16px;
            font-size:13px;"
          @click=${() => this.loadServices(true)}
          ?disabled=${this.repoListLoading || this.actionsLocked}
        >${this.repoListLoading
          ? html`<span class="spinner"></span> Refreshing`
          : '🔄 Refresh'}</button>
      </div>
    `;
  }

  renderRestoreAllCard() {
    const count = this.repoCount();
    return html`
      <div style="padding:20px;background:rgba(245,158,11,.1);
                  border:2px solid var(--hf-warn);border-radius:8px;
                  margin-bottom:24px;">
        <div style="font-size:16px;font-weight:600;color:var(--hf-warn);
                    margin-bottom:8px;">🔄 Restore Entire System</div>
        <div style="font-size:14px;color:var(--hf-warn);margin-bottom:12px;">
          Restore all ${count} backup repositories from their latest
          snapshots — services, databases, and optionally system
          configuration. Use this for disaster recovery or migrating to a
          new machine.
        </div>
        <label style="display:flex;align-items:center;gap:8px;
                      font-size:14px;color:var(--hf-warn);cursor:pointer;
                      margin-bottom:12px;">
          <input type="checkbox"
            .checked=${this.includeSystemConfig}
            @change=${(e) => { this.includeSystemConfig = e.target.checked; }}
            style="width:16px;height:16px;cursor:pointer;" />
          <span>Include system configuration (/etc/nixos)</span>
        </label>
        <button class="btn btn-danger"
          @click=${() => this.handleRestoreAll()}
          ?disabled=${this.actionsLocked || count === 0}
        >Restore Entire System from Latest Backups</button>
      </div>
    `;
  }

  /**
   * Progress indicator for the background "resolve every repo's backup
   * paths" warm. Shows a real progress bar (done/total) instead of an
   * indefinite skeleton, so the page never looks broken/stuck.
   */
  renderPathsProgress() {
    const p = this.pathsProgress || {};
    if (p.state === 'ready') return '';

    if (p.state === 'error') {
      return html`
        <div class="status-line err" style="margin-bottom:16px;">
          <span>⚠️ Couldn't resolve backup paths.</span>
          <button class="btn btn-secondary"
            style="padding:6px 12px;font-size:13px;margin-left:auto;"
            @click=${() => this.loadAllPaths(true)}>Retry</button>
        </div>`;
    }

    const { done = 0, total = 0 } = p;
    // Before the backend reports a total it's still enumerating repos.
    const pct = total > 0 ? Math.round((done / total) * 100) : 0;
    return html`
      <div class="paths-progress">
        <div class="paths-progress-head">
          <span class="spinner"></span>
          <span>${total > 0
            ? html`Reading backup details — <strong>${done} of
                ${total}</strong> repositories`
            : 'Preparing backup repository list…'}</span>
          ${total > 0 ? html`<span class="paths-progress-pct">${pct}%</span>`
            : ''}
        </div>
        <div class="progress-bar">
          <div style="width:${total > 0 ? pct : 0}%"></div>
        </div>
      </div>
    `;
  }

  renderRepoGroup(title, desc, localRepos, bbRepos, isSystem) {
    if (localRepos.length === 0 && bbRepos.length === 0) return '';
    // One card per repo: a repo backed up both locally and to Backblaze
    // is a single entry, with the source chosen inside the card.
    const repos = [...new Set([...localRepos, ...bbRepos])].sort();
    return html`
      <div class="repo-group ${isSystem ? 'system' : ''}">
        <h4 style=${isSystem ? 'color:var(--hf-warn);' : ''}>${title}</h4>
        <p class="desc">${desc}</p>
        ${isSystem ? html`
          <div class="status-line err" style="margin-bottom:12px;">
            ⚠️ Restoring system configuration overwrites /etc/nixos. The
            restored config does NOT take effect until you run a
            <code>nixos-rebuild</code> afterwards.
          </div>` : ''}
        <div class="repo-list">
          ${repos.map(r => this.renderRepoRow(r))}
        </div>
      </div>
    `;
  }

  /**
   * Is this an extra-path repository (current `extra-path-N` or the
   * legacy combined `extra-paths`)? Those are identified by a directory
   * path, not a service name, so the row shows the path as the title.
   */
  isExtraPathRepo(repo) {
    return repo.startsWith('extra-path-') || repo === 'extra-paths';
  }

  renderRepoRow(repo) {
    const expanded = this.expandedRepo === repo;
    const isExtra = this.isExtraPathRepo(repo);
    const sources = this.sourcesForRepo(repo);

    // Path summary for the collapsed header: use whichever source has
    // resolved paths (both sources back up the same dirs for a service).
    const paths = this.repositoryPaths[`local:${repo}`]
      ?? this.repositoryPaths[`backblaze:${repo}`];
    const pathsKnown = paths !== undefined;

    // Title: service repos -> service name; extra-path repos -> the
    // actual backed-up directory (skeleton until paths resolve).
    let title = null;
    if (isExtra) {
      if (pathsKnown) {
        title = paths.length > 0 ? paths[0] : repo;
      }
    } else {
      title = repo;
    }

    // Secondary line under the title.
    let summary = null;
    if (pathsKnown) {
      if (isExtra) {
        summary = paths.length > 1
          ? `+${paths.length - 1} more path${
              paths.length - 1 !== 1 ? 's' : ''}`
          : '';
      } else if (paths.length === 0) {
        summary = '';
      } else {
        const head = paths.slice(0, 2).join(', ');
        summary = paths.length > 2
          ? `${head} +${paths.length - 2} more` : head;
      }
    }

    // Source availability tags shown on the collapsed header.
    const sourceTags = html`
      ${sources.includes('local')
        ? html`<span class="repo-tag">Local</span>` : ''}
      ${sources.includes('backblaze')
        ? html`<span class="repo-tag bb">☁️ Backblaze</span>` : ''}
    `;

    return html`
      <div class="repo-row">
        <div class="repo-head ${this.actionsLocked ? 'disabled' : ''}"
          @click=${() => { if (!this.actionsLocked)
            this.toggleRepo(repo); }}>
          <span class="chevron ${expanded ? 'open' : ''}">▶</span>
          <div class="grow">
            <div>
              ${title !== null
                ? html`<span class="repo-name" title=${title}>${title}</span>`
                : html`<span class="skeleton skeleton-title"></span>`}
              ${sourceTags}
            </div>
            ${summary === null
              ? html`<span class="skeleton skeleton-sub"></span>`
              : (summary
                  ? html`<div class="repo-paths">${summary}</div>` : '')}
          </div>
        </div>
        ${expanded ? html`
          <div class="repo-body">
            ${this.renderRepoBody(repo, sources)}
          </div>
        ` : ''}
      </div>
    `;
  }

  /**
   * The expanded card body: a segmented Local/Backblaze source toggle
   * (only shown when the repo has both sources), then the snapshot
   * picker for the selected source.
   */
  renderRepoBody(repo, sources) {
    const source = this.expandedSource;
    return html`
      ${sources.length > 1 ? html`
        <div class="source-toggle">
          ${sources.map(s => html`
            <button
              class="source-toggle-btn ${s === source ? 'active' : ''}"
              @click=${() => this.selectRepoSource(repo, s)}
            >${s === 'backblaze' ? '☁️ Backblaze' : 'Local'}</button>
          `)}
        </div>
      ` : ''}
      ${this.renderSnapshotPicker(repo, source)}
    `;
  }

  renderSnapshotPicker(repo, source) {
    if (this.snapshotsLoading) {
      return html`<div class="status-line muted">
        <span class="spinner"></span> Loading snapshots…</div>`;
    }
    if (this.snapshots.length === 0) {
      return html`<p style="color:var(--hf-text-muted);font-size:14px;">
        No snapshots found for this repository.</p>`;
    }
    const selected = this.snapshots.find(
      s => s.id === this.selectedSnapshot);
    // restic snapshot JSON records `paths` (the backup roots).
    const selectedPaths = (selected && Array.isArray(selected.paths))
      ? selected.paths : [];

    return html`
      <div class="snapshots">
        ${this.snapshots.map((snap, i) => html`
          <div class="snapshot
            ${this.selectedSnapshot === snap.id ? 'selected' : ''}"
            @click=${() => { this.selectedSnapshot = snap.id; }}>
            <div class="time">${snap.time}
              ${i === 0 ? html`<span style="color:var(--hf-accent);
                font-size:12px;"> (latest)</span>` : ''}</div>
            <div class="meta">ID: ${snap.id?.substring(0, 8)}
              ${snap.hostname ? `· ${snap.hostname}` : ''}</div>
          </div>
        `)}
      </div>

      ${selectedPaths.length > 0 ? html`
        <div class="restore-targets">
          <div class="restore-targets-label">
            This restore will overwrite:
          </div>
          <ul>
            ${selectedPaths.map(p => html`<li><code>${p}</code></li>`)}
          </ul>
        </div>
      ` : ''}

      <button class="btn btn-danger"
        @click=${() => this.handleRestore(repo, source,
          this.selectedSnapshot)}
        ?disabled=${this.actionsLocked || !this.selectedSnapshot}
      >Restore Selected Snapshot</button>
    `;
  }

  // ----------------------------------------------------------- render

  render() {
    return html`
      <div class="module-container">
        <div class="tabs">
          <button class="tab ${this.activeTab === 'status'
            ? 'active' : ''}"
            @click=${() => this.handleTabChange('status')}
          >Status</button>
          <button class="tab ${this.activeTab === 'configuration'
            ? 'active' : ''}"
            @click=${() => this.handleTabChange('configuration')}
          >Configuration</button>
          <button class="tab ${this.activeTab === 'restore' ? 'active' : ''}"
            @click=${() => this.handleTabChange('restore')}
          >Restore</button>
        </div>

        ${this.activeTab === 'configuration'
          ? this.renderConfigurationTab()
          : this.activeTab === 'restore'
            ? this.renderRestoreTab()
            : this.renderStatusTab()}
      </div>

      ${this.renderJobOverlay()}
      <progress-modal></progress-modal>
    `;
  }
}

customElements.define('backups-module', BackupsModule);
