import { LitElement, html, css } from 'lit';
import '../../shared/config-section.js';
import '../../shared/form-field.js';
import '../../shared/table-editor.js';
import '../../shared/progress-modal.js';
import '../secrets-input.js';
import { BackupJobControllerMixin } from '../../shared/backup-job-controller.js';
import { navIcon } from '../../../shared/icons.js';

/**
 * Backups configuration module.
 *
 * Handles local backups, Backblaze B2 cloud backups, and restore
 * operations. Long-running operations (restore, restore-all, trigger,
 * sync) are modelled as backend "jobs" — the job state machine, the
 * poller, and the progress banner/overlay are shared with the Status
 * page via BackupJobControllerMixin (shared/backup-job-controller.js).
 * The Restore tab renders its repository list immediately;
 * per-repository paths and snapshots load lazily on demand.
 */
class BackupsModule extends BackupJobControllerMixin(LitElement) {
  static properties = {
    config: { type: Object },
    undeployedPaths: { attribute: false },  // Set<dotted-path> not yet deployed
    appliedConfig: { attribute: false },    // deployed baseline for row highlight
    modified: { type: Boolean },
    activeTab: { type: String },
    /**
     * Module sub-route from the URL (admin-app passes the path segment
     * after `#/backups/`). On change we map it onto activeTab; on tab
     * click we emit `sub-route-change` so admin-app can update the
     * hash. The empty string means "no sub-route set" → keep the
     * default tab; an unknown value is ignored.
     */
    subRoute: { type: String },
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

    // Run tab: repository label -> its SOURCE directories, read from
    // config (no restic). Keyed by bare label, e.g. "extra-path-2".
    sourcePaths: { type: Object },

    // Snapshot picker (expanded repo)
    expandedRepo: { type: String },     // repo name currently expanded
    expandedSource: { type: String },   // 'local' | 'backblaze' shown in card
    snapshots: { type: Array },
    snapshotsLoading: { type: Boolean },
    selectedSnapshot: { type: String },

    includeSystemConfig: { type: Boolean },

    // Orphaned extra-path-<id> restic repositories: present on disk /
    // in B2 but with no matching entry in extra-from-paths. Listed in
    // the Configure tab so the operator can decide whether to keep
    // their snapshots or purge the storage.
    orphanRepos: { type: Array },
    orphanReposLoading: { type: Boolean },
    purgingOrphan: { type: String, state: true },

    // The single active backend job, polled live. The job state and
    // its render helpers come from BackupJobControllerMixin; these
    // declarations keep them reactive on this subclass.
    currentJob: { type: Object },
    jobLog: { type: String },
    jobOverlayOpen: { type: Boolean },

    // Live Backblaze credential check (does NOT require a rebuild).
    verifyingBackblaze: { type: Boolean, state: true },
    backblazeVerifyResult: { type: Object, state: true }
  };

