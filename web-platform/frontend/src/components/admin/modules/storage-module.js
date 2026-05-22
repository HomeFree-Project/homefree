import { LitElement, html, css } from 'lit';
import '../../shared/config-section.js';
import '../../shared/table-editor.js';
import {
  getStorageDrives,
  getStoragePools,
  previewStoragePool,
  createStoragePool,
  getStoragePoolCreateStatus,
  forgetStoragePool,
} from '../../../api/client.js';

/**
 * Storage module (Phase 1) — turn unused drives into a local btrfs data volume.
 *
 * User-facing term is "volume"; the config key, API routes and Nix option keep
 * "pool" internally (storage.pools, /api/storage/pools), so most identifiers in
 * this file are still named pool/pools — only the visible copy says "volume".
 *
 * Drives + volumes are live data from /api/storage/*. Creation is an imperative
 * action (the backend formats the disks and records the volume in
 * homefree-config.json); the module then emits a `config-change` so the new
 * volume flows through the normal pending-change / Apply path that mounts it —
 * exactly like the Mounts module. "Forget" removes the record only (data on
 * the disks is left intact).
 */

const PROFILES = [
  { value: 'single', label: 'Single (one drive, no redundancy)', min: 1, exact: 1,
    blurb: 'One drive. No protection — if it fails, the data is lost.' },
  { value: 'raid1', label: 'Mirror (RAID1)', min: 2,
    blurb: 'Keeps a full copy on each drive. Survives a drive failure. Usable space is about half the total.' },
  { value: 'raid0', label: 'Stripe (RAID0)', min: 2,
    blurb: 'Combines drives for full capacity, but NO redundancy — any one drive failing loses everything.' },
  { value: 'raid10', label: 'Stripe + Mirror (RAID10)', min: 4, even: true,
    blurb: 'Mirrored and striped. Needs an even number of drives (4+). Usable space is about half the total.' },
];

const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$/;

function formatBytes(n) {
  if (n === null || n === undefined) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  let v = n, i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i += 1; }
  return v.toFixed(i === 0 || v >= 100 ? 0 : 1) + ' ' + units[i];
}

class StorageModule extends LitElement {
  static properties = {
    config: { type: Object },
    appliedConfig: { attribute: false },
    drives: { state: true },
    pools: { state: true },
    loading: { state: true },
    loadError: { state: true },
    wizardOpen: { state: true },
    wizardStep: { state: true },
    selected: { state: true },
    profile: { state: true },
    poolName: { state: true },
    mountpoint: { state: true },
    preview: { state: true },
    ackErase: { state: true },
    creating: { state: true },
    createStatus: { state: true },
    createError: { state: true },
    forgetTarget: { state: true },
    ackBoot: { state: true },
  };

