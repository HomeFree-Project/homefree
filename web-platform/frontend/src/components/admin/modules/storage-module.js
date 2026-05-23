import { LitElement, html, css } from 'lit';
import '../../shared/config-section.js';
import '../../shared/table-editor.js';
import { confirmDialog } from '../../shared/confirm-dialog.js';
import {
  getStorageDrives,
  getStoragePools,
  previewStoragePool,
  createStoragePool,
  getStoragePoolCreateStatus,
  forgetStoragePool,
  reclaimStorageDisks,
  getStorageReclaimStatus,
  getStorageImportable,
  importStoragePool,
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
  { value: 'raid5', label: 'Single parity (RAID5)', min: 3,
    blurb: 'Survives one drive failing while keeping most capacity (total minus one drive). Built on Linux md with btrfs on top; the array syncs in the background after creation.' },
  { value: 'raid6', label: 'Double parity (RAID6)', min: 4,
    blurb: 'Survives ANY TWO drives failing. Usable space is total minus two drives — the best balance of capacity and safety for four or more large drives. Built on Linux md with btrfs on top; the array syncs in the background after creation.' },
];

const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$/;

// homefree.mounts entries are split across two Storage sections by direction:
// network (this box mounts a remote share IN — below NFS Shares) vs local disk
// (mount an existing local device — below Volumes). Default fs-type is nfs.
const NETWORK_FS = ['nfs', 'cifs', 'smb', 'smbfs'];

// Both destructive flows (create a volume, reclaim drives) wipe whole drives,
// so each confirm requires the user to type this exact phrase — a deliberate
// gate beyond a checkbox. Same phrase for both, matched trimmed + case-insensitively.
const ERASE_CONFIRM_PHRASE = 'I understand all data will be lost by this operation';

function formatBytes(n) {
  if (n === null || n === undefined) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  let v = n, i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i += 1; }
  return v.toFixed(i === 0 || v >= 100 ? 0 : 1) + ' ' + units[i];
}

// Order-independent value key (mirrors table-editor._stableKey) so a record
// compares equal regardless of JSON key order.
function stableKey(v) {
  return JSON.stringify(v, (k, val) =>
    (val && typeof val === 'object' && !Array.isArray(val))
      ? Object.keys(val).sort().reduce((o, kk) => { o[kk] = val[kk]; return o; }, {})
      : val);
}