  static styles = css`
    :host { display: block; }

    /* Width cap + centering is applied once, app-wide, on
       admin-app.js's .content-area > * — no per-module max-width. */
    .module-container { width: 100%; }

    /* ---- tabs ---- */
    /* Sticky so the tab bar stays visible while the long Configure or
       Run content scrolls. admin-app.js .content-area is the scroll
       container; the 24px top gutter lives on .content-area > *
       (this host element) so it scrolls with the content rather than
       sitting fixed above the scrollport.

       A sticky bar inside that gutter has to *extend itself* into the
       gutter — otherwise it pins 24px below the scrollport top and
       scrolled content shows through the strip above it. The
       standard CSS sticky pattern handles this with a paired negative
       top margin (to reach up to the host's top edge) and matching
       top padding (so the tab buttons render at their original
       position). Net layout is identical; the sticky strip now spans
       the entire scrollport-top to its border-bottom. */
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
    }
    .tab:hover { color: var(--hf-text); }
    .tab.active {
      color: var(--hf-accent);
      border-bottom-color: var(--hf-accent);
    }

    /* ---- generic boxes ---- */
    /* Unified notification box — grey-tinted bg, colored left edge,
       colored heading, normal body text. .warn-box is applied
       alongside .info-box and only re-colours the edge + heading. */
    .info-box {
      background: rgba(59, 130, 246, 0.08);
      border-left: 4px solid var(--hf-accent);
      padding: 14px 18px;
      border-radius: 8px;
      margin-bottom: 20px;
      color: var(--hf-text-muted);
      font-size: 13px;
      line-height: 1.5;
    }
    .info-box strong { color: var(--hf-text); }
    .info-box > strong:first-child { display: block; margin-bottom: 8px; }
    .info-box ul { margin: 8px 0 0 20px; padding: 0; }
    .info-box a { color: var(--hf-accent); text-decoration: none; }
    .info-box a:hover { text-decoration: underline; }

    .warn-box {
      border-left-color: var(--hf-warn);
    }

    /* Extra Backup Paths: help text lives above the embedded
       <table-editor>. The table styling itself comes from the shared
       component. */
    .extra-paths-help {
      font-size: 12.5px;
      color: var(--hf-text-muted);
      margin-bottom: 8px;
    }

    /* Orphan-repo list: one row per (label, source) pair. The right-
       aligned Purge button mirrors the table-editor's per-row action
       column so the two adjacent sections feel like one surface. */
    .orphan-repos-list {
      margin-top: 4px;
      display: flex;
      flex-direction: column;
      gap: 8px;
    }
    .orphan-repos-row {
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: 12px;
      padding: 10px 14px;
      background: var(--hf-surface-2);
      border: 1px solid var(--hf-border);
      border-radius: 8px;
    }
    .orphan-repos-main {
      display: flex;
      flex-direction: column;
      gap: 6px;
      min-width: 0;
      flex: 1 1 auto;
    }
    .orphan-repos-label {
      display: flex;
      align-items: center;
      gap: 10px;
      font-size: 14px;
      color: var(--hf-text);
      min-width: 0;
    }
    .orphan-repos-paths {
      margin: 0;
      padding: 0 0 0 18px;
      list-style: disc;
      font-size: 12.5px;
      color: var(--hf-text-muted);
      font-family: var(--hf-font-mono, monospace);
      word-break: break-all;
    }
    .orphan-repos-paths.placeholder,
    .orphan-repos-paths.error {
      list-style: none;
      padding-left: 0;
      font-family: inherit;
    }
    .orphan-repos-paths.error {
      color: var(--hf-err);
    }

    /* Skeleton shimmer for the orphan section: same shimmer the
       hardware/dashboard modules use so the placeholder shape lines
       up with the rest of the admin UI. Painted while the orphan
       list itself is loading, and while the batched path warm is
       still resolving an individual orphan's snapshot. */
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
    .skeleton-title       { width: 160px; height: 14px; }
    .skeleton-purge-btn   { width: 70px; height: 28px; border-radius: 6px;
                            flex: 0 0 auto; }
    .orphan-repos-paths.skeleton-paths {
      display: flex;
      flex-direction: column;
      gap: 6px;
      padding-left: 0;
      list-style: none;
    }
    .skeleton-path-row    { width: 260px; height: 12px; }
    .skeleton-path-row.short { width: 180px; }
    @keyframes shimmer {
      from { background-position: 100% 0; }
      to   { background-position: 0 0; }
    }
    .orphan-repos-label strong {
      font-weight: 600;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .orphan-repos-source {
      font-size: 11.5px;
      letter-spacing: 0.04em;
      text-transform: uppercase;
      color: var(--hf-text-muted);
      padding: 2px 8px;
      border: 1px solid var(--hf-border);
      border-radius: 999px;
    }

    /* ---- visually distinct sub-card inside a config-section ---- */
    .subsection {
      margin-top: 24px;
      padding: 18px 20px 4px;
      background: var(--hf-surface-2);
      border: 1px solid var(--hf-border);
      border-radius: 10px;
    }
    .subsection-header {
      margin-bottom: 14px;
    }
    .subsection-title {
      font-size: 14px;
      font-weight: 600;
      color: var(--hf-text);
    }
    .subsection-description {
      margin-top: 4px;
      font-size: 13px;
      color: var(--hf-text-muted);
    }
    .subsection-description a {
      color: var(--hf-accent);
      text-decoration: none;
    }
    .subsection-description a:hover { text-decoration: underline; }

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
    .health-row.ok   { border-left-color: var(--hf-ok); }
    .health-row.warn { border-left-color: var(--hf-warn); }
    .health-row.err  { border-left-color: var(--hf-err); }
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
    .health-failed.health-never { color: var(--hf-warn); }
    .health-badge {
      font-size: 12px;
      font-weight: 600;
      padding: 2px 8px;
      border-radius: 999px;
    }
    .health-badge.ok  {
      background: rgba(16,185,129,.15); color: var(--hf-ok);
    }
    .health-badge.warn {
      background: rgba(245,158,11,.15); color: var(--hf-warn);
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
    .btn-primary   { background: var(--hf-accent); color: #06281c; }
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
    .btn-sm { padding: 6px 12px; font-size: 13px; }

    /* per-service "back up now" list (Run tab) */
    .svc-backup-list { display: grid; gap: 2px; margin-top: 6px; }
    .svc-backup-row {
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 8px 10px;
      border-radius: 8px;
    }
    .svc-backup-row:nth-child(odd) { background: var(--hf-surface-2); }
    .svc-backup-name { flex: 1; font-size: 14px; color: var(--hf-text); }
    .svc-backup-actions { display: flex; gap: 6px; }

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
      display: flex; align-items: center; gap: 8px;
    }
    /* Monochrome group-header icon — matches the sidebar nav icons:
       inherits the heading text color, 18px square. */
    .repo-group-icon {
      display: inline-flex;
      flex-shrink: 0;
    }
    .repo-group-icon svg {
      width: 18px; height: 18px;
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
      color: #06281c;
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
    this.undeployedPaths = new Set();
    this.appliedConfig = null;
    this.activeTab = 'status';
    this.subRoute = '';
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

    this.sourcePaths = {};

    this.expandedRepo = null;
    this.expandedSource = null;
    this.snapshots = [];
    this.snapshotsLoading = false;
    this.selectedSnapshot = null;

    this.includeSystemConfig = false;

    this.orphanRepos = [];
    this.orphanReposLoading = false;
    this.purgingOrphan = '';

    this.currentJob = null;
    this.jobLog = '';
    this.jobOverlayOpen = false;

    this.verifyingBackblaze = false;
    this.backblazeVerifyResult = null;

    // internal (non-reactive)
    this._jobPollTimer = null;
    this._pathsPollTimer = null;
    this._canaryPollTimer = null;
    this._autoVerifyTimer = null;
    this._jobLogOffset = 0;
    this._restoreAllConfirmText = '';
    this._servicesLoadedOnce = false;
    // The Restore tab's snapshot path-warm and the Run tab's config
    // path load are each started once, lazily, on first tab open.
    this._pathsWarmStarted = false;
    this._sourcePathsLoaded = false;
  }

  // ----------------------------------------------------------- lifecycle

  async connectedCallback() {
    super.connectedCallback();

    // Adopt the URL's sub-route on initial mount. updated() also tracks
    // later changes (back/forward navigation), but on first paint we
    // want the right tab BEFORE the data-loading kicks off so
    // tab-specific lazy loads (Run/Restore repo lists) fire early.
    this._applySubRoute(this.subRoute);

    await Promise.all([
      this.loadSecretsStatus(),
      this.loadBackupConfigStatus(),
      this.loadCanaryStatus(),
      this.loadBackupHealth(),
      this.loadOrphanRepos(),
      this.refreshCurrentJob()
    ]);
    // If a job is already running, attach the live poller.
    if (this.isJobActive(this.currentJob)) {
      this.startJobPolling();
    }
    // Auto-run Backblaze verify so the Configure tab does not display
    // a "Verify required" warning when everything is already filled in
    // — the user only had to click Verify the first time the inputs
    // changed; reload should re-check without a click.
    this._maybeAutoVerifyBackblaze();
    // If a self-test is running, poll until it finishes.
    if (this.canaryStatus?.running) {
      this.startCanaryPolling();
    }
  }

  /**
   * Lit reactive update hook — runs after every property change.
   * We watch `subRoute` so that back/forward navigation (which fires
   * `hashchange` → admin-app re-derives currentSubRoute → this prop
   * updates) restores the right tab without a click. Internal tab
   * clicks update activeTab directly AND emit sub-route-change; the
   * round-trip lands subRoute === activeTab, so the equality guard
   * below skips a redundant re-apply.
   */
  updated(changed) {
    if (changed.has('subRoute')) {
      this._applySubRoute(this.subRoute);
    }
    // After a successful Apply, appliedConfig is updated by admin-app.
    // Re-check the orphan list so any extra-from-paths entry just
    // deleted (and therefore now orphaned) surfaces immediately.
    if (changed.has('appliedConfig')) {
      this.loadOrphanRepos();
    }
  }

  /**
   * Map a URL sub-route onto activeTab. An empty sub-route restores
   * the default landing tab (Status) — that covers the user clicking
   * the sidebar Backups item to come back to the module: admin-app
   * clears currentSubRoute on sidebar nav, so we need to fall back
   * here rather than leaving the previous tab selected.
   *
   * Unknown values are ignored so a stale or hand-typed hash does
   * not blank out the page. Calls handleTabChange with silent=true
   * so we do not echo the change back as a sub-route-change event
   * (which would re-trigger admin-app → updated → this method).
   */
  _applySubRoute(sub) {
    const target = sub || 'status';
    const validTabs = new Set(['status', 'run', 'restore', 'configuration']);
    if (!validTabs.has(target)) return;
    if (this.activeTab === target) return;
    this.handleTabChange(target, { silent: true });
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    this.stopCanaryPolling();
    if (this._pathsPollTimer) {
      clearTimeout(this._pathsPollTimer);
      this._pathsPollTimer = null;
    }
    if (this._autoVerifyTimer) {
      clearTimeout(this._autoVerifyTimer);
      this._autoVerifyTimer = null;
    }
  }

  // ----------------------------------------------------------- job model
  //
  // The job state machine, poller, startJob() and banner/overlay
  // renders come from BackupJobControllerMixin. This module only adds
  // the page-specific follow-up that runs when a job finishes.

  onJobFinishedHook(job) {
    const kind = job?.kind;
    // A restore changed on-disk data; refresh repo lists/paths.
    if (kind === 'restore' || kind === 'restore-all') {
      this.loadServices(true);
    }
    // A backup/sync run changes last-run health - refresh the panel.
    if (kind === 'backup' || kind === 'sync') {
      this.loadBackupHealth();
    }
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

  /**
   * Load the list of extra-path-<id> restic repos that exist but are
   * no longer referenced by backups.extra-from-paths. Cheap on the
   * backend (one config read + one directory scan per source) so we
   * can refresh it after every Apply and on every Configure-tab open.
   */
  async loadOrphanRepos() {
    this.orphanReposLoading = true;
    try {
      const res = await fetch('/api/backups/orphan-repos');
      if (res.ok) {
        const data = await res.json();
        this.orphanRepos = data.orphans || [];
      } else {
        this.orphanRepos = [];
      }
    } catch (e) {
      console.error('Error loading orphan repos:', e);
      this.orphanRepos = [];
    } finally {
      this.orphanReposLoading = false;
    }
    // To show what each orphan was backing up we need its latest
    // snapshot's `paths`. We deliberately do NOT fire one /paths
    // request per orphan in parallel: each one shells out to a
    // blocking `restic snapshots` from inside an async handler, which
    // stalls the event loop and starves /health (the admin-api
    // watchdog then declares the unit unhealthy and restarts it).
    // Instead we lean on the existing batched warm
    // (/api/backups/paths) the Restore tab already uses. It returns
    // paths for every repo on the source, configured AND orphan, with
    // streaming progress and server-side caching. The render then
    // reads from this.repositoryPaths and shows a skeleton until each
    // orphan's entry arrives. Only kick off the warm when there is
    // at least one orphan to display, so a clean install does no work.
    if (this.orphanRepos.length && !this._pathsWarmStarted) {
      this._pathsWarmStarted = true;
      this.loadAllPaths(false);
    }
  }

  /**
   * Strong-confirm prompt before purging an orphan repository. The
   * action is irreversible: it deletes the underlying storage (a
   * local directory or a B2 prefix) and any restic snapshots it
   * held. The backend re-validates label + source and re-checks
   * orphan status, so a concurrent Apply that puts a path back
   * cannot lose its history through this surface.
   */
  handlePurgeOrphan(orphan) {
    const where = orphan.source === 'backblaze'
      ? 'Backblaze B2' : 'local storage';
    this.confirmModal().show(
      'Purge backup history?',
      `Delete the ${orphan.label} restic repository from ${where}? ` +
      `Every snapshot it holds will be removed permanently.`,
      'confirm',
      {
        confirmText: 'Purge',
        cancelText: 'Cancel',
        confirmVariant: 'danger',
        details: [
          { message: 'This is irreversible — the snapshots cannot be '
              + 'recovered after purge', type: 'warning' },
          { message: orphan.source === 'backblaze'
              ? 'Only the Backblaze B2 copy is removed. Run Purge '
                + 'again on the local copy if it also needs to go.'
              : 'Only the local copy is removed. Run Purge again on '
                + 'the Backblaze copy if it also needs to go.',
            type: 'warning' },
        ],
        confirmCallback: () => this.performPurgeOrphan(orphan),
      });
  }

  async performPurgeOrphan(orphan) {
    const key = `${orphan.source}:${orphan.label}`;
    this.purgingOrphan = key;
    try {
      const res = await fetch('/api/backups/orphan-repos/purge', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          label: orphan.label, source: orphan.source,
        }),
      });
      const data = await res.json().catch(() => ({}));
      if (res.ok && data.success) {
        this.showNotification(
          `Purged ${orphan.label} from ${orphan.source}.`, 'success');
        // Optimistically drop the row from local state. We do NOT
        // re-fetch /orphan-repos here: B2's list API is eventually
        // consistent, so a list call seconds after a successful
        // `rclone purge` may still report the prefix. Refetching
        // would put the just-purged row back on screen until the
        // bucket listing settles — exactly the bug the operator hit.
        // The natural refreshes (Configure-tab re-open via the
        // updated() hook on appliedConfig change, or a page reload)
        // confirm against the settled state.
        this.orphanRepos = this.orphanRepos.filter(o =>
          !(o.source === orphan.source && o.label === orphan.label));
        // Drop the purged label from the shared repositoryPaths
        // cache (used for both this section's paths display and the
        // Restore tab's per-repo paths).
        if (this.repositoryPaths && key in this.repositoryPaths) {
          const remaining = { ...this.repositoryPaths };
          delete remaining[key];
          this.repositoryPaths = remaining;
        }
        // The Restore tab's repo list also needs the purged label
        // gone. The backend cleared its services cache as part of
        // purge, so this force-refresh sees the real state.
        this.loadServices(true);
      } else {
        const msg = data.error || data.detail
          || `Purge failed (status ${res.status})`;
        this.showNotification(`Purge failed: ${msg}`, 'error');
      }
    } catch (e) {
      console.error('Error purging orphan repo:', e);
      this.showNotification(`Purge failed: ${e.message}`, 'error');
    } finally {
      this.purgingOrphan = '';
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
  async loadServices(force = false, { warmPaths = true } = {}) {
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
      // Warm the per-repo snapshot paths for the Restore tab. This is
      // the slow part (a restic call per repo), so the Run tab opts
      // out via warmPaths:false — it reads source paths from config
      // instead (loadSourcePaths).
      if (warmPaths) {
        this._pathsWarmStarted = true;
        this.loadAllPaths(force);
      }
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

  async handleTabChange(tab, { silent = false } = {}) {
    this.activeTab = tab;
    // Tell admin-app to persist the choice in the URL. `silent` is
    // set when the call came FROM the URL sync (initial mount or
    // back/forward navigation) — re-emitting in that case would just
    // re-write the same hash and risk a feedback loop.
    if (!silent) {
      this.dispatchEvent(new CustomEvent('sub-route-change', {
        detail: { subRoute: tab },
        bubbles: true,
        composed: true,
      }));
    }
    if (tab !== 'restore' && tab !== 'run') return;

    // Both tabs need the repository lists (cheap; no restic). Load once.
    // The Run tab opts out of the slow snapshot path-warm — it shows
    // SOURCE paths from config instead. Each of the two follow-up loads
    // is guarded by its own flag, so opening one tab first does not
    // starve the other (e.g. Run-first must not skip Restore's warm).
    if (!this._servicesLoadedOnce) {
      this.loadServices(false, { warmPaths: tab === 'restore' });
    } else if (tab === 'restore' && !this._pathsWarmStarted) {
      // Run was opened first (lists already loaded, warm skipped) —
      // start the snapshot warm now that Restore needs it.
      this._pathsWarmStarted = true;
      this.loadAllPaths(false);
    }

    // Run tab: load config-derived source paths once (instant).
    if (tab === 'run' && !this._sourcePathsLoaded) {
      this.loadSourcePaths();
    }
  }

  /**
   * Load each repository's SOURCE directories from config — what WILL
   * be backed up. Cheap (no restic); the Run tab uses this to show
   * real paths instantly instead of the slow snapshot warm.
   */
  async loadSourcePaths() {
    this._sourcePathsLoaded = true;
    try {
      const res = await fetch('/api/backups/source-paths');
      if (res.ok) {
        const d = await res.json();
        this.sourcePaths = d.paths || {};
      }
    } catch (e) {
      console.error('Error loading source paths:', e);
      // Non-fatal: rows fall back to showing the repo label.
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

  // True when `path` (a dotted config path) holds a change not yet deployed.
  _undeployed(path) {
    return this.undeployedPaths?.has(path) || false;
  }

  handleFieldChange(field, value) {
    const newConfig = { ...this.config };
    const path = field.split('.');
    let cur = newConfig;
    for (let i = 0; i < path.length - 1; i++) cur = cur[path[i]];
    cur[path[path.length - 1]] = value;
    this.config = newConfig;
    this.modified = true;
    // Bucket changed -> any cached verify result is stale (it was
    // resolved against the old bucket name). Debounce the auto-verify
    // so we do not fire one POST per keystroke; the user usually pastes
    // or types the bucket name, then we Verify against the settled
    // value ~700ms after they stop typing.
    if (field === 'backups.backblaze-bucket'
        || field === 'backups.backblaze-enable') {
      this.backblazeVerifyResult = null;
      if (this._autoVerifyTimer) clearTimeout(this._autoVerifyTimer);
      this._autoVerifyTimer = setTimeout(() => {
        this._autoVerifyTimer = null;
        this._maybeAutoVerifyBackblaze();
      }, 700);
    }
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { config: newConfig }, bubbles: true, composed: true
    }));
  }

  async handleSecretUpdated() {
    // Stored credentials changed - last verify result is stale.
    this.backblazeVerifyResult = null;
    // Refresh which secrets exist BEFORE auto-verify; the auto-verify
    // gate checks secretsStatus and we want it reading the new truth.
    await Promise.all([
      this.loadSecretsStatus(),
      this.loadBackupConfigStatus(),
    ]);
    this._maybeAutoVerifyBackblaze();
  }

  /**
   * Fire a Verify automatically when bucket + both secrets are set
   * and no result is currently cached. Skips when:
   *   - the user is mid-verify already,
   *   - any of the three inputs is empty (the General-section warning
   *     panel handles that case),
   *   - a cached result already exists (good or bad — we don't want
   *     to clobber a real "creds invalid" message with another spin
   *     of the same call on every render).
   * Cached results ARE cleared in handleSecretUpdated and in
   * handleFieldChange when the bucket or enable flag changes, so this
   * helper will then naturally re-run.
   */
  _maybeAutoVerifyBackblaze() {
    if (this.verifyingBackblaze) return;
    if (this.backblazeVerifyResult) return;
    const bucketSet = !!(this.config?.backups
                         && this.config.backups['backblaze-bucket']);
    const idSet = !!this.secretsStatus?.['backblaze-id'];
    const keySet = !!this.secretsStatus?.['backblaze-key'];
    if (!bucketSet || !idSet || !keySet) return;
    this.handleVerifyBackblaze();
  }

  async handleVerifyBackblaze() {
    this.verifyingBackblaze = true;
    this.backblazeVerifyResult = null;
    try {
      // Send the *pending* bucket name so verify checks what the user
      // sees on screen, not the last-saved value on disk.
      const pendingBucket = (this.config?.backups
                             && this.config.backups['backblaze-bucket'])
                            || '';
      const r = await fetch('/api/backups/backblaze/verify', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ bucket: pendingBucket }),
      });
      let data = null;
      try { data = await r.json(); } catch (_) { data = null; }
      if (!r.ok) {
        this.backblazeVerifyResult = {
          success: false,
          error: (data && (data.detail || data.error))
            || `Verify request failed (${r.status})`
        };
      } else {
        this.backblazeVerifyResult = data || { success: false,
          error: 'Empty response from verify endpoint' };
      }
    } catch (err) {
      this.backblazeVerifyResult = {
        success: false,
        error: `Verify request failed: ${err.message || err}`
      };
    } finally {
      this.verifyingBackblaze = false;
    }
  }

  /**
   * Verify button + last-check result.
   *
   * Renders only when both Backblaze secrets are set. Calls the live
   * /api/backups/backblaze/verify endpoint - no rebuild needed.
   */
  renderBackblazeVerify() {
    const idSet = !!this.secretsStatus?.['backblaze-id'];
    const keySet = !!this.secretsStatus?.['backblaze-key'];
    const bucketSet = !!(this.config?.backups
                         && this.config.backups['backblaze-bucket']);
    const ready = idSet && keySet && bucketSet && this.hasAuthorizedKeys;
    if (!idSet || !keySet) {
      return '';
    }
    const disabledHint = !bucketSet
      ? 'Set a Backblaze Bucket Name above to enable verification.'
      : (!this.hasAuthorizedKeys
        ? 'Add an SSH authorized key in System settings first.'
        : '');
    const r = this.backblazeVerifyResult;
    let resultBox = '';
    if (r) {
      if (r.success && r.bucket_ok !== false && r.writable !== false) {
        const bucketLine = r.bucket_name
          ? html`<div>Bucket <code>${r.bucket_name}</code> is
              reachable with this key.</div>`
          : html`<div>No bucket configured yet — credentials look
              good, but set a Backblaze Bucket Name below to finish
              setup.</div>`;
        const writeLine = r.writable === true
          ? html`<div>Key has the capabilities needed to write and
              prune backups.</div>`
          : '';
        resultBox = html`
          <div class="info-box" style="border-left-color: var(--hf-ok);
                                       margin-top: 12px;">
            <strong style="color: var(--hf-ok);">
              ✓ Backblaze credentials verified
            </strong>
            ${bucketLine}
            ${writeLine}
          </div>`;
      } else if (r.success && r.writable === false) {
        // Auth + bucket may be fine, but the key can't write — restic
        // would fail on the first backup. Treat as a hard failure.
        resultBox = html`
          <div class="info-box warn-box" style="margin-top: 12px;">
            <strong>⚠️ Key is read-only for this bucket</strong>
            <div>${r.writable_error
              || 'This application key cannot write or delete files. '
                 + 'Restic backups would fail.'}</div>
            ${r.missing_capabilities && r.missing_capabilities.length
              ? html`<div>Missing capabilities:
                  <code>${r.missing_capabilities.join(', ')}</code></div>`
              : ''}
          </div>`;
      } else if (r.success && r.bucket_ok === false) {
        resultBox = html`
          <div class="info-box warn-box" style="margin-top: 12px;">
            <strong>⚠️ Credentials work, but the bucket check
              failed</strong>
            <div>${r.bucket_error
              || `Bucket '${r.bucket_name}' could not be verified.`}</div>
          </div>`;
      } else {
        resultBox = html`
          <div class="info-box" style="border-left-color: var(--hf-err);
                                       margin-top: 12px;">
            <strong style="color: var(--hf-err);">
              ✗ Backblaze credentials did not verify
            </strong>
            <div>${r.error || 'Unknown error.'}</div>
          </div>`;
      }
    }
    return html`
      <div class="btn-row" style="margin-top: 4px; align-items: center;">
        <button
          class="btn btn-secondary btn-sm"
          ?disabled=${!ready || this.verifyingBackblaze}
          @click=${() => this.handleVerifyBackblaze()}
          title="Live-check the saved Application KeyID / Application Key
                 against Backblaze B2"
        >
          ${this.verifyingBackblaze ? 'Verifying…' : 'Verify Credentials'}
        </button>
        ${disabledHint ? html`
          <span style="font-size: 12.5px; color: var(--hf-text-muted);">
            ${disabledHint}
          </span>` : ''}
      </div>
      ${resultBox}
    `;
  }

  /**
   * Render the Extra Backup Paths table via the shared <table-editor>.
   *
   * Each row is { id, path, enabled }. `id` is the entry's stable
   * identifier and owns the restic repository label (extra-path-<id>)
   * — see services/backup/default.nix. Because labels are bound to id
   * (NOT array position), reordering or deleting rows can never
   * rewire an existing repo to a different source path. Newly-added
   * rows get an id allocated below in the @data-change wrapper;
   * existing entries' ids are preserved through normalize → render →
   * round-trip. Deletion leaves the previous restic repo orphaned in
   * place — purge it via the orphan-repo section to free storage.
   *
   * Tolerates legacy entries (bare string, or object without id) that
   * have not yet been migrated to the new shape: id is filled in from
   * the array index, matching the loader / activation-script
   * fallback so labels remain consistent across the upgrade.
   */
  renderExtraPaths(entries) {
    const toRow = (entry, index) => {
      if (typeof entry === 'string') {
        return { id: String(index), path: entry, enabled: true };
      }
      const rawId = entry && typeof entry.id === 'string' ? entry.id : '';
      return {
        id: rawId !== '' ? rawId : String(index),
        path: entry.path || '',
        enabled: entry.enabled !== false,
      };
    };
    const rows = (entries || []).map(toRow);
    const appliedRows = (this.appliedConfig?.backups?.['extra-from-paths']
      || []).map(toRow);
    const columns = [
      { key: 'path', label: 'Path', type: 'text',
        placeholder: '/mnt/ellis/Documents' },
      { key: 'enabled', label: 'Enabled', type: 'boolean', default: true },
    ];
    // Allocate ids for any newly-added rows BEFORE the change reaches
    // the parent config. The table-editor builds new rows from the
    // visible `columns` (which deliberately exclude id, since id is
    // not user-edited), so a fresh row lands here without one. We
    // assign max(int(existing ids)) + 1, treating non-integer ids as
    // -1 so new ids stay in a simple integer sequence.
    const handleChange = (e) => {
      const data = (e.detail.data || []).slice();
      let maxId = -1;
      for (const row of data) {
        const n = Number.parseInt(row && row.id, 10);
        if (Number.isFinite(n) && n > maxId) maxId = n;
      }
      for (let i = 0; i < data.length; i++) {
        const row = data[i];
        if (!row || typeof row.id !== 'string' || row.id === '') {
          maxId += 1;
          data[i] = { ...row, id: String(maxId) };
        }
      }
      this.handleFieldChange('backups.extra-from-paths', data);
    };
    return html`
      <div class="extra-paths-help">
        HomeFree service data is already backed up automatically; use
        this for user files (Documents, Photos, etc.). Each entry has
        a stable identifier, so deleting or reordering rows never
        affects another entry's backup history. Disabling stops
        scheduled backups for an entry while keeping its restic
        repository intact; deleting leaves the repository orphaned in
        place — use the Purge section below to remove an orphan's
        snapshots once you are sure you do not need them.
      </div>
      <table-editor
        .columns=${columns}
        .data=${rows}
        .appliedData=${appliedRows}
        .rowKey=${'id'}
        .neutralBooleans=${true}
        addLabel="Add Entry"
        @data-change=${handleChange}
      ></table-editor>
    `;
  }

  /**
   * Render the source paths an orphan's latest restic snapshot was
   * backing up. Data comes from this.repositoryPaths (populated by
   * the shared batched warm, /api/backups/paths) — we deliberately
   * do NOT make a separate /paths request per orphan, since each
   * one would block the admin-api event loop on a restic subprocess.
   *
   * Shows a shimmer skeleton until the warm reaches this orphan, an
   * error message if the warm failed, or the path list once ready.
   */
  renderOrphanPaths(orphan) {
    const key = `${orphan.source}:${orphan.label}`;
    const paths = this.repositoryPaths?.[key];
    if (Array.isArray(paths)) {
      if (!paths.length) {
        return html`<div class="orphan-repos-paths placeholder">
          No paths recorded in the latest snapshot.
        </div>`;
      }
      return html`
        <ul class="orphan-repos-paths">
          ${paths.map(p => html`<li>${p}</li>`)}
        </ul>
      `;
    }
    if (this.pathsProgress?.state === 'error') {
      return html`<div class="orphan-repos-paths error">
        Snapshot scan failed. Open the Restore tab and click Retry to
        try again.
      </div>`;
    }
    return html`
      <div class="orphan-repos-paths skeleton-paths">
        <span class="skeleton skeleton-path-row"></span>
        <span class="skeleton skeleton-path-row short"></span>
      </div>
    `;
  }

  /**
   * Render the orphaned restic repositories section. An orphan is a
   * repository that physically exists (a directory under to-path, or
   * a prefix in the B2 bucket) but whose extra-from-paths entry has
   * been deleted from the config. Each row shows the label, source,
   * and a strongly-confirmed Purge button that removes the storage.
   *
   * Hidden when no orphans exist so the Configure tab stays clean
   * for the common case.
   */
  renderOrphanRepos() {
    // Initial fetch in flight — paint a section shell with a single
    // skeleton row so the operator gets layout feedback without
    // waiting on the result. We always render the section while
    // loading so the page-load latency does not hide it; once the
    // result arrives we either show real rows or unmount cleanly
    // (no orphans = section disappears).
    if (this.orphanReposLoading && !this.orphanRepos.length) {
      return html`
        <config-section
          title="Orphaned Backup Repositories"
          description="Checking for restic repositories that no longer
            match an Extra Backup Paths entry…"
        >
          <div class="orphan-repos-list">
            <div class="orphan-repos-row">
              <div class="orphan-repos-main">
                <div class="orphan-repos-label">
                  <span class="skeleton skeleton-title"></span>
                </div>
                <div class="orphan-repos-paths skeleton-paths">
                  <span class="skeleton skeleton-path-row"></span>
                </div>
              </div>
              <span class="skeleton skeleton-purge-btn"></span>
            </div>
          </div>
        </config-section>
      `;
    }
    const orphans = this.orphanRepos || [];
    if (!orphans.length) return '';
    return html`
      <config-section
        title="Orphaned Backup Repositories"
        description="Restic repositories whose entry was removed from
          Extra Backup Paths. Their snapshots are preserved until you
          purge them; the storage is otherwise unreferenced."
      >
        <div class="extra-paths-help">
          Each row below is a restic repository that exists on disk or
          in Backblaze B2 but no longer has a matching Extra Backup
          Paths entry. Purge removes the repository's storage and all
          snapshots it holds — irreversible. Local and Backblaze
          copies are listed separately so you can keep one and purge
          the other.
        </div>
        <div class="orphan-repos-list">
          ${orphans.map(o => {
            const key = `${o.source}:${o.label}`;
            const busy = this.purgingOrphan === key;
            return html`
              <div class="orphan-repos-row">
                <div class="orphan-repos-main">
                  <div class="orphan-repos-label">
                    <strong>${o.label}</strong>
                    <span class="orphan-repos-source">${o.source}</span>
                  </div>
                  ${this.renderOrphanPaths(o)}
                </div>
                <button
                  class="btn btn-danger btn-sm"
                  ?disabled=${busy || this.purgingOrphan !== ''}
                  @click=${() => this.handlePurgeOrphan(o)}
                >${busy ? 'Purging…' : 'Purge'}</button>
              </div>
            `;
          })}
        </div>
      </config-section>
    `;
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

  /**
   * Back up a single repository to one source ('local'|'backblaze').
   * `label` is the repository id used by the API (e.g. extra-path-5);
   * the confirm dialog shows the resolved real path/name instead.
   */
  handleRunService(label, source) {
    const sourceLabel = source === 'backblaze' ? 'Backblaze' : 'local';
    // Prefer the real directory for extra-path repos; fall back to the
    // repo id for service repos (which are already human-readable).
    const paths = this.sourcePaths?.[label];
    const display = (this.isExtraPathRepo(label) && paths && paths.length)
      ? paths[0] : label;
    this.confirmModal().show(
      `Back Up ${display}`,
      `Run the ${sourceLabel} backup for ${display} now.`,
      'confirm',
      {
        confirmText: 'Run Backup',
        cancelText: 'Cancel',
        confirmVariant: 'primary',
        details: [
          { message: `Only ${display} is backed up — other `
              + 'repositories are left untouched', type: 'info' },
          { message: 'Runs in the background; you can leave this page',
            type: 'info' }
        ],
        confirmCallback: () => this.startJob(
          `/api/backups/services/${encodeURIComponent(label)}`
          + `/trigger?source=${source}`, null)
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
  //
  // renderJobBanner() and renderJobOverlay() are provided by
  // BackupJobControllerMixin.

  // ----------------------------------------------------- render: config

  /**
   * Status tab - the landing view. Answers "are my backups OK?":
   * the live job banner, the per-source Backup Health panel, and the
   * Backup Self-Test. On-demand triggering lives on the Run tab.
   */
  renderStatusTab() {
    return html`
      ${this.renderJobBanner()}
      ${this.renderBackupHealth()}
      ${this.renderCanarySection()}
    `;
  }

  // -------------------------------------------------------- render: run

  /**
   * Run tab - on-demand backups. Bulk triggers at the top, then a
   * per-service list grouped like the Restore tab, each row showing
   * the repository's real name / path. Scheduled backups still run
   * nightly — this tab is for an immediate, ad-hoc run.
   */
  renderRunTab() {
    const resticReady =
      !!this.backupConfigStatus?.restic_password_configured;

    if (!resticReady) {
      return html`
        ${this.renderJobBanner()}
        <config-section title="Run Backups"
          description="Start a backup now, in addition to the nightly schedule">
          <div class="info-box warn-box">
            <strong>⚠️ Restic password not configured</strong>
            <div>Set the Restic backup password on the Configure tab
              before running backups.</div>
          </div>
        </config-section>
      `;
    }

    const b2Ready = !!this.backupConfigStatus?.backblaze_available;
    const busy = this.actionsLocked;

    return html`
      ${this.renderJobBanner()}
      <config-section
        title="Run Backups"
        description="Start a backup now, in addition to the nightly schedule"
      >
        <div class="btn-row">
          <button
            class="btn btn-secondary"
            @click=${() => this.handleTriggerBackups()}
            ?disabled=${busy}
          >Run All Backups</button>
          ${b2Ready ? html`
            <button
              class="btn btn-secondary"
              @click=${() => this.handleBackupBackblaze()}
              ?disabled=${busy}
            >Back Up All to Backblaze</button>
          ` : ''}
        </div>
        ${busy ? html`
          <p style="font-size:13px;color:var(--hf-text-muted);
                    margin-top:8px;">
            A ${this.jobKindLabel(this.currentJob.kind).toLowerCase()} is
            currently running — see the banner above.
          </p>` : ''}

