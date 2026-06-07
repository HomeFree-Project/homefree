import { LitElement, html, css } from 'lit';
import {
  getPluginFlakes,
  savePluginFlake,
  deletePluginFlake,
  validatePluginFlake,
  checkPluginFlakeUpdate,
  updatePluginFlake,
  getPluginDirectory,
} from '../../../api/client.js';
import '../../shared/file-browser.js';
import { confirmDialog } from '../../shared/confirm-dialog.js';
import { actionIcon } from '../../../shared/icons.js';
// Drives the admin top-bar "Saving…/Saved" pill from this out-of-band
// module (it persists via its own endpoints, not the merged-config
// auto-save). admin-app listens for the bubbling, composed `save-status`
// event. Kept inline (not a shared file) so it ships in this already-
// tracked module rather than a separate file that can miss the build.
function emitSaveStatus(el, status, error = '') {
  el.dispatchEvent(new CustomEvent('save-status', {
    detail: { status, error }, bubbles: true, composed: true,
  }));
}

/**
 * Plugins module — install plugin flakes that extend HomeFree.
 *
 * Two ways to add a plugin: pick one from the Plugin Directory (curated
 * Forgejo org at git.homefree.host/homefree-plugins) or register an
 * arbitrary Nix flake by URL/path for third-party / self-hosted plugins.
 * Both paths flow through /api/plugins/flakes; the directory just
 * prefills the form.
 *
 * Registering a flake rewrites /etc/nixos/flake.nix and custom-flakes.nix
 * but does NOT rebuild — that lands the change in homefree-config.json too,
 * so the shell's dirty detection fires and the sidebar "Apply" button
 * activates. The admin rebuilds from there.
 */
class PluginsModule extends LitElement {
  static properties = {
    undeployedPaths: { attribute: false },  // Set<dotted-path> not yet deployed
    appliedConfig: { attribute: false },    // deployed baseline (per-flake diff)
    flakes: { type: Array, state: true },
    loading: { type: Boolean, state: true },
    error: { type: String, state: true },
    notice: { type: String, state: true },
    // Plugin Directory state (curated catalog from
    // git.homefree.host/homefree-plugins, fetched via the backend proxy).
    directory: { type: Array, state: true },
    directoryLoading: { type: Boolean, state: true },
    directoryError: { type: String, state: true },
    directorySourceUrl: { type: String, state: true },
    directoryCacheStale: { type: Boolean, state: true },
    installingSlug: { type: String, state: true },
    // Plugin Store modal state.
    storeOpen: { type: Boolean, state: true },
    storeQuery: { type: String, state: true },
    storeSort: { type: String, state: true }, // 'name' | 'updated' | 'created'
    // Modal containing the custom-flake form. Open by:
    //   - clicking [Add Custom Plugin] in the header (no editingId);
    //   - clicking Edit on an installed row (prefilled);
    //   - clicking Manage on an installed entry in the Plugin Store.
    editPluginOpen: { type: Boolean, state: true },
    // Substring filter for the installed-plugins list (debounced).
    installedQuery: { type: String, state: true },
    // Add-flake form state.
    formType: { type: String, state: true },
    formName: { type: String, state: true },
    formUrl: { type: String, state: true },
    formInputName: { type: String, state: true },
    formInputNameTouched: { type: Boolean, state: true },
    formModuleAttr: { type: String, state: true },
    showAdvanced: { type: Boolean, state: true },
    formErrors: { type: Array, state: true },
    saving: { type: Boolean, state: true },
    probing: { type: Boolean, state: true },
    probeResult: { type: Object, state: true },
    fileBrowserOpen: { type: Boolean, state: true },
    editingId: { type: String, state: true },
  };