class StorageModule extends LitElement {
  static properties = {
    config: { type: Object },
    appliedConfig: { attribute: false },
    drives: { state: true },
    pools: { state: true },
    importable: { state: true },
    importTarget: { state: true },
    importName: { state: true },
    importMountpoint: { state: true },
    importError: { state: true },
    loading: { state: true },
    loadError: { state: true },
    wizardOpen: { state: true },
    wizardStep: { state: true },
    selected: { state: true },
    profile: { state: true },
    poolName: { state: true },
    mountpoint: { state: true },
    preview: { state: true },
    createConfirmText: { state: true },
    creating: { state: true },
    createStatus: { state: true },
    createError: { state: true },
    ackBoot: { state: true },
    reclaimTarget: { state: true },
    reclaimConfirmText: { state: true },
    reclaiming: { state: true },
    reclaimStatus: { state: true },
    reclaimError: { state: true },
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
    .help-box strong { color: var(--hf-text); }
    .help-box > strong:first-child { display: block; margin-bottom: 6px; font-size: 14px; }
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

    /* Buttons — identical to shared/table-editor.js + shared/confirm-dialog.js
       so this page matches the rest of the site (AGENTS.md UI consistency). */
    .btn {
      padding: 9px 16px; border-radius: 6px;
      border: 1px solid var(--hf-border-2);
      background: var(--hf-surface-2); color: var(--hf-text);
      font-size: 13px; font-weight: 500; font-family: inherit;
      cursor: pointer; transition: all 0.15s;
    }
    .btn:hover { background: var(--hf-surface-3); border-color: var(--hf-text-subtle); }
    .btn:disabled { opacity: 0.5; cursor: not-allowed; }
    .btn-primary { background: var(--hf-accent); color: #06281c; border-color: var(--hf-accent); }
    .btn-primary:hover { background: var(--hf-accent-hover); border-color: var(--hf-accent-hover); }
    .btn-danger {
      background: var(--hf-surface-2); color: var(--hf-err);
      border-color: color-mix(in srgb, var(--hf-err) 45%, transparent);
    }
    .btn-danger:hover {
      background: color-mix(in srgb, var(--hf-err) 14%, transparent);
      border-color: var(--hf-err);
    }
    /* Compact per-row/card action button — identical to table-editor's .btn-row. */
    .btn-row {
      background: var(--hf-surface-2); border: 1px solid var(--hf-border-2);
      color: var(--hf-text); cursor: pointer;
      padding: 5px 12px; border-radius: 6px;
      font-size: 12px; font-weight: 500; font-family: inherit;
      transition: all 0.15s;
    }
    .btn-row:hover { background: var(--hf-surface-3); border-color: var(--hf-text-subtle); }
    .btn-row:disabled { opacity: 0.5; cursor: not-allowed; }
    .btn-row.delete { color: var(--hf-err); border-color: color-mix(in srgb, var(--hf-err) 45%, transparent); }
    .btn-row.delete:hover { background: color-mix(in srgb, var(--hf-err) 14%, transparent); border-color: var(--hf-err); }
    /* A teardownable array/group, drawn as a rounded, light-bordered box around
       its header row + member rows (needs border-collapse: separate on the
       table). The header is the box top; member rows form the sides; the last
       member closes the bottom. */
    tr.set-box-top > td {
      background: var(--hf-surface-3);
      border: 1px solid var(--hf-border-2);
      border-bottom: none;
      border-radius: 10px 10px 0 0;
      padding: 10px 12px;
    }
    tr.set-box > td { background: var(--hf-surface-2); }
    tr.set-box > td:first-child { border-left: 1px solid var(--hf-border-2); }
    tr.set-box > td:last-child { border-right: 1px solid var(--hf-border-2); }
    tr.set-box-last > td { border-bottom: 1px solid var(--hf-border-2); }
    tr.set-box-last > td:first-child { border-bottom-left-radius: 10px; }
    tr.set-box-last > td:last-child { border-bottom-right-radius: 10px; }
    .set-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
    .set-head-info strong { font-size: 13px; color: var(--hf-text); }
    .set-head-sub { color: var(--hf-text-muted); font-size: 12px; margin-top: 2px; word-break: break-all; }
    /* Refresh lives in the drives table header. */
    .th-action { display: flex; align-items: center; justify-content: space-between; gap: 10px; }
    .reclaim-hint {
      margin-top: 6px; font-size: 11px; color: var(--hf-warn); line-height: 1.45;
      max-width: 360px; white-space: normal;
    }
    .reclaim-hint .blockers { color: var(--hf-text-subtle); margin-top: 3px; }
    .reclaim-hint .blk {
      display: block; font-family: var(--hf-font-mono, monospace);
    }

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
    /* Undeployed (created/changed, not yet applied) — match table-editor's
       row-undeployed: amber tint + inset left bar. */
    .pool-card.undeployed {
      background: var(--hf-warn-soft);
      box-shadow: inset 3px 0 0 0 var(--hf-warn);
    }
    .pool-card.removed .pool-name { text-decoration: line-through; }
    .pool-card.removed { opacity: 0.85; }
    .pool-top { display: flex; align-items: baseline; justify-content: space-between; gap: 10px; flex-wrap: wrap; }
    .pool-name { font-size: 15px; font-weight: 600; color: var(--hf-text); }
    .pool-meta { color: var(--hf-text-muted); font-size: 12px; margin-top: 4px; }
    .pool-members { color: var(--hf-text-subtle); font-size: 12px; margin-top: 6px; word-break: break-all; }
    .pending-note { color: var(--hf-warn); font-size: 12px; margin-top: 8px; font-weight: 500; }
    .snap-row {
      display: flex; align-items: center; gap: 8px;
      margin-top: 10px; font-size: 13px; color: var(--hf-text);
    }
    .snap-row input { cursor: pointer; }
    .snap-row .hint { margin: 0; }
    /* Pending (undeployed) — same amber treatment as .pool-card.undeployed /
       table-editor row-undeployed. Only the OS-root toggle gets this class. */
    .snap-row.undeployed {
      background: var(--hf-warn-soft);
      box-shadow: inset 3px 0 0 0 var(--hf-warn);
      border-radius: 6px;
      padding: 8px 10px;
    }
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
    .badge-muted { background: var(--hf-surface-3); color: var(--hf-text-muted); }

    .inline-confirm {
      margin-top: 10px; padding: 10px; border-radius: 8px;
      background: var(--hf-warn-soft); color: var(--hf-text); font-size: 12px;
    }
    .inline-confirm .row { display: flex; gap: 8px; margin-top: 8px; }

    .empty { color: var(--hf-text-subtle); font-size: 13px; padding: 8px 0; }

    /* ---- drives table ---- */
    .table-wrap { overflow-x: auto; }
    table { width: 100%; border-collapse: separate; border-spacing: 0; font-size: 13px; min-width: 560px; }
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

    /* Layout picker — replaces the wizard's plain <select>. Filtered by what
       the current drive count can use, so the visible options change as drives
       are selected. */
    .profile-list { display: flex; flex-direction: column; gap: 6px; }
    .profile-card {
      padding: 10px 12px;
      border: 1px solid var(--hf-border-2);
      border-radius: 8px;
      background: var(--hf-surface-2);
      cursor: pointer;
      transition: all 0.15s;
    }
    .profile-card:hover {
      background: var(--hf-surface-3);
      border-color: var(--hf-text-subtle);
    }
    .profile-card.selected {
      border-color: var(--hf-accent);
      background: var(--hf-accent-soft);
    }
    .profile-card:focus-visible { outline: 2px solid var(--hf-accent); outline-offset: 2px; }
    .profile-label { font-weight: 600; color: var(--hf-text); font-size: 13px; }
    .profile-blurb { color: var(--hf-text-muted); font-size: 12px; margin-top: 3px; line-height: 1.4; }
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

    /* Skeleton placeholders on first load — shimmer copied from the other
       admin modules (dashboard/backups) so all skeletons look identical. */
    .skeleton {
      display: inline-block; border-radius: 4px; vertical-align: middle;
      background: linear-gradient(90deg,
        var(--hf-surface-3) 25%, var(--hf-border-2) 37%, var(--hf-surface-3) 63%);
      background-size: 400% 100%;
      animation: shimmer 1.4s ease infinite;
    }
    .skeleton-title { width: 140px; height: 15px; }
    .skeleton-sub   { width: 210px; height: 11px; margin-top: 8px; }
    .skeleton-badge { width: 92px;  height: 20px; border-radius: 999px; }
    .skeleton-cell  { width: 70px;  height: 13px; }
    @keyframes shimmer {
      from { background-position: 100% 0; }
      to   { background-position: 0 0; }
    }

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
    // null = not loaded yet (show skeletons); [] = loaded and genuinely empty.
    this.drives = null;
    this.pools = null;
    this.importable = [];
    this.importTarget = null;
    this.importName = '';
    this.importMountpoint = '';
    this.importError = '';
    this.loading = true;
    this.loadError = '';
    this._resetWizard();
    this.reclaimTarget = null;
    this.reclaimConfirmText = '';
    this.reclaiming = false;
    this.reclaimStatus = null;
    this.reclaimError = '';
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

  updated(changed) {
    // Live drive/pool data reflects the running SYSTEM (mounts, assembled
    // arrays), not config, so it goes stale after an Apply changes things —
    // e.g. forgetting a volume + Apply unmounts it, but the "unmount to
    // reclaim" hint lingered until a manual page reload. admin-app refreshes
    // appliedConfig only on load and when a rebuild completes, so a change to
    // it (after the initial set) is our signal that an Apply finished — reload
    // the live data then. (config changes on every keystroke; appliedConfig
    // does not, so this won't over-fetch.)
    if (changed.has('appliedConfig') && changed.get('appliedConfig') && !this.loading) {
      this.loadData();
    }
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
    this.createConfirmText = '';
    this.ackBoot = false;
    this.creating = false;
    this.createStatus = null;
    this.createError = '';
  }

  async loadData() {
    this.loading = true;
    this.loadError = '';
    try {
      const [d, p, imp] = await Promise.all([
        getStorageDrives(), getStoragePools(), getStorageImportable()]);
      this.drives = d.drives || [];
      this.pools = p.pools || [];
      this.importable = imp.importable || [];
    } catch (e) {
      this.loadError = e.message || 'Failed to load storage information.';
      // Surface the error state, not perpetual skeletons.
      if (this.drives === null) this.drives = [];
      if (this.pools === null) this.pools = [];
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
    this._ensureProfileStillValid();
    this._refreshPreview();
  }

  _setProfile(value) {
    this.profile = value;
    this._refreshPreview();
  }

  // If the current selection no longer satisfies `this.profile`'s constraints
  // (e.g. user deselected a drive so raid6 is no longer possible), clear it —
  // otherwise the filtered card list would render with nothing visibly chosen
  // while internal state still pointed at an impossible layout.
  _ensureProfileStillValid() {
    if (!this.profile) return;
    const p = PROFILES.find((x) => x.value === this.profile);
    const n = this.selected.length;
    if (!p
      || n < p.min
      || (p.exact && n !== p.exact)
      || (p.even && n % 2 !== 0)) {
      this.profile = '';
    }
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

  // Config pool records derived from the live API list: runtime stripped
  // (config carries identity only), with the editable `snapshots` flag overlaid
  // from the current config so a pending per-volume toggle survives a reload /
  // create / forget. A freshly-created volume isn't in config yet, so it falls
  // back to the API value (absent → snapshots off, the default).
  _poolRecords() {
    const cfgPools = this.config?.storage?.pools || [];
    return (this.pools || []).map((p) => {
      const { runtime, ...rec } = p;
      const cfgRec = cfgPools.find((c) => c.name === p.name);
      rec.snapshots = (cfgRec && cfgRec.snapshots !== undefined)
        ? !!cfgRec.snapshots
        : !!rec.snapshots;
      // Overlay the editable `enabled` (mount/unmount) flag from config too, so
      // a pending toggle survives a re-emit.
      if (cfgRec && cfgRec.enabled !== undefined) rec.enabled = cfgRec.enabled;
      return rec;
    });
  }

  _emitPools(records) {
    // Emit only the storage delta (not the whole merged config): admin-app's
    // handleConfigChange spreads detail.config into pendingConfig, and we don't
    // want to mark unrelated sections dirty. getMergedConfig reads
    // pendingConfig.storage.
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { config: { storage: { ...(this.config?.storage || {}), pools: records || this._poolRecords() } }, module: 'storage' },
      bubbles: true,
      composed: true,
    }));
  }

  // Per-volume snapshot opt-in. State reads from config (pending edits win),
  // falling back to the live API record. Toggling rebuilds the full pool list
  // (so sibling volumes + their flags are preserved) and emits it.
  _poolSnapshotsEnabled(name) {
    const cfgRec = (this.config?.storage?.pools || []).find((p) => p.name === name);
    if (cfgRec && cfgRec.snapshots !== undefined) return !!cfgRec.snapshots;
    const live = (this.pools || []).find((p) => p.name === name);
    return !!(live && live.snapshots);
  }

  _togglePoolSnapshots(name, enabled) {
    const records = this._poolRecords().map((r) =>
      r.name === name ? { ...r, snapshots: enabled } : r);
    this._emitPools(records);
  }

  // Mount/Unmount is a CONFIG op: it toggles the volume's `enabled` flag, which
  // takes effect on the next Apply (and is reversible by toggling back). State
  // reads from config (pending wins), falling back to the live record.
  _poolEnabled(name) {
    const cfgRec = (this.config?.storage?.pools || []).find((p) => p.name === name);
    if (cfgRec && cfgRec.enabled !== undefined) return cfgRec.enabled !== false;
    const live = (this.pools || []).find((p) => p.name === name);
    return !(live && live.enabled === false);
  }

  _togglePoolEnabled(name, enabled) {
    const records = this._poolRecords().map((r) =>
      r.name === name ? { ...r, enabled } : r);
    this._emitPools(records);
  }

  // A volume card is "undeployed" (amber) when its current config record isn't
  // present by-value in the deployed appliedConfig — i.e. newly created or
  // changed (e.g. snapshots toggled) since the last Apply. Mirrors
  // table-editor's _rowUndeployed so volumes flag the same way the NFS shares
  // table and the rest of the app do. No deployed baseline → never flag.
  // What the next Apply will actually do to this volume, in plain words —
  // shown on the line alongside the (real-state) badge + amber highlight, so
  // the badge stays truthful while the pending intent is still visible. Null
  // when nothing is pending for it.
  _poolPendingLabel(p) {
    if (!this._poolUndeployed(p.name)) return null;
    const applied = (this.appliedConfig?.storage?.pools || []).find((a) => a.name === p.name);
    const enabled = this._poolEnabled(p.name);
    if (!applied) return enabled ? 'New — will mount on Apply' : 'New — added on Apply';
    const appliedEnabled = applied.enabled !== false;
    if (enabled && !appliedEnabled) return 'Will mount on Apply';
    if (!enabled && appliedEnabled) return 'Will unmount on Apply';
    return 'Changes will take effect on Apply';
  }

  _poolUndeployed(name) {
    if (!this.appliedConfig || !Object.keys(this.appliedConfig).length) return false;
    const applied = this.appliedConfig?.storage?.pools || [];
    const current = (this.config?.storage?.pools || []).find((p) => p.name === name);
    if (!current) return false;
    const key = stableKey(current);
    return !applied.some((a) => stableKey(a) === key);
  }

  // Volumes that were deployed but have been Removed and not yet applied — they
  // vanish from the live pool list, so we render a "ghost" card from the
  // appliedConfig to show the pending removal (it's a config change, hence
  // amber + Apply), instead of the change being invisible bar the nav dot.
  _removedPools() {
    if (!this.appliedConfig || !Object.keys(this.appliedConfig).length) return [];
    const applied = this.appliedConfig?.storage?.pools || [];
    const currentNames = new Set((this.config?.storage?.pools || []).map((p) => p.name));
    return applied.filter((a) => a.name && !currentNames.has(a.name));
  }

  _renderRemovedCard(a) {
    return html`
      <div class="pool-card undeployed removed">
        <div class="pool-top">
          <div>
            <span class="pool-name">${a.name}</span>
            <div class="pool-meta">${a.profile} · mount <code>${a.mountpoint}</code></div>
          </div>
          <span class="badge badge-warn">Removing</span>
        </div>
        <div class="pending-note">⟳ Will be removed (unmounted) on Apply — data stays on the disks</div>
      </div>
    `;
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

  // OS-root snapshot opt-in (homefree.snapshots.system.enable, a TOP-LEVEL
  // config key — not under storage). admin-app.getMergedConfig + pathOwnerModuleId
  // map `snapshots.*` to this module. Emit the whole snapshots object (spreading
  // current) so retention and other keys are never dropped.
  _emitSnapshots(enable) {
    const cur = this.config?.snapshots || {};
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: {
        config: { snapshots: { ...cur, system: { ...(cur.system || {}), enable } } },
        module: 'storage',
      },
      bubbles: true,
      composed: true,
    }));
  }

  // True when the OS-root snapshot toggle differs from the deployed config —
  // mirrors _poolUndeployed so this control flags amber like the rest of the UI.
  _snapshotsSystemUndeployed() {
    if (!this.appliedConfig || !Object.keys(this.appliedConfig).length) return false;
    return !!this.config?.snapshots?.system?.enable
      !== !!this.appliedConfig?.snapshots?.system?.enable;
  }

  _renderSnapshots() {
    const on = !!this.config?.snapshots?.system?.enable;
    return html`
      <config-section title="Snapshots" description="Scheduled local btrfs snapshots for recovering lost files">
        <label class="snap-row ${this._snapshotsSystemUndeployed() ? 'undeployed' : ''}">
          <input type="checkbox" .checked=${on}
                 @change=${(e) => this._emitSnapshots(e.target.checked)} />
          <span>Snapshot the system drive (<code>/</code> and <code>/home</code>)</span>
        </label>
        <div class="hint" style="margin-top:8px">
          Snapshots are fast point-in-time copies for recovering deleted or
          overwritten files — kept on a timeline (roughly a day of hourly, a week
          of daily, a month of weekly, and six months of monthly). They live on
          the same drive, so they are <strong>not a backup</strong> (use Backups
          for off-box copies) and <strong>not system rollback</strong> (NixOS
          generations handle that). Turn on snapshots for a data volume from its
          card above. Apply to take effect.
        </div>
      </config-section>
    `;
  }

  // The LAN subnet (homefree.network.lan-subnet) is the sensible default for
  // a new NFS share's "Allowed clients" — anything on the LAN can mount it,
  // matching the typical home/single-network use case. Hardcoded fallback
  // matches the schema default in module.nix.
  _defaultAllowedClients() {
    return this.config?.network?.['lan-subnet'] || '10.0.0.0/24';
  }

  _renderShares() {
    const shares = this.config?.storage?.shares || [];
    const applied = this.appliedConfig?.storage?.shares || [];
    // Exact NFS mount target per share, so clients use the full export PATH
    // (e.g. 10.0.0.1:/mnt/ellis) instead of the share name (/ellis).
    const lan = this.config?.network?.['lan-address'] || '<server-ip>';
    const mountable = shares.filter((s) => s.enabled !== false && s.path);
    const defAllowed = this._defaultAllowedClients();
    const columns = [
      { key: 'enabled', label: 'Enabled', type: 'boolean', default: true },
      { key: 'name', label: 'Name', type: 'text', placeholder: 'media' },
      { key: 'path', label: 'Path', type: 'path', placeholder: '/mnt/tank/media', rootPath: '/mnt' },
      { key: 'allowed', label: 'Allowed clients', type: 'tags',
        default: defAllowed, placeholder: 'e.g. 10.0.0.0/24, 10.0.0.42' },
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
          NFS uses host/subnet trust (no per-user login) — clients matching any
          listed CIDR or IP may mount the share. New shares default to your
          LAN subnet (<code>${defAllowed}</code>); remove that chip and add
          individual IPs to lock a share down. SMB and per-user access are a
          later phase.
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

  // ---- mounts (homefree.mounts) — split by direction into two sections ----
  // Editing one section preserves the other's rows: we re-merge against the
  // current config and emit the whole `mounts` array (admin-app whole-replaces
  // pendingConfig.mounts), exactly like the shares/pools pattern.

  _isNetworkMount(m) {
    return NETWORK_FS.includes(((m && m['fs-type']) || 'nfs').toLowerCase());
  }

  _emitMounts(mounts) {
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { config: { mounts }, module: 'storage' },
      bubbles: true,
      composed: true,
    }));
  }

  _handleNetworkMountsChange(e) {
    const local = (this.config?.mounts || []).filter((m) => !this._isNetworkMount(m));
    this._emitMounts([...local, ...(e.detail.data || [])]);
  }

  _handleDiskMountsChange(e) {
    const network = (this.config?.mounts || []).filter((m) => this._isNetworkMount(m));
    this._emitMounts([...network, ...(e.detail.data || [])]);
  }

  _renderDiskMounts() {
    const all = this.config?.mounts || [];
    const rows = all.filter((m) => !this._isNetworkMount(m));
    const applied = (this.appliedConfig?.mounts || []).filter((m) => !this._isNetworkMount(m));
    const columns = [
      { key: 'enabled', label: 'Enabled', type: 'boolean', default: true },
      { key: 'mount-point', label: 'Mount point', type: 'path',
        placeholder: '/mnt/data', rootPath: '/mnt' },
      { key: 'device', label: 'Device', type: 'text', placeholder: '/dev/disk/by-uuid/…' },
      { key: 'fs-type', label: 'Type', type: 'text', placeholder: 'ext4', default: 'ext4' },
      { key: 'automount', label: 'Automount', type: 'boolean' },
      { key: 'idle-timeout', label: 'Idle (s)', type: 'text', placeholder: '600', default: '600' },
    ];
    return html`
      <config-section title="Disk mounts"
        description="Mount an existing local disk or partition that HomeFree doesn't manage as a volume">
        <table-editor
          .columns=${columns}
          .data=${rows}
          .appliedData=${applied}
          .rowKey=${'mount-point'}
          addLabel="Add disk mount"
          .neutralBooleans=${true}
          @data-change=${this._handleDiskMountsChange}
        ></table-editor>
      </config-section>
    `;
  }

  _renderNetworkMounts() {
    const all = this.config?.mounts || [];
    const rows = all.filter((m) => this._isNetworkMount(m));
    const applied = (this.appliedConfig?.mounts || []).filter((m) => this._isNetworkMount(m));
    const columns = [
      { key: 'enabled', label: 'Enabled', type: 'boolean', default: true },
      { key: 'mount-point', label: 'Mount point', type: 'path',
        placeholder: '/mnt/ellis', rootPath: '/mnt' },
      { key: 'device', label: 'Remote share', type: 'text', placeholder: '10.0.0.42:/volume1/ellis' },
      { key: 'fs-type', label: 'Type', type: 'text', placeholder: 'nfs', default: 'nfs' },
      { key: 'nfs-version', label: 'NFS ver', type: 'text', placeholder: '3', default: '3' },
      { key: 'automount', label: 'Automount', type: 'boolean', default: true },
      { key: 'idle-timeout', label: 'Idle (s)', type: 'text', placeholder: '600', default: '600' },
    ];
    return html`
      <config-section title="Network Mounts"
        description="Mount a remote NFS/SMB share from another machine ONTO this box (this box as a client) — the reverse of NFS Shares above">
        <table-editor
          .columns=${columns}
          .data=${rows}
          .appliedData=${applied}
          .rowKey=${'mount-point'}
          addLabel="Add network mount"
          .neutralBooleans=${true}
          @data-change=${this._handleNetworkMountsChange}
        ></table-editor>
        <div class="hint" style="margin-top:8px">
          With <strong>Automount</strong> on, the share mounts on first access and
          unmounts after <code>idle</code> seconds. Untick <strong>Enabled</strong>
          to keep the row but skip the mount (useful when the remote host is
          offline — an unreachable export hangs anything touching the mount point).
        </div>
      </config-section>
    `;
  }

  // ---- remove (drop the config record; non-destructive, reversible via Attach) ----

  async _removeVolume(p) {
    const ok = await confirmDialog({
      title: `Remove volume "${p.name}"?`,
      message:
        'The btrfs filesystem and its data stay on the disks — this only removes ' +
        'it from HomeFree’s configuration, and you can re-attach it later from ' +
        '“Available to attach”. Apply afterwards to unmount. (To wipe the ' +
        'drives instead, use Reclaim.)',
      confirmText: 'Remove',
      variant: 'danger',
    });
    if (!ok) return;
    try {
      await forgetStoragePool(p.name);
      await this.loadData();
      this._emitPools();
    } catch (e) {
      this.loadError = e.message || 'Failed to remove volume.';
    }
  }

  // ---- import (re-attach an existing on-disk volume; non-destructive) ----

  _openImport(cand) {
    this.importTarget = cand.fs_uuid;
    this.importName = (cand.label && NAME_RE.test(cand.label)) ? cand.label : '';
    this.importMountpoint = this.importName ? '/mnt/' + this.importName : '';
    this._importMpEdited = false;
    this.importError = '';
  }

  _closeImport() {
    this.importTarget = null;
    this.importError = '';
  }

  _onImportName(e) {
    this.importName = e.target.value;
    if (!this._importMpEdited) {
      const n = this.importName.trim();
      this.importMountpoint = n ? '/mnt/' + n : '';
    }
  }

  _onImportMp(e) {
    this._importMpEdited = true;
    this.importMountpoint = e.target.value;
  }

  async _doImport(cand) {
    this.importError = '';
    try {
      await importStoragePool({
        fs_uuid: cand.fs_uuid,
        name: this.importName.trim(),
        mountpoint: this.importMountpoint.trim(),
      });
      this.importTarget = null;
      await this.loadData();      // moves it from "import" to a recorded volume
      this._emitPools();          // flow through pending → Apply (mounts it)
    } catch (e) {
      this.importError = e.message || 'Failed to import volume.';
    }
  }

  // ---- reclaim (release + wipe an in-use array/LVM group) ----

  _openReclaim(reclaim) {
    this.reclaimTarget = reclaim;
    this.reclaimConfirmText = '';
    this.reclaiming = false;
    this.reclaimStatus = null;
    this.reclaimError = '';
  }

  get _reclaimConfirmed() {
    return this.reclaimConfirmText.trim().toLowerCase()
      === ERASE_CONFIRM_PHRASE.toLowerCase();
  }

  get _createConfirmed() {
    return this.createConfirmText.trim().toLowerCase()
      === ERASE_CONFIRM_PHRASE.toLowerCase();
  }

  _closeReclaim() {
    if (this.reclaiming) return;       // never abandon a teardown mid-flight
    this._stopPolling();
    this.reclaimTarget = null;
  }

  async _doReclaim() {
    this.reclaiming = true;
    this.reclaimError = '';
    this.reclaimStatus = { step: 'starting', progress: 0, message: 'Starting…' };
    try {
      await reclaimStorageDisks(this.reclaimTarget.member_ids);
      this._pollReclaim();
    } catch (e) {
      this.reclaiming = false;
      this.reclaimStatus = null;       // back to the confirm view so it's retryable
      this.reclaimError = e.message || 'Failed to start reclaim.';
    }
  }

  _pollReclaim() {
    this._stopPolling();
    const tick = async () => {
      try {
        const s = await getStorageReclaimStatus();
        this.reclaimStatus = s;
        if (s.error) { this.reclaiming = false; this.reclaimError = s.error; return; }
        if (s.completed) { this.reclaiming = false; await this.loadData(); return; }
      } catch (e) {
        // transient — keep polling
      }
      this._pollTimer = setTimeout(tick, 1000);
    };
    this._pollTimer = setTimeout(tick, 800);
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
          it. For four or more large drives, <strong>double parity (RAID6)</strong>
          gives the most usable space while surviving two drive failures; parity
          volumes build on Linux md and sync in the background after creation.
          To reuse drives that already belong to another array or volume (e.g. an
          imported NAS), click <strong>Reclaim</strong> next to a drive in the
          table below — that releases and wipes the whole group, after which the
          drives become selectable here.
        </div>

        ${this.loadError ? html`<div class="err-banner">${this.loadError}</div>` : ''}

        ${this._renderDrives()}
        ${this._renderPools()}
        ${this._renderImportable()}
        ${this._renderDiskMounts()}
        ${this._renderSnapshots()}
        ${this._renderShares()}
        ${this._renderNetworkMounts()}
        ${this.wizardOpen ? this._renderWizard() : ''}
        ${this.reclaimTarget ? this._renderReclaimModal() : ''}
      </div>
    `;
  }

  _renderPools() {
    const loading = this.pools === null;       // first load not finished
    const pools = this.pools || [];
    const removed = this._removedPools();       // recorded-then-removed, pending Apply
    const canCreate = !loading && (this.eligibleDrives.length > 0 || this.overridableDrives.length > 0);
    return html`
      <config-section title="Volumes" description="Local btrfs data volumes on this machine">
        <button slot="actions" class="btn btn-primary"
                ?disabled=${!canCreate}
                @click=${this._openWizard}>+ Create volume</button>
        ${loading
          ? html`<div class="pools">${this._renderSkeletonCards(2)}</div>`
          : (pools.length === 0 && removed.length === 0
              ? html`<div class="empty" style="padding:4px 0">No volumes yet.</div>`
              : html`
                <div class="pools">
                  ${pools.map((p) => this._renderPoolCard(p))}
                  ${removed.map((a) => this._renderRemovedCard(a))}
                </div>`)}
        ${!loading && this.eligibleDrives.length === 0 && this.overridableDrives.length === 0 ? html`
          <div class="hint">No eligible drives available to create a new volume.</div>` : ''}
      </config-section>
    `;
  }

  // Existing on-disk volumes not attached to HomeFree (e.g. a Removed one, or
  // drives moved from another box). Re-attaching writes the config record back
  // — no reformatting — and the volume mounts on the next Apply.
  _renderImportable() {
    const items = this.importable || [];
    if (!items.length) return '';
    return html`
      <config-section title="Available to attach"
        description="Existing volumes found on the disks but not attached — attach without erasing">
        <div class="pools">
          ${items.map((c) => this._renderImportCard(c))}
        </div>
      </config-section>
    `;
  }

  _renderImportCard(c) {
    const open = this.importTarget === c.fs_uuid;
    const canImport = NAME_RE.test((this.importName || '').trim())
      && (this.importMountpoint || '').trim().startsWith('/');
    return html`
      <div class="pool-card">
        <div class="pool-top">
          <div>
            <span class="pool-name">${c.label || '(unlabelled btrfs)'}</span>
            <div class="pool-meta">
              ${c.profile} · ${(c.members || []).length} drive(s) · ${formatBytes(c.size_bytes)}
            </div>
          </div>
          <div class="pool-actions">
            <span class="badge badge-warn">Not attached</span>
            ${open ? '' : html`<button class="btn btn-primary" @click=${() => this._openImport(c)}>Attach…</button>`}
          </div>
        </div>
        <div class="pool-members">${(c.members || []).join(', ')}</div>
        ${open ? html`
          <div class="inline-confirm">
            Attach this volume — <strong>no data is erased</strong>. Choose a name and mount point:
            <div class="field" style="margin-top:10px">
              <label>Name</label>
              <input type="text" .value=${this.importName} @input=${this._onImportName} placeholder="data" />
            </div>
            <div class="field">
              <label>Mount point</label>
              <input type="text" .value=${this.importMountpoint} @input=${this._onImportMp} placeholder="/mnt/data" />
            </div>
            ${this.importError ? html`<div class="err-banner">${this.importError}</div>` : ''}
            <div class="row">
              <button class="btn" @click=${this._closeImport}>Cancel</button>
              <button class="btn btn-primary" ?disabled=${!canImport} @click=${() => this._doImport(c)}>Attach</button>
            </div>
          </div>` : ''}
      </div>
    `;
  }

  _renderSkeletonCards(n) {
    return Array.from({ length: n }).map(() => html`
      <div class="pool-card">
        <div class="pool-top">
          <div>
            <span class="skeleton skeleton-title"></span>
            <div class="pool-meta"><span class="skeleton skeleton-sub"></span></div>
          </div>
          <span class="skeleton skeleton-badge"></span>
        </div>
      </div>
    `);
  }

  _renderSkeletonRows(nCols, nRows) {
    const cols = Array.from({ length: nCols });
    return Array.from({ length: nRows }).map(() => html`
      <tr>${cols.map(() => html`<td><span class="skeleton skeleton-cell"></span></td>`)}</tr>
    `);
  }

  _renderPoolCard(p) {
    const rt = p.runtime || {};
    // Badge shows the REAL current state — never a predicted/pending one.
    // Pending edits are conveyed by the amber card highlight + the Apply button,
    // not by faking the badge. `mounted` is checked FIRST: a mounted volume is
    // "Mounted" even when its /dev/disk/by-uuid symlink is missing (udev doesn't
    // always create it for md), which is what used to make it wrongly read
    // "Drive(s) not present".
    const enabled = this._poolEnabled(p.name);
    let badge;
    if (rt.mounted) badge = html`<span class="badge badge-ok">Mounted</span>`;
    else if (rt.present) badge = html`<span class="badge badge-muted">Not mounted</span>`;
    else badge = html`<span class="badge badge-err">Drive(s) not present</span>`;

    const pct = (rt.total_bytes && rt.used_bytes != null)
      ? Math.min(100, Math.round((rt.used_bytes / rt.total_bytes) * 100)) : null;

    return html`
      <div class="pool-card ${this._poolUndeployed(p.name) ? 'undeployed' : ''}">
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
            ${enabled
              ? html`<button class="btn-row" @click=${() => this._togglePoolEnabled(p.name, false)}>Unmount</button>`
              : html`<button class="btn-row" @click=${() => this._togglePoolEnabled(p.name, true)}>Mount</button>`}
            <button class="btn-row delete" @click=${() => this._removeVolume(p)}>Remove…</button>
          </div>
        </div>

        ${this._poolPendingLabel(p) ? html`
          <div class="pending-note">⟳ ${this._poolPendingLabel(p)}</div>` : ''}

        ${pct !== null ? html`
          <div class="usage-bar"><div class="usage-fill" style="width:${pct}%"></div></div>
          <div class="pool-meta">${formatBytes(rt.used_bytes)} of ${formatBytes(rt.total_bytes)} used</div>
        ` : ''}

        <div class="pool-members">${(p.members || []).join(', ')}</div>

        ${rt.md ? html`
          <div class="pool-meta">
            Array: ${rt.md.state}${rt.md.resync_pct != null ? ' · resync ' + rt.md.resync_pct + '%' : ''}${rt.md.degraded ? ' · DEGRADED' : ''}
          </div>` : ''}

        <label class="snap-row">
          <input type="checkbox"
                 .checked=${this._poolSnapshotsEnabled(p.name)}
                 @change=${(e) => this._togglePoolSnapshots(p.name, e.target.checked)} />
          <span>Snapshots <span class="hint">— hourly/daily timeline for file recovery</span></span>
        </label>
      </div>
    `;
  }

  _renderDrives() {
    const loading = this.drives === null;      // first load not finished
    const drives = this.drives || [];
    // A drive's set id only if it belongs to a MULTI-drive reclaim group.
    const setGid = (dr) => (dr && dr.reclaim && (dr.reclaim.member_ids || []).length > 1)
      ? dr.reclaim.id : null;
    return html`
      <config-section title="Drives" description="Every non-removable drive detected on this machine">
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Drive</th><th>Size</th><th>Type</th><th>Temp</th><th>Health</th>
                <th>
                  <div class="th-action">
                    <span>Status</span>
                    <button class="btn-row" ?disabled=${loading} @click=${this.loadData}>↻ Refresh</button>
                  </div>
                </th>
              </tr>
            </thead>
            <tbody>
              ${loading
                ? this._renderSkeletonRows(6, 4)
                : drives.length === 0
                  ? html`<tr><td colspan="6" class="empty" style="text-align:center; padding:18px;">No drives detected.</td></tr>`
                  : drives.map((d, i) => this._renderDriveRow(d, {
                      isSet: !!setGid(d),
                      firstOfSet: !!setGid(d) && setGid(d) !== setGid(drives[i - 1]),
                      lastOfSet: !!setGid(d) && setGid(d) !== setGid(drives[i + 1]),
                    }))}
            </tbody>
          </table>
        </div>
      </config-section>
    `;
  }

  _renderDriveRow(d, opts) {
    const { isSet = false, firstOfSet = false, lastOfSet = false } = opts || {};
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

    // A reclaim acts on a whole array/group: a multi-drive set gets a single
    // header row (description + one button) atop a rounded bordered box around
    // its members. A single-drive group just shows the button on its own row.
    const rec = d.reclaim;
    const setSize = rec ? (rec.member_ids || []).length : 0;

    const header = (isSet && firstOfSet) ? html`
      <tr class="set-box-top">
        <td colspan="6">
          <div class="set-head">
            <div class="set-head-info">
              <strong>${this._reclaimGroupTitle(rec)} · ${setSize} drives</strong>
              <div class="set-head-sub">${rec.description} — erasing reclaims all ${setSize} drives.</div>
            </div>
            <button class="btn btn-danger" @click=${() => this._openReclaim(rec)}>Reclaim &amp; erase…</button>
          </div>
        </td>
      </tr>` : '';

    return html`
      ${header}
      <tr class="${isSet ? 'set-box' : ''} ${isSet && lastOfSet ? 'set-box-last' : ''}">
        <td>
          <div>${d.model || 'Unknown'}</div>
          <div class="serial">${d.by_id || d.name}</div>
        </td>
        <td class="muted">${formatBytes(d.size_bytes)}</td>
        <td class="muted">${cls}${tran ? ' · ' + tran : ''}</td>
        <td class="muted">${temp}</td>
        <td class="muted">${health}</td>
        <td>
          ${status}
          ${rec && !isSet ? html`
            <button class="btn-row delete" @click=${() => this._openReclaim(rec)}>Reclaim &amp; erase…</button>` : ''}
          ${d.reclaim_blocked ? this._renderReclaimBlocked(d.reclaim_blocked) : ''}
        </td>
      </tr>
    `;
  }

  _reclaimGroupTitle(rec) {
    if (rec.kind === 'mdadm') return 'RAID array';
    if (rec.kind === 'lvm') return 'LVM volume group';
    return 'Disk group';
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
    const n = this.selected.length;
    // Filter PROFILES by what the current drive count can actually use, so the
    // wizard never offers a layout that can't be created (the previous
    // <select> showed everything regardless). The list visibly changes as the
    // user picks drives.
    const available = PROFILES.filter((p) =>
      n >= p.min
      && (!p.exact || n === p.exact)
      && (!p.even || n % 2 === 0));
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
        ${n === 0
          ? html`<div class="hint">Select drives above to see available layouts.</div>`
          : html`
            <div class="profile-list" role="radiogroup" aria-label="Storage layout">
              ${available.map((p) => html`
                <div class="profile-card ${this.profile === p.value ? 'selected' : ''}"
                     role="radio"
                     aria-checked=${this.profile === p.value ? 'true' : 'false'}
                     tabindex="0"
                     @click=${() => this._setProfile(p.value)}
                     @keydown=${(e) => { if (e.key === ' ' || e.key === 'Enter') { e.preventDefault(); this._setProfile(p.value); } }}>
                  <div class="profile-label">${p.label}</div>
                  <div class="profile-blurb">${p.blurb}</div>
                </div>`)}
            </div>`}
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
        <button class="btn" @click=${this._closeWizard}>Cancel</button>
        <button class="btn btn-primary" ?disabled=${!this._canConfigure}
                @click=${() => { this.createConfirmText = ''; this.wizardStep = 2; }}>Review</button>
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

      ${overridden.length > 0 ? html`
        <label class="ack">
          <input type="checkbox" .checked=${this.ackBoot} @change=${(e) => { this.ackBoot = e.target.checked; }} />
          <span>I confirm ${overridden.map((d) => d.name).join(', ')}
            ${overridden.length > 1 ? 'are' : 'is'} NOT a boot disk for any system I need.</span>
        </label>` : ''}

      <div class="field">
        <label>To confirm erasing ${chosen.length} drive(s), type <code>${ERASE_CONFIRM_PHRASE}</code></label>
        <input type="text" .value=${this.createConfirmText}
               @input=${(e) => { this.createConfirmText = e.target.value; }}
               placeholder=${ERASE_CONFIRM_PHRASE}
               autocomplete="off" autocapitalize="off" spellcheck="false" />
      </div>

      <div class="modal-actions">
        <button class="btn" @click=${() => { this.wizardStep = 1; }}>Back</button>
        <button class="btn btn-danger"
                ?disabled=${!this._createConfirmed || (overridden.length > 0 && !this.ackBoot)}
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
          <button class="btn" @click=${() => { this.wizardStep = 1; this.createError = ''; }}>Back</button>
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

  // Explains why a reclaimable-but-mounted array can't be reclaimed yet, and
  // (if any) the processes holding the mount busy — see backend reclaim_blocked.
  _renderReclaimBlocked(rb) {
    const mps = (rb.mountpoints || []).join(', ');
    const blk = rb.blockers || [];
    return html`
      <div class="reclaim-hint">
        Mounted${mps ? ' at ' + mps : ''} — unmount it (Apply) to reclaim these drives.
        ${blk.length ? html`
          <div class="blockers">
            Currently held open by ${blk.length} process${blk.length === 1 ? '' : 'es'} —
            close ${blk.length === 1 ? 'it' : 'them'} first:
            ${blk.slice(0, 6).map((b) => html`
              <span class="blk">${b.command} (pid ${b.pid}${b.user ? ', ' + b.user : ''})</span>`)}
            ${blk.length > 6 ? html`<span class="blk">… and ${blk.length - 6} more</span>` : ''}
          </div>` : ''}
      </div>
    `;
  }

  _renderReclaimModal() {
    const r = this.reclaimTarget;
    const members = (r.member_ids || [])
      .map((id) => (this.drives || []).find((d) => d.by_id === id))
      .filter(Boolean);
    const inProgress = this.reclaiming || (this.reclaimStatus && !this.reclaimError);
    return html`
      <div class="overlay" @click=${(e) => { if (e.target === e.currentTarget) this._closeReclaim(); }}>
        <div class="modal">
          ${inProgress ? this._renderReclaimProgress() : html`
            <h2>Reclaim drives — this erases them</h2>
            <div class="sub">
              This releases ${r.description}. All data on the following
              ${members.length} drive(s) is <strong>permanently destroyed</strong>,
              after which they become available for a new volume:
            </div>
            <ul class="erase-list">
              ${members.map((d) => html`
                <li>
                  <strong>${d.model || 'Unknown'}</strong> — ${formatBytes(d.size_bytes)}
                  <div class="serial">${d.by_id}</div>
                </li>`)}
            </ul>
            <div class="field">
              <label>To confirm, type <code>${ERASE_CONFIRM_PHRASE}</code></label>
              <input type="text" .value=${this.reclaimConfirmText}
                     @input=${(e) => { this.reclaimConfirmText = e.target.value; }}
                     placeholder=${ERASE_CONFIRM_PHRASE}
                     autocomplete="off" autocapitalize="off" spellcheck="false" />
            </div>
            ${this.reclaimError ? html`<div class="err-banner">${this.reclaimError}</div>` : ''}
            <div class="modal-actions">
              <button class="btn" @click=${this._closeReclaim}>Cancel</button>
              <button class="btn btn-danger" ?disabled=${!this._reclaimConfirmed} @click=${this._doReclaim}>Reclaim drives</button>
            </div>`}
        </div>
      </div>
    `;
  }

  _renderReclaimProgress() {
    const s = this.reclaimStatus || {};
    const pct = Math.round(s.progress || 0);
    if (s.completed) {
      return html`
        <h2>Drives reclaimed</h2>
        <div class="sub">${s.message || 'Done.'}</div>
        <div class="preview-box">The drives are now available. Use <strong>Create volume</strong> to build a new volume.</div>
        <div class="modal-actions">
          <button class="btn btn-primary" @click=${this._closeReclaim}>Done</button>
        </div>`;
    }
    return html`
      <h2>Reclaiming drives…</h2>
      <div class="sub">${s.message || 'Working…'}</div>
      <div class="progress"><div style="width:${pct}%"></div></div>
      <div class="hint">${pct}% — ${s.step || ''}</div>
      <div class="hint">Tearing down the old array and wiping the drives. Keep this tab open.</div>
    `;
  }
}

customElements.define('storage-module', StorageModule);
