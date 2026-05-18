import { LitElement, html, css } from 'lit';
import {
  getDeveloperFlakes,
  saveDeveloperFlake,
  deleteDeveloperFlake,
  validateDeveloperFlake,
  getHomefreeBase,
  saveHomefreeBase,
  validateHomefreeBase,
} from '../../../api/client.js';
import '../../shared/file-browser.js';

/**
 * Developers module — register custom Nix flakes.
 *
 * A production HomeFree install tracks the upstream `homefree-base` flake
 * and pulls releases via the Updates page. This module lets an admin ALSO
 * compose their own flakes' nixosModules into the build, so they can run
 * custom apps/modules without forking and without losing upstream updates.
 *
 * Registering a flake rewrites /etc/nixos/flake.nix and custom-flakes.nix
 * but does NOT rebuild — that lands the change in homefree-config.json too,
 * so the shell's dirty detection fires and the sidebar "Apply Changes"
 * button activates. The admin rebuilds from there.
 */
class DevelopersModule extends LitElement {
  static properties = {
    flakes: { type: Array, state: true },
    loading: { type: Boolean, state: true },
    error: { type: String, state: true },
    notice: { type: String, state: true },
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
    // Alternate HomeFree base repo panel state.
    baseLoading: { type: Boolean, state: true },
    baseOfficialUrl: { type: String, state: true },
    baseEnabled: { type: Boolean, state: true },
    baseType: { type: String, state: true },
    baseUrl: { type: String, state: true },
    baseSaving: { type: Boolean, state: true },
    baseProbing: { type: Boolean, state: true },
    baseProbeResult: { type: Object, state: true },
    baseErrors: { type: Array, state: true },
    baseWarnings: { type: Array, state: true },
    baseNotice: { type: String, state: true },
    baseBrowserOpen: { type: Boolean, state: true },
  };

  static styles = css`
    :host { display: block; }
    .module-container { width: 100%; }

    .info-box {
      background: var(--hf-accent-soft);
      border-left: 4px solid var(--hf-accent);
      padding: 16px;
      border-radius: 8px;
      margin-bottom: 20px;
      color: var(--hf-accent);
    }
    .info-box strong { display: block; margin-bottom: 8px; }

    .notice {
      background: rgba(74,222,128,0.1);
      border: 1px solid rgba(74,222,128,0.35);
      color: #4ade80;
      padding: 14px 18px;
      border-radius: 8px;
      margin-bottom: 16px;
    }
    .notice strong { color: #4ade80; }

    .error {
      background: rgba(248,113,113,0.08);
      border: 1px solid rgba(248,113,113,0.3);
      color: #fca5a5;
      padding: 12px 16px;
      border-radius: 6px;
      margin-bottom: 16px;
    }

    .warn {
      background: rgba(250,204,21,0.1);
      border: 1px solid rgba(250,204,21,0.35);
      color: #facc15;
      padding: 10px 14px;
      border-radius: 6px;
      margin-bottom: 12px;
      font-size: 13px;
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

    .type-toggle { display: flex; gap: 8px; margin-bottom: 14px; }
    .type-toggle button {
      flex: 1;
      padding: 8px;
      background: var(--hf-surface-2);
      color: var(--hf-text-muted);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      cursor: pointer;
      font-size: 13px;
    }
    .type-toggle button.active {
      background: var(--hf-accent);
      color: #06281c;
      border-color: var(--hf-accent);
      font-weight: 600;
    }

    .input-with-browse { display: flex; gap: 8px; }
    .input-with-browse input { flex: 1; }

    button.btn {
      padding: 8px 16px;
      background: var(--hf-surface);
      color: var(--hf-text);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      cursor: pointer;
      font-size: 14px;
    }
    button.btn:hover:not(:disabled) { background: var(--hf-surface-2); }
    button.btn:disabled { opacity: 0.5; cursor: not-allowed; }
    button.btn.primary {
      background: var(--hf-accent);
      color: #06281c;
      border-color: var(--hf-accent);
      font-weight: 600;
    }
    button.btn.danger { color: #f87171; border-color: rgba(248,113,113,0.3); }

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
  `;

  constructor() {
    super();
    this.flakes = [];
    this.loading = true;
    this.error = '';
    this.notice = '';
    this.baseLoading = true;
    this.baseOfficialUrl = '';
    this.baseEnabled = false;
    this.baseType = 'local';
    this.baseUrl = '';
    this.baseSaving = false;
    this.baseProbing = false;
    this.baseProbeResult = null;
    this.baseErrors = [];
    this.baseWarnings = [];
    this.baseNotice = '';
    this.baseBrowserOpen = false;
    this._resetForm();
  }

  connectedCallback() {
    super.connectedCallback();
    this.loadFlakes();
    this.loadBaseOverride();
  }

