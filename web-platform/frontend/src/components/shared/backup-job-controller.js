import { html, css } from 'lit';

/**
 * Shared backup-job controller.
 *
 * Long-running backup-subsystem operations (trigger, sync, restore)
 * are modelled as backend "jobs": a component POSTs a job-starting
 * endpoint, then a single poller watches /api/backups/jobs/current and
 * tails the job log, rendering a live progress overlay with a
 * per-repository checklist.
 *
 * This logic is shared by more than one admin page (the Backups
 * configuration page and the Status page), so it lives here as:
 *
 *   - `BackupJobControllerMixin(Base)` — a Lit class mixin carrying the
 *     job state, the poller, `startJob()`, and the banner/overlay
 *     renders. Mix it into a LitElement subclass.
 *   - `backupJobStyles` — the `css` rules the banner/overlay markup
 *     needs; add it to the host component's `static styles` array.
 *
 * A host component MUST provide a `showNotification(message, type)`
 * method (the mixin calls it on success/failure). It MAY override
 * `onJobFinishedHook(job)` to refresh page-specific data when a job
 * ends (default: no-op).
 *
 * Reactive properties the mixin contributes (the host must spread
 * `BackupJobControllerMixin.properties` into its own `static
 * properties`): `currentJob`, `jobLog`, `jobOverlayOpen`.
 */
export const BackupJobControllerMixin = (Base) => {
  class BackupJobController extends Base {
    static properties = {
      ...(Base.properties || {}),
      currentJob: { type: Object },
      jobLog: { type: String },
      jobOverlayOpen: { type: Boolean },
    };

    constructor() {
      super();
      this.currentJob = null;
      this.jobLog = '';
      this.jobOverlayOpen = false;
      // internal (non-reactive)
      this._jobPollTimer = null;
      this._jobLogOffset = 0;
    }

    // --------------------------------------------------------- lifecycle

    /**
     * Attach the job poller if a job is already running. Call this from
     * the host's connectedCallback (after it has fetched the current
     * job via refreshCurrentJob()).
     */
    connectedCallback() {
      super.connectedCallback();
      this._jobBeforeUnload = () => this.stopJobPolling();
      window.addEventListener('beforeunload', this._jobBeforeUnload);
    }

    disconnectedCallback() {
      super.disconnectedCallback();
      if (this._jobBeforeUnload) {
        window.removeEventListener('beforeunload', this._jobBeforeUnload);
      }
      this.stopJobPolling();
    }

    // --------------------------------------------------------- job model

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

        // A new job appeared or the tracked job changed: reset the tail.
        if (this.currentJob && (!prev || prev.id !== this.currentJob.id)) {
          this._jobLogOffset = 0;
          this.jobLog = '';
        }
        if (this.currentJob) {
          await this.fetchJobLog(this.currentJob.id);
        }

        // Job just finished: stop polling, refresh derived data.
        if (prev && this.isJobActive(prev) &&
            !this.isJobActive(this.currentJob)) {
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
      // Page-specific follow-up (refresh repo lists, health, etc.).
      this.onJobFinishedHook(job);
    }

    /** Override in the host to refresh page-specific data on job end. */
    onJobFinishedHook(_job) {}

    jobKindLabel(kind) {
      return {
        'restore': 'Restore',
        'restore-all': 'Full-system restore',
        'backup': 'Local backup',
        'sync': 'Backblaze backup',
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
          body: body ? JSON.stringify(body) : undefined,
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

    // ------------------------------------------------------ job renders

    repoStateIcon(state) {
      return { pending: '·', running: '⟳', done: '✓', failed: '✕' }[state]
        || '·';
    }

    closeOverlayIfDone() {
      if (!this.isJobActive(this.currentJob)) this.jobOverlayOpen = false;
    }

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
        sub = job.error ||
          `${failed} repositor${failed === 1 ? 'y' : 'ies'} failed`;
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
                         : (job.state === 'failed'
                             ? '— failed' : '— complete')}
              </span>
            </div>

            <div class="job-panel-body">
              ${showChecklist ? html`
                <div class="progress-bar">
                  <div style="width:${pct}%"></div>
                </div>
                <div class="repo-progress">
                  ${job.repos.map(r => html`
                    <div class="progress-row ${r.state}">
                      <span class="ico">${this.repoStateIcon(r.state)}</span>
                      <span>${r.name}</span>
                      ${r.error
                        ? html`<span class="err">${r.error}</span>` : ''}
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
                  ? `${done}/${total} done${failed
                      ? `, ${failed} failed` : ''}`
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
  }
  return BackupJobController;
};

/**
 * CSS the renderJobBanner()/renderJobOverlay() markup depends on. Add
 * to a host component's `static styles` array, e.g.
 *   static styles = [backupJobStyles, css`...own rules...`];
 *
 * Assumes the host already defines the `.btn`, `.btn-primary`,
 * `.btn-secondary` button classes (every admin module does) and the
 * `--hf-*` design tokens.
 */
export const backupJobStyles = css`
  .spinner {
    display: inline-block;
    width: 14px; height: 14px;
    border: 2px solid currentColor;
    border-top-color: transparent;
    border-radius: 50%;
    animation: hf-job-spin 1s linear infinite;
    flex-shrink: 0;
  }
  .spinner.lg { width: 18px; height: 18px; }
  @keyframes hf-job-spin { to { transform: rotate(360deg); } }

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

  /* ---- job overlay ---- */
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
`;
