import { LitElement, html, css } from 'lit';
import { getAppVersions, refreshAppVersions } from '../../../api/client.js';

/**
 * App Versions module (Advanced section).
 *
 * Read-only view of every container declared on the box, showing its
 * currently-deployed image tag alongside the latest tag available
 * from upstream. The backend serves a cached snapshot — see
 * web-platform/backend/resolvers/app_versions.py for how the cache
 * is populated (daily systemd timer + on-demand refresh button).
 */
class AppVersionsModule extends LitElement {
  static properties = {
    loading: { type: Boolean, state: true },
    refreshing: { type: Boolean, state: true },
    error: { type: String, state: true },
    apps: { type: Array, state: true },
  };

  static styles = css`
    :host { display: block; }

    .module-container { width: 100%; }

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
    .info-box > strong:first-child {
      display: block;
      margin-bottom: 8px;
    }

    .toolbar {
      display: flex;
      align-items: center;
      gap: 12px;
      flex-wrap: wrap;
      margin-bottom: 16px;
    }
    .summary {
      color: var(--hf-text-muted);
      font-size: 13px;
    }
    .summary .sep { margin: 0 8px; color: var(--hf-text-subtle); }
    .summary .count { color: var(--hf-text); font-weight: 600; }
    .summary .outdated { color: var(--hf-warn); }
    .summary .floating { color: #60a5fa; }
    .summary .local    { color: #a78bfa; }
    .summary .unknown { color: var(--hf-text-muted); }
    .summary .ok { color: var(--hf-ok); }

    .toolbar .spacer { flex: 1; }

    button.btn {
      padding: 9px 16px;
      background: var(--hf-surface-2);
      color: var(--hf-text);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      cursor: pointer;
      font-size: 13px;
      font-weight: 500;
      font-family: inherit;
    }
    button.btn:hover:not(:disabled) {
      background: var(--hf-surface-3);
      border-color: var(--hf-text-subtle);
    }
    button.btn:disabled { opacity: 0.5; cursor: wait; }

    .table-wrap {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      overflow-x: auto;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 13px;
    }
    th, td {
      text-align: left;
      padding: 10px 14px;
      border-bottom: 1px solid var(--hf-border);
      vertical-align: top;
    }
    th {
      color: var(--hf-text-muted);
      font-weight: 600;
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      background: var(--hf-surface-2);
      position: sticky;
      top: 0;
    }
    tr:last-child td { border-bottom: none; }

    .name {
      color: var(--hf-text);
      font-weight: 600;
    }
    .name .container {
      display: block;
      font-weight: 400;
      font-size: 12px;
      color: var(--hf-text-muted);
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    }
    .registry {
      color: var(--hf-text-muted);
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 12px;
    }
    .version {
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      color: var(--hf-text);
    }
    .latest .note {
      display: block;
      color: var(--hf-text-muted);
      font-family: inherit;
      font-size: 11px;
      margin-top: 2px;
    }

    .pill {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 3px 9px;
      border-radius: 999px;
      font-size: 11px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      white-space: nowrap;
    }
    .pill.ok       { background: rgba(74,222,128,0.12); color: #4ade80; }
    .pill.outdated { background: rgba(250,204,21,0.12); color: #facc15; }
    .pill.floating { background: rgba(96,165,250,0.12); color: #60a5fa; }
    .pill.local    { background: rgba(167,139,250,0.12); color: #a78bfa; }
    .pill.unknown  { background: rgba(148,163,184,0.12); color: var(--hf-text-muted); }

    /* Advisory badge — severity-coloured, links to the project's
       GitHub advisories list. Smaller than the status pill so it
       reads as a secondary signal on the row. */
    a.adv-badge {
      display: inline-flex;
      align-items: center;
      gap: 4px;
      padding: 2px 8px;
      margin-top: 4px;
      border-radius: 999px;
      font-size: 11px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      white-space: nowrap;
      text-decoration: none;
    }
    a.adv-badge.critical { background: rgba(239,68,68,0.16);  color: #f87171; }
    a.adv-badge.high     { background: rgba(249,115,22,0.16); color: #fb923c; }
    a.adv-badge.medium   { background: rgba(250,204,21,0.12); color: #facc15; }
    a.adv-badge.low      { background: rgba(148,163,184,0.12); color: var(--hf-text-muted); }
    a.adv-badge:hover { filter: brightness(1.15); text-decoration: underline; }

    a.release-link {
      display: inline-block;
      margin-top: 4px;
      font-size: 11px;
      color: var(--hf-accent);
      text-decoration: none;
    }
    a.release-link:hover { text-decoration: underline; }

    tr.outdated .version { color: var(--hf-warn); }
    tr.unknown  td      { opacity: 0.85; }
    tr.floating td      { opacity: 0.95; }
    tr.local    td      { opacity: 0.95; }
    /* A row with critical or high advisories carries an extra signal —
       give the latest cell a faint red tint so the row stands out
       even at a glance, regardless of update status. */
    tr.has-critical-advisory td.col-latest { background: rgba(239,68,68,0.06); }
    tr.has-high-advisory     td.col-latest { background: rgba(249,115,22,0.05); }

    .error {
      background: rgba(59, 130, 246, 0.08);
      border-left: 4px solid var(--hf-err);
      color: var(--hf-text-muted);
      padding: 14px 18px;
      border-radius: 8px;
      margin-bottom: 16px;
      font-size: 13px;
      line-height: 1.5;
    }
    .muted { color: var(--hf-text-muted); font-size: 13px; }

    /* Mobile: collapse registry into a subtitle under the service
       name; stack the current/latest cells inside a single column
       so the row still fits on a phone. */
    @media (max-width: 700px) {
      th.col-registry, td.col-registry { display: none; }
      th.col-current,  td.col-current  { display: none; }
      th.col-latest { font-size: 11px; }
      td.col-latest .stacked {
        display: flex;
        flex-direction: column;
        gap: 2px;
      }
      td.col-latest .current-inline {
        color: var(--hf-text-muted);
        font-size: 11px;
      }
      .name .container { font-size: 11px; }
      .name .registry-inline {
        display: block;
        font-weight: 400;
        font-size: 11px;
        color: var(--hf-text-muted);
        font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      }
    }
    @media (min-width: 701px) {
      .name .registry-inline { display: none; }
      td.col-latest .current-inline { display: none; }
    }
  `;

