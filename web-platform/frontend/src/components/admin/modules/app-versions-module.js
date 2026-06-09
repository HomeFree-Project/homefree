import { LitElement, html, css } from 'lit';
import {
  getAppVersions,
  refreshAppVersions,
  upgradeApps,
  getHomefreeBase,
  saveHomefreeBase,
  validateHomefreeBase,
  updateHomefreeBaseFlakes,
  getHomefreeBaseNixpkgs,
  getIsoStatus,
  buildIso,
} from '../../../api/client.js';
import '../../shared/file-browser.js';

// Drives the admin top-bar Saving/Saved pill from this module's
// out-of-band persistence (the alt-base panel saves via its own
// endpoint, not the merged-config auto-save). Same shape as the
// helper in plugins-module.js.
function emitSaveStatus(el, status, error = '') {
  el.dispatchEvent(new CustomEvent('save-status', {
    detail: { status, error },
    bubbles: true,
    composed: true,
  }));
}

/**
 * Source Code module (Developer section, route id app-versions).
 *
 * Combines three power-user surfaces into one page:
 *   1. Alternate HomeFree repository panel — pick a fork or a local
 *      working copy to build the system from instead of the official
 *      remote.
 *   2. Update Apps button — runs scripts/upgrade-apps.py against the
 *      local checkout to bump every safely-bumpable image pin. Only
 *      enabled when the alternate base is set to a local repo (the
 *      official-remote tree isn't writable from this box).
 *   3. App version table — every container declared on the box, with
 *      current vs. upstream-latest. Cache is refreshed daily by a
 *      systemd timer plus on-demand via the Refresh button.
 */
