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
  getPromotableBtrfs,
  promoteVolume,
  getMounts,
  getMountableDevices,
  getSystemVolumes,
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
    promotable: { state: true },        // candidates from list_promotable_btrfs
    promoteOpen: { state: true },       // modal visibility
    promoteCand: { state: true },       // currently-selected candidate (object)
    promoteName: { state: true },
    promoteMountpoint: { state: true },
    promoteError: { state: true },
    promoting: { state: true },         // inflight → disable submit
    mountsRuntime: { state: true },     // live homefree.mounts + statvfs
    mountableDevices: { state: true },  // disks/partitions that could be added
    systemVolumes: { state: true },     // read-only OS root mount
    addVolumeOpen: { state: true },     // router modal: which-flow chooser
    addMountOpen: { state: true },
    addMountSource: { state: true },    // selected fs_uuid OR "__custom__"
    addMountDevice: { state: true },    // free-form device (when __custom__)
    addMountFsType: { state: true },    // free-form fs-type (when __custom__)
    addMountPoint: { state: true },
    addMountError: { state: true },
    addingMount: { state: true },
    addNetworkOpen: { state: true },
    netMountPoint: { state: true },
    netDevice: { state: true },
    netFsType: { state: true },         // 'nfs' | 'cifs'
    netNfsVersion: { state: true },
    netAutomount: { state: true },
    netIdleTimeout: { state: true },
    netError: { state: true },
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
    /* "Contains existing data" — the warning lives in the title-row chip
       only. We deliberately do NOT amber-tint the drive option itself: the
       data-escape callout below the picker is the page's amber-tinted
       region, and two yellow blocks side-by-side fights for attention. */
    .data-badge {
      display: inline-block; margin-left: 8px;
      padding: 1px 8px; border-radius: 999px;
      background: var(--hf-warn-soft); color: var(--hf-warn);
      font-size: 11px; font-weight: 600; white-space: nowrap;
    }
    /* Step-1 escape-hatch notice: sits right above the modal-actions row;
       the actual switch-flow action is a third primary button alongside
       Cancel + Review, so this block is text-only. */
    .data-escape {
      margin: 8px 0; padding: 10px 12px;
      background: var(--hf-warn-soft);
      border-left: 3px solid var(--hf-warn);
      border-radius: 6px;
      font-size: 13px; line-height: 1.45;
    }
    .data-escape strong { color: var(--hf-warn); }
    /* Add-volume router uses the same .drive-opt shell as the wizard's drive
       picker, but the description here IS the primary content (not secondary
       identity), so it needs to be readable — the wizard's d-sub size (11px)
       is too small for body copy. */
    .add-vol-routes .drive-opt { padding: 14px 16px; }
    .add-vol-routes .route-title {
      font-size: 15px; font-weight: 600; color: var(--hf-text);
      margin-bottom: 4px;
    }
    .add-vol-routes .route-desc {
      font-size: 13px; line-height: 1.45;
      color: var(--hf-text-muted);
    }

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
    this.promotable = [];
    this.promoteOpen = false;
    this.promoteCand = null;
    this.promoteName = '';
    this.promoteMountpoint = '';
    this.promoteError = '';
    this.promoting = false;
    this.mountsRuntime = [];
    this.mountableDevices = [];
    this.systemVolumes = [];
    this.addVolumeOpen = false;
    this.addMountOpen = false;
    this.addMountSource = '';
    this.addMountDevice = '';
    this.addMountFsType = '';
    this.addMountPoint = '';
    this.addMountError = '';
    this.addingMount = false;
    this.addNetworkOpen = false;
    this.netMountPoint = '';
    this.netDevice = '';
    this.netFsType = 'nfs';
    this.netNfsVersion = '3';
    this.netAutomount = true;
    this.netIdleTimeout = '600';
    this.netError = '';
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
      const [d, p, imp, pr, mr, md, sv] = await Promise.all([
        getStorageDrives(), getStoragePools(), getStorageImportable(),
        getPromotableBtrfs(), getMounts(), getMountableDevices(),
        getSystemVolumes()]);
      this.drives = d.drives || [];
      this.pools = p.pools || [];
      this.importable = imp.importable || [];
      this.promotable = pr.promotable || [];
      this.mountsRuntime = mr.mounts || [];
      this.mountableDevices = md.devices || [];
      this.systemVolumes = sv.system_volumes || [];
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

  // Drives offered in the create wizard: usable-now plus owner-overridable,
  // minus anything already claimed by a pending edit (`storage.pools` member
  // or `homefree.mounts` device that hasn't reached Apply yet). `list_drives`
  // only sees the live filesystem state (`/proc/mounts`), so without this
  // pending-claim filter a disk you just added via "Use existing filesystem"
  // would still appear here — and selecting it would silently wipe the
  // filesystem you decided to keep.
  get selectableDrives() {
    const claimed = this._claimedDriveIds;
    return [...this.eligibleDrives, ...this.overridableDrives]
      .filter((d) => !claimed.has(d.by_id));
  }

  get _claimedDriveIds() {
    const claimed = new Set();
    // Pools — pending + committed (`this.config` is the merged view).
    for (const p of (this.config?.storage?.pools || [])) {
      for (const m of (p.members || [])) claimed.add(m);
    }
    // Already-applied mounts: backend resolved the underlying whole-disk by-id.
    for (const m of (this.mountsRuntime || [])) {
      for (const id of (m.disk_by_ids || [])) claimed.add(id);
    }
    // Pending-but-not-Applied mounts: resolve fs_uuid → mountable candidate →
    // its underlying disk by-id. Best-effort; an opaque custom device path we
    // can't match falls through (worst case the disk shows in the wizard and
    // the user's explicit "wipe" gesture still wins).
    for (const m of (this.config?.mounts || [])) {
      const spec = (m.device || '').trim();
      let u = '';
      if (spec.startsWith('UUID=')) u = spec.slice(5);
      else if (spec.startsWith('/dev/disk/by-uuid/')) u = spec.slice('/dev/disk/by-uuid/'.length);
      if (!u) continue;
      const dev = (this.mountableDevices || []).find((d) => d.fs_uuid === u);
      if (dev && dev.disk_by_id) claimed.add(dev.disk_by_id);
    }
    return claimed;
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

  // Keep `this.profile` consistent with the current drive count:
  //  1. If the currently-chosen layout is no longer valid (e.g. user
  //     deselected a drive so raid6 isn't possible), clear it.
  //  2. If exactly one layout is *available* (typically 1 drive → only
  //     Single), auto-select it. With one option visible the picker reads
  //     as informational, not as an action — auto-selecting removes the
  //     hidden step where Review stays disabled until the user clicks the
  //     lone card. Going from 1 → 2 drives runs (1) which clears Single
  //     (it has `exact: 1`), forcing a deliberate choice between the
  //     newly-visible multi-drive layouts. Going 2 → 1 runs (2) and
  //     re-selects Single.
  _ensureProfileStillValid() {
    if (this.profile) {
      const p = PROFILES.find((x) => x.value === this.profile);
      const n = this.selected.length;
      if (!p
        || n < p.min
        || (p.exact && n !== p.exact)
        || (p.even && n % 2 !== 0)) {
        this.profile = '';
      }
    }
    if (!this.profile) {
      const n = this.selected.length;
      const available = PROFILES.filter((p) =>
        n >= p.min && (!p.exact || n === p.exact) && (!p.even || n % 2 === 0));
      if (available.length === 1) {
        this.profile = available[0].value;
      }
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

  // Mount cards mirror Volume cards: title + subtitle, real-state badge,
  // pending-action note (amber), usage bar when mounted+local, action buttons.
  // No snapshots row (that's a Volume-only concept).
  _renderMountCard(m, runtime, promoUuids) {
    const mp = m['mount-point'] || '';
    const fsType = m['fs-type'] || '';
    const dev = m.device || '';
    const enabled = m.enabled !== false;
    const rt = runtime?.runtime || { mounted: false, used_bytes: null, total_bytes: null };
    const byIds = runtime?.disk_by_ids || [];
    const undeployed = this._mountUndeployed(mp);

    let badge;
    if (rt.mounted) badge = html`<span class="badge badge-ok">Mounted</span>`;
    else if (!enabled) badge = html`<span class="badge badge-muted">Disabled</span>`;
    else badge = html`<span class="badge badge-muted">Not mounted</span>`;

    const pct = (rt.total_bytes && rt.used_bytes != null)
      ? Math.min(100, Math.round((rt.used_bytes / rt.total_bytes) * 100)) : null;

    // A btrfs mount that's still in `homefree.mounts` is a promotion
    // opportunity — surface the button right on the card so the user doesn't
    // have to find it in the Drives section. Detection mirrors the Drives
    // affordance (matches by fs_uuid via `promoUuids`).
    const fsUuid = this._fsUuidForMount(m, runtime);
    const promotable = (fsType.toLowerCase() === 'btrfs') && fsUuid
      && promoUuids.has(fsUuid);
    const promoteCand = promotable
      ? (this.promotable || []).find((p) => p.fs_uuid === fsUuid)
      : null;

    return html`
      <div class="pool-card ${undeployed ? 'undeployed' : ''}">
        <div class="pool-top">
          <div>
            <span class="pool-name">${mp || '(no mount point)'}</span>
            <div class="pool-meta">
              ${fsType || '?'} · device <code>${dev || '—'}</code>
            </div>
          </div>
          <div class="pool-actions">
            ${badge}
            ${enabled
              ? html`<button class="btn-row" @click=${() => this._toggleMountEnabled(mp, false)}>Unmount</button>`
              : html`<button class="btn-row" @click=${() => this._toggleMountEnabled(mp, true)}>Mount</button>`}
            ${promoteCand ? html`
              <button class="btn-row" @click=${() => this._openPromote(promoteCand)}>Promote to volume…</button>` : ''}
            <button class="btn-row delete" @click=${() => this._removeMount(m)}>Remove…</button>
          </div>
        </div>

        ${this._mountPendingLabel(m) ? html`
          <div class="pending-note">⟳ ${this._mountPendingLabel(m)}</div>` : ''}

        ${pct !== null ? html`
          <div class="usage-bar"><div class="usage-fill" style="width:${pct}%"></div></div>
          <div class="pool-meta">${formatBytes(rt.used_bytes)} of ${formatBytes(rt.total_bytes)} used</div>
        ` : ''}

        ${byIds.length ? html`
          <div class="pool-members">${byIds.join(', ')}</div>` : ''}
      </div>
    `;
  }

  // Read-only "System" card: surfaces the OS root mount in the unified
  // Volumes list. Same .pool-card skeleton as everything else, but the
  // actions area carries just a muted "Read-only" badge (no Mount /
  // Unmount / Remove / Promote) — this is informational. Never undeployed
  // (the OS mount isn't user-edited), no pending states.
  _renderSystemCard(s) {
    const rt = s.runtime || {};
    const byIds = s.disk_by_ids || [];
    const pct = (rt.total_bytes && rt.used_bytes != null)
      ? Math.min(100, Math.round((rt.used_bytes / rt.total_bytes) * 100)) : null;
    return html`
      <div class="pool-card">
        <div class="pool-top">
          <div>
            <span class="pool-name">System</span>
            <div class="pool-meta">${s['fs-type'] || '?'} · root mount <code>/</code></div>
          </div>
          <div class="pool-actions">
            <span class="badge badge-muted">Read-only</span>
          </div>
        </div>
        ${pct !== null ? html`
          <div class="usage-bar"><div class="usage-fill" style="width:${pct}%"></div></div>
          <div class="pool-meta">${formatBytes(rt.used_bytes)} of ${formatBytes(rt.total_bytes)} used</div>
        ` : ''}
        ${byIds.length ? html`<div class="pool-members">${byIds.join(', ')}</div>` : ''}
      </div>
    `;
  }

  // Ghost card for a mount that was deployed but has been removed in pending
  // edits — same idea as `_renderRemovedCard` for volumes, so the pending
  // removal isn't invisible bar the nav dot.
  _renderRemovedMountCard(m) {
    const mp = m['mount-point'] || '';
    return html`
      <div class="pool-card undeployed removed">
        <div class="pool-top">
          <div>
            <span class="pool-name">${mp}</span>
            <div class="pool-meta">${m['fs-type'] || '?'} · device <code>${m.device || '—'}</code></div>
          </div>
          <div class="pool-actions">
            <span class="badge badge-warn">Pending removal</span>
            <button class="btn-row" @click=${() => this._undoRemoveMount(m)}>Undo</button>
          </div>
        </div>
        <div class="pending-note">⟳ Will be unmounted and removed on Apply</div>
      </div>
    `;
  }

  // Mounts in appliedConfig that aren't in pendingConfig anymore — the user
  // tapped Remove but hasn't applied. We surface them as ghost cards so a
  // pending removal is visible.
  _removedMounts() {
    if (!this.appliedConfig || !Object.keys(this.appliedConfig).length) return [];
    const applied = this.appliedConfig?.mounts || [];
    const currentMps = new Set((this.config?.mounts || []).map((m) => m['mount-point']));
    return applied.filter((a) => a['mount-point'] && !currentMps.has(a['mount-point']));
  }

  _mountUndeployed(mp) {
    if (!this.appliedConfig || !Object.keys(this.appliedConfig).length) return false;
    const current = (this.config?.mounts || []).find((m) => m['mount-point'] === mp);
    if (!current) return false;
    const applied = (this.appliedConfig?.mounts || []).find((m) => m['mount-point'] === mp);
    if (!applied) return true;
    return stableKey(current) !== stableKey(applied);
  }

  _mountPendingLabel(m) {
    const mp = m['mount-point'];
    if (!this._mountUndeployed(mp)) return null;
    const applied = (this.appliedConfig?.mounts || []).find((a) => a['mount-point'] === mp);
    const enabled = m.enabled !== false;
    if (!applied) return enabled ? 'New — will mount on Apply' : 'New — added on Apply';
    const appliedEnabled = applied.enabled !== false;
    if (enabled && !appliedEnabled) return 'Will mount on Apply';
    if (!enabled && appliedEnabled) return 'Will unmount on Apply';
    return 'Changes will take effect on Apply';
  }

  // Try to pull the fs-uuid for a mount record without an extra round-trip:
  // - device spec is `UUID=<X>` or `/dev/disk/by-uuid/<X>` → read it directly,
  // - otherwise fall back to the runtime's resolved real device path matched
  //   against the promotable list (which carries fs_uuid + device).
  _fsUuidForMount(m, runtime) {
    const spec = (m.device || '').trim();
    if (spec.startsWith('UUID=')) return spec.slice(5);
    if (spec.startsWith('/dev/disk/by-uuid/')) {
      return spec.slice('/dev/disk/by-uuid/'.length);
    }
    const real = runtime?.device_real;
    if (real) {
      const cand = (this.promotable || []).find((p) => p.device === real);
      if (cand) return cand.fs_uuid;
    }
    return '';
  }

  _toggleMountEnabled(mountPoint, enabled) {
    const all = this.config?.mounts || [];
    const next = all.map((m) =>
      m['mount-point'] === mountPoint ? { ...m, enabled } : m);
    this._emitMounts(next);
  }

  async _removeMount(m) {
    const mp = m['mount-point'] || '(unnamed mount)';
    const ok = await confirmDialog({
      title: `Remove "${mp}" from Disk Mounts?`,
      message: 'The mount config row is dropped — on Apply the box stops '
             + 'mounting this device here. The filesystem on the device is '
             + 'left untouched; you can re-add the mount later.',
      confirmText: 'Remove',
      variant: 'danger',
    });
    if (!ok) return;
    const all = this.config?.mounts || [];
    this._emitMounts(all.filter((row) => row['mount-point'] !== m['mount-point']));
  }

  _undoRemoveMount(m) {
    const all = this.config?.mounts || [];
    this._emitMounts([...all, m]);
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

  // ---- promote (any unmanaged btrfs → managed volume; modal flow) ----

  _openPromote(short) {
    // `short` may be the abridged shape carried on a drive row
    // (promotable_btrfs) — look up the full candidate for `members` etc.
    const full = (this.promotable || []).find(
      (p) => p.fs_uuid === short.fs_uuid) || short;
    this.promoteCand = full;
    this.promoteName = full.suggested_name || '';
    this.promoteMountpoint = full.suggested_mountpoint
      || full.mount_point || '';
    this.promoteError = '';
    this.promoting = false;
    this.promoteOpen = true;
  }

  _closePromote() {
    if (this.promoting) return;     // don't yank the modal mid-write
    this.promoteOpen = false;
    this.promoteCand = null;
    this.promoteError = '';
  }

  _onPromoteName(e) { this.promoteName = e.target.value; }
  _onPromoteMountpoint(e) { this.promoteMountpoint = e.target.value; }

  async _doPromote() {
    const cand = this.promoteCand;
    if (!cand) return;
    this.promoteError = '';
    this.promoting = true;
    try {
      const mp = (cand.mount_point || this.promoteMountpoint || '').trim();
      await promoteVolume(cand.fs_uuid, this.promoteName.trim(), mp);
      await this.loadData();      // refresh drives/pools/importable/promotable
      // The backend wrote pools (added) + mounts (any row pointing at this
      // fs-uuid removed) in one atomic write. Mirror BOTH deltas to
      // pendingConfig so the merged view matches disk — emitting only pools
      // would leave the just-promoted row visible in the Disk Mounts table.
      const remainingMounts = (this.config?.mounts || [])
        .filter((m) => !this._mountTargetsFsUuid(m, cand.fs_uuid));
      this._emitMounts(remainingMounts);
      this._emitPools();
      this.promoteOpen = false;
      this.promoteCand = null;
    } catch (e) {
      this.promoteError = e.message || 'Failed to promote volume.';
    } finally {
      this.promoting = false;
    }
  }

  // Mirror of backend `_row_targets_fs`: a mount row targets this fs-uuid if
  // its device spec resolves to the same fs. Used to scrub the matching row
  // from the pending mounts list after a successful promote so the UI agrees
  // with what the backend just wrote. blkid resolution isn't reachable from
  // the browser, so we cover the on-the-wire forms (UUID=, by-uuid path); the
  // backend already did the authoritative removal, so a missed match here
  // just means one extra Apply cycle to reconcile — not a correctness break.
  _mountTargetsFsUuid(m, fsUuid) {
    const spec = String(m?.device || '');
    if (spec.startsWith('UUID=')) return spec.slice(5) === fsUuid;
    if (spec.startsWith('/dev/disk/by-uuid/')) {
      return spec.slice('/dev/disk/by-uuid/'.length) === fsUuid;
    }
    return false;
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
        ${this._renderVolumes()}
        ${this._renderImportable()}
        ${this._renderSnapshots()}
        ${this._renderShares()}
        ${this.wizardOpen ? this._renderWizard() : ''}
        ${this.reclaimTarget ? this._renderReclaimModal() : ''}
        ${this.promoteOpen ? this._renderPromoteModal() : ''}
        ${this.addVolumeOpen ? this._renderAddVolumeRouter() : ''}
        ${this.addMountOpen ? this._renderAddMountModal() : ''}
        ${this.addNetworkOpen ? this._renderAddNetworkShareModal() : ''}
      </div>
    `;
  }

  // Unified Volumes section — managed pools + local mounts + network shares,
  // intermixed in one alphabetical list. Backend partitioning (storage.pools
  // vs homefree.mounts) is implementation detail; the user sees one list of
  // "volumes attached to this box". Dedup is enforced server-side: list_mounts
  // skips any row whose fs-uuid is also in storage.pools.
  _renderVolumes() {
    const loadingPools = this.pools === null;
    const pools = this.pools || [];
    // Pending mount rows drive identity (what exists from the user's POV);
    // runtime rows (keyed by mount-point) carry mounted/used/total/by-id.
    const pendingMounts = this.config?.mounts || [];
    const rtByMp = new Map((this.mountsRuntime || [])
      .map((rt) => [rt['mount-point'], rt]));
    const removedPools = this._removedPools();
    const removedMounts = this._removedMounts();
    const promoUuids = new Set((this.promotable || []).map((p) => p.fs_uuid));

    const items = [
      ...(this.systemVolumes || []).map((s) => ({
        kind: 'system', sortKey: s['mount-point'] || '', data: s,
      })),
      ...pools.map((p) => ({ kind: 'pool', sortKey: p.mountpoint || '', data: p })),
      ...pendingMounts.map((m) => ({
        kind: this._isNetworkMount(m) ? 'network' : 'local',
        sortKey: m['mount-point'] || '',
        data: m,
        runtime: rtByMp.get(m['mount-point']),
      })),
      ...removedPools.map((a) => ({ kind: 'pool-removed', sortKey: a.mountpoint || '', data: a })),
      ...removedMounts.map((m) => ({ kind: 'mount-removed', sortKey: m['mount-point'] || '', data: m })),
    ];
    items.sort((a, b) => (a.sortKey || '').localeCompare(b.sortKey || ''));

    const renderItem = (it) => {
      switch (it.kind) {
        case 'system':         return this._renderSystemCard(it.data);
        case 'pool':           return this._renderPoolCard(it.data);
        case 'local':          return this._renderMountCard(it.data, it.runtime, promoUuids);
        case 'network':        return this._renderMountCard(it.data, it.runtime, promoUuids);
        case 'pool-removed':   return this._renderRemovedCard(it.data);
        case 'mount-removed':  return this._renderRemovedMountCard(it.data);
        default:               return '';
      }
    };

    return html`
      <config-section title="Volumes"
        description="Storage volumes attached to this box — local disks, network shares, and managed pools">
        <button slot="actions" class="btn btn-primary" @click=${this._openAddVolume}>
          + Add volume…
        </button>
        ${loadingPools
          ? html`<div class="pools">${this._renderSkeletonCards(2)}</div>`
          : (items.length === 0
              ? html`<div class="empty" style="padding:4px 0">No volumes yet.</div>`
              : html`<div class="pools">${items.map(renderItem)}</div>`)}
      </config-section>
    `;
  }

  // Existing on-disk volumes not attached to HomeFree (e.g. a Removed one, or
  // drives moved from another box). Re-attaching writes the config record back
  // — no reformatting — and the volume mounts on the next Apply.
  _renderImportable() {
    // Btrfs candidates now flow through the Promote affordance in Drives
    // (covers mounted-via-homefree.mounts AND unmounted, single- AND
    // multi-drive). Filter them out here so the same disk doesn't appear in
    // two sections. The section auto-hides when the result is empty — which
    // it is in practice today, since list_importable scans only btrfs.
    // Reserved for future non-btrfs (ext4/xfs/…) attach.
    const promotedUuids = new Set((this.promotable || []).map((p) => p.fs_uuid));
    const items = (this.importable || []).filter((c) => !promotedUuids.has(c.fs_uuid));
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
    // A drive's set id when it belongs to a MULTI-drive reclaim group OR a
    // MULTI-drive unmanaged-btrfs candidate. Both render under the same
    // set-box (header row + bordered member block) — the only difference is
    // what the header says + which action button it carries.
    const setGid = (dr) => {
      if (!dr) return null;
      if (dr.reclaim && (dr.reclaim.member_ids || []).length > 1) {
        return dr.reclaim.id;
      }
      const pb = dr.promotable_btrfs;
      if (pb && (pb.member_count || 0) > 1) return 'btrfs:' + pb.fs_uuid;
      return null;
    };
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
    const pb = d.promotable_btrfs;
    // An unmanaged btrfs disk lands ineligible with "in use by an existing
    // btrfs filesystem" — accurate but reads as a dead end. Soften the badge
    // so the user understands the disk is reachable (just unmanaged), and
    // surface the mount path when it has one.
    let status;
    if (pb) {
      status = pb.mount_point
        ? html`<span class="badge badge-warn">Btrfs · ${pb.mount_point}</span>`
        : html`<span class="badge badge-warn">Btrfs · unmanaged</span>`;
    } else if (d.eligible) {
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

    // A multi-drive set (reclaim OR unmanaged-btrfs) gets a single header row
    // — description + one action button — atop a rounded bordered box around
    // its members. A single-drive case puts the action on the row itself.
    const rec = d.reclaim;
    const recSize = rec ? (rec.member_ids || []).length : 0;
    const isBtrfsSet = !!pb && (pb.member_count || 0) > 1;
    const isReclaimSet = !!rec && recSize > 1;

    let header = '';
    if (isSet && firstOfSet) {
      if (isReclaimSet) {
        header = html`
          <tr class="set-box-top">
            <td colspan="6">
              <div class="set-head">
                <div class="set-head-info">
                  <strong>${this._reclaimGroupTitle(rec)} · ${recSize} drives</strong>
                  <div class="set-head-sub">${rec.description} — erasing reclaims all ${recSize} drives.</div>
                </div>
                <button class="btn btn-danger" @click=${() => this._openReclaim(rec)}>Reclaim &amp; erase…</button>
              </div>
            </td>
          </tr>`;
      } else if (isBtrfsSet) {
        header = html`
          <tr class="set-box-top">
            <td colspan="6">
              <div class="set-head">
                <div class="set-head-info">
                  <strong>${this._btrfsGroupTitle(pb)}</strong>
                  <div class="set-head-sub">${this._btrfsGroupSub(pb)}</div>
                </div>
                <button class="btn btn-primary" @click=${() => this._openPromote(pb)}>Promote to volume…</button>
              </div>
            </td>
          </tr>`;
      }
    }

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
          ${pb && !isSet ? html`
            <button class="btn-row" @click=${() => this._openPromote(pb)}>Promote to volume…</button>` : ''}
        </td>
      </tr>
    `;
  }

  _btrfsGroupTitle(pb) {
    const lbl = pb.label ? `‘${pb.label}’` : '(unlabelled)';
    return `Btrfs filesystem · ${lbl} · ${pb.member_count} drives · ${pb.profile}`;
  }

  _btrfsGroupSub(pb) {
    const where = pb.mount_point
      ? html`Mounted at <code>${pb.mount_point}</code> outside HomeFree.`
      : html`Not currently mounted.`;
    return html`${where} Promote to a managed volume to enable snapshots, scrub, and backup integration.`;
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

  // Modal for promoting an unmanaged btrfs → managed Volume. One form covers
  // mounted (read-only path) AND unmounted (editable path) cases — the source
  // candidate's `mount_point` drives the difference.
  _renderPromoteModal() {
    const c = this.promoteCand || {};
    const mounted = !!c.mount_point;
    const nameOk = NAME_RE.test((this.promoteName || '').trim());
    const mpOk = (this.promoteMountpoint || '').trim().startsWith('/');
    const canSubmit = nameOk && mpOk && !this.promoting;
    const lbl = c.label ? `‘${c.label}’` : '(unlabelled btrfs)';
    return html`
      <div class="overlay" @click=${(e) => { if (e.target === e.currentTarget) this._closePromote(); }}>
        <div class="modal">
          <h2>Promote to managed volume</h2>
          <div class="sub">
            ${lbl} · ${c.profile || '?'} · ${(c.member_count || (c.members && c.members.length) || 1)} drive(s) ·
            ${formatBytes(c.size_bytes || 0)}
          </div>

          ${c.members && c.members.length ? html`
            <div class="field">
              <label>Members</label>
              <div class="pool-members" style="margin-top:4px">${c.members.join(', ')}</div>
            </div>` : ''}

          <div class="field">
            <label>Name</label>
            <input type="text" .value=${this.promoteName}
                   @input=${this._onPromoteName}
                   placeholder="${c.suggested_name || 'storage'}" />
            <div class="hint">Letters, digits, ‘-’ or ‘_’; starts with a letter or digit (max 32 chars).</div>
          </div>

          <div class="field">
            <label>Mount point</label>
            ${mounted ? html`
              <input type="text" .value=${c.mount_point} readonly
                     style="opacity:0.7; cursor:not-allowed" />
              <div class="hint">
                Current mount path. Change it later through the volume settings
                if you need to move it.
              </div>` : html`
              <input type="text" .value=${this.promoteMountpoint}
                     @input=${this._onPromoteMountpoint}
                     placeholder="${c.suggested_mountpoint || '/mnt/storage'}" />`}
          </div>

          ${this.promoteError ? html`<div class="err-banner">${this.promoteError}</div>` : ''}

          <div class="row" style="display:flex; gap:8px; justify-content:flex-end; margin-top:12px">
            <button class="btn" ?disabled=${this.promoting} @click=${this._closePromote}>Cancel</button>
            <button class="btn btn-primary" ?disabled=${!canSubmit} @click=${this._doPromote}>
              ${this.promoting ? 'Promoting…' : 'Promote'}
            </button>
          </div>
        </div>
      </div>
    `;
  }

  // Add Disk Mount modal — radio-card source picker (live-detected partitions
  // and disks with a filesystem) plus a "Custom device…" fallback for when
  // the scan misses something (unusual layouts, future plug-ins, etc.).
  _renderAddMountModal() {
    const devices = this.mountableDevices || [];
    const isCustom = this.addMountSource === '__custom__';
    const selected = !isCustom
      ? devices.find((d) => d.fs_uuid === this.addMountSource)
      : null;

    const effectiveDevice = isCustom
      ? (this.addMountDevice || '').trim()
      : (selected ? selected.device : '');
    const effectiveFsType = isCustom
      ? (this.addMountFsType || '').trim()
      : (selected ? selected.fs_type : '');
    const mp = (this.addMountPoint || '').trim();
    const mpOk = mp.startsWith('/');
    const sourceOk = !!effectiveDevice && !!effectiveFsType;
    // Mount-point collision check covers BOTH stores — a pool mountpoint and
    // a mount-row mountpoint occupy the same path on disk, so dupes between
    // them are just as bad as dupes within either store.
    const dupMp = (this.config?.mounts || []).some((m) => m['mount-point'] === mp)
      || (this.pools || []).some((p) => p.mountpoint === mp);
    const canSubmit = mpOk && sourceOk && !dupMp && !this.addingMount;

    // If the selected filesystem is btrfs AND it qualifies for managed-pool
    // semantics (single-device or md-backed, by-id stable, etc.), the Add
    // button routes through `promote_volume` instead of a plain mount row —
    // so the user doesn't have to make a second Promote click. Surface that
    // outcome in the modal so the action is honest about what it'll do.
    const willPromote = !isCustom && selected
      && (effectiveFsType || '').toLowerCase() === 'btrfs'
      && (this.promotable || []).some((p) => p.fs_uuid === selected.fs_uuid);

    return html`
      <div class="overlay" @click=${(e) => { if (e.target === e.currentTarget) this._closeAddMount(); }}>
        <div class="modal">
          <h2>Add existing filesystem</h2>
          <div class="sub">
            Mount a disk or partition that already has data. Btrfs filesystems
            are added as managed volumes (snapshots + scrub); other filesystems
            (ext4, xfs, ntfs, …) are added as plain mounts.
          </div>

          <div class="field">
            <label>Source</label>
            <div class="drive-pick">
              ${devices.length === 0 ? html`
                <div class="hint" style="padding:8px 0">
                  No mountable disks or partitions detected — use the custom
                  entry below.
                </div>` : devices.map((d) => html`
                <label class="drive-opt ${this.addMountSource === d.fs_uuid ? 'sel' : ''}">
                  <input type="radio" name="add-mount-src"
                         .checked=${this.addMountSource === d.fs_uuid}
                         @change=${() => this._selectMountSource(d)} />
                  <span class="d-main">
                    <div>${d.display_name} — ${formatBytes(d.size_bytes)} · ${d.fs_type}${d.label ? ' · ‘' + d.label + '’' : ''}</div>
                    <div class="d-sub">${d.device_path} · UUID=${d.fs_uuid}</div>
                  </span>
                </label>`)}
              <label class="drive-opt ${isCustom ? 'sel' : ''}">
                <input type="radio" name="add-mount-src"
                       .checked=${isCustom}
                       @change=${this._selectCustomSource} />
                <span class="d-main">
                  <div>Custom device…</div>
                  <div class="d-sub">Enter a device spec yourself (e.g. <code>UUID=…</code>, <code>LABEL=…</code>, or <code>/dev/sdX1</code>)</div>
                </span>
              </label>
            </div>
          </div>

          ${isCustom ? html`
            <div class="field">
              <label>Device</label>
              <input type="text" .value=${this.addMountDevice}
                     @input=${(e) => { this.addMountDevice = e.target.value; }}
                     placeholder="UUID=… or /dev/sdb1" />
            </div>
            <div class="field">
              <label>Filesystem type</label>
              <input type="text" .value=${this.addMountFsType}
                     @input=${(e) => { this.addMountFsType = e.target.value; }}
                     placeholder="ext4" />
            </div>` : ''}

          <div class="field">
            <label>Mount point</label>
            <input type="text" .value=${this.addMountPoint}
                   @input=${(e) => { this.addMountPoint = e.target.value; }}
                   placeholder="/mnt/data" />
            ${dupMp ? html`
              <div class="hint" style="color:var(--hf-err)">A volume at <code>${mp}</code> already exists.</div>` : ''}
            ${willPromote ? html`
              <div class="hint">
                Will be added as a <strong>managed volume</strong> (snapshots,
                scrub, backup integration). Volume name will be the mount
                point's basename.
              </div>` : ''}
          </div>

          ${this.addMountError ? html`<div class="err-banner">${this.addMountError}</div>` : ''}

          <div class="row" style="display:flex; gap:8px; justify-content:flex-end; margin-top:12px">
            <button class="btn" ?disabled=${this.addingMount} @click=${this._closeAddMount}>Cancel</button>
            <button class="btn btn-primary" ?disabled=${!canSubmit} @click=${this._doAddMount}>
              ${this.addingMount ? 'Adding…' : 'Add'}
            </button>
          </div>
        </div>
      </div>
    `;
  }

  _openAddMount() {
    this.addMountOpen = true;
    this.addMountSource = '';
    this.addMountDevice = '';
    this.addMountFsType = '';
    this.addMountPoint = '';
    this.addMountError = '';
    this.addingMount = false;
  }

  _closeAddMount() {
    if (this.addingMount) return;
    this.addMountOpen = false;
    this.addMountError = '';
  }

  _selectMountSource(d) {
    this.addMountSource = d.fs_uuid;
    // Auto-fill a sensible mount point if the user hasn't typed one yet:
    // /mnt/<label> if there's a usable label, else /mnt/<short-uuid>.
    if (!this.addMountPoint) {
      const slug = (d.label || '').match(/^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$/)
        ? d.label
        : `data-${d.fs_uuid.slice(0, 4)}`;
      this.addMountPoint = '/mnt/' + slug;
    }
  }

  _selectCustomSource() {
    this.addMountSource = '__custom__';
  }

  async _doAddMount() {
    const isCustom = this.addMountSource === '__custom__';
    const selected = !isCustom
      ? (this.mountableDevices || []).find((d) => d.fs_uuid === this.addMountSource)
      : null;
    const device = isCustom ? this.addMountDevice.trim() : (selected ? selected.device : '');
    const fsType = isCustom ? this.addMountFsType.trim() : (selected ? selected.fs_type : '');
    const mp = this.addMountPoint.trim();
    if (!device || !fsType || !mp.startsWith('/')) return;
    this.addMountError = '';

    // Route btrfs → managed pool when the candidate is promote-eligible. This
    // makes the "Add existing filesystem" path automatically write to
    // storage.pools (snapshots/scrub) without a follow-up Promote click. A
    // btrfs that's not in `this.promotable` (e.g. multi-device-native; layout
    // unknowable offline) falls through to the plain-mount path below.
    if (!isCustom && selected && fsType.toLowerCase() === 'btrfs') {
      const promo = (this.promotable || []).find((p) => p.fs_uuid === selected.fs_uuid);
      if (promo) {
        const name = mp.replace(/\/+$/, '').split('/').pop() || '';
        if (!NAME_RE.test(name)) {
          this.addMountError = `Can't derive a volume name from "${mp}" — `
            + 'use a mount point whose basename starts with a letter/digit '
            + "and contains only letters, digits, ‘-’ or ‘_’.";
          return;
        }
        this.addingMount = true;
        try {
          await promoteVolume(promo.fs_uuid, name, mp);
          await this.loadData();
          this._emitPools();   // promote also pruned any mounts row → list_mounts dedup catches it
          this.addMountOpen = false;
        } catch (e) {
          this.addMountError = e.message || 'Failed to add as managed volume.';
        } finally {
          this.addingMount = false;
        }
        return;
      }
    }

    // Non-btrfs, custom device, or btrfs that doesn't qualify for a managed
    // pool: add as a plain mount row. Same defaults the old table-editor used.
    const newRow = {
      enabled: true,
      'mount-point': mp,
      device,
      'fs-type': fsType,
      automount: false,
      'idle-timeout': '600',
      'extra-options': [],
    };
    const all = this.config?.mounts || [];
    this._emitMounts([...all, newRow]);
    this.addMountOpen = false;
  }

  // Add-volume router modal — one entry point for the three Add flows. Each
  // card describes its use-case in user terms (no managed-vs-mount jargon)
  // and routes to the underlying flow that's actually different enough to
  // warrant its own modal: format-blank-drives wizard, pick-existing-fs
  // modal, or add-network-share modal.
  _renderAddVolumeRouter() {
    const canCreate = this.eligibleDrives.length > 0
                       || this.overridableDrives.length > 0;
    return html`
      <div class="overlay" @click=${(e) => { if (e.target === e.currentTarget) this._closeAddVolume(); }}>
        <div class="modal">
          <h2>Add a volume</h2>
          <div class="sub">How would you like to add storage to this box?</div>

          <div class="drive-pick add-vol-routes" style="margin-top:6px">
            <label class="drive-opt ${!canCreate ? 'warn-opt' : ''}"
                   @click=${() => canCreate && this._chooseAddRoute('create')}
                   style="${canCreate ? 'cursor:pointer' : 'cursor:not-allowed; opacity:0.55'}">
              <span class="d-main">
                <div class="route-title">Create a new managed volume</div>
                <div class="route-desc">
                  ${canCreate
                    ? 'Format blank drives, pick a RAID layout, mount as a managed pool with snapshot and scrub integration.'
                    : 'No eligible blank drives detected — free up a drive in the Drives section first.'}
                </div>
              </span>
            </label>

            <label class="drive-opt"
                   @click=${() => this._chooseAddRoute('existing')}
                   style="cursor:pointer">
              <span class="d-main">
                <div class="route-title">Use existing filesystem</div>
                <div class="route-desc">
                  Mount a local disk or partition that already has data — auto-detected or custom device path.
                </div>
              </span>
            </label>

            <label class="drive-opt"
                   @click=${() => this._chooseAddRoute('network')}
                   style="cursor:pointer">
              <span class="d-main">
                <div class="route-title">Add network share</div>
                <div class="route-desc">
                  Mount an NFS or SMB export from another machine on the LAN.
                </div>
              </span>
            </label>
          </div>

          <div class="row" style="display:flex; gap:8px; justify-content:flex-end; margin-top:12px">
            <button class="btn" @click=${this._closeAddVolume}>Cancel</button>
          </div>
        </div>
      </div>
    `;
  }

  _openAddVolume() {
    this.addVolumeOpen = true;
  }

  _closeAddVolume() {
    this.addVolumeOpen = false;
  }

  _chooseAddRoute(which) {
    this.addVolumeOpen = false;
    if (which === 'create') this._openWizard();
    else if (which === 'existing') this._openAddMount();
    else if (which === 'network') this._openAddNetwork();
  }

  // Add network share modal — mirrors the schema the old Network Mounts
  // table-editor exposed (mount-point, server:/export, fs-type, nfs-version,
  // automount, idle-timeout). One field per row, same defaults as the
  // table-editor's row-add (enabled, automount on, idle 600s).
  _renderAddNetworkShareModal() {
    const mp = (this.netMountPoint || '').trim();
    const dev = (this.netDevice || '').trim();
    const mpOk = mp.startsWith('/');
    const devOk = dev.length > 0;
    const isNfs = this.netFsType === 'nfs';
    const dupMp = (this.config?.mounts || []).some((m) => m['mount-point'] === mp);
    const canSubmit = mpOk && devOk && !dupMp;

    return html`
      <div class="overlay" @click=${(e) => { if (e.target === e.currentTarget) this._closeAddNetwork(); }}>
        <div class="modal">
          <h2>Add network share</h2>
          <div class="sub">Mount an NFS or SMB share from another machine onto this box.</div>

          <div class="field">
            <label>Mount point</label>
            <input type="text" .value=${this.netMountPoint}
                   @input=${(e) => { this.netMountPoint = e.target.value; }}
                   placeholder="/mnt/share" />
            ${dupMp ? html`<div class="hint" style="color:var(--hf-err)">A mount at <code>${mp}</code> already exists.</div>` : ''}
          </div>

          <div class="field">
            <label>Server &amp; export</label>
            <input type="text" .value=${this.netDevice}
                   @input=${(e) => { this.netDevice = e.target.value; }}
                   placeholder="${isNfs ? '10.0.0.42:/volume1/share' : '//10.0.0.42/share'}" />
            <div class="hint">
              ${isNfs
                ? 'NFS: hostname or IP, colon, export path on the server.'
                : 'SMB: //hostname/share-name'}
            </div>
          </div>

          <div class="field">
            <label>Type</label>
            <div class="drive-pick">
              <label class="drive-opt ${isNfs ? 'sel' : ''}" style="cursor:pointer">
                <input type="radio" name="net-fs"
                       .checked=${isNfs}
                       @change=${() => { this.netFsType = 'nfs'; }} />
                <span class="d-main"><div>NFS</div></span>
              </label>
              <label class="drive-opt ${!isNfs ? 'sel' : ''}" style="cursor:pointer">
                <input type="radio" name="net-fs"
                       .checked=${!isNfs}
                       @change=${() => { this.netFsType = 'cifs'; }} />
                <span class="d-main"><div>SMB / CIFS</div></span>
              </label>
            </div>
          </div>

          ${isNfs ? html`
            <div class="field">
              <label>NFS version</label>
              <input type="text" .value=${this.netNfsVersion}
                     @input=${(e) => { this.netNfsVersion = e.target.value; }}
                     placeholder="3" />
            </div>` : ''}

          <div class="field">
            <label style="display:flex; align-items:center; gap:8px">
              <input type="checkbox" .checked=${this.netAutomount}
                     @change=${(e) => { this.netAutomount = e.target.checked; }} />
              <span>Automount on access (unmount after idle)</span>
            </label>
          </div>

          ${this.netAutomount ? html`
            <div class="field">
              <label>Idle timeout (seconds)</label>
              <input type="text" .value=${this.netIdleTimeout}
                     @input=${(e) => { this.netIdleTimeout = e.target.value; }}
                     placeholder="600" />
            </div>` : ''}

          ${this.netError ? html`<div class="err-banner">${this.netError}</div>` : ''}

          <div class="row" style="display:flex; gap:8px; justify-content:flex-end; margin-top:12px">
            <button class="btn" @click=${this._closeAddNetwork}>Cancel</button>
            <button class="btn btn-primary" ?disabled=${!canSubmit} @click=${this._doAddNetwork}>Add</button>
          </div>
        </div>
      </div>
    `;
  }

  _openAddNetwork() {
    this.addNetworkOpen = true;
    this.netMountPoint = '';
    this.netDevice = '';
    this.netFsType = 'nfs';
    this.netNfsVersion = '3';
    this.netAutomount = true;
    this.netIdleTimeout = '600';
    this.netError = '';
  }

  _closeAddNetwork() {
    this.addNetworkOpen = false;
    this.netError = '';
  }

  _doAddNetwork() {
    const mp = this.netMountPoint.trim();
    const dev = this.netDevice.trim();
    if (!mp.startsWith('/') || !dev) return;
    const row = {
      enabled: true,
      'mount-point': mp,
      device: dev,
      'fs-type': this.netFsType,
      'nfs-version': this.netFsType === 'nfs' ? (this.netNfsVersion || '3') : '3',
      automount: this.netAutomount,
      'idle-timeout': this.netIdleTimeout || '600',
      'extra-options': [],
    };
    const all = this.config?.mounts || [];
    this._emitMounts([...all, row]);
    this.addNetworkOpen = false;
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
    // When the user's selection contains a drive with an existing filesystem
    // that ALSO has a Use-Existing alternative, surface a notice + a third
    // action button — and swap primary emphasis so the non-destructive path
    // gets the green button, not Review. Returns null when no escape applies.
    const escape = this._existingDataEscapeInfo();
    return html`
      <h2>Create a storage volume</h2>
      <div class="sub">Select drives, choose a layout, and name the volume.</div>

      <div class="field">
        <label>Drives <span class="hint">(${this.selected.length} selected)</span></label>
        <div class="drive-pick">
          ${this.selectableDrives.map((d) => {
            const warn = d.overridable;
            const hasData = !!d.has_existing_data;
            const dataLabel = d.existing_label ? ' ‘' + d.existing_label + '’' : '';
            const dataKind = d.existing_fstype || 'data';
            return html`
              <label class="drive-opt ${warn ? 'warn-opt' : ''} ${this.selected.includes(d.by_id) ? 'sel' : ''}">
                <input type="checkbox"
                       .checked=${this.selected.includes(d.by_id)}
                       @change=${() => this._toggleDrive(d.by_id)} />
                <span class="d-main">
                  <div>
                    ${warn ? '⚠ ' : ''}${d.model || 'Unknown'} — ${formatBytes(d.size_bytes)}
                    ${hasData ? html`<span class="data-badge">Contains ${dataKind}${dataLabel} — will be wiped</span>` : ''}
                  </div>
                  <div class="d-sub">${d.by_id}${warn ? ' · ' + d.ineligible_reason : ''}</div>
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

      ${escape ? html`
        <div class="data-escape">
          <strong>${escape.count === 1 ? 'This drive contains' : 'These drives contain'} existing data that will be wiped.</strong>
          Did you mean to keep the existing filesystem and just mount it?
        </div>` : ''}

      <div class="modal-actions">
        <button class="btn" @click=${this._closeWizard}>Cancel</button>
        ${escape ? html`
          <button class="btn btn-primary"
                  @click=${() => this._switchToExistingFlow(escape.cand)}>
            Use existing filesystem instead…
          </button>
          <button class="btn" ?disabled=${!this._canConfigure}
                  @click=${() => { this.createConfirmText = ''; this.wizardStep = 2; }}>Review</button>`
        : html`
          <button class="btn btn-primary" ?disabled=${!this._canConfigure}
                  @click=${() => { this.createConfirmText = ''; this.wizardStep = 2; }}>Review</button>`}
      </div>
    `;
  }

  // Returns { cand, count } when the user has selected at least one drive
  // with an existing filesystem we can ALSO mount via "Use existing
  // filesystem" (i.e. that drive has a candidate in mountableDevices). Used
  // by Step 1 to surface the non-destructive escape hatch. LUKS/swap drives
  // show has_existing_data but aren't in mountableDevices, so the escape
  // stays silent there to avoid promising a flow we can't deliver.
  _existingDataEscapeInfo() {
    const sel = (this.drives || []).filter((d) =>
      this.selected.includes(d.by_id) && d.has_existing_data);
    if (!sel.length) return null;
    const cand = sel
      .map((d) => (this.mountableDevices || []).find((m) => m.disk_by_id === d.by_id))
      .find(Boolean);
    if (!cand) return null;
    return { cand, count: sel.length };
  }

  _switchToExistingFlow(cand) {
    this._closeWizard();
    this._openAddMount();
    this._selectMountSource(cand);
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