  static styles = css`
    :host { display: block; }
    /* Width cap + centering is applied once, app-wide, on
       admin-app.js's .content-area > * — no per-module max-width. */
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
    .info-box > strong:first-child { display: block; margin-bottom: 8px; }

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

    .error {
      background: rgba(59, 130, 246, 0.08);
      border-left: 4px solid var(--hf-err);
      padding: 14px 18px;
      border-radius: 8px;
      margin-bottom: 16px;
      color: var(--hf-text-muted);
      font-size: 13px;
      line-height: 1.5;
    }

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

    .card {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      padding: 16px;
      margin-bottom: 20px;
    }

    .flake-row {
      display: flex;
      align-items: center;
      gap: 12px;
      flex-wrap: wrap;
      padding: 12px 14px;
      background: var(--hf-surface);
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      margin-bottom: 10px;
    }
    .flake-row .meta { flex: 1; min-width: 200px; }
    .flake-row .name { color: var(--hf-text); font-weight: 600; }
    .flake-row .url {
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 12px;
      color: var(--hf-text-muted);
      word-break: break-all;
    }
    .flake-row .sub { color: var(--hf-text-muted); font-size: 12px; }

    .badge {
      display: inline-block;
      padding: 2px 8px;
      border-radius: 999px;
      font-size: 11px;
      font-weight: 600;
    }
    .badge.local  { background: rgba(96,165,250,0.15); color: #60a5fa; }
    .badge.remote { background: rgba(167,139,250,0.15); color: #a78bfa; }
    /* Per-row update-state badges. Amber matches the app-wide undeployed
       treatment so an available update reads as the same kind of pending
       work as any other staged change. */
    .badge.update-available {
      background: var(--hf-warn-soft);
      color: var(--hf-warn);
    }
    .badge.update-ok {
      background: rgba(34,197,94,0.15);
      color: #4ade80;
    }
    .badge.update-err {
      background: rgba(239,68,68,0.15);
      color: var(--hf-err);
    }

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

    /* Compact segmented control — buttons sized to their content and
       joined into a single pill, so they don't stretch on wide screens. */
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

    /* Canonical admin button — 9px 16px / 13px / radius 6px. */
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
    button.btn:disabled { opacity: 0.5; cursor: not-allowed; }
    button.btn.primary {
      background: var(--hf-accent);
      color: #06281c;
      border-color: var(--hf-accent);
    }
    button.btn.primary:hover:not(:disabled) {
      background: var(--hf-accent-hover);
      border-color: var(--hf-accent-hover);
    }
    button.btn.danger {
      color: var(--hf-err);
      border-color: color-mix(in srgb, var(--hf-err) 45%, transparent);
    }
    button.btn.danger:hover:not(:disabled) {
      background: color-mix(in srgb, var(--hf-err) 14%, transparent);
      border-color: var(--hf-err);
    }

    .actions { display: flex; gap: 10px; flex-wrap: wrap; margin-top: 8px; }
    .advanced-toggle {
      background: none;
      border: none;
      color: var(--hf-accent);
      cursor: pointer;
      font-size: 13px;
      padding: 0;
      margin-bottom: 12px;
    }
    .muted { color: var(--hf-text-muted); font-size: 13px; }
    .toggle-switch { display: inline-flex; align-items: center; gap: 6px; }

    /* Undeployed-change treatment — the app-wide amber convention
       (--hf-warn / --hf-warn-soft): an edit not yet applied. The base-repo
       toggle/URL ALSO rewrite flake.nix; that side is flagged separately by
       the backend build-inputs check, so here we mirror only the
       homefree-config.json plugins.* diff. */
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
    .flake-row.changed {
      background: var(--hf-warn-soft);
      border-color: var(--hf-warn);
    }
    .flake-row.flash-row {
      animation: hf-flash 1.4s ease-out;
    }
    @keyframes hf-flash {
      0%   { box-shadow: 0 0 0 2px var(--hf-accent); }
      100% { box-shadow: 0 0 0 0  transparent; }
    }

    /* Plugin Directory grid. Cards reuse the same surface/border tokens
       as flake-row so the page reads as one design system. Single column
       at phone width per the UI-consistency-and-mobile rule. */
    .directory-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
      gap: 12px;
      margin-bottom: 24px;
    }
    .directory-card {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      padding: 14px;
      display: flex;
      flex-direction: column;
      gap: 8px;
    }
    /* No installed-state border: the Installed pill in the card
       header is the legible signal (the green border was too subtle
       and overlapped with hover/focus rings). */
    .directory-card .name {
      color: var(--hf-text);
      font-weight: 600;
      font-size: 14px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
    }
    .directory-card .description {
      color: var(--hf-text-muted);
      font-size: 13px;
      line-height: 1.4;
      flex: 1;
      min-height: 36px;
    }
    .directory-card .footer {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
      margin-top: 4px;
    }
    .directory-card .footer a {
      color: var(--hf-text-muted);
      font-size: 12px;
      text-decoration: none;
    }
    .directory-card .footer a:hover { color: var(--hf-text); }
    .directory-card .card-error {
      color: var(--hf-err);
      font-size: 12px;
    }
    .badge.installed {
      background: rgba(34, 197, 94, 0.15);
      color: #4ade80;
    }
    .directory-empty {
      color: var(--hf-text-muted);
      font-size: 13px;
      margin-bottom: 16px;
    }
    .directory-stale-note {
      color: var(--hf-warn);
      font-size: 12px;
      margin-bottom: 8px;
    }
    .directory-header {
      display: flex;
      align-items: baseline;
      justify-content: space-between;
      gap: 8px;
      margin: 24px 0 12px;
    }
    .directory-header h3 { margin: 0; }
    .directory-header .refresh {
      background: none;
      border: none;
      color: var(--hf-accent);
      cursor: pointer;
      font-size: 12px;
      font-family: inherit;
      padding: 0;
    }
    .directory-header .refresh:disabled { opacity: 0.5; cursor: default; }

    /* Store pill on the installed list — marks rows whose flake url
       matches a current directory entry. Subtle accent tint so it sits
       next to the local/remote type pill without competing. */
    .badge.store {
      background: rgba(96, 165, 250, 0.15);
      color: var(--hf-accent);
    }

    /* Plugin Store modal. Backdrop is the click/Escape capture surface;
       the inner .hf-modal is sized + bordered. Sticky filter bar over a
       scrolling body so the search/sort controls stay reachable. */
    .hf-modal-backdrop {
      position: fixed;
      inset: 0;
      background: rgba(0, 0, 0, 0.55);
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 16px;
      z-index: 100;
    }
    .hf-modal {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border-2);
      border-radius: 10px;
      width: min(900px, 100%);
      height: min(700px, 100%);
      display: flex;
      flex-direction: column;
      overflow: hidden;
      box-shadow: 0 24px 48px rgba(0, 0, 0, 0.35);
    }
    .hf-modal-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 14px 18px;
      border-bottom: 1px solid var(--hf-border-2);
      flex-shrink: 0;
    }
    .hf-modal-header h3 {
      margin: 0;
      color: var(--hf-text);
      font-size: 16px;
    }
    .hf-modal-close {
      background: none;
      border: none;
      color: var(--hf-text-muted);
      cursor: pointer;
      font-size: 20px;
      line-height: 1;
      padding: 4px 8px;
      border-radius: 4px;
      font-family: inherit;
    }
    .hf-modal-close:hover {
      background: var(--hf-surface-3);
      color: var(--hf-text);
    }
    .hf-modal-filter-bar {
      position: sticky;
      top: 0;
      background: var(--hf-surface);
      border-bottom: 1px solid var(--hf-border-2);
      padding: 12px 18px;
      display: flex;
      gap: 10px;
      align-items: center;
      flex-wrap: wrap;
      flex-shrink: 0;
    }
    .hf-modal-filter-bar input[type=search] {
      flex: 1 1 240px;
      box-sizing: border-box;
      padding: 8px 10px;
      background: var(--hf-surface-2);
      color: var(--hf-text);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      font-size: 14px;
      font-family: inherit;
    }
    .hf-modal-filter-bar .sort-group {
      display: flex;
      gap: 6px;
      flex-wrap: wrap;
    }
    .sort-btn {
      padding: 7px 12px;
      background: var(--hf-surface-2);
      color: var(--hf-text-muted);
      border: 1px solid var(--hf-border-2);
      border-radius: 999px;
      cursor: pointer;
      font-size: 12px;
      font-family: inherit;
    }
    .sort-btn.active {
      background: var(--hf-accent);
      color: #06281c;
      border-color: var(--hf-accent);
      font-weight: 600;
    }
    .hf-modal-body {
      flex: 1;
      overflow-y: auto;
      padding: 18px;
    }
    .hf-modal-body .directory-grid { margin-bottom: 0; }
    .hf-modal-footer {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 10px 18px;
      border-top: 1px solid var(--hf-border-2);
      color: var(--hf-text-muted);
      font-size: 12px;
      flex-shrink: 0;
    }
    .hf-modal-footer .refresh {
      background: none;
      border: none;
      color: var(--hf-accent);
      cursor: pointer;
      font-size: 12px;
      font-family: inherit;
      padding: 0;
    }
    .hf-modal-footer .refresh:disabled { opacity: 0.5; cursor: default; }
    .hf-modal-empty {
      color: var(--hf-text-muted);
      font-size: 13px;
      padding: 12px 0;
    }
    /* Edit-plugin modal: footer is a right-aligned action row
       (Validate · Cancel · Save). Distinct from the store modal's
       count/refresh footer. */
    .hf-modal-footer-actions {
      justify-content: flex-end;
      gap: 8px;
      color: var(--hf-text);
    }
    /* The edit modal sizes a little smaller than the store — the
       form rarely needs 700px of vertical space. */
    .hf-modal-form { height: min(620px, 100%); }

    /* Installed-plugins header: title + Add Custom Plugin + Plugin
       Store buttons. The button group can wrap to its own row on
       narrow widths. */
    .installed-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
      margin: 8px 0 12px;
      flex-wrap: wrap;
    }
    .installed-header h3 { margin: 0; }
    .installed-header .actions {
      display: flex;
      gap: 8px;
      flex-wrap: wrap;
    }

    /* Inline filter bar above the installed-plugins list. Same input
       styling as the modal's filter bar so the page reads consistently;
       no sort pills here because the order is fixed (store-first, then
       alphabetical). */
    .installed-filter-bar {
      display: flex;
      gap: 10px;
      margin-bottom: 10px;
    }
    .installed-filter-bar input[type=search] {
      flex: 1 1 auto;
      box-sizing: border-box;
      padding: 8px 10px;
      background: var(--hf-surface-2);
      color: var(--hf-text);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      font-size: 14px;
      font-family: inherit;
    }

    /* Icon + label buttons. The inline svg is sized 16x16 and inherits
       the button's text colour via stroke=currentColor. */
    .btn-icon {
      display: inline-flex;
      align-items: center;
      gap: 6px;
    }
    .btn-icon svg {
      width: 16px;
      height: 16px;
      flex-shrink: 0;
    }

    @media (max-width: 600px) {
      .directory-grid { grid-template-columns: 1fr; }
      .hf-modal-backdrop { padding: 0; }
      .hf-modal {
        width: 100%;
        height: 100%;
        border-radius: 0;
        border: none;
      }
      .hf-modal-filter-bar { padding: 10px 12px; }
      .hf-modal-body { padding: 12px; }
    }
  `;