  static styles = css`
    :host { display: block; }
    .module-container { width: 100%; }

    .help-box {
      background: rgba(59, 130, 246, 0.08);
      border-left: 4px solid var(--hf-accent);
      padding: 14px 18px;
      border-radius: 8px;
      margin-bottom: 20px;
      color: var(--hf-text-muted);
      font-size: 13px;
      line-height: 1.5;
    }
    .help-box strong { display: block; margin-bottom: 6px; color: var(--hf-text); font-size: 14px; }
    code {
      background: var(--hf-surface-2);
      padding: 1px 5px; border-radius: 3px;
      font-family: var(--hf-font-mono, monospace); font-size: 12px;
    }
    .mount-cmds {
      margin-top: 12px; padding: 12px; border-radius: 8px;
      background: var(--hf-surface-2); border: 1px solid var(--hf-border);
    }
    .mount-cmds-head { font-size: 12px; color: var(--hf-text-muted); margin-bottom: 8px; }
    .mount-cmd-row { display: flex; align-items: center; gap: 10px; padding: 3px 0; flex-wrap: wrap; }
    .mc-name { font-size: 13px; color: var(--hf-text); min-width: 90px; font-weight: 500; }
    .mc-target { user-select: all; }  /* click-drag selects the whole target */

    .section-head {
      display: flex; align-items: center; justify-content: space-between;
      gap: 12px; margin-bottom: 12px; flex-wrap: wrap;
    }

    .btn {
      background: var(--hf-surface-2);
      color: var(--hf-text);
      border: 1px solid var(--hf-border-2);
      border-radius: 8px; padding: 8px 14px;
      font-size: 13px; cursor: pointer; font-weight: 500;
    }
    .btn:hover { background: var(--hf-surface-3); }
    .btn:disabled { opacity: 0.5; cursor: not-allowed; }
    .btn-primary { background: var(--hf-accent); color: #04140d; border-color: transparent; }
    .btn-primary:hover { background: var(--hf-accent-hover); }
    .btn-danger { background: var(--hf-err); color: #fff; border-color: transparent; }
    .btn-ghost { background: transparent; border-color: transparent; color: var(--hf-text-muted); }

    .err-banner {
      background: var(--hf-warn-soft); border-left: 4px solid var(--hf-warn);
      padding: 10px 14px; border-radius: 8px; margin-bottom: 16px;
      color: var(--hf-text); font-size: 13px;
    }

    /* ---- pool cards ---- */
    .pools { display: flex; flex-direction: column; gap: 12px; }
    .pool-card {
      border: 1px solid var(--hf-border-2); border-radius: 10px;
      background: var(--hf-surface); padding: 14px 16px;
    }
    .pool-top { display: flex; align-items: baseline; justify-content: space-between; gap: 10px; flex-wrap: wrap; }
    .pool-name { font-size: 15px; font-weight: 600; color: var(--hf-text); }
    .pool-meta { color: var(--hf-text-muted); font-size: 12px; margin-top: 4px; }
    .pool-members { color: var(--hf-text-subtle); font-size: 12px; margin-top: 6px; word-break: break-all; }
    .usage-bar { height: 6px; border-radius: 3px; background: var(--hf-surface-3); margin-top: 10px; overflow: hidden; }
    .usage-fill { height: 100%; background: var(--hf-accent); }
    .pool-actions { display: flex; gap: 8px; align-items: center; }

    .badge {
      display: inline-block; padding: 2px 8px; border-radius: 999px;
      font-size: 11px; font-weight: 600; white-space: nowrap;
    }
    .badge-ok { background: var(--hf-accent-soft); color: var(--hf-accent); }
    .badge-warn { background: var(--hf-warn-soft); color: var(--hf-warn); }
    .badge-err { background: rgba(239,68,68,0.15); color: var(--hf-err); }

    .inline-confirm {
      margin-top: 10px; padding: 10px; border-radius: 8px;
      background: var(--hf-warn-soft); color: var(--hf-text); font-size: 12px;
    }
    .inline-confirm .row { display: flex; gap: 8px; margin-top: 8px; }

    .empty { color: var(--hf-text-subtle); font-size: 13px; padding: 8px 0; }

    /* ---- drives table ---- */
    .table-wrap { overflow-x: auto; }
    table { width: 100%; border-collapse: collapse; font-size: 13px; min-width: 560px; }
    th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--hf-border); }
    th { color: var(--hf-text-subtle); font-weight: 600; font-size: 12px; }
    td.muted { color: var(--hf-text-muted); }
    .serial { color: var(--hf-text-subtle); font-size: 11px; font-family: var(--hf-font-mono, monospace); }

    /* ---- wizard modal ---- */
    .overlay {
      position: fixed; inset: 0; background: rgba(0,0,0,0.6);
      display: flex; align-items: center; justify-content: center;
      padding: 16px; z-index: 1000;
    }
    .modal {
      background: var(--hf-surface); border: 1px solid var(--hf-border-2);
      border-radius: 12px; width: 100%; max-width: 640px;
      max-height: 90vh; overflow-y: auto; padding: 22px;
    }
    .modal h2 { margin: 0 0 4px; font-size: 18px; color: var(--hf-text); }
    .modal .sub { color: var(--hf-text-muted); font-size: 13px; margin-bottom: 16px; }

    .field { margin-bottom: 14px; }
    .field label { display: block; font-size: 13px; color: var(--hf-text); margin-bottom: 5px; font-weight: 500; }
    .field input[type="text"], .field select {
      width: 100%; box-sizing: border-box;
      background: var(--hf-surface-2); color: var(--hf-text);
      border: 1px solid var(--hf-border-2); border-radius: 8px;
      padding: 9px 11px; font-size: 13px;
    }
    .hint { color: var(--hf-text-subtle); font-size: 11px; margin-top: 4px; }

    .drive-pick { display: flex; flex-direction: column; gap: 6px; }
    .drive-opt {
      display: flex; align-items: center; gap: 10px;
      border: 1px solid var(--hf-border-2); border-radius: 8px;
      padding: 9px 11px; cursor: pointer;
    }
    .drive-opt.sel { border-color: var(--hf-accent); background: var(--hf-accent-soft); }
    .drive-opt .d-main { flex: 1; min-width: 0; }
    .drive-opt .d-sub { color: var(--hf-text-subtle); font-size: 11px; }
    .drive-opt.warn-opt { border-color: var(--hf-warn); }
    .drive-opt.warn-opt.sel { background: var(--hf-warn-soft); border-color: var(--hf-warn); }
    .select-warn {
      margin-top: 10px; padding: 10px 12px; border-radius: 8px;
      background: var(--hf-warn-soft); border-left: 3px solid var(--hf-warn);
      color: var(--hf-text); font-size: 12px; line-height: 1.5;
    }

    .preview-box {
      background: var(--hf-surface-2); border-radius: 8px; padding: 12px;
      margin: 6px 0 14px; font-size: 13px; color: var(--hf-text);
    }
    .preview-box .big { font-size: 20px; font-weight: 700; }
    .warn-line { color: var(--hf-warn); font-size: 12px; margin-top: 6px; }

    .erase-list { margin: 6px 0 0; padding: 0; list-style: none; }
    .erase-list li { padding: 8px 0; border-bottom: 1px solid var(--hf-border); font-size: 13px; }
    .ack { display: flex; align-items: flex-start; gap: 8px; margin: 14px 0; font-size: 13px; color: var(--hf-text); }

    .progress { height: 8px; border-radius: 4px; background: var(--hf-surface-3); overflow: hidden; margin: 12px 0; }
    .progress > div { height: 100%; background: var(--hf-accent); transition: width .3s; }

    .modal-actions { display: flex; justify-content: flex-end; gap: 10px; margin-top: 18px; }

    @media (max-width: 640px) {
      .modal { padding: 16px; }
      .modal-actions { flex-direction: column-reverse; }
      .modal-actions .btn { width: 100%; }
    }
  `;