        <h3 style="font-size:16px;font-weight:600;margin:24px 0 12px;">
          Back up an individual repository
        </h3>
        ${this.repoListLoading && !this._servicesLoadedOnce ? html`
          <div class="status-line muted">
            <span class="spinner"></span>
            Loading backup repositories…
          </div>
        ` : this.repoListError ? html`
          <div class="status-line err">${this.repoListError}</div>
        ` : html`
          ${this.renderRunGroup('box', 'Services',
              'Service data, databases, and application configuration',
              this.localServices, this.backblazeServices)}
          ${this.renderRunGroup('folder', 'Extra Paths',
              'User-defined custom paths (e.g. NAS folders)',
              this.localExtraPaths, this.backblazeExtraPaths)}
          ${this.renderRunGroup('settings', 'System Configuration',
              'Network and service configuration (/etc/nixos)',
              this.localSystemConfig, this.backblazeSystemConfig)}
          ${this.repoCount() === 0 ? html`
            <div class="status-line muted">
              No backup repositories found.
            </div>` : ''}
        `}
      </config-section>
    `;
  }

  /** A group of run-rows (Services / Extra Paths / System Config). */
  renderRunGroup(iconId, title, desc, localRepos, bbRepos) {
    if (localRepos.length === 0 && bbRepos.length === 0) return '';
    // One row per repo: a repo backed up both locally and to Backblaze
    // is a single entry with both trigger buttons.
    const repos = [...new Set([...localRepos, ...bbRepos])].sort();
    return html`
      <div class="repo-group">
        <h4><span class="repo-group-icon">${navIcon(iconId)}</span>${title}</h4>
        <p class="desc">${desc}</p>
        <div class="svc-backup-list">
          ${repos.map(r => this.renderRunRow(r))}
        </div>
      </div>
    `;
  }

  /**
   * One repository in the Run tab: real name / path on the left,
   * Local + Backblaze trigger buttons on the right. Flat — no
   * expand/collapse (that is the Restore tab's renderRepoRow).
   */
  renderRunRow(repo) {
    const busy = this.actionsLocked;
    const sources = this.sourcesForRepo(repo);
    const isExtra = this.isExtraPathRepo(repo);

    // SOURCE directories from config (loadSourcePaths) — keyed by the
    // bare repo label. No restic, resolves near-instantly.
    const paths = this.sourcePaths[repo] || [];

    // Service repos show the service name; extra-path repos show the
    // actual backed-up directory (fall back to the label if config
    // hasn't been read yet, or the repo has no recorded paths).
    let title = repo;
    if (isExtra && paths.length > 0) title = paths[0];

    // Secondary line: for extra-path repos, "+N more"; for service
    // repos, the source directories (skip the dump dirs we appended).
    let summary = '';
    if (isExtra && paths.length > 1) {
      summary = `+${paths.length - 1} more path`
        + (paths.length - 1 !== 1 ? 's' : '');
    } else if (!isExtra && paths.length > 0) {
      const dirs = paths.filter(
        p => !p.startsWith('/var/backup/'));
      if (dirs.length) {
        const head = dirs.slice(0, 2).join(', ');
        summary = dirs.length > 2
          ? `${head} +${dirs.length - 2} more` : head;
      }
    }

    return html`
      <div class="svc-backup-row">
        <div class="svc-backup-name">
          <span title=${title}>${title}</span>
          ${summary
            ? html`<div class="repo-paths">${summary}</div>` : ''}
        </div>
        <div class="svc-backup-actions">
          ${sources.includes('local') ? html`
            <button
              class="btn btn-secondary btn-sm"
              title="Back up ${repo} to the local repository"
              @click=${() => this.handleRunService(repo, 'local')}
              ?disabled=${busy}
            >Local</button>
          ` : ''}
          ${sources.includes('backblaze') ? html`
            <button
              class="btn btn-secondary btn-sm"
              title="Back up ${repo} to Backblaze B2"
              @click=${() => this.handleRunService(repo, 'backblaze')}
              ?disabled=${busy}
            >Backblaze</button>
          ` : ''}
        </div>
      </div>
    `;
  }

  renderConfigurationTab() {
    const { backups } = this.config;

    // Remote-backup readiness gates the warning under the toggle.
    // "Ready" means: bucket name set AND both credentials saved AND
    // the last live verify came back fully green (auth + bucket +
    // write capabilities). The verify result is cleared whenever any
    // of those inputs change, so a stale ✓ cannot leak through.
    const remoteEnabled = !!backups['backblaze-enable'];
    const bucketSet = !!backups['backblaze-bucket'];
    const idSet = !!this.secretsStatus?.['backblaze-id'];
    const keySet = !!this.secretsStatus?.['backblaze-key'];
    // Inputs missing for remote backups. The actual Verify pass/fail
    // surfaces next to the Verify button in renderBackblazeVerify, so
    // this banner stays focused on "what does the user still need to
    // fill in?" — auto-verify handles the rest once everything's set.
    const v = this.backblazeVerifyResult;
    const remoteWarnings = [];
    let remoteVerifyFailed = false;
    if (remoteEnabled) {
      if (!bucketSet) remoteWarnings.push('a bucket name');
      if (!idSet) remoteWarnings.push('an Application KeyID');
      if (!keySet) remoteWarnings.push('an Application Key');
      // A verify result exists AND it didn't fully pass — show a
      // distinct banner pointing the user at the diagnostic details
      // in the Remote Backups section.
      if (bucketSet && idSet && keySet && v
          && (!v.success || v.bucket_ok === false
              || v.writable === false)) {
        remoteVerifyFailed = true;
      }
    }

    return html`
      ${this.renderJobBanner()}