  constructor() {
    super();
    this.flakes = [];
    this.loading = true;
    this.error = '';
    this.notice = '';
    this.undeployedPaths = new Set();
    this.appliedConfig = null;
    this.directory = [];
    this.directoryLoading = true;
    this.directoryError = '';
    this.directorySourceUrl = '';
    this.directoryCacheStale = false;
    this.installingSlug = '';
    this.storeOpen = false;
    this.storeQuery = '';
    this.storeSort = 'name';
    this.editPluginOpen = false;
    this.installedQuery = '';
    // Debounced search-input handlers, created once so the timers
    // survive re-renders.
    this._storeQueryTimer = 0;
    this._installedQueryTimer = 0;
    this._onEscape = this._onEscape.bind(this);
    // Transient per-row update state for remote flakes, keyed by flake id.
    // Shape: { state, latestRev, oldRev, newRev, error, message }. Not a
    // Lit reactive property — the Map identity never changes and Lit can't
    // diff its contents, so mutations are paired with requestUpdate().
    this._updateState = new Map();
    this._resetForm();
  }

  connectedCallback() {
    super.connectedCallback();
    this.loadFlakes();
    this.loadDirectory();
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    // Defensive: if the user navigates away with a modal open, restore
    // body scroll and drop the Escape listener — neither would survive
    // a SPA re-mount cleanly otherwise. Use the same closes so the
    // chrome is rolled back atomically.
    if (this.storeOpen) this._closeStore();
    if (this.editPluginOpen) this._closeEditPlugin();
  }

  _resetForm() {
    this.formType = 'local';
    this.formName = '';
    this.formUrl = '';
    this.formInputName = '';
    this.formInputNameTouched = false;
    this.formModuleAttr = 'default';
    this.showAdvanced = false;
    this.formErrors = [];
    this.saving = false;
    this.probing = false;
    this.probeResult = null;
    this.fileBrowserOpen = false;
    this.editingId = '';
  }

  async loadFlakes() {
    this.loading = true;
    this.error = '';
    try {
      const data = await getPluginFlakes();
      this.flakes = data.flakes || [];
    } catch (e) {
      this.error = e.message || 'Failed to load registered flakes.';
    } finally {
      this.loading = false;
    }
  }

  // Plugin Directory — curated catalog from git.homefree.host. Backend
  // caches the upstream Forgejo response and tags each entry with
  // installed=true if its flakeUrl matches a registered plugin's url.
  async loadDirectory(forceRefresh = false) {
    this.directoryLoading = true;
    this.directoryError = '';
    try {
      const data = await getPluginDirectory({ forceRefresh });
      this.directory = Array.isArray(data?.plugins) ? data.plugins : [];
      this.directorySourceUrl = data?.sourceUrl || '';
      this.directoryCacheStale = !!data?.cacheStale;
      if (data?.error) this.directoryError = data.error;
    } catch (e) {
      this.directoryError = e.message || 'Failed to load plugin directory.';
      this.directory = [];
    } finally {
      this.directoryLoading = false;
    }
  }