  async loadBaseOverride() {
    this.baseLoading = true;
    try {
      const data = await getHomefreeBase();
      this.baseOfficialUrl = data.officialUrl || '';
      this.baseEnabled = !!data.enabled;
      this.baseType = data.type || 'local';
      // Local entries are stored git+file://-prefixed; show the bare path.
      const url = data.url || '';
      this.baseUrl = (this.baseType === 'local' && url.startsWith('git+file://'))
        ? url.slice('git+file://'.length)
        : url;
    } catch (e) {
      this.error = e.message || 'Failed to load the alternate-base setting.';
    } finally {
      this.baseLoading = false;
    }
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
      const data = await getDeveloperFlakes();
      this.flakes = data.flakes || [];
    } catch (e) {
      this.error = e.message || 'Failed to load registered flakes.';
    } finally {
      this.loading = false;
    }
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
    this.formType = type;
    this.formUrl = '';
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
      this.probeResult = await validateDeveloperFlake({
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
    try {
      const result = await saveDeveloperFlake({
        id: this.editingId || undefined,
        name: this.formName,
        type: this.formType,
        url: this.formUrl,
        inputName: this.formInputName,
        moduleAttr: this.formModuleAttr || 'default',
        enabled: true,
      });
      this.notice = result.message || 'Flake registered. Click Apply Changes to rebuild.';
      this._resetForm();
      await this.loadFlakes();
      this._notifyDirty();
    } catch (e) {
      // The backend returns 400 with { errors: [...] } on validation failure;
      // fetchAPI surfaces that body on the thrown error.
      this.formErrors = (e.body && e.body.errors) || [e.message || 'Failed to register flake.'];
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
    try {
      await saveDeveloperFlake({ ...flake, enabled: !flake.enabled });
      await this.loadFlakes();
      this._notifyDirty();
    } catch (e) {
      this.error = (e.body && e.body.errors && e.body.errors.join(' '))
        || e.message || 'Failed to update flake.';
    }
  }

  async _delete(flake) {
    if (!confirm(`Remove the custom flake "${flake.name}"?`)) return;
    this.error = '';
    this.notice = '';
    try {
      const result = await deleteDeveloperFlake(flake.id);
      this.notice = result.message || 'Flake removed. Click Apply Changes to rebuild.';
      await this.loadFlakes();
      this._notifyDirty();
    } catch (e) {
      this.error = e.message || 'Failed to remove flake.';
    }
  }

  // Nudge the shell to re-check dirty state so the sidebar Apply button
  // enables immediately rather than on its next poll.
  _notifyDirty() {
    this.dispatchEvent(new CustomEvent('updates-applied', {
      bubbles: true, composed: true,
    }));
  }

  // ---- alternate HomeFree base repo panel -------------------------
  //
  // The panel persists like the rest of the admin UI — no Save button.
  // The enabled toggle and the type toggle persist immediately; the URL
  // field persists on blur / Enter (not on every keystroke, so a
  // half-typed path never rewrites flake.nix). Enabling with no URL yet
  // is not persisted — it just reveals the field — so it cannot fail
  // the backend's enabled-needs-a-URL check.

  // True when there is something coherent to persist: either the
  // override is off, or it is on AND a URL has been entered.
  get _baseReadyToPersist() {
    return !this.baseEnabled || !!(this.baseUrl || '').trim();
  }

  async _persistBase() {
    if (!this._baseReadyToPersist) return;  // enabled but URL not entered yet
    this.baseSaving = true;
    this.baseErrors = [];
    this.baseWarnings = [];
    this.baseNotice = '';
    this.error = '';
    try {
      const result = await saveHomefreeBase({
        enabled: this.baseEnabled,
        type: this.baseType,
        url: this.baseUrl,
      });
      // The backend always saves the setting; an invalid path/URL comes
      // back as warnings (the repo is saved but not applied), not errors.
      this.baseWarnings = result.warnings || [];
      this.baseNotice = this.baseWarnings.length
        ? ''
        : (result.message || 'Saved. Click Apply Changes to rebuild.');
      this.baseProbeResult = null;
      await this.loadBaseOverride();
      this._notifyDirty();
    } catch (e) {
      this.baseErrors = (e.body && e.body.errors)
        || [e.message || 'Failed to save the alternate base repository.'];
    } finally {
      this.baseSaving = false;
    }
  }

  _onBaseToggle(e) {
    this.baseEnabled = e.target.checked;
    this.baseProbeResult = null;
    // Disabling always persists; enabling persists only once a URL exists.
    this._persistBase();
  }

  _setBaseType(type) {
    if (this.baseType === type) return;
    this.baseType = type;
    this.baseUrl = '';
    this.baseProbeResult = null;
    // A type switch clears the URL — persist so a stale URL of the other
    // kind doesn't linger (no-op if enabled, since URL is now empty).
    this._persistBase();
  }

  _handleBasePathSelected(e) {
    this.baseUrl = e.detail.path;
    this.baseBrowserOpen = false;
    this._persistBase();
  }

  // Persist when the URL field loses focus or the user presses Enter.
  _onBaseUrlCommit() {
    this._persistBase();
  }

  async _probeBase() {
    if (!this.baseUrl) {
      this.baseErrors = ['Enter a repository path or URL before validating.'];
      return;
    }
    this.baseProbing = true;
    this.baseProbeResult = null;
    this.baseErrors = [];
    try {
      this.baseProbeResult = await validateHomefreeBase({
        type: this.baseType,
        url: this.baseUrl,
      });
    } catch (e) {
      this.baseErrors = [e.message || 'Could not probe the repository.'];
    } finally {
      this.baseProbing = false;
    }
  }

  _renderBaseProbe() {
    const p = this.baseProbeResult;
    if (!p) return '';
    return html`
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

        ${this.baseNotice
          ? html`<div class="notice"><strong>Done.</strong> ${this.baseNotice}</div>`
          : ''}
        ${this.baseErrors.map((m) => html`<div class="error">${m}</div>`)}
        ${this.baseWarnings.map((m) => html`<div class="warn">⚠️ ${m}</div>`)}

        <label class="toggle-switch" style="margin-bottom:14px">
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

            <div class="type-toggle">
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
                <label class="field">
                  <span class="lbl">Local HomeFree repository</span>
                  <div class="input-with-browse">
                    <input
                      type="text"
                      .value=${this.baseUrl}
                      placeholder="/home/you/homefree"
                      @input=${(e) => { this.baseUrl = e.target.value; }}
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
                <label class="field">
                  <span class="lbl">Repository URL</span>
                  <input
                    type="text"
                    .value=${this.baseUrl}
                    placeholder="github:owner/homefree"
                    @input=${(e) => { this.baseUrl = e.target.value; }}
                    @change=${this._onBaseUrlCommit}
                    @keydown=${(e) => { if (e.key === 'Enter') e.target.blur(); }}
                  />
                  <span class="hint">
                    A flake reference to a HomeFree repository, e.g.
                    github:owner/homefree or git+https://example.com/homefree.git.
                    Saved when you click away or press Enter.
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
                ?disabled=${this.baseProbing || !this.baseUrl}
                @click=${this._probeBase}
              >${this.baseProbing ? 'Validating…' : 'Validate'}</button>
              ${this.baseSaving
                ? html`<span class="muted" style="align-self:center">Saving…</span>`
                : ''}
            </div>
          `
          : ''}
      </div>

      ${this.baseBrowserOpen ? html`
        <file-browser
          ?open=${this.baseBrowserOpen}
          .currentPath=${this.baseUrl || '/home'}
          @path-selected=${this._handleBasePathSelected}
          @close=${() => { this.baseBrowserOpen = false; }}
        ></file-browser>
      ` : ''}
    `;
  }

  _renderProbe() {
    const p = this.probeResult;
    if (!p) return '';
    return html`
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

        ${this.formType === 'local'
          ? html`
            <label class="field">
              <span class="lbl">Local flake repository</span>
              <div class="input-with-browse">
                <input
                  type="text"
                  .value=${this.formUrl}
                  placeholder="/home/you/my-flake"
                  @input=${(e) => { this.formUrl = e.target.value; }}
                />
                <button class="btn" @click=${() => { this.fileBrowserOpen = true; }}>
                  📁 Browse
                </button>
              </div>
              <span class="hint">
                A git repository on this machine containing a flake.nix.
                Stored as a git+file:// flake reference.
              </span>
            </label>
          `
          : html`
            <label class="field">
              <span class="lbl">Flake URL</span>
              <input
                type="text"
                .value=${this.formUrl}
                placeholder="github:owner/repo"
                @input=${(e) => { this.formUrl = e.target.value; }}
              />
              <span class="hint">
                A flake reference, e.g. github:owner/repo, gitlab:owner/repo
                or git+https://example.com/repo.git
              </span>
            </label>
          `}

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
            class="btn primary"
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
    if (this.loading) return html`<p class="muted">Loading registered flakes…</p>`;
    if (this.flakes.length === 0) {
      return html`<p class="muted">No custom flakes registered yet.</p>`;
    }
    return html`
      ${this.flakes.map((f) => html`
        <div class="flake-row">
          <div class="meta">
            <div class="name">
              ${f.name}
              <span class="badge ${f.type}">${f.type}</span>
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
          <button class="btn" @click=${() => this._editFlake(f)}>Edit</button>
          <button class="btn danger" @click=${() => this._delete(f)}>Remove</button>
        </div>
      `)}
    `;
  }

  render() {
    return html`
      <div class="module-container">
        ${this._renderBasePanel()}

        <div class="info-box">
          <strong>Custom Flakes</strong>
          Register your own Nix flakes to extend HomeFree with custom apps and
          modules. Each registered flake's <code>nixosModules</code> are composed
          into the system build — so you can run your own code while still
          receiving upstream updates. Registering a flake does not rebuild;
          click <strong>Apply Changes</strong> in the sidebar afterwards.
        </div>

        ${this.notice ? html`<div class="notice"><strong>Done.</strong> ${this.notice}</div>` : ''}
        ${this.error ? html`<div class="error">${this.error}</div>` : ''}

        <h3>Registered flakes</h3>
        ${this._renderList()}

        ${this._renderForm()}
      </div>
    `;
  }
}

customElements.define('developers-module', DevelopersModule);