      <config-section title="General">
        <form-field
          label="Enable Local Backups"
          type="boolean"
          .value=${backups.enable}
          help="Back up to a local storage device on this machine"
          ?undeployed=${this._undeployed('backups.enable')}
          @field-change=${(e) =>
            this.handleFieldChange('backups.enable', e.detail.value)}
        ></form-field>

        <form-field
          label="Enable Remote Backups"
          type="boolean"
          .value=${backups['backblaze-enable']}
          help="Also send encrypted backups to off-site cloud storage"
          ?undeployed=${this._undeployed('backups.backblaze-enable')}
          @field-change=${(e) =>
            this.handleFieldChange('backups.backblaze-enable', e.detail.value)}
        ></form-field>
        ${remoteEnabled && remoteWarnings.length ? html`
          <div class="info-box warn-box">
            <strong>⚠️ Remote backups are not ready yet</strong>
            <div>Configure ${this._listAnd(remoteWarnings)} in the
              <strong>Remote Backups</strong> section below. Until then,
              the nightly remote backup will fail.</div>
          </div>
        ` : (remoteEnabled && remoteVerifyFailed ? html`
          <div class="info-box warn-box">
            <strong>⚠️ Remote credentials did not verify</strong>
            <div>The bucket name or credentials in the
              <strong>Remote Backups</strong> section below were
              rejected by Backblaze B2. Open that section for the
              detailed error and fix the failing input.</div>
          </div>
        ` : '')}

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
          label="Backup Encryption Password"
          description="Encryption password for backup repositories (required for backups and restores)"
          .exists=${this.secretsStatus?.['restic-password'] || false}
          ?disabled=${!this.hasAuthorizedKeys}
          @secret-updated=${() => this.handleSecretUpdated()}
        ></secrets-input>
        <div class="info-box warn-box">
          <strong>⚠️ Save this password somewhere safe</strong>
          <div>The encryption password protects every backup. Store it in
            a password manager or another safe place <em>outside</em> this
            machine — if you lose it, your backups cannot be
            recovered.</div>
        </div>
      </config-section>