  async _installFromDirectory(entry) {
    this.installingSlug = entry.slug;
    this.error = '';
    this.notice = '';
    emitSaveStatus(this, 'saving');
    try {
      const result = await savePluginFlake({
        name: entry.displayName,
        type: 'remote',
        url: entry.flakeUrl,
        // Repo slugs in the homefree-plugins org are pre-namespaced
        // (homefree-ai, homefree-navidrome, …) so they're safe to use
        // directly as the Nix input name — uniquely identify the plugin
        // AND don't collide with reserved names.
        inputName: entry.slug,
        moduleAttr: 'default',
        enabled: true,
      });
      this.notice = result.message
        || `Installed ${entry.displayName}. Click Apply to rebuild.`;
      await this.loadFlakes();
      await this.loadDirectory();
      this._notifyDirty();
      emitSaveStatus(this, 'saved');
    } catch (e) {
      const msg = (e.body && e.body.errors && e.body.errors.join(' '))
        || e.message
        || `Could not install ${entry.displayName}.`;
      this.error = msg;
      emitSaveStatus(this, 'error', msg);
    } finally {
      this.installingSlug = '';
    }
  }

  _scrollToFlake(id) {
    if (!id) return;
    const row = this.renderRoot.querySelector(`[data-flake-id="${id}"]`);
    if (!row) return;
    row.scrollIntoView({ behavior: 'smooth', block: 'center' });
    row.classList.add('flash-row');
    setTimeout(() => row.classList.remove('flash-row'), 1500);
  }

  // ---- Plugin Store modal -----------------------------------------

  _openStore() {
    this.storeOpen = true;
    this._updateModalChrome();
    // Refresh the directory in the background on open, so a stale
    // cache doesn't show old installed-state if the user added a
    // plugin via the manual form between opens. Non-forced so the
    // backend cache TTL still applies.
    this.loadDirectory();
  }

  _closeStore() {
    this.storeOpen = false;
    this._updateModalChrome();
  }

  _openAddPlugin() {
    this._resetForm();
    this.editPluginOpen = true;
    this._updateModalChrome();
  }

  _openEditPlugin(flake) {
    // _editFlake fills the form fields from the row data; we then
    // open the modal. Order matters — opening first would briefly
    // flash the modal with the previous edit's state.
    this._editFlake(flake);
    this.editPluginOpen = true;
    this._updateModalChrome();
  }

  _closeEditPlugin() {
    this.editPluginOpen = false;
    this._resetForm();
    this._updateModalChrome();
  }

  // Centralised body-scroll lock + Escape listener wiring. Locks while
  // either modal is open, restores when both are closed. Called from
  // every open/close path so the bookkeeping never drifts.
  _updateModalChrome() {
    const anyOpen = this.storeOpen || this.editPluginOpen;
    document.body.style.overflow = anyOpen ? 'hidden' : '';
    if (anyOpen) {
      document.addEventListener('keydown', this._onEscape);
    } else {
      document.removeEventListener('keydown', this._onEscape);
    }
  }

  _onEscape(e) {
    if (e.key !== 'Escape') return;
    // Edit modal stacks on top of the store, so close it first.
    if (this.editPluginOpen) this._closeEditPlugin();
    else if (this.storeOpen) this._closeStore();
  }

  _onBackdropClick(e) {
    // Only the bare backdrop triggers a close — clicks inside the
    // .hf-modal box bubble up but should not close the modal.
    if (e.target === e.currentTarget) this._closeStore();
  }

  _onEditBackdropClick(e) {
    if (e.target === e.currentTarget) this._closeEditPlugin();
  }

  _onStoreQueryInput(e) {
    const value = e.target.value;
    if (this._storeQueryTimer) clearTimeout(this._storeQueryTimer);
    this._storeQueryTimer = setTimeout(() => {
      this.storeQuery = value;
    }, 200);
  }

  _onInstalledQueryInput(e) {
    const value = e.target.value;
    if (this._installedQueryTimer) clearTimeout(this._installedQueryTimer);
    this._installedQueryTimer = setTimeout(() => {
      this.installedQuery = value;
    }, 200);
  }

  // Filter + sort the registered flakes for the installed-plugins list.
  // Sort tiers (each ranked by name within the tier):
  //   0 — Store-installed (curated set up top, easiest to scan).
  //   1 — Remote flakes (custom URLs).
  //   2 — Local working-tree flakes.
  // Substring filter matches name + url, case-insensitive.
  _installedEntries() {
    const q = (this.installedQuery || '').trim().toLowerCase();
    const matches = (f) => {
      if (!q) return true;
      const hay = `${f.name || ''} ${f.url || ''}`.toLowerCase();
      return hay.includes(q);
    };
    const rank = (f) => {
      if (this._isFromDirectory(f)) return 0;
      if (f.type === 'remote') return 1;
      return 2;
    };
    const list = (this.flakes || []).filter(matches);
    const cmp = (a, b) => {
      const ra = rank(a), rb = rank(b);
      if (ra !== rb) return ra - rb;
      return (a.name || '').localeCompare(b.name || '');
    };
    return list.slice().sort(cmp);
  }

  _setStoreSort(key) {
    this.storeSort = key;
  }

  // Filtered + sorted view of `this.directory` for the modal body.
  _storeEntries() {
    const q = (this.storeQuery || '').trim().toLowerCase();
    const matches = (e) => {
      if (!q) return true;
      const hay = `${e.displayName || ''} ${e.description || ''}`.toLowerCase();
      return hay.includes(q);
    };
    const filtered = (this.directory || []).filter(matches);
    const sorted = filtered.slice();
    if (this.storeSort === 'updated') {
      // Forgejo ISO timestamps lex-sort the same as date-sort.
      sorted.sort((a, b) => (b.updatedAt || '').localeCompare(a.updatedAt || ''));
    } else if (this.storeSort === 'created') {
      sorted.sort((a, b) => (b.createdAt || '').localeCompare(a.createdAt || ''));
    } else {
      sorted.sort((a, b) =>
        (a.displayName || a.slug || '').localeCompare(b.displayName || b.slug || ''));
    }
    return sorted;
  }