class AppVersionsModule extends LitElement {
  static properties = {
    loading: { type: Boolean, state: true },
    refreshing: { type: Boolean, state: true },
    error: { type: String, state: true },
    apps: { type: Array, state: true },
    // Surfaced from admin-app so the alt-base panel's per-field amber
    // dirty-state highlight matches the rest of the admin UI.
    undeployedPaths: { type: Object },
    appliedConfig: { type: Object },
    // Alternate HomeFree base repo panel state (moved here from the
    // Plugins page; copy-mirrored, not extracted to a shared component,
    // because only two surfaces use it).
    baseLoading: { type: Boolean, state: true },
    baseOfficialUrl: { type: String, state: true },
    baseEnabled: { type: Boolean, state: true },
    baseType: { type: String, state: true },
    baseLocalUrl: { type: String, state: true },
    baseRemoteUrl: { type: String, state: true },
    baseRemoteRef: { type: String, state: true },
    baseSaving: { type: Boolean, state: true },
    baseProbing: { type: Boolean, state: true },
    baseProbeResult: { type: Object, state: true },
    baseErrors: { type: Array, state: true },
    baseWarnings: { type: Array, state: true },
    baseBrowserOpen: { type: Boolean, state: true },
    // Update Apps button state.
    upgrading: { type: Boolean, state: true },
    upgradeResult: { type: Object, state: true },
    upgradeError: { type: String, state: true },
    // Name of the single app whose per-row Update button is running, or
    // null. Only one per-row update runs at a time (the backend bump is
    // serialized anyway).
    updatingApp: { type: String, state: true },
    // Update flakes (nix flake update on the local base checkout) state.
    flakeUpdating: { type: Boolean, state: true },
    flakeUpdateResult: { type: Object, state: true },
    flakeUpdateError: { type: String, state: true },
    // nixpkgs commit/date pinned in the relevant flake.lock.
    nixpkgsInfo: { type: Object, state: true },
    // Publish ISO image panel state.
    isoLoading: { type: Boolean, state: true },
    isoBuild: { type: Object, state: true },
    isoLatest: { type: Object, state: true },
    isoLogTail: { type: String, state: true },
    isoError: { type: String, state: true },
    // Source-picker modal — only used when an alternate base is enabled
    // (otherwise the click goes straight to a default-source build).
    sourcePickerOpen: { type: Boolean, state: true },
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
    .summary .disabled { color: var(--hf-text-muted); }

    .toolbar .spacer { flex: 1; }

    button.btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 7px;
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

    /* Small spinner that lives inside a button while its action runs.
       Inherits the button's text color via currentColor so it reads on
       any button variant. Reuses the iso-spin keyframes defined below. */
    .inline-spinner {
      width: 13px;
      height: 13px;
      border: 2px solid var(--hf-border-2);
      border-top-color: currentColor;
      border-radius: 50%;
      animation: iso-spin 0.8s linear infinite;
      flex-shrink: 0;
    }

    /* Status cell: pill + per-row Update button laid out horizontally so
       the button uses the spare width on desktop instead of doubling the
       row height. flex-wrap lets the button drop below the pill only when
       the column is genuinely too narrow (phones). */
    .status-cell {
      display: flex;
      align-items: center;
      gap: 8px;
      flex-wrap: wrap;
    }
    button.btn.row-update {
      padding: 4px 11px;
      font-size: 11px;
      font-weight: 600;
    }

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
    /* Marks a row whose app/image is declared in the source but not
       currently deployed (a disabled app, or an optional sidecar image
       that isn't running). Distinct from the status pill — an app can
       be both disabled and outdated. */
    .name .disabled-tag {
      display: inline-block;
      margin-left: 8px;
      padding: 1px 8px;
      border-radius: 999px;
      font-size: 10px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      background: var(--hf-surface-3);
      color: var(--hf-text-muted);
      vertical-align: middle;
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
    .pill.pending  { background: var(--hf-warn-soft); color: var(--hf-warn); }

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
    /* Pending rebuild — the source pins a newer version than what's
       deployed. Amber the whole row, the same undeployed-change signal
       used elsewhere in the admin UI, and emphasise the staged version
       in the Current column. */
    tr.pending td { background: var(--hf-warn-soft); }
    tr.pending .col-current,
    tr.pending .current-inline { color: var(--hf-warn); font-weight: 600; }
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

    /* Alt-base panel + Update Apps bar styles, mirrored from the
       Plugins page so the look is identical between the two surfaces. */
    .card {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      padding: 16px;
      margin-bottom: 20px;
    }
    .notice {
      background: rgba(59, 130, 246, 0.08);
      border-left: 4px solid var(--hf-accent);
      padding: 14px 18px;
      border-radius: 8px;
      margin-bottom: 16px;
      color: var(--hf-text-muted);
      font-size: 13px;
      line-height: 1.5;
    }
    .notice strong { color: var(--hf-text); }
    .warn {
      background: rgba(59, 130, 246, 0.08);
      border-left: 4px solid var(--hf-warn);
      padding: 14px 18px;
      border-radius: 8px;
      margin-bottom: 12px;
      color: var(--hf-text-muted);
      font-size: 13px;
      line-height: 1.5;
    }
    h3 { color: var(--hf-text); margin: 24px 0 12px; font-size: 16px; }
    label.field { display: block; margin-bottom: 14px; }
    label.field .lbl {
      display: block;
      color: var(--hf-text);
      font-size: 13px;
      font-weight: 600;
      margin-bottom: 4px;
    }
    label.field .hint {
      color: var(--hf-text-muted);
      font-size: 12px;
      margin-top: 3px;
    }
    input[type=text] {
      width: 100%;
      box-sizing: border-box;
      padding: 8px 10px;
      background: var(--hf-surface-2);
      color: var(--hf-text);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      font-size: 14px;
    }
    .type-toggle {
      display: inline-flex;
      margin-bottom: 14px;
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      overflow: hidden;
    }
    .type-toggle button {
      padding: 7px 16px;
      background: var(--hf-surface-2);
      color: var(--hf-text-muted);
      border: none;
      border-right: 1px solid var(--hf-border-2);
      cursor: pointer;
      font-size: 13px;
    }
    .type-toggle button:last-child { border-right: none; }
    .type-toggle button.active {
      background: var(--hf-accent);
      color: #06281c;
      font-weight: 600;
    }
    .input-with-browse { display: flex; gap: 8px; }
    .input-with-browse input { flex: 1; }
    .toggle-switch { display: inline-flex; align-items: center; gap: 6px; }
    .toggle-switch.changed {
      background: var(--hf-warn-soft);
      border: 1px solid var(--hf-warn);
      border-radius: 6px;
      padding: 4px 10px;
    }
    .type-toggle.changed { border-color: var(--hf-warn); }
    label.field.changed .lbl {
      display: inline-block;
      background: var(--hf-warn-soft);
      border-radius: 4px;
      padding: 2px 6px;
    }
    label.field.changed input[type=text] {
      background: var(--hf-warn-soft);
      border-color: var(--hf-warn);
    }
    .actions { display: flex; gap: 10px; flex-wrap: wrap; margin-top: 8px; }

    /* Current nixpkgs commit + date, read from the relevant flake.lock.
       Sits at the bottom of the alt-base card. */
    .nixpkgs-line {
      display: flex;
      align-items: center;
      gap: 8px;
      flex-wrap: wrap;
      margin-top: 14px;
      padding-top: 12px;
      border-top: 1px solid var(--hf-border);
      font-size: 12px;
      color: var(--hf-text-muted);
    }
    .nixpkgs-line .lbl { color: var(--hf-text); font-weight: 600; }
    .nixpkgs-line code {
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      color: var(--hf-text);
    }
    .nixpkgs-line a { color: var(--hf-accent); text-decoration: none; }
    .nixpkgs-line a:hover { text-decoration: underline; }

    /* Result panel shown after Update apps / Update flakes runs. */
    .upgrade-result {
      padding: 12px 14px;
      background: var(--hf-surface);
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      margin-bottom: 20px;
      font-size: 13px;
      color: var(--hf-text-muted);
      line-height: 1.6;
    }
    .upgrade-result strong { color: var(--hf-text); }
    .upgrade-result ul { margin: 6px 0 0; padding-left: 20px; }
    .upgrade-result code {
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 12px;
      color: var(--hf-text);
    }

    /* Publish ISO image panel — sits below the Update Apps bar. Shows
       both the most recently published installer image (name/size/hash)
       and the live build state when one is running. */
    .iso-panel {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      padding: 16px;
      margin-bottom: 20px;
    }
    .iso-panel h3 { margin: 0 0 12px; }
    .iso-meta {
      display: grid;
      grid-template-columns: max-content 1fr;
      column-gap: 16px;
      row-gap: 4px;
      font-size: 13px;
      margin-bottom: 14px;
    }
    .iso-meta dt { color: var(--hf-text-muted); }
    .iso-meta dd {
      margin: 0;
      color: var(--hf-text);
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 12px;
      word-break: break-all;
    }
    .iso-actions { display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
    .iso-status {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      font-size: 13px;
      color: var(--hf-text-muted);
    }
    .spinner {
      width: 14px;
      height: 14px;
      border: 2px solid var(--hf-border-2);
      border-top-color: var(--hf-warn);
      border-radius: 50%;
      animation: iso-spin 0.9s linear infinite;
      flex-shrink: 0;
    }
    @keyframes iso-spin { to { transform: rotate(360deg); } }

    /* Collapsible build log — closed by default so the panel stays
       compact. The HTML details toggle is browser-native, accessible
       by default, and survives re-renders because the open-state is a
       DOM attribute (not Lit-managed state). */
    .iso-log-toggle {
      margin-top: 12px;
    }
    .iso-log-toggle > summary {
      list-style: none;
      cursor: pointer;
      color: var(--hf-text-muted);
      font-size: 12px;
      padding: 4px 0;
      user-select: none;
    }
    .iso-log-toggle > summary::-webkit-details-marker { display: none; }
    .iso-log-toggle > summary::before {
      content: "▸ ";
      display: inline-block;
      transition: transform 0.15s ease;
    }
    .iso-log-toggle[open] > summary::before { transform: rotate(90deg); }
    .iso-log {
      margin-top: 8px;
      padding: 10px 12px;
      background: var(--hf-surface-2);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 11px;
      color: var(--hf-text-muted);
      white-space: pre-wrap;
      word-break: break-all;
      max-height: 280px;
      overflow: auto;
    }

    /* Source-picker overlay. A bare-bones modal — only used when alt
       is enabled, to ask which tree to build from. Built inline rather
       than via confirmDialog because it's tri-state (cancel + two
       choices) and confirmDialog only supports yes/no. */
    .source-picker-overlay {
      position: fixed;
      inset: 0;
      background: rgba(0, 0, 0, 0.55);
      display: flex;
      align-items: center;
      justify-content: center;
      z-index: 1000;
      padding: 16px;
    }
    .source-picker-card {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border-2);
      border-radius: 10px;
      padding: 20px 22px;
      max-width: 480px;
      width: 100%;
      box-shadow: 0 20px 50px rgba(0,0,0,0.4);
    }
    .source-picker-card h3 { margin: 0 0 8px; }
    .source-picker-card p {
      margin: 0 0 18px;
      color: var(--hf-text-muted);
      font-size: 13px;
      line-height: 1.5;
    }
    .source-picker-card .options {
      display: flex;
      flex-direction: column;
      gap: 10px;
      margin-bottom: 16px;
    }
    .source-picker-card .options button {
      text-align: left;
      padding: 12px 14px;
    }
    .source-picker-card .options button .opt-title {
      display: block;
      color: var(--hf-text);
      font-weight: 600;
      margin-bottom: 4px;
    }
    .source-picker-card .options button .opt-sub {
      display: block;
      color: var(--hf-text-muted);
      font-size: 12px;
      font-weight: 400;
    }
    .source-picker-card .footer {
      display: flex;
      justify-content: flex-end;
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
    this.undeployedPaths = new Set();
    this.appliedConfig = null;
    this.baseLoading = true;
    this.baseOfficialUrl = '';
    this.baseEnabled = false;
    this.baseType = 'local';
    this.baseLocalUrl = '';
    this.baseRemoteUrl = '';
    this.baseRemoteRef = '';
    this.baseSaving = false;
    this.baseProbing = false;
    this.baseProbeResult = null;
    this.baseErrors = [];
    this.baseWarnings = [];
    this.baseBrowserOpen = false;
    this.upgrading = false;
    this.upgradeResult = null;
    this.upgradeError = '';
    this.updatingApp = null;
    this.flakeUpdating = false;
    this.flakeUpdateResult = null;
    this.flakeUpdateError = '';
    this.nixpkgsInfo = null;
    this.isoLoading = true;
    this.isoBuild = { state: 'idle' };
    this.isoLatest = null;
    this.isoLogTail = '';
    this.isoError = '';
    this.sourcePickerOpen = false;
    this._isoPollTimer = null;
  }

  connectedCallback() {
    super.connectedCallback();
    this.load();
    this.loadBaseOverride();
    this.loadNixpkgsInfo();
    this.loadIsoStatus();
  }

  async loadNixpkgsInfo() {
    try {
      const info = await getHomefreeBaseNixpkgs();
      this.nixpkgsInfo = info && info.rev ? info : null;
    } catch (e) {
      this.nixpkgsInfo = null;
    }
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this._pollTimer) {
      clearTimeout(this._pollTimer);
      this._pollTimer = null;
    }
    if (this._isoPollTimer) {
      clearTimeout(this._isoPollTimer);
      this._isoPollTimer = null;
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

  // ---- Alternate HomeFree base repo panel ------------------------------
  //
  // Same persistence model as the rest of the admin UI: enabled and type
  // toggles persist immediately; URL field persists on blur / Enter (not
  // every keystroke, so a half-typed path never rewrites flake.nix).
  // Enabling with no URL yet is not persisted, so the backend's
  // enabled-needs-a-URL check never fires.

  async loadBaseOverride() {
    this.baseLoading = true;
    try {
      const data = await getHomefreeBase();
      this.baseOfficialUrl = data.officialUrl || '';
      this.baseEnabled = !!data.enabled;
      this.baseType = data.type || 'local';
      const local = data.localUrl || '';
      this.baseLocalUrl = local.startsWith('git+file://')
        ? local.slice('git+file://'.length)
        : local;
      this.baseRemoteUrl = data.remoteUrl || '';
      this.baseRemoteRef = data.remoteRef || '';
    } catch (e) {
      this.error = e.message || 'Failed to load the alternate-base setting.';
    } finally {
      this.baseLoading = false;
    }
  }

  get _activeBaseUrl() {
    return this.baseType === 'remote' ? this.baseRemoteUrl : this.baseLocalUrl;
  }

  get _baseReadyToPersist() {
    return !this.baseEnabled || !!(this._activeBaseUrl || '').trim();
  }

  async _persistBase() {
    if (!this._baseReadyToPersist) return;
    this.baseSaving = true;
    this.baseErrors = [];
    this.baseWarnings = [];
    this.error = '';
    emitSaveStatus(this, 'saving');
    try {
      const result = await saveHomefreeBase({
        enabled: this.baseEnabled,
        type: this.baseType,
        localUrl: this.baseLocalUrl,
        remoteUrl: this.baseRemoteUrl,
        remoteRef: this.baseType === 'remote' ? (this.baseRemoteRef || undefined) : undefined,
      });
      this.baseWarnings = result.warnings || [];
      this.baseProbeResult = null;
      await this.loadBaseOverride();
      this.dispatchEvent(new CustomEvent('updates-applied', {
        bubbles: true, composed: true,
      }));
      emitSaveStatus(this, 'saved');
    } catch (e) {
      this.baseErrors = (e.body && e.body.errors)
        || [e.message || 'Failed to save the alternate base repository.'];
      emitSaveStatus(this, 'error', this.baseErrors[0]);
    } finally {
      this.baseSaving = false;
    }
  }

  _onBaseToggle(e) {
    this.baseEnabled = e.target.checked;
    this.baseProbeResult = null;
    this._persistBase();
  }

  _setBaseType(type) {
    if (this.baseType === type) return;
    this.baseType = type;
    this.baseProbeResult = null;
    this._persistBase();
  }

  _handleBasePathSelected(e) {
    this.baseLocalUrl = e.detail.path;
    this.baseBrowserOpen = false;
    this._persistBase();
  }

  _onBaseUrlCommit() {
    this._persistBase();
  }

  async _probeBase() {
    if (!this._activeBaseUrl) {
      this.baseErrors = ['Enter a repository path or URL before validating.'];
      return;
    }
    this.baseProbing = true;
    this.baseProbeResult = null;
    this.baseErrors = [];
    try {
      this.baseProbeResult = await validateHomefreeBase({
        type: this.baseType,
        url: this._activeBaseUrl,
        ref: this.baseType === 'remote' ? (this.baseRemoteRef || undefined) : undefined,
      });
    } catch (e) {
      this.baseErrors = [e.message || 'Could not probe the repository.'];
    } finally {
      this.baseProbing = false;
    }
  }

  _baseFieldChanged(field) {
    return this.undeployedPaths?.has('developers.homefree-base.' + field) || false;
  }

  // True when bumping pins from this UI is meaningful: the box is
  // building from a local checkout the admin-api process can edit.
  // A remote URL is read-only; the official upstream is read-only.
  get _canUpgradeApps() {
    return this.baseEnabled
      && this.baseType === 'local'
      && !!(this.baseLocalUrl || '').trim();
  }

  async runUpgradeApps() {
    if (this.upgrading || !this._canUpgradeApps) return;
    this.upgrading = true;
    this.upgradeError = '';
    this.upgradeResult = null;
    try {
      this.upgradeResult = await upgradeApps({ dryRun: false });
      // Re-poll versions so the table reflects the new pins immediately
      // (the resolver cache still shows old current until next refresh,
      // but the operator gets visual confirmation the run finished).
      await this.load();
    } catch (e) {
      this.upgradeError = e.message || 'Update Apps failed.';
    } finally {
      this.upgrading = false;
    }
  }

  // Bump a single app's pin via the same upgrade-apps.py machinery with an
  // --app filter. The result panel (below the toolbar) shows the outcome;
  // the row stays Outdated until a rebuild deploys the new pin, since the
  // "current" column reflects the deployed image, not the source pin.
  async runUpgradeApp(app) {
    if (this.upgrading || this.updatingApp || !this._canUpgradeApps) return;
    this.updatingApp = app.name;
    this.upgradeError = '';
    this.upgradeResult = null;
    try {
      this.upgradeResult = await upgradeApps({ app: app.name });
      await this.load();
    } catch (e) {
      this.upgradeError = e.body?.detail || e.message || 'Update failed.';
    } finally {
      this.updatingApp = null;
    }
  }

  // Runs `nix flake update` in the local base checkout (same writable-local
  // prerequisite as Update apps). Bumps flake.lock inputs; the operator
  // rebuilds afterwards to deploy.
  async runUpdateFlakes() {
    if (this.flakeUpdating || !this._canUpgradeApps) return;
    this.flakeUpdating = true;
    this.flakeUpdateError = '';
    this.flakeUpdateResult = null;
    try {
      this.flakeUpdateResult = await updateHomefreeBaseFlakes();
      // flake.lock changed — refresh the displayed nixpkgs commit/date.
      await this.loadNixpkgsInfo();
    } catch (e) {
      this.flakeUpdateError = e.body?.detail || e.message || 'Update flakes failed.';
    } finally {
      this.flakeUpdating = false;
    }
  }

  // ---- Publish ISO image ----------------------------------------------
  //
  // GET /api/source/iso/status returns the latest published artifact +
  // the current build state. While build.state === 'running' we poll
  // every 3s (cheap — backend just reads its in-memory state and tails
  // a small log file). Once running flips to done/error we stop.

  async loadIsoStatus() {
    this.isoLoading = true;
    try {
      const data = await getIsoStatus();
      this.isoBuild = data?.build || { state: 'idle' };
      this.isoLatest = data?.latest || null;
      this.isoLogTail = data?.log_tail || '';
      this.isoError = '';
      // If the backend says a build is live (e.g. we navigated back to
      // the page while one is running), resume polling.
      if (this.isoBuild.state === 'running' && !this._isoPollTimer) {
        this._scheduleIsoPoll();
      }
    } catch (e) {
      this.isoError = e.message || 'Failed to read ISO status.';
    } finally {
      this.isoLoading = false;
    }
  }

  _scheduleIsoPoll() {
    if (this._isoPollTimer) return;
    this._isoPollTimer = setTimeout(async () => {
      this._isoPollTimer = null;
      await this.loadIsoStatus();
      if (this.isoBuild?.state === 'running') {
        this._scheduleIsoPoll();
      }
    }, 3000);
  }

  // Click handler. If alt-base is enabled+local, open the source picker
  // (alt vs official). Otherwise default to the official-public path
  // (the only build option when there is no local checkout).
  _onPublishClick() {
    if (this.isoBuild?.state === 'running') return;
    if (this._canUpgradeApps) {
      this.sourcePickerOpen = true;
      return;
    }
    this._kickBuild('main');
  }

  async _kickBuild(source) {
    this.sourcePickerOpen = false;
    this.isoError = '';
    try {
      const data = await buildIso({ source });
      this.isoBuild = data?.build || { state: 'running', source };
      this._scheduleIsoPoll();
    } catch (e) {
      this.isoError = e.body?.detail || e.message || 'Failed to start build.';
    }
  }

  _renderCounts() {
    const outdated = this.apps.filter((a) => a.status === 'outdated').length;
    const ok = this.apps.filter((a) => a.status === 'up-to-date').length;
    const floating = this.apps.filter((a) => a.status === 'floating').length;
    const local = this.apps.filter((a) => a.status === 'local').length;
    const unknown = this.apps.filter((a) => a.status === 'unknown').length;
    const disabled = this.apps.filter((a) => a.enabled === false).length;
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
        ${disabled > 0 ? html`
          <span class="sep">·</span>
          <span class="count disabled">${disabled}</span> not enabled
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
    if (app.enabled === false) rowClasses.push('is-disabled');
    if (app.pending) rowClasses.push('pending');
    return html`
      <tr class=${rowClasses.join(' ')}>
        <td class="name">
          ${projectLabel}
          ${app.enabled === false
            ? html`<span class="disabled-tag"
                         title="Declared in the source but not currently deployed on this box.">Disabled</span>`
            : ''}
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
        <td class="col-status">
          <div class="status-cell">
            ${app.pending
              ? html`<span class="pill pending"
                           title="Updated to ${app.pending_version} in the source — rebuild to deploy (currently running ${app.deployed_version}).">Pending rebuild</span>`
              : this._renderPill(app.status)}
            ${app.status === 'outdated' && this._canUpgradeApps && !app.pending
              ? html`
                <button
                  class="btn row-update"
                  ?disabled=${this.upgrading
                    || (this.updatingApp && this.updatingApp !== app.name)}
                  title="Bump this app's pin to ${app.latest}. Rebuild after to deploy."
                  @click=${() => this.runUpgradeApp(app)}
                >
                  ${this.updatingApp === app.name
                    ? html`<span class="inline-spinner"></span>Updating…`
                    : 'Update'}
                </button>`
              : ''}
          </div>
        </td>
      </tr>
    `;
  }

  _renderBaseProbe() {
    const p = this.baseProbeResult;
    if (!p) return '';
    const normalized = p.normalizedUrl && p.normalizedUrl !== (this._activeBaseUrl || '').trim()
      ? p.normalizedUrl
      : '';
    return html`
      ${normalized
        ? html`<div class="notice">Interpreted as <code>${normalized}</code></div>`
        : ''}
      ${(p.errors || []).map((m) => html`<div class="error">${m}</div>`)}
      ${(p.warnings || []).map((m) => html`<div class="warn">⚠️ ${m}</div>`)}
      ${p.valid && (p.errors || []).length === 0 && (p.warnings || []).length === 0
        ? html`<div class="notice">Repository is reachable and exposes nixosModules.homefree.</div>`
        : ''}
    `;
  }

  _renderBasePanel() {
    if (this.baseLoading) {
      return html`
        <div class="card">
          <h3 style="margin-top:0">Alternate HomeFree repository</h3>
          <p class="muted">Loading…</p>
        </div>`;
    }
    return html`
      <div class="card">
        <h3 style="margin-top:0">Alternate HomeFree repository</h3>
        <p class="muted">
          Build this system from an alternate HomeFree repository — a fork or
          a local working copy — instead of the official one, while still
          managing everything from this admin panel.
        </p>

        ${this.baseErrors.map((m) => html`<div class="error">${m}</div>`)}
        ${this.baseWarnings.map((m) => html`<div class="warn">⚠️ ${m}</div>`)}

        <label class="toggle-switch ${this._baseFieldChanged('enabled') ? 'changed' : ''}" style="margin-bottom:14px">
          <input
            type="checkbox"
            .checked=${this.baseEnabled}
            @change=${this._onBaseToggle}
          />
          <span class="lbl" style="margin:0">Enable</span>
        </label>

        ${this.baseEnabled
          ? html`
            <div class="warn">
              Alternate HomeFree repository is active. System updates will not
              be visible unless the alternate repository is disabled.
            </div>

            <div class="type-toggle ${this._baseFieldChanged('type') ? 'changed' : ''}">
              <button
                class=${this.baseType === 'local' ? 'active' : ''}
                @click=${() => this._setBaseType('local')}
              >Local repository</button>
              <button
                class=${this.baseType === 'remote' ? 'active' : ''}
                @click=${() => this._setBaseType('remote')}
              >Remote URL</button>
            </div>

            ${this.baseType === 'local'
              ? html`
                <label class="field ${this._baseFieldChanged('localUrl') ? 'changed' : ''}">
                  <span class="lbl">Local HomeFree repository</span>
                  <div class="input-with-browse">
                    <input
                      type="text"
                      .value=${this.baseLocalUrl}
                      placeholder="/home/you/homefree"
                      @input=${(e) => { this.baseLocalUrl = e.target.value; }}
                      @change=${this._onBaseUrlCommit}
                      @keydown=${(e) => { if (e.key === 'Enter') e.target.blur(); }}
                    />
                    <button class="btn" @click=${() => { this.baseBrowserOpen = true; }}>
                      📁 Browse
                    </button>
                  </div>
                  <span class="hint">
                    A git checkout of a HomeFree repository on this machine.
                    Stored as a git+file:// flake reference. Saved when you
                    click away or press Enter.
                  </span>
                </label>
              `
              : html`
                <label class="field ${this._baseFieldChanged('remoteUrl') ? 'changed' : ''}">
                  <span class="lbl">Repository URL</span>
                  <input
                    type="text"
                    .value=${this.baseRemoteUrl}
                    placeholder="github:owner/homefree"
                    @input=${(e) => { this.baseRemoteUrl = e.target.value; }}
                    @change=${this._onBaseUrlCommit}
                    @keydown=${(e) => { if (e.key === 'Enter') e.target.blur(); }}
                  />
                  <span class="hint">
                    A flake reference to a HomeFree repository, e.g.
                    github:owner/homefree or git+https://example.com/homefree.git.
                    Saved when you click away or press Enter.
                  </span>
                </label>
                <label class="field ${this._baseFieldChanged('remoteRef') ? 'changed' : ''}">
                  <span class="lbl">Branch / tag / commit (optional)</span>
                  <input
                    type="text"
                    .value=${this.baseRemoteRef}
                    placeholder="e.g. main, v1.2.3, fix/my-branch, or a commit SHA"
                    @input=${(e) => { this.baseRemoteRef = e.target.value; }}
                    @change=${this._onBaseUrlCommit}
                    @keydown=${(e) => { if (e.key === 'Enter') e.target.blur(); }}
                  />
                  <span class="hint">
                    Pin the repository to a specific branch, tag, or commit —
                    handy for testing a branch before it is merged. Leave blank
                    to track the repository default branch.
                  </span>
                </label>
              `}
          `
          : html`
            <p class="muted">
              Currently building from the official HomeFree repository:
              <br />
              <code style="font-family:ui-monospace,monospace;font-size:12px">
                ${this.baseOfficialUrl}
              </code>
            </p>
          `}

        ${this._renderBaseProbe()}

        ${this.baseEnabled
          ? html`
            <div class="actions">
              <button
                class="btn"
                ?disabled=${this.baseProbing || !this._activeBaseUrl}
                @click=${this._probeBase}
              >${this.baseProbing ? 'Validating…' : 'Validate'}</button>
              ${this._canUpgradeApps
                ? html`
                  <button
                    class="btn"
                    ?disabled=${this.flakeUpdating}
                    title="Runs 'nix flake update' in the local checkout to bump its flake.lock inputs (nixpkgs, etc.). Rebuild after to deploy."
                    @click=${this.runUpdateFlakes}
                  >
                    ${this.flakeUpdating
                      ? html`<span class="inline-spinner"></span>Updating flakes…`
                      : 'Update flakes'}
                  </button>
                `
                : ''}
              ${this.baseSaving
                ? html`<span class="muted" style="align-self:center">Saving…</span>`
                : ''}
            </div>
            ${this.flakeUpdateError
              ? html`<div class="error" style="margin-top:12px">${this.flakeUpdateError}</div>`
              : ''}
            ${this._renderFlakeUpdateResult()}
          `
          : ''}

        ${this._renderNixpkgsInfo()}
      </div>

      ${this.baseBrowserOpen ? html`
        <file-browser
          ?open=${this.baseBrowserOpen}
          .currentPath=${this.baseLocalUrl || '/home'}
          @path-selected=${this._handleBasePathSelected}
          @close=${() => { this.baseBrowserOpen = false; }}
        ></file-browser>
      ` : ''}
    `;
  }

  _renderNixpkgsInfo() {
    const n = this.nixpkgsInfo;
    if (!n || !n.rev) return '';
    const ref = n.ref
      ? (n.repo || 'nixpkgs') + '/' + n.ref
      : (n.repo || 'nixpkgs');
    return html`
      <div class="nixpkgs-line">
        <span class="lbl">nixpkgs</span>
        <span>${ref}</span>
        ${n.commitUrl
          ? html`<a href=${n.commitUrl} target="_blank" rel="noopener noreferrer"
                    title="View commit on GitHub"><code>${n.shortRev}</code></a>`
          : html`<code>${n.shortRev}</code>`}
        ${n.date ? html`<span>· ${n.date}</span>` : ''}
        ${n.source === 'checkout' ? html`<span>· local checkout</span>` : ''}
      </div>
    `;
  }

  _renderFlakeUpdateResult() {
    const r = this.flakeUpdateResult;
    if (!r) return '';
    const updated = Array.isArray(r.updated) ? r.updated : [];
    if (updated.length === 0) {
      return html`
        <div class="upgrade-result" style="margin-top:12px">
          <strong>Flakes updated.</strong> No inputs changed — already
          current. Rebuild to deploy.
        </div>`;
    }
    return html`
      <div class="upgrade-result" style="margin-top:12px">
        <div><strong>${updated.length} flake input(s) updated:</strong></div>
        <ul>${updated.map((u) => html`<li><code>${u}</code></li>`)}</ul>
        <div style="margin-top:8px">Rebuild to deploy the updated inputs.</div>
      </div>
    `;
  }

  _renderUpgradeResult() {
    const r = this.upgradeResult;
    if (!r) return '';
    const bumped = Array.isArray(r.bumped) ? r.bumped : [];
    const zskipped = Array.isArray(r.skipped_zitadel) ? r.skipped_zitadel : [];
    const warnings = Array.isArray(r.warnings) ? r.warnings : [];
    const errors = Array.isArray(r.errors) ? r.errors : [];
    const nothing = bumped.length === 0 && zskipped.length === 0
      && warnings.length === 0 && errors.length === 0;
    if (nothing) {
      return html`<div class="upgrade-result"><strong>All up-to-date.</strong> No bumps were needed.</div>`;
    }
    return html`
      <div class="upgrade-result">
        ${bumped.length > 0 ? html`
          <div><strong>${bumped.length} pin(s) bumped:</strong></div>
          <ul>
            ${bumped.map((b) => html`
              <li>
                <code>${b.app}</code>
                ${b.binding ? html` / <code>${b.binding}</code>` : ''}
                : <code>${b.current_value}</code> → <code>${b.new_value}</code>
              </li>
            `)}
          </ul>
          <div style="margin-top:8px">
            Re-build to deploy: <code>sudo scripts/build.sh --switch</code>
          </div>
        ` : ''}
        ${zskipped.length > 0 ? html`
          <div style="margin-top:10px">
            <strong>${zskipped.length} Zitadel pin(s) skipped</strong>
            to avoid SSO lockout. Bump by hand after arranging an
            out-of-band login.
          </div>
        ` : ''}
        ${warnings.length > 0 ? html`
          <div style="margin-top:10px"><strong>Warnings:</strong></div>
          <ul>${warnings.map((w) => html`<li>${w}</li>`)}</ul>
        ` : ''}
        ${errors.length > 0 ? html`
          <div style="margin-top:10px"><strong>Errors:</strong></div>
          <ul>${errors.map((e) => html`<li>${e}</li>`)}</ul>
        ` : ''}
      </div>
    `;
  }

  _formatBytes(n) {
    if (typeof n !== 'number' || !isFinite(n)) return '';
    const mb = n / (1024 * 1024);
    if (mb >= 1024) return (mb / 1024).toFixed(2) + ' GB';
    return mb.toFixed(1) + ' MB';
  }

  _formatRelative(epochSec) {
    if (!epochSec) return '';
    const ageSec = Math.max(0, Math.floor(Date.now() / 1000 - epochSec));
    if (ageSec < 90) return ageSec + 's ago';
    if (ageSec < 5400) return Math.floor(ageSec / 60) + 'm ago';
    if (ageSec < 172800) return Math.floor(ageSec / 3600) + 'h ago';
    return Math.floor(ageSec / 86400) + 'd ago';
  }

  _renderIsoPanel() {
    const b = this.isoBuild || { state: 'idle' };
    const running = b.state === 'running';
    const startedAgo = running && b.started_at
      ? Math.max(0, Math.floor(Date.now() / 1000 - b.started_at)) + 's'
      : '';
    const finishedAgo = b.state === 'done' || b.state === 'error'
      ? this._formatRelative(b.finished_at)
      : '';
    const sourceLabel = b.source === 'main'
      ? 'official upstream' : (b.source === 'alt' ? 'alternate base' : '');
    const latest = this.isoLatest;
    return html`
      <div class="iso-panel">
        <h3>Installer ISO</h3>
        ${latest && latest.name ? html`
          <dl class="iso-meta">
            <dt>Published</dt><dd>${latest.name}</dd>
            <dt>Size</dt><dd>${this._formatBytes(latest.size)}</dd>
            ${latest.sha256 ? html`
              <dt>sha256</dt><dd>${latest.sha256}</dd>
            ` : ''}
            ${latest.modified ? html`
              <dt>Built</dt><dd>${this._formatRelative(latest.modified)}</dd>
            ` : ''}
          </dl>
        ` : html`
          <p class="muted" style="margin-top:0">
            No installer ISO has been published yet from this box.
          </p>
        `}

        ${this.isoError ? html`<div class="error">${this.isoError}</div>` : ''}

        ${b.state === 'error' ? html`
          <div class="error" style="margin-bottom:12px">
            <strong>Build failed${sourceLabel ? ' (' + sourceLabel + ')' : ''}.</strong>
            ${b.error || ''}
            ${finishedAgo ? ' — ' + finishedAgo : ''}
          </div>
        ` : ''}
        ${b.state === 'done' ? html`
          <div class="notice" style="margin-bottom:12px">
            <strong>Build succeeded${sourceLabel ? ' (' + sourceLabel + ')' : ''}.</strong>
            ${finishedAgo}
          </div>
        ` : ''}

        <div class="iso-actions">
          <button
            class="btn primary"
            ?disabled=${running || this.isoLoading}
            @click=${this._onPublishClick}
          >${running ? 'Building…' : 'Build & publish ISO'}</button>
          ${running ? html`
            <span class="iso-status">
              <span class="spinner" role="status" aria-label="building"></span>
              <span>
                Building${sourceLabel ? ' from ' + sourceLabel : ''}${startedAgo ? ' · ' + startedAgo : ''}
              </span>
            </span>
          ` : ''}
        </div>

        ${this.isoLogTail ? html`
          <details class="iso-log-toggle">
            <summary>Build log</summary>
            <div class="iso-log">${this.isoLogTail}</div>
          </details>
        ` : ''}
      </div>
    `;
  }

  _renderSourcePicker() {
    if (!this.sourcePickerOpen) return '';
    const altPath = this.baseLocalUrl || 'the alternate base';
    return html`
      <div class="source-picker-overlay" @click=${(e) => {
        if (e.target.classList.contains('source-picker-overlay')) {
          this.sourcePickerOpen = false;
        }
      }}>
        <div class="source-picker-card">
          <h3>Build installer ISO from…</h3>
          <p>
            An alternate HomeFree repository is active. Pick which source
            tree the resulting installer should install:
          </p>
          <div class="options">
            <button class="btn" @click=${() => this._kickBuild('alt')}>
              <span class="opt-title">Alternate repository</span>
              <span class="opt-sub">
                Builds from <code>${altPath}</code>. The ISO installs YOUR
                HomeFree, including any local source modifications.
              </span>
            </button>
            <button class="btn" @click=${() => this._kickBuild('main')}>
              <span class="opt-title">Official public repository</span>
              <span class="opt-sub">
                Clones the upstream HomeFree to a temporary directory and
                builds the standard public release.
              </span>
            </button>
          </div>
          <div class="footer">
            <button class="btn" @click=${() => { this.sourcePickerOpen = false; }}>
              Cancel
            </button>
          </div>
        </div>
      </div>
    `;
  }

  render() {
    return html`
      <div class="module-container">
        ${this._renderBasePanel()}

        ${this._renderIsoPanel()}

        ${this._renderSourcePicker()}

        <div class="info-box">
          <strong>App versions</strong>
          Every app declared in the source, with the version it is pinned
          to and the latest version available from each image's upstream
          registry. Latest-version lookups run once a day in the
          background; click Refresh to fetch fresh data on demand. Images
          on unsupported registries show <strong>Unknown</strong> with a
          short reason.
        </div>

        ${this.error ? html`<div class="error">${this.error}</div>` : ''}

        <div class="toolbar">
          ${this.loading && this.apps.length === 0
            ? html`<span class="muted">Loading…</span>`
            : this._renderCounts()}
          <span class="spacer"></span>
          <button
            class="btn"
            ?disabled=${!this._canUpgradeApps || this.upgrading || this.updatingApp}
            title=${this._canUpgradeApps
              ? 'Bumps every safely-bumpable image pin in the local checkout. Rebuild after to deploy.'
              : 'Enable an alternate HomeFree repository above with a local checkout to make pins editable.'}
            @click=${this.runUpgradeApps}
          >
            ${this.upgrading
              ? html`<span class="inline-spinner"></span>Updating apps…`
              : 'Update apps'}
          </button>
          <button
            class="btn"
            @click=${this.refresh}
            ?disabled=${this.refreshing || this.loading}
          >
            ${this.refreshing
              ? html`<span class="inline-spinner"></span>Refreshing…`
              : 'Refresh'}
          </button>
        </div>

        ${this.upgradeError ? html`<div class="error">${this.upgradeError}</div>` : ''}
        ${this._renderUpgradeResult()}

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