  constructor() {
    super();
    this.config = {};
    this.appliedConfig = null;
    this.drives = [];
    this.pools = [];
    this.loading = true;
    this.loadError = '';
    this._resetWizard();
    this.forgetTarget = null;
    this._pollTimer = null;
  }

  connectedCallback() {
    super.connectedCallback();
    this.loadData();
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    this._stopPolling();
  }

  _resetWizard() {
    this.wizardOpen = false;
    this.wizardStep = 1;
    this.selected = [];
    this.profile = '';
    this.poolName = '';
    this.mountpoint = '';
    this._mountpointEdited = false;
    this.preview = null;
    this.ackErase = false;
    this.ackBoot = false;
    this.creating = false;
    this.createStatus = null;
    this.createError = '';
  }

  async loadData() {
    this.loading = true;
    this.loadError = '';
    try {
      const [d, p] = await Promise.all([getStorageDrives(), getStoragePools()]);
      this.drives = d.drives || [];
      this.pools = p.pools || [];
    } catch (e) {
      this.loadError = e.message || 'Failed to load storage information.';
    } finally {
      this.loading = false;
    }
  }

  get eligibleDrives() {
    return (this.drives || []).filter((d) => d.eligible);
  }

  // Soft-blocked drives (e.g. an inactive EFI partition) — hidden behind the
  // wizard's Advanced disclosure and usable only with explicit confirmation.
  get overridableDrives() {
    return (this.drives || []).filter((d) => d.overridable);
  }