      <config-section
        title="Local Backups"
        description="Automatic encrypted backups to a local storage device using Restic"
      >
        <form-field
          label="Backup Directory"
          type="text"
          .value=${backups['to-path']}
          placeholder="/var/lib/backups"
          help="Path to local backup storage. To target an NFS share, add it in the Mounts module first."
          ?undeployed=${this._undeployed('backups.to-path')}
          @field-change=${(e) =>
            this.handleFieldChange('backups.to-path', e.detail.value)}
        ></form-field>

        ${backups.enable ? html`
          <div class="info-box">
            <strong>ℹ️ Backup Information</strong>
            <div>HomeFree uses Restic for encrypted, deduplicated backups.
              Local backups run automatically after 2 AM daily (staggered);
              ${backups['backblaze-enable']
                ? 'remote backups run after 4 AM. '
                : ''}each service is a separate restic repository with
              7-daily / 5-weekly / 10-yearly retention.
              To run a backup on demand, use
              the&nbsp;<strong>Run</strong>&nbsp;tab.</div>
          </div>
        ` : ''}
      </config-section>

      <config-section
        title="Remote Backups"
        description="Off-site encrypted backups to cloud storage"
      >
        <div class="info-box">
          <strong>ℹ️ Remote backups use Backblaze B2 Cloud Storage</strong>
          <div>To use it:
            <ul>
              <li>Create a B2 account at
                <a href="https://www.backblaze.com/" target="_blank"
                   rel="noopener noreferrer">backblaze.com</a></li>
              <li>Create a bucket for your backups</li>
              <li>Generate application keys with read/write access</li>
              <li>Fill in the bucket name and credentials below</li>
            </ul>
          </div>
        </div>