  constructor() {
    super();
    this.loading = true;
    this.refreshing = false;
    this.error = '';
    this.apps = [];
    this._pollTimer = null;
    this._pollDeadline = 0;
  }

  connectedCallback() {
    super.connectedCallback();
    this.load();
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this._pollTimer) {
      clearTimeout(this._pollTimer);
      this._pollTimer = null;
    }
  }

  async load() {
    this.loading = true;
    this.error = '';
    try {
      const result = await getAppVersions();
      this.apps = Array.isArray(result?.apps) ? result.apps : [];
    } catch (e) {
      this.error = e.message || 'Failed to load app versions.';
    } finally {
      this.loading = false;
    }
  }

  async refresh() {
    if (this.refreshing) return;
    this.refreshing = true;
    this.error = '';
    try {
      await refreshAppVersions();
      // Snapshot the existing last_checked values so we can detect
      // when the backend has finished writing new ones.
      const baseline = new Map(
        (this.apps || []).map((a) => [a.name, a.last_checked || ''])
      );
      this._pollDeadline = Date.now() + 60_000;
      this._pollForUpdates(baseline);
    } catch (e) {
      this.error = e.message || 'Failed to start refresh.';
      this.refreshing = false;
    }
  }

  async _pollForUpdates(baseline) {
    try {
      const result = await getAppVersions();
      this.apps = Array.isArray(result?.apps) ? result.apps : [];
      // Done when every row's last_checked has advanced past the
      // baseline (or the row's status is no longer pending). If
      // baseline was empty (first ever refresh), any non-null
      // last_checked is fresh.
      const advanced = this.apps.every((a) => {
        const before = baseline.get(a.name) || '';
        return (a.last_checked || '') !== before;
      });
      if (advanced || Date.now() > this._pollDeadline) {
        this.refreshing = false;
        this._pollTimer = null;
        return;
      }
    } catch (e) {
      // Transient errors during polling are fine — just keep trying
      // until the deadline.
    }
    this._pollTimer = setTimeout(
      () => this._pollForUpdates(baseline), 5000
    );
  }

  _renderCounts() {
    const outdated = this.apps.filter((a) => a.status === 'outdated').length;
    const ok = this.apps.filter((a) => a.status === 'up-to-date').length;
    const floating = this.apps.filter((a) => a.status === 'floating').length;
    const local = this.apps.filter((a) => a.status === 'local').length;
    const unknown = this.apps.filter((a) => a.status === 'unknown').length;
    return html`
      <span class="summary">
        <span class="count outdated">${outdated}</span> updates available
        <span class="sep">·</span>
        <span class="count ok">${ok}</span> up to date
        ${floating > 0 ? html`
          <span class="sep">·</span>
          <span class="count floating">${floating}</span> floating
        ` : ''}
        ${local > 0 ? html`
          <span class="sep">·</span>
          <span class="count local">${local}</span> local
        ` : ''}
        ${unknown > 0 ? html`
          <span class="sep">·</span>
          <span class="count unknown">${unknown}</span> unknown
        ` : ''}
      </span>
    `;
  }

  _renderPill(status) {
    if (status === 'up-to-date') {
      return html`<span class="pill ok">Up to date</span>`;
    }
    if (status === 'outdated') {
      return html`<span class="pill outdated">Update available</span>`;
    }
    if (status === 'floating') {
      return html`<span class="pill floating">Floating tag</span>`;
    }
    if (status === 'local') {
      return html`<span class="pill local">Local image</span>`;
    }
    return html`<span class="pill unknown">Unknown</span>`;
  }

  _renderAdvisoryBadge(app) {
    if (!app.advisory_count || !app.advisories_url) return '';
    const severity = app.advisory_max_severity || 'low';
    const titles = (app.advisories || [])
      .map((a) => `${(a.severity || '?').toUpperCase()}: ${a.summary || a.id}`)
      .join('\n');
    const label = app.advisory_count === 1
      ? '1 advisory'
      : `${app.advisory_count} advisories`;
    return html`
      <a class="adv-badge ${severity}"
         href=${app.advisories_url}
         target="_blank"
         rel="noopener noreferrer"
         title=${titles}>${label} (${severity})</a>
    `;
  }

  _renderRow(app) {
    const projectLabel = app.project_name || app.name;
    const registryShort = app.registry
      ? (app.repo ? app.registry + '/' + app.repo : app.registry)
      : (app.repo || '');
    const rowClasses = [app.status];
    const sev = app.advisory_max_severity;
    if (sev === 'critical') rowClasses.push('has-critical-advisory');
    else if (sev === 'high') rowClasses.push('has-high-advisory');
    return html`
      <tr class=${rowClasses.join(' ')}>
        <td class="name">
          ${projectLabel}
          ${projectLabel !== app.name
            ? html`<span class="container">${app.name}</span>`
            : ''}
          ${registryShort
            ? html`<span class="registry-inline">${registryShort}</span>`
            : ''}
        </td>
        <td class="col-registry registry">${registryShort || ''}</td>
        <td class="col-current version">${app.current || '—'}</td>
        <td class="col-latest version latest">
          <div class="stacked">
            <span>${app.latest || 'Unknown'}</span>
            ${app.current
              ? html`<span class="current-inline">current ${app.current}</span>`
              : ''}
            ${app.note && app.status !== 'up-to-date'
              ? html`<span class="note" title=${app.note}>${app.note}</span>`
              : ''}
            ${app.changelog_url
              ? html`<a class="release-link"
                        href=${app.changelog_url}
                        target="_blank"
                        rel="noopener noreferrer">Release notes ↗</a>`
              : ''}
            ${this._renderAdvisoryBadge(app)}
          </div>
        </td>
        <td>${this._renderPill(app.status)}</td>
      </tr>
    `;
  }

  render() {
    return html`
      <div class="module-container">
        <div class="info-box">
          <strong>App versions</strong>
          Every container declared on this box, with the version that is
          currently deployed and the latest version available from each
          image's upstream registry. Latest-version lookups run once a
          day in the background; click Refresh to fetch fresh data on
          demand. Images on unsupported registries show
          <strong>Unknown</strong> with a short reason.
        </div>

        ${this.error ? html`<div class="error">${this.error}</div>` : ''}

        <div class="toolbar">
          ${this.loading && this.apps.length === 0
            ? html`<span class="muted">Loading…</span>`
            : this._renderCounts()}
          <span class="spacer"></span>
          <button
            class="btn"
            @click=${this.refresh}
            ?disabled=${this.refreshing || this.loading}
          >${this.refreshing ? 'Refreshing…' : 'Refresh'}</button>
        </div>

        ${this.loading && this.apps.length === 0
          ? html`<p class="muted">Loading container catalog…</p>`
          : this.apps.length === 0
            ? html`<p class="muted">No containers declared on this box.</p>`
            : html`
              <div class="table-wrap">
                <table>
                  <thead>
                    <tr>
                      <th>Service</th>
                      <th class="col-registry">Image</th>
                      <th class="col-current">Current</th>
                      <th class="col-latest">Latest</th>
                      <th>Status</th>
                    </tr>
                  </thead>
                  <tbody>
                    ${this.apps.map((a) => this._renderRow(a))}
                  </tbody>
                </table>
              </div>
            `}
      </div>
    `;
  }
}

customElements.define('app-versions-module', AppVersionsModule);