  get _selectedOverridable() {
    const ov = new Set(this.overridableDrives.map((d) => d.by_id));
    return this.selected.some((id) => ov.has(id));
  }

  // Drives offered in the create wizard: usable-now plus owner-overridable.
  // Hard-blocked disks (OS, mounted, active RAID/swap) are never offered.
  get selectableDrives() {
    return [...this.eligibleDrives, ...this.overridableDrives];
  }

  // ---- wizard control ----

  _openWizard() {
    this._resetWizard();
    this.wizardOpen = true;
  }

  _closeWizard() {
    this._stopPolling();
    this._resetWizard();
  }

  _toggleDrive(byId) {
    const next = this.selected.includes(byId)
      ? this.selected.filter((x) => x !== byId)
      : [...this.selected, byId];
    this.selected = next;
    this._refreshPreview();
  }

  _onProfile(e) {
    this.profile = e.target.value;
    this._refreshPreview();
  }

  _onName(e) {
    this.poolName = e.target.value;
    if (!this._mountpointEdited) {
      const safe = this.poolName.trim();
      this.mountpoint = safe ? '/mnt/' + safe : '';
    }
  }

  _onMountpoint(e) {
    this._mountpointEdited = true;
    this.mountpoint = e.target.value;
  }

  async _refreshPreview() {
    const prof = PROFILES.find((p) => p.value === this.profile);
    if (!prof || this.selected.length < prof.min) { this.preview = null; return; }
    try {
      this.preview = await previewStoragePool(this.selected, this.profile);
    } catch (e) {
      this.preview = null;
    }
  }

  get _validSelection() {
    const prof = PROFILES.find((p) => p.value === this.profile);
    if (!prof) return false;
    if (prof.exact && this.selected.length !== prof.exact) return false;
    if (this.selected.length < prof.min) return false;
    if (prof.even && this.selected.length % 2 !== 0) return false;
    return true;
  }

  get _canConfigure() {
    return NAME_RE.test(this.poolName.trim())
      && this.mountpoint.trim().startsWith('/')
      && this._validSelection;
  }

  // ---- create ----

  async _doCreate() {
    this.creating = true;
    this.wizardStep = 3;
    this.createError = '';
    this.createStatus = { step: 'starting', progress: 0, message: 'Starting…' };
    const payload = {
      name: this.poolName.trim(),
      mountpoint: this.mountpoint.trim(),
      profile: this.profile,
      members: this.selected,
      encrypted: false,
      force: this._selectedOverridable,
    };
    try {
      await createStoragePool(payload);
      this._pollStatus();
    } catch (e) {
      this.creating = false;
      this.createError = e.message || 'Failed to start volume creation.';
    }
  }

  _pollStatus() {
    this._stopPolling();
    const tick = async () => {
      try {
        const s = await getStoragePoolCreateStatus();
        this.createStatus = s;
        if (s.error) {
          this.creating = false;
          this.createError = s.error;
          return;
        }
        if (s.completed) {
          this.creating = false;
          await this._onCreated();
          return;
        }
      } catch (e) {
        // transient — keep polling
      }
      this._pollTimer = setTimeout(tick, 1000);
    };
    this._pollTimer = setTimeout(tick, 800);
  }

  _stopPolling() {
    if (this._pollTimer) { clearTimeout(this._pollTimer); this._pollTimer = null; }
  }

  // After a successful create/forget: reload live data and push the new pool
  // list into the config flow so it shows as a pending change and Apply mounts
  // it. We emit the records WITHOUT the runtime field (config carries identity
  // only).
  async _onCreated() {
    await this.loadData();
    this._emitPools();
  }