        <form-field
          label="Backblaze Bucket Name"
          type="text"
          .value=${backups['backblaze-bucket']}
          placeholder="my-homefree-backups"
          help="B2 bucket name for storing backups"
          .error=${backups['backblaze-enable']
            && !backups['backblaze-bucket']
            ? 'A bucket name is required when remote backups are enabled.'
            : ''}
          ?undeployed=${this._undeployed('backups.backblaze-bucket')}
          @field-change=${(e) =>
            this.handleFieldChange('backups.backblaze-bucket', e.detail.value)}
        ></form-field>

        <div class="subsection">
          <div class="subsection-header">
            <div class="subsection-title">Backblaze B2 Credentials</div>
            <div class="subsection-description">
              Application Key for your
              <a href="https://www.backblaze.com/" target="_blank"
                 rel="noopener noreferrer">Backblaze</a>
              B2 account. Create one under
              <em>Application Keys</em> in the B2 console.
            </div>
          </div>
          <secrets-input
            serviceLabel="backup"
            secretKey="backblaze-id"
            label="Backblaze Application KeyID"
            description="Your Backblaze B2 Application KeyID"
            .exists=${this.secretsStatus?.['backblaze-id'] || false}
            ?missing=${remoteEnabled
              && !this.secretsStatus?.['backblaze-id']}
            missingMessage="Set the Application KeyID to enable remote backups."
            ?disabled=${!this.hasAuthorizedKeys}
            @secret-updated=${() => this.handleSecretUpdated()}
          ></secrets-input>
          <secrets-input
            serviceLabel="backup"
            secretKey="backblaze-key"
            label="Backblaze Application Key"
            description="Your Backblaze B2 application key"
            .exists=${this.secretsStatus?.['backblaze-key'] || false}
            ?missing=${remoteEnabled
              && !this.secretsStatus?.['backblaze-key']}
            missingMessage="Set the Application Key to enable remote backups."
            ?disabled=${!this.hasAuthorizedKeys}
            @secret-updated=${() => this.handleSecretUpdated()}
          ></secrets-input>

