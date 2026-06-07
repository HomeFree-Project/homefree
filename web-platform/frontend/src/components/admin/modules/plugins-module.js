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
    .directory-card.installed { border-color: var(--hf-accent); }
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
    @media (max-width: 600px) {
      .directory-grid { grid-template-columns: 1fr; }
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
      this._resetForm();
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

  _renderDirectory() {
    if (this.directoryLoading && this.directory.length === 0) {
      return html`<p class="muted">Loading plugin directory…</p>`;
    }
    if (this.directoryError && this.directory.length === 0) {
      return html`
        <div class="directory-empty">
          Could not load the plugin directory: ${this.directoryError}
        </div>
      `;
    }
    if (this.directory.length === 0) {
      return html`
        <div class="directory-empty">
          No plugins are available in the directory yet.
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
        ${this.directory.map((entry) => this._renderDirectoryCard(entry))}
      </div>
    `;
  }

  _renderDirectoryCard(entry) {
    const installing = this.installingSlug === entry.slug;
    const desc = entry.description || 'No description provided.';
    return html`
      <div class="directory-card ${entry.installed ? 'installed' : ''}">
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
              @click=${() => this._scrollToFlake(entry.installedFlakeId)}>
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

  _renderForm() {
    const editing = !!this.editingId;
    return html`
      <h3>${editing ? 'Edit custom flake' : 'Add a custom flake'}</h3>
      <div class="card">
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

        <div class="actions">
          <button
            class="btn"
            ?disabled=${this.saving || !this.formName || !this.formUrl}
            @click=${this._save}
          >${this.saving ? 'Saving…' : (editing ? 'Save changes' : 'Register flake')}</button>
          <button
            class="btn"
            ?disabled=${this.probing || !this.formUrl}
            @click=${this._probe}
          >${this.probing ? 'Validating…' : 'Validate'}</button>
          ${editing ? html`
            <button class="btn" @click=${() => { this._resetForm(); }}>Cancel</button>
          ` : ''}
        </div>
      </div>

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
    return html`
      ${this.flakes.map((f) => {
        const upd = this._getUpdateState(f.id);
        return html`
        <div class="flake-row ${this._flakeChanged(f) ? 'changed' : ''}" data-flake-id=${f.id}>
          <div class="meta">
            <div class="name">
              ${f.name}
              <span class="badge ${f.type}">${f.type}</span>
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
          <button class="btn" @click=${() => this._editFlake(f)}>Edit</button>
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

        <div class="info-box">
          <strong>Plugins</strong>
          Extend HomeFree with extra apps and modules. Install one from the
          Plugin Directory below, or register your own Nix flake at the
          bottom of the page. Each plugin's <code>nixosModules</code> are
          composed into the system build; installing one does not rebuild —
          click <strong>Apply</strong> in the sidebar afterwards.
        </div>

        ${this.notice ? html`<div class="notice"><strong>Done.</strong> ${this.notice}</div>` : ''}
        ${this.error ? html`<div class="error">${this.error}</div>` : ''}

        <div class="directory-header">
          <h3>Plugin Directory</h3>
          <button
            class="refresh"
            ?disabled=${this.directoryLoading}
            @click=${() => this.loadDirectory(true)}
            title="Re-fetch the catalog from git.homefree.host"
          >${this.directoryLoading ? 'Refreshing…' : 'Refresh'}</button>
        </div>
        ${this._renderDirectory()}

        <h3>Registered plugins</h3>
        ${this._renderList()}

        ${this._renderForm()}
      </div>
    `;
  }
}

customElements.define('plugins-module', PluginsModule);