  _manageInstalled(entry) {
    // Find the actual flake by the id the directory entry was tagged
    // with — that's the same object the row's Edit button would pass
    // to _openEditPlugin. Close the store FIRST so opening the edit
    // modal on top of it doesn't double-lock body scroll.
    const id = entry?.installedFlakeId;
    const flake = (this.flakes || []).find((f) => f.id === id);
    this._closeStore();
    if (flake) {
      this._openEditPlugin(flake);
    }
  }

  // True if a registered flake's url matches a directory entry's
  // flakeUrl — drives the "Store" pill on installed rows. Returns
  // false when the directory hasn't loaded yet; Lit re-renders the
  // row once it does, so the pill appears then.
  _isFromDirectory(flake) {
    if (!flake || !flake.url) return false;
    return (this.directory || []).some((e) => e.flakeUrl === flake.url);
  }

  // Mirror the backend's _slugify_input_name so the suggested input name
  // matches what the server would derive.
  _slugify(name) {
    const slug = (name || '')
      .trim().toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '');
    return `custom-${slug || 'flake'}`;
  }

  _onNameInput(e) {
    this.formName = e.target.value;
    if (!this.formInputNameTouched) {
      this.formInputName = this._slugify(this.formName);
    }
  }

  _onInputNameInput(e) {
    this.formInputName = e.target.value;
    this.formInputNameTouched = true;
  }

  _setType(type) {
    // Keep whatever the user has typed — the same input box serves both
    // kinds; only the placeholder/label/hint change. Clearing on toggle
    // was the annoyance. The probe result is type-specific, so drop it.
    this.formType = type;
    this.probeResult = null;
  }

  _handlePathSelected(e) {
    this.formUrl = e.detail.path;
    this.fileBrowserOpen = false;
  }

  async _probe() {
    if (!this.formUrl) {
      this.formErrors = ['Enter a flake path or URL before validating.'];
      return;
    }
    this.probing = true;
    this.probeResult = null;
    this.formErrors = [];
    try {
      this.probeResult = await validatePluginFlake({
        type: this.formType,
        url: this.formUrl,
        moduleAttr: this.formModuleAttr || 'default',
      });
    } catch (e) {
      this.formErrors = [e.message || 'Could not probe the flake.'];
    } finally {
      this.probing = false;
    }
  }

  async _save() {
    this.saving = true;
    this.formErrors = [];
    this.error = '';
    this.notice = '';
    emitSaveStatus(this, 'saving');
    try {
      const result = await savePluginFlake({
        id: this.editingId || undefined,
        name: this.formName,
        type: this.formType,
        url: this.formUrl,
        inputName: this.formInputName,
        moduleAttr: this.formModuleAttr || 'default',
        enabled: true,
      });
      this.notice = result.message || 'Flake registered. Click Apply to rebuild.';
      // Close the modal on a successful save. _closeEditPlugin runs
      // _resetForm so the form is empty next time it opens.
      this._closeEditPlugin();
      await this.loadFlakes();
      this._notifyDirty();
      emitSaveStatus(this, 'saved');
    } catch (e) {
      // The backend returns 400 with { errors: [...] } on validation failure;
      // fetchAPI surfaces that body on the thrown error.
      this.formErrors = (e.body && e.body.errors) || [e.message || 'Failed to register flake.'];
      emitSaveStatus(this, 'error', this.formErrors[0]);
    } finally {
      this.saving = false;
    }
  }

  _editFlake(flake) {
    this.editingId = flake.id;
    this.formType = flake.type;
    this.formName = flake.name;
    // Local entries are stored as git+file:// — show the bare path in the form.
    this.formUrl = flake.type === 'local' && flake.url.startsWith('git+file://')
      ? flake.url.slice('git+file://'.length)
      : flake.url;
    this.formInputName = flake.inputName;
    this.formInputNameTouched = true;
    this.formModuleAttr = flake.moduleAttr || 'default';
    this.showAdvanced = true;
    this.probeResult = null;
    this.formErrors = [];
  }

  async _toggleEnabled(flake) {
    this.error = '';
    emitSaveStatus(this, 'saving');
    try {
      await savePluginFlake({ ...flake, enabled: !flake.enabled });
      await this.loadFlakes();
      this._notifyDirty();
      emitSaveStatus(this, 'saved');
    } catch (e) {
      this.error = (e.body && e.body.errors && e.body.errors.join(' '))
        || e.message || 'Failed to update flake.';
      emitSaveStatus(this, 'error', this.error);
    }
  }

  async _delete(flake) {
    const ok = await confirmDialog({
      title: 'Remove plugin?',
      message: `Remove the plugin "${flake.name}"? Its apps and modules will no longer be composed into the system after the next rebuild.`,
      confirmText: 'Remove',
      variant: 'danger',
    });
    if (!ok) return;
    this.error = '';
    this.notice = '';
    emitSaveStatus(this, 'saving');
    try {
      await deletePluginFlake(flake.id);
      // No success notice — the top-bar "Saved" pill is the feedback.
      await this.loadFlakes();
      // Refresh the directory so an uninstalled plugin flips back to
      // showing an Install button. Skip the upstream fetch (the
      // installed-state is recomputed against the cached result).
      this.loadDirectory();
      this._notifyDirty();
      emitSaveStatus(this, 'saved');
    } catch (e) {
      this.error = e.message || 'Failed to remove flake.';
      emitSaveStatus(this, 'error', this.error);
    }
  }

  // Nudge the shell to re-check dirty state so the sidebar Apply button
  // enables immediately rather than on its next poll.
  _notifyDirty() {
    this.dispatchEvent(new CustomEvent('updates-applied', {
      bubbles: true, composed: true,
    }));
  }

  // ---- remote-flake update check / re-lock ------------------------
  //
  // Remote inputs stay pinned at their flake.lock rev across rebuilds
  // (only LOCAL working-tree inputs and the homefree-* base are auto-
  // re-locked in build.sh / _refresh_local_inputs). These two handlers
  // surface that pinning to the operator: one probes upstream, the
  // other re-locks just that input. The re-lock surfaces through the
  // standard "build inputs changed" Apply reason, so the operator
  // deploys it via the sidebar Apply pill like any other staged edit.

  _getUpdateState(id) {
    return this._updateState.get(id) || { state: 'idle' };
  }

  _bumpUpdateState(id, patch) {
    const prior = this._updateState.get(id) || { state: 'idle' };
    this._updateState.set(id, { ...prior, ...patch });
    this.requestUpdate();
  }

  async _checkUpdate(flake) {
    this._bumpUpdateState(flake.id, { state: 'checking', error: '' });
    try {
      const result = await checkPluginFlakeUpdate(flake.id);
      if (result.updateAvailable) {
        this._bumpUpdateState(flake.id, {
          state: 'available',
          latestRev: result.latestRev,
        });
      } else {
        this._bumpUpdateState(flake.id, { state: 'up-to-date' });
        // Drop the transient up-to-date badge after a few seconds so the
        // row doesn't carry a stale 'fresh check' indicator forever.
        setTimeout(() => {
          const cur = this._updateState.get(flake.id);
          if (cur && cur.state === 'up-to-date') {
            this._bumpUpdateState(flake.id, { state: 'idle' });
          }
        }, 4000);
      }
    } catch (e) {
      const msg = (e.body && e.body.message)
        || (e.body && e.body.detail)
        || e.message
        || 'Could not check for updates.';
      this._bumpUpdateState(flake.id, { state: 'error', error: msg });
    }
  }

  async _applyUpdate(flake) {
    this._bumpUpdateState(flake.id, { state: 'updating', error: '' });
    emitSaveStatus(this, 'saving');
    try {
      const result = await updatePluginFlake(flake.id);
      this._bumpUpdateState(flake.id, {
        state: 'updated',
        oldRev: result.oldRev,
        newRev: result.newRev,
        message: result.message || 'Updated — click Apply to deploy.',
      });
      // The flake.lock drift the backend just introduced is detected by
      // build_inputs_dirty() and surfaces as 'build inputs changed' in
      // the sidebar Apply note. Nudge the shell to re-check now.
      this._notifyDirty();
      emitSaveStatus(this, 'saved');
    } catch (e) {
      const msg = (e.body && e.body.message)
        || (e.body && e.body.detail)
        || e.message
        || 'Failed to update flake.';
      this._bumpUpdateState(flake.id, { state: 'error', error: msg });
      emitSaveStatus(this, 'error', msg);
    }
  }

  // Modal body: search/sort applied to the cached directory entries.
  // Empty / loading / error states render here, not on the page proper,
  // so the page never carries an "empty directory" message while the
  // modal is closed.
  _renderStoreBody() {
    if (this.directoryLoading && this.directory.length === 0) {
      return html`<p class="muted">Loading plugin directory…</p>`;
    }
    if (this.directoryError && this.directory.length === 0) {
      return html`
        <div class="hf-modal-empty">
          Could not load the plugin directory: ${this.directoryError}
        </div>
      `;
    }
    if (this.directory.length === 0) {
      return html`
        <div class="hf-modal-empty">
          No plugins are available in the directory yet.
        </div>
      `;
    }
    const entries = this._storeEntries();
    if (entries.length === 0) {
      return html`
        <div class="hf-modal-empty">
          No plugins match your search.
        </div>
      `;
    }
    return html`
      ${this.directoryCacheStale ? html`
        <div class="directory-stale-note">
          Showing cached results — could not reach the directory.
        </div>
      ` : ''}
      <div class="directory-grid">
        ${entries.map((entry) => this._renderDirectoryCard(entry))}
      </div>
    `;
  }

  _renderDirectoryCard(entry) {
    const installing = this.installingSlug === entry.slug;
    const desc = entry.description || 'No description provided.';
    return html`
      <div class="directory-card">
        <div class="name">
          <span>${entry.displayName}</span>
          ${entry.installed
            ? html`<span class="badge installed">Installed</span>`
            : ''}
        </div>
        <div class="description">${desc}</div>
        <div class="footer">
          ${entry.installed ? html`
            <button class="btn"
              @click=${() => this._manageInstalled(entry)}>
              Manage
            </button>
          ` : html`
            <button class="btn"
              ?disabled=${installing || !entry.flakeUrl}
              @click=${() => this._installFromDirectory(entry)}>
              ${installing ? 'Installing…' : 'Install'}
            </button>
          `}
          ${entry.htmlUrl ? html`
            <a href=${entry.htmlUrl} target="_blank" rel="noopener noreferrer">
              Source ↗
            </a>
          ` : ''}
        </div>
      </div>
    `;
  }

  _renderEditPluginModal() {
    if (!this.editPluginOpen) return '';
    const editing = !!this.editingId;
    const title = editing ? 'Edit Custom Plugin' : 'Add Custom Plugin';
    const saveLabel = this.saving
      ? 'Saving…'
      : (editing ? 'Save changes' : 'Add plugin');
    return html`
      <div class="hf-modal-backdrop" @click=${(e) => this._onEditBackdropClick(e)}>
        <div class="hf-modal hf-modal-form" role="dialog" aria-modal="true" aria-label=${title}>
          <div class="hf-modal-header">
            <h3>${title}</h3>
            <button class="hf-modal-close"
              aria-label="Close"
              @click=${() => this._closeEditPlugin()}>✕</button>
          </div>
          <div class="hf-modal-body">
            ${this._renderForm()}
          </div>
          <div class="hf-modal-footer hf-modal-footer-actions">
            <button class="btn"
              ?disabled=${this.probing || !this.formUrl}
              @click=${this._probe}
            >${this.probing ? 'Validating…' : 'Validate'}</button>
            <button class="btn"
              @click=${() => this._closeEditPlugin()}
            >Cancel</button>
            <button class="btn primary"
              ?disabled=${this.saving || !this.formName || !this.formUrl}
              @click=${this._save}
            >${saveLabel}</button>
          </div>
        </div>
      </div>
    `;
  }

  _renderStoreModal() {
    if (!this.storeOpen) return '';
    const sortBtn = (key, label) => html`
      <button
        class="sort-btn ${this.storeSort === key ? 'active' : ''}"
        @click=${() => this._setStoreSort(key)}
      >${label}</button>
    `;
    return html`
      <div class="hf-modal-backdrop" @click=${(e) => this._onBackdropClick(e)}>
        <div class="hf-modal" role="dialog" aria-modal="true" aria-label="Plugin Store">
          <div class="hf-modal-header">
            <h3>Plugin Store</h3>
            <button class="hf-modal-close"
              aria-label="Close"
              @click=${() => this._closeStore()}>✕</button>
          </div>
          <div class="hf-modal-filter-bar">
            <input
              type="search"
              placeholder="Search plugins…"
              .value=${this.storeQuery}
              @input=${(e) => this._onStoreQueryInput(e)}
            />
            <div class="sort-group">
              ${sortBtn('name', 'Name')}
              ${sortBtn('updated', 'Recently updated')}
              ${sortBtn('created', 'Recently added')}
            </div>
          </div>
          <div class="hf-modal-body">
            ${this._renderStoreBody()}
          </div>
          <div class="hf-modal-footer">
            <span>${this.directory.length} plugin${this.directory.length === 1 ? '' : 's'} in the directory</span>
            <button class="refresh"
              ?disabled=${this.directoryLoading}
              @click=${() => this.loadDirectory(true)}
            >${this.directoryLoading ? 'Refreshing…' : 'Refresh'}</button>
          </div>
        </div>
      </div>
    `;
  }

  _renderProbe() {
    const p = this.probeResult;
    if (!p) return '';
    const normalized = p.normalizedUrl && p.normalizedUrl !== (this.formUrl || '').trim()
      ? p.normalizedUrl
      : '';
    return html`
      ${normalized
        ? html`<div class="notice">Interpreted as <code>${normalized}</code></div>`
        : ''}
      ${(p.errors || []).map((m) => html`<div class="error">${m}</div>`)}
      ${(p.warnings || []).map((m) => html`<div class="warn">⚠️ ${m}</div>`)}
      ${p.valid && (p.errors || []).length === 0 && (p.warnings || []).length === 0
        ? html`<div class="notice">Flake is reachable and exposes the requested module.</div>`
        : ''}
    `;
  }

  // Form body rendered inside the Edit-plugin modal. The modal header
  // carries the "Add / Edit" title; the modal footer wraps Save +
  // Validate + Cancel. So this body returns ONLY the field stack and
  // the probe/error feedback — no h3, no card wrapper, no buttons.
  _renderForm() {
    return html`
      <div class="type-toggle">
        <button
          class=${this.formType === 'local' ? 'active' : ''}
          @click=${() => this._setType('local')}
        >Local repository</button>
        <button
          class=${this.formType === 'remote' ? 'active' : ''}
          @click=${() => this._setType('remote')}
        >Remote URL</button>
      </div>

      <label class="field">
        <span class="lbl">Name</span>
        <input
          type="text"
          .value=${this.formName}
          placeholder="My custom apps"
          @input=${this._onNameInput}
        />
      </label>

      <label class="field">
        <span class="lbl">${this.formType === 'local' ? 'Local flake repository' : 'Flake URL'}</span>
        <div class="input-with-browse">
          <input
            type="text"
            .value=${this.formUrl}
            placeholder=${this.formType === 'local' ? '/home/you/my-flake' : 'github:owner/repo'}
            @input=${(e) => { this.formUrl = e.target.value; }}
          />
          ${this.formType === 'local' ? html`
            <button class="btn" @click=${() => { this.fileBrowserOpen = true; }}>
              📁 Browse
            </button>
          ` : ''}
        </div>
        <span class="hint">
          ${this.formType === 'local'
            ? 'A git repository on this machine containing a flake.nix. Stored as a git+file:// flake reference.'
            : 'A flake reference, e.g. github:owner/repo, gitlab:owner/repo or git+https://example.com/repo.git'}
        </span>
      </label>

      <button class="advanced-toggle" @click=${() => { this.showAdvanced = !this.showAdvanced; }}>
        ${this.showAdvanced ? '▾ Hide advanced' : '▸ Advanced'}
      </button>

      ${this.showAdvanced ? html`
        <label class="field">
          <span class="lbl">Flake input name</span>
          <input
            type="text"
            .value=${this.formInputName}
            @input=${this._onInputNameInput}
          />
          <span class="hint">
            The identifier this flake gets in /etc/nixos/flake.nix.
            Must be unique. Auto-derived from the name.
          </span>
        </label>
        <label class="field">
          <span class="lbl">Module attribute</span>
          <input
            type="text"
            .value=${this.formModuleAttr}
            placeholder="default"
            @input=${(e) => { this.formModuleAttr = e.target.value; }}
          />
          <span class="hint">
            Which nixosModules.&lt;attr&gt; of the flake to compose into
            the system. Usually "default".
          </span>
        </label>
      ` : ''}

      ${this.formErrors.map((m) => html`<div class="error">${m}</div>`)}
      ${this._renderProbe()}

      ${this.fileBrowserOpen ? html`
        <file-browser
          ?open=${this.fileBrowserOpen}
          .currentPath=${this.formUrl || '/home'}
          @path-selected=${this._handlePathSelected}
          @close=${() => { this.fileBrowserOpen = false; }}
        ></file-browser>
      ` : ''}
    `;
  }

  _renderList() {
    if (this.loading) return html`<p class="muted">Loading registered plugins…</p>`;
    if (this.flakes.length === 0) {
      return html`<p class="muted">No plugins registered yet.</p>`;
    }
    const entries = this._installedEntries();
    return html`
      <div class="installed-filter-bar">
        <input
          type="search"
          placeholder="Search installed plugins…"
          .value=${this.installedQuery}
          @input=${(e) => this._onInstalledQueryInput(e)}
        />
      </div>
      ${entries.length === 0 ? html`
        <p class="muted">No plugins match your search.</p>
      ` : ''}
      ${entries.map((f) => {
        const upd = this._getUpdateState(f.id);
        return html`
        <div class="flake-row ${this._flakeChanged(f) ? 'changed' : ''}" data-flake-id=${f.id}>
          <div class="meta">
            <div class="name">
              ${f.name}
              ${this._isFromDirectory(f)
                ? html`<span class="badge store" title="Installed from the Plugin Store">Store</span>`
                : html`<span class="badge ${f.type}">${f.type}</span>`}
              ${upd.state === 'available' ? html`
                <span class="badge update-available">update available</span>
              ` : ''}
              ${upd.state === 'up-to-date' ? html`
                <span class="badge update-ok">up to date</span>
              ` : ''}
              ${upd.state === 'updated' ? html`
                <span class="badge update-available">updated — apply to deploy</span>
              ` : ''}
              ${upd.state === 'error' ? html`
                <span class="badge update-err" title=${upd.error || ''}>check failed</span>
              ` : ''}
              ${f.enabled ? '' : html`<span class="sub">— disabled</span>`}
            </div>
            <div class="url">${f.url}</div>
            <div class="sub">input: ${f.inputName} · module: ${f.moduleAttr || 'default'}</div>
          </div>
          <label class="toggle-switch">
            <input
              type="checkbox"
              .checked=${f.enabled}
              @change=${() => this._toggleEnabled(f)}
            />
            <span class="sub">Enabled</span>
          </label>
          ${this._renderUpdateControl(f, upd)}
          <button class="btn" @click=${() => this._openEditPlugin(f)}>Edit</button>
          <button class="btn danger" @click=${() => this._delete(f)}>Remove</button>
        </div>
      `;
      })}
    `;
  }

  // Per-row update control. Remote flakes get a real button that cycles
  // through check / update states. Local flakes are auto-re-locked on
  // every Apply, so they get a passive hint instead of a button.
  _renderUpdateControl(f, upd) {
    if (f.type === 'local') {
      return html`<span class="sub" title="Local working-tree inputs are re-locked on every Apply.">Auto-refreshes on Apply</span>`;
    }
    if (upd.state === 'available') {
      return html`
        <button class="btn primary" @click=${() => this._applyUpdate(f)}>
          Update
        </button>
      `;
    }
    if (upd.state === 'checking') {
      return html`<button class="btn" disabled>Checking…</button>`;
    }
    if (upd.state === 'updating') {
      return html`<button class="btn" disabled>Updating…</button>`;
    }
    if (upd.state === 'updated') {
      return html`<button class="btn" disabled>Updated</button>`;
    }
    if (upd.state === 'error') {
      return html`
        <button class="btn" title=${upd.error || ''} @click=${() => this._checkUpdate(f)}>
          Retry check
        </button>
      `;
    }
    return html`
      <button class="btn" @click=${() => this._checkUpdate(f)}>
        Check for updates
      </button>
    `;
  }

  // Coarse "undeployed" flag for the plugins section: true when the
  // plugins section of the on-disk config differs from the deployed one.
  // The backend reports the flakes array as a whole-value path under
  // "plugins", so this is section-level, not per-row. Legacy boxes still
  // running pre-migration may surface paths under "developers" — accept
  // either until the next-release cleanup drops the legacy alias.
  _pluginsUndeployed() {
    if (!this.undeployedPaths) return false;
    for (const p of this.undeployedPaths) {
      if (p === 'plugins' || p.startsWith('plugins.')) return true;
      if (p === 'developers.flakes') return true;
    }
    return false;
  }

  // True when a registered flake differs from its deployed entry (newly added
  // or modified), matched by stable id. list_flakes() returns the rows verbatim
  // from plugins.flakes, so the applied snapshot is the identical shape and a
  // JSON compare is exact. Falls back to the section-level flag when there's no
  // deployed baseline (fresh box). Reads either applied key during the
  // legacy-alias window.
  _flakeChanged(flake) {
    const appliedFlakes = this.appliedConfig?.plugins?.flakes
      ?? this.appliedConfig?.developers?.flakes;
    if (!Array.isArray(appliedFlakes)) {
      return this.undeployedPaths?.has('plugins.flakes')
        || this.undeployedPaths?.has('developers.flakes')
        || false;
    }
    const prior = appliedFlakes.find((f) => f && f.id === flake.id);
    if (!prior) return true;
    return JSON.stringify(prior) !== JSON.stringify(flake);
  }

  render() {
    return html`
      <div class="module-container">
        ${this._pluginsUndeployed() ? html`
          <div style="display:flex;align-items:center;gap:8px;margin-bottom:16px;padding:10px 14px;border-radius:8px;background:var(--hf-warn-soft);border:1px solid var(--hf-warn);color:var(--hf-warn);font-size:13px;font-weight:500;">
            <span style="width:8px;height:8px;border-radius:50%;background:var(--hf-warn);flex-shrink:0;"></span>
            <span>Undeployed plugin changes — click Apply in the sidebar to deploy.</span>
          </div>
        ` : ''}

        ${this.notice ? html`<div class="notice"><strong>Done.</strong> ${this.notice}</div>` : ''}
        ${this.error ? html`<div class="error">${this.error}</div>` : ''}

        <div class="installed-header">
          <h3>Installed plugins</h3>
          <div class="actions">
            <button class="btn btn-icon"
              @click=${() => this._openAddPlugin()}
              title="Register a flake by URL or path"
            >${actionIcon('plus')}<span>Add Custom Plugin</span></button>
            <button class="btn primary btn-icon"
              @click=${() => this._openStore()}
              title="Browse the curated catalog at git.homefree.host/homefree-plugins"
            >${actionIcon('developers')}<span>Plugin Store</span></button>
          </div>
        </div>
        ${this._renderList()}

        ${this._renderStoreModal()}
        ${this._renderEditPluginModal()}
      </div>
    `;
  }
}

customElements.define('plugins-module', PluginsModule);