          ${this.renderBackblazeVerify()}
        </div>
      </config-section>

      <config-section
        title="Extra Backup Paths"
        description="Additional directories to include in scheduled backups"
      >
        ${this.renderExtraPaths(backups['extra-from-paths'] || [])}
      </config-section>

      ${this.renderOrphanRepos()}
    `;
  }

  /** Oxford-comma join: ["a"] → "a"; ["a","b"] → "a and b";
   *  ["a","b","c"] → "a, b, and c". Used by the General-section
   *  "Remote backups are not ready yet" warning. */
  _listAnd(items) {
    if (!items || items.length === 0) return '';
    if (items.length === 1) return items[0];
    if (items.length === 2) return `${items[0]} and ${items[1]}`;
    return `${items.slice(0, -1).join(', ')}, and ${items[items.length - 1]}`;
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

    // Three states, in priority order:
    //   err   - one or more backups ran and errored (a real problem)
    //   warn  - none errored, but some have never run yet (an unknown,
    //           e.g. a freshly-provisioned box before its first window)
    //   ok    - every backup has run and the last run succeeded
    const failed = data.failed || 0;
    const neverRun = data.never_run || 0;
    let cls;
    let summary;
    if (failed > 0) {
      cls = 'err';
      summary = html`<span class="health-badge err">✗ ${failed}
          failed</span>`;
    } else if (neverRun > 0) {
      cls = 'warn';
      summary = html`<span class="health-badge warn">⚠ ${neverRun}
          never run</span>`;
    } else {
      cls = 'ok';
      summary = html`<span class="health-badge ok">✓ Healthy</span>`;
    }

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
        ${failed > 0 && data.failed_services?.length ? html`
          <div class="health-failed">
            Failed: ${data.failed_services.join(', ')}
          </div>` : ''}
        ${neverRun > 0 && data.never_run_services?.length ? html`
          <div class="health-failed health-never">
            Never run: ${data.never_run_services.join(', ')}
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
          ?undeployed=${dirty}
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
            : (this.canaryStarting ? 'Starting…' : 'Run Check Now')}
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
        ?undeployed=${this._undeployed('services.backup-canary.selftest-source')}
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
            Configure tab before restoring.
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
          ${this.renderRepoGroup('box', 'Services',
              'Service data, databases, and application configuration',
              this.localServices, this.backblazeServices, false)}
          ${this.renderRepoGroup('folder', 'Extra Paths',
              'User-defined custom paths (e.g. NAS folders)',
              this.localExtraPaths, this.backblazeExtraPaths, false)}
          ${this.renderRepoGroup('settings', 'System Configuration',
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

  renderRepoGroup(iconId, title, desc, localRepos, bbRepos, isSystem) {
    if (localRepos.length === 0 && bbRepos.length === 0) return '';
    // One card per repo: a repo backed up both locally and to Backblaze
    // is a single entry, with the source chosen inside the card.
    const repos = [...new Set([...localRepos, ...bbRepos])].sort();
    return html`
      <div class="repo-group ${isSystem ? 'system' : ''}">
        <h4 style=${isSystem ? 'color:var(--hf-warn);' : ''}>
          <span class="repo-group-icon">${navIcon(iconId)}</span>${title}
        </h4>
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
          <button class="tab ${this.activeTab === 'run'
            ? 'active' : ''}"
            @click=${() => this.handleTabChange('run')}
          >Run</button>
          <button class="tab ${this.activeTab === 'restore' ? 'active' : ''}"
            @click=${() => this.handleTabChange('restore')}
          >Restore</button>
          <button class="tab ${this.activeTab === 'configuration'
            ? 'active' : ''}"
            @click=${() => this.handleTabChange('configuration')}
          >Configure</button>
        </div>

        ${this.activeTab === 'configuration'
          ? this.renderConfigurationTab()
          : this.activeTab === 'restore'
            ? this.renderRestoreTab()
            : this.activeTab === 'run'
              ? this.renderRunTab()
              : this.renderStatusTab()}
      </div>

      ${this.renderJobOverlay()}
      <progress-modal></progress-modal>
    `;
  }
}

customElements.define('backups-module', BackupsModule);