  _emitPools() {
    // Emit only the storage delta (not the whole merged config): admin-app's
    // handleConfigChange spreads detail.config into pendingConfig, and we don't
    // want to mark unrelated sections dirty. getMergedConfig reads
    // pendingConfig.storage. Records carry identity only — strip runtime.
    const records = (this.pools || []).map((p) => {
      const { runtime, ...rec } = p;
      return rec;
    });
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { config: { storage: { ...(this.config?.storage || {}), pools: records } }, module: 'storage' },
      bubbles: true,
      composed: true,
    }));
  }

  // NFS shares are plain config rows (no imperative action) — edited via a
  // table-editor like Mounts. We emit the full storage object (spreading the
  // current pools) so a shares edit never drops the volumes list.
  _handleSharesChange(e) {
    // The table-editor keys its per-row diff on `name` (rowKey="name", see
    // _renderShares). Strip any leftover synthetic `id` on the way out: an
    // earlier attempt to add a stable `id` regressed — pre-existing shares had
    // no id in the deployed applied-config, so stamping one made them show as
    // BOTH changed and removed whenever the list changed (e.g. adding a
    // sibling). Renaming a share still reads as remove+add in the diff (minor,
    // and consistent with the other config tables); adding/editing is clean.
    const rows = (e.detail.data || []).map(({ id, ...r }) => r);
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { config: { storage: { ...(this.config?.storage || {}), shares: rows } }, module: 'storage' },
      bubbles: true,
      composed: true,
    }));
  }

  _renderShares() {
    const shares = this.config?.storage?.shares || [];
    const applied = this.appliedConfig?.storage?.shares || [];
    // Exact NFS mount target per share, so clients use the full export PATH
    // (e.g. 10.0.0.1:/mnt/ellis) instead of the share name (/ellis).
    const lan = this.config?.network?.['lan-address'] || '<server-ip>';
    const mountable = shares.filter((s) => s.enabled !== false && s.path);
    const columns = [
      { key: 'enabled', label: 'Enabled', type: 'boolean', default: true },
      { key: 'name', label: 'Name', type: 'text', placeholder: 'media' },
      { key: 'path', label: 'Path', type: 'text', placeholder: '/mnt/tank/media' },
      { key: 'allowed', label: 'Allowed clients', type: 'text', placeholder: '10.0.0.0/24' },
      { key: 'read-only', label: 'Read-only', type: 'boolean', default: false },
    ];
    return html`
      <config-section title="NFS Shares" description="Export a volume (or a folder within one) over NFS to your LAN">
        <table-editor
          .columns=${columns}
          .data=${shares}
          .appliedData=${applied}
          .rowKey=${'name'}
          addLabel="Add NFS share"
          .neutralBooleans=${true}
          @data-change=${this._handleSharesChange}
        ></table-editor>
        <div class="hint" style="margin-top:8px">
          NFS uses host/subnet trust (no per-user login). Leave "Allowed clients"
          blank to default to your LAN subnet. SMB and per-user access are a later phase.
        </div>
        ${mountable.length ? html`
          <div class="mount-cmds">
            <div class="mount-cmds-head">Mount from a LAN client — use the full export path, not the share name:</div>
            ${mountable.map((s) => html`
              <div class="mount-cmd-row">
                <span class="mc-name">${s.name}</span>
                <code class="mc-target">${lan}:${s.path}</code>
              </div>`)}
            <div class="hint" style="margin-top:8px">
              e.g. <code class="mc-target">sudo mount -t nfs ${lan}:${mountable[0].path} /mnt/${mountable[0].name}</code>
            </div>
          </div>` : ''}
      </config-section>
    `;
  }

  // ---- forget ----

  async _confirmForget(name) {
    try {
      await forgetStoragePool(name);
      this.forgetTarget = null;
      await this.loadData();
      this._emitPools();
    } catch (e) {
      this.loadError = e.message || 'Failed to forget volume.';
    }
  }

  // ---- render ----

  render() {
    return html`
      <div class="module-container">
        <div class="help-box">
          <strong>Storage volumes</strong>
          Combine unused drives into a local <code>btrfs</code> data volume for
          media, files, or backups. Creating a volume <strong>erases</strong> the
          selected drives. The OS drive and any in-use drive can never be
          selected. After creating a volume, click <strong>Apply</strong> to mount
          it. Parity (RAID5/6) is not offered yet — choose a mirror for
          redundancy.
        </div>

        ${this.loadError ? html`<div class="err-banner">${this.loadError}</div>` : ''}

        ${this._renderPools()}
        ${this._renderShares()}
        ${this._renderDrives()}
        ${this.wizardOpen ? this._renderWizard() : ''}
      </div>
    `;
  }

  _renderPools() {
    const pools = this.pools || [];
    return html`
      <config-section title="Volumes" description="Local btrfs data volumes on this machine">
        <div class="section-head">
          <span class="empty">${pools.length === 0 ? 'No volumes yet.' : ''}</span>
          <button class="btn btn-primary"
                  ?disabled=${this.eligibleDrives.length === 0 && this.overridableDrives.length === 0}
                  @click=${this._openWizard}>+ Create volume</button>
        </div>
        ${pools.length === 0 ? '' : html`
          <div class="pools">
            ${pools.map((p) => this._renderPoolCard(p))}
          </div>`}
        ${this.eligibleDrives.length === 0 && this.overridableDrives.length === 0 && !this.loading ? html`
          <div class="hint">No eligible drives available to create a new volume.</div>` : ''}
      </config-section>
    `;
  }

  _renderPoolCard(p) {
    const rt = p.runtime || {};
    let badge;
    if (!rt.present) badge = html`<span class="badge badge-err">Drive(s) not present</span>`;
    else if (rt.mounted) badge = html`<span class="badge badge-ok">Mounted</span>`;
    else badge = html`<span class="badge badge-warn">Apply to mount</span>`;

    const pct = (rt.total_bytes && rt.used_bytes != null)
      ? Math.min(100, Math.round((rt.used_bytes / rt.total_bytes) * 100)) : null;

    return html`
      <div class="pool-card">
        <div class="pool-top">
          <div>
            <span class="pool-name">${p.name}</span>
            <div class="pool-meta">
              ${p.profile} · ${(p.members || []).length} drive(s) ·
              mount <code>${p.mountpoint}</code>
            </div>
          </div>
          <div class="pool-actions">
            ${badge}
            <button class="btn btn-ghost" @click=${() => { this.forgetTarget = p.name; }}>Forget</button>
          </div>
        </div>

        ${pct !== null ? html`
          <div class="usage-bar"><div class="usage-fill" style="width:${pct}%"></div></div>
          <div class="pool-meta">${formatBytes(rt.used_bytes)} of ${formatBytes(rt.total_bytes)} used</div>
        ` : ''}

        <div class="pool-members">${(p.members || []).join(', ')}</div>

        ${this.forgetTarget === p.name ? html`
          <div class="inline-confirm">
            Forget volume <strong>${p.name}</strong>? The btrfs filesystem and its
            data stay on the disks — only the mount is removed. Apply afterwards
            to unmount.
            <div class="row">
              <button class="btn btn-ghost" @click=${() => { this.forgetTarget = null; }}>Cancel</button>
              <button class="btn btn-danger" @click=${() => this._confirmForget(p.name)}>Forget</button>
            </div>
          </div>` : ''}
      </div>
    `;
  }

  _renderDrives() {
    const drives = this.drives || [];
    return html`
      <config-section title="Drives" description="Every non-removable drive detected on this machine">
        <div class="section-head">
          <span class="empty">${this.loading ? 'Loading…' : (drives.length === 0 ? 'No drives detected.' : '')}</span>
          <button class="btn" @click=${this.loadData}>Refresh</button>
        </div>
        ${drives.length === 0 ? '' : html`
          <div class="table-wrap">
            <table>
              <thead>
                <tr><th>Drive</th><th>Size</th><th>Type</th><th>Temp</th><th>Health</th><th>Status</th></tr>
              </thead>
              <tbody>
                ${drives.map((d) => this._renderDriveRow(d))}
              </tbody>
            </table>
          </div>`}
      </config-section>
    `;
  }

  _renderDriveRow(d) {
    const cls = (d.drive_class || '').toUpperCase();
    const tran = d.transport ? d.transport.toUpperCase() : '';
    let status;
    if (d.eligible) {
      status = d.has_existing_data
        ? html`<span class="badge badge-warn">Available · has data (${d.existing_fstype || '?'})</span>`
        : html`<span class="badge badge-ok">Available</span>`;
    } else {
      status = html`<span class="badge badge-err">${d.ineligible_reason || 'In use'}</span>`;
    }
    const temp = (d.temp_c !== null && d.temp_c !== undefined) ? d.temp_c + '°C' : '—';
    let health = '—';
    if (d.smart_available) {
      health = d.smart_passed === false ? html`<span class="badge badge-err">FAIL</span>` : 'OK';
    }
    return html`
      <tr>
        <td>
          <div>${d.model || 'Unknown'}</div>
          <div class="serial">${d.by_id || d.name}</div>
        </td>
        <td class="muted">${formatBytes(d.size_bytes)}</td>
        <td class="muted">${cls}${tran ? ' · ' + tran : ''}</td>
        <td class="muted">${temp}</td>
        <td class="muted">${health}</td>
        <td>${status}</td>
      </tr>
    `;
  }

  _renderWizard() {
    return html`
      <div class="overlay" @click=${(e) => { if (e.target === e.currentTarget && !this.creating) this._closeWizard(); }}>
        <div class="modal">
          ${this.wizardStep === 1 ? this._renderStepConfigure()
            : this.wizardStep === 2 ? this._renderStepConfirm()
            : this._renderStepProgress()}
        </div>
      </div>
    `;
  }

  _renderStepConfigure() {
    const prof = PROFILES.find((p) => p.value === this.profile);
    return html`
      <h2>Create a storage volume</h2>
      <div class="sub">Select drives, choose a layout, and name the volume.</div>

      <div class="field">
        <label>Drives <span class="hint">(${this.selected.length} selected)</span></label>
        <div class="drive-pick">
          ${this.selectableDrives.map((d) => {
            const warn = d.overridable;
            const sub = warn
              ? d.by_id + ' · ' + d.ineligible_reason
              : d.by_id + (d.has_existing_data ? ' · contains data (' + (d.existing_fstype || '?') + ')' : '');
            return html`
              <label class="drive-opt ${warn ? 'warn-opt' : ''} ${this.selected.includes(d.by_id) ? 'sel' : ''}">
                <input type="checkbox"
                       .checked=${this.selected.includes(d.by_id)}
                       @change=${() => this._toggleDrive(d.by_id)} />
                <span class="d-main">
                  <div>${warn ? '⚠ ' : ''}${d.model || 'Unknown'} — ${formatBytes(d.size_bytes)}</div>
                  <div class="d-sub">${sub}</div>
                </span>
              </label>`;
          })}
        </div>
        ${this._selectedOverridable ? html`
          <div class="select-warn">
            ⚠ You've selected a disk that may be a boot disk. It will be
            <strong>completely erased</strong>. Only continue if it isn't in use
            by another system — you'll confirm this before the volume is created.
          </div>` : ''}
      </div>

      <div class="field">
        <label>Layout</label>
        <select @change=${this._onProfile} .value=${this.profile}>
          <option value="" ?selected=${this.profile === ''}>Choose a layout…</option>
          ${PROFILES.map((p) => html`<option value=${p.value} ?selected=${this.profile === p.value}>${p.label}</option>`)}
        </select>
        ${prof ? html`<div class="hint">${prof.blurb}</div>` : ''}
      </div>

      ${this.preview ? html`
        <div class="preview-box">
          <div class="big">${formatBytes(this.preview.usable_bytes)} usable</div>
          <div class="hint">${formatBytes(this.preview.raw_bytes)} raw across ${this.preview.member_count} drive(s)</div>
          ${(this.preview.warnings || []).map((w) => html`<div class="warn-line">${w}</div>`)}
        </div>` : ''}

      <div class="field">
        <label>Volume name</label>
        <input type="text" placeholder="tank" .value=${this.poolName} @input=${this._onName} />
        <div class="hint">Letters, digits, '-' or '_'. Also used as the btrfs label.</div>
      </div>

      <div class="field">
        <label>Mount point</label>
        <input type="text" placeholder="/mnt/tank" .value=${this.mountpoint} @input=${this._onMountpoint} />
      </div>

      <div class="modal-actions">
        <button class="btn btn-ghost" @click=${this._closeWizard}>Cancel</button>
        <button class="btn btn-primary" ?disabled=${!this._canConfigure}
                @click=${() => { this.ackErase = false; this.wizardStep = 2; }}>Review</button>
      </div>
    `;
  }

  _renderStepConfirm() {
    const chosen = (this.drives || []).filter((d) => this.selected.includes(d.by_id));
    const overridden = chosen.filter((d) => d.overridable);
    return html`
      <h2>Confirm — this erases the selected drives</h2>
      <div class="sub">
        Volume <strong>${this.poolName.trim()}</strong> (${this.profile}), mounted at
        <code>${this.mountpoint.trim()}</code>. All data on these drives will be
        permanently destroyed:
      </div>
      <ul class="erase-list">
        ${chosen.map((d) => html`
          <li>
            <strong>${d.model || 'Unknown'}</strong> — ${formatBytes(d.size_bytes)}
            <div class="serial">${d.by_id}</div>
            ${d.has_existing_data ? html`<div class="warn-line">Currently contains a ${d.existing_fstype || 'filesystem'}${d.existing_label ? " labelled '" + d.existing_label + "'" : ''}.</div>` : ''}
          </li>`)}
      </ul>

      <label class="ack">
        <input type="checkbox" .checked=${this.ackErase} @change=${(e) => { this.ackErase = e.target.checked; }} />
        <span>I understand these ${chosen.length} drive(s) will be erased and their data lost.</span>
      </label>

      ${overridden.length > 0 ? html`
        <label class="ack">
          <input type="checkbox" .checked=${this.ackBoot} @change=${(e) => { this.ackBoot = e.target.checked; }} />
          <span>I confirm ${overridden.map((d) => d.name).join(', ')}
            ${overridden.length > 1 ? 'are' : 'is'} NOT a boot disk for any system I need.</span>
        </label>` : ''}

      <div class="modal-actions">
        <button class="btn btn-ghost" @click=${() => { this.wizardStep = 1; }}>Back</button>
        <button class="btn btn-danger"
                ?disabled=${!this.ackErase || (overridden.length > 0 && !this.ackBoot)}
                @click=${this._doCreate}>Create volume</button>
      </div>
    `;
  }

  _renderStepProgress() {
    const s = this.createStatus || {};
    const pct = Math.round(s.progress || 0);
    if (this.createError) {
      return html`
        <h2>Volume creation failed</h2>
        <div class="err-banner">${this.createError}</div>
        <div class="modal-actions">
          <button class="btn btn-ghost" @click=${() => { this.wizardStep = 1; this.createError = ''; }}>Back</button>
          <button class="btn" @click=${this._closeWizard}>Close</button>
        </div>
      `;
    }
    if (s.completed) {
      return html`
        <h2>Volume created</h2>
        <div class="sub">${s.message || 'Done.'}</div>
        <div class="preview-box">Click <strong>Apply</strong> in the sidebar to mount the volume.</div>
        <div class="modal-actions">
          <button class="btn btn-primary" @click=${this._closeWizard}>Done</button>
        </div>
      `;
    }
    return html`
      <h2>Creating volume…</h2>
      <div class="sub">${s.message || 'Working…'}</div>
      <div class="progress"><div style="width:${pct}%"></div></div>
      <div class="hint">${pct}% — ${s.step || ''}</div>
      <div class="hint">Formatting can take a while on large drives. Keep this tab open.</div>
    `;
  }
}

customElements.define('storage-module', StorageModule);
