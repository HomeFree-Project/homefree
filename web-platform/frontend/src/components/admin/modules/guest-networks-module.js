import { LitElement, html, css } from 'lit';
import { confirmDialog } from '../../shared/confirm-dialog.js';

/**
 * Guest Networks module.
 *
 * Defines isolated VLANs (guest, IoT, internet-blocked, etc.) that the
 * router creates as 802.1Q sub-interfaces on the LAN NIC, each with its
 * own subnet, DHCP scope, and firewall isolation policy. Devices land
 * on a VLAN only when the AP/switch downstream maps them to the right
 * tagged segment.
 *
 * The list lives in homefree-config.json under network.guest-networks
 * and is mapped into homefree.network.guest-networks by the loader.
 * Editing flows through the standard pendingConfig pipeline: a
 * config-change event updates pendingConfig, the user clicks Apply,
 * nixos-rebuild activates the new VLAN sub-interfaces, dnsmasq scopes,
 * and nftables rules.
 *
 * Per-device assignment is on the LAN Clients page (Network dropdown
 * on the static-IP edit modal). This page only defines the networks.
 */
class GuestNetworksModule extends LitElement {
  static properties = {
    serverConfig: { type: Object },
    pendingConfig: { type: Object },
    appliedConfig: { attribute: false },
    editIndex: { type: Number, state: true },
    editForm: { type: Object, state: true },
    editError: { type: String, state: true },
  };

  static styles = css`
    :host { display: block; }
    .module-container { width: 100%; }

    h2 {
      font-size: 18px;
      font-weight: 600;
      color: var(--hf-text);
      margin: 0 0 4px;
    }
    .subtitle {
      font-size: 13px;
      color: var(--hf-text-muted);
      margin-bottom: 16px;
      max-width: 760px;
      line-height: 1.5;
    }

    .note {
      background: rgba(59, 130, 246, 0.08);
      border-left: 4px solid var(--hf-accent);
      color: var(--hf-text-muted);
      border-radius: 8px;
      padding: 14px 18px;
      font-size: 13px;
      line-height: 1.5;
      margin-bottom: 16px;
    }
    .note strong { color: var(--hf-text); }

    .panel {
      border: 1px solid var(--hf-border);
      border-radius: 8px;
      overflow: hidden;
      background: var(--hf-surface);
    }
    .table-container { overflow-x: auto; }
    table {
      width: 100%;
      border-collapse: collapse;
      min-width: max-content;
      font-size: 13px;
    }
    thead { background: var(--hf-surface-2); }
    th {
      padding: 10px 16px;
      text-align: left;
      font-size: 11px;
      font-weight: 600;
      color: var(--hf-text-muted);
      text-transform: uppercase;
      letter-spacing: 0.06em;
      border-bottom: 1px solid var(--hf-border);
      white-space: nowrap;
    }
    td {
      padding: 11px 16px;
      border-top: 1px solid var(--hf-border);
      color: var(--hf-text);
      white-space: nowrap;
    }
    @media (max-width: 600px) {
      th { padding: 10px 8px; }
      td { padding: 11px 8px; }
    }
    td.mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    td.col-bool { text-align: center; }
    th.col-bool { text-align: center; }
    .bool-yes { color: var(--hf-accent); font-weight: 600; }
    .bool-no  { color: var(--hf-text-muted); font-weight: 600; }

    tr.row-undeployed td { background: var(--hf-warn-soft); }
    tr.row-undeployed td:first-child {
      box-shadow: inset 3px 0 0 0 var(--hf-warn);
    }
    tr.row-removed td {
      background: var(--hf-warn-soft);
      color: var(--hf-text-subtle);
      text-decoration: line-through;
    }
    tr.row-removed td.actions-cell { text-decoration: none; }
    tr.row-removed td:first-child {
      box-shadow: inset 3px 0 0 0 var(--hf-warn);
    }

    .actions-cell { text-align: right; white-space: nowrap; }
    .row-actions { display: inline-flex; gap: 8px; }

    .btn-row {
      background: var(--hf-surface-2);
      border: 1px solid var(--hf-border-2);
      color: var(--hf-text);
      cursor: pointer;
      padding: 5px 12px;
      border-radius: 6px;
      font-size: 12px;
      font-weight: 500;
      font-family: inherit;
      transition: all 0.15s;
    }
    .btn-row:hover {
      background: var(--hf-surface-3);
      border-color: var(--hf-text-subtle);
    }
    .btn-row.delete {
      color: var(--hf-err);
      border-color: color-mix(in srgb, var(--hf-err) 45%, transparent);
    }
    .btn-row.delete:hover {
      background: color-mix(in srgb, var(--hf-err) 14%, transparent);
      border-color: var(--hf-err);
    }

    .add-row-btn {
      display: block;
      width: 100%;
      padding: 11px;
      background: var(--hf-surface-2);
      border: none;
      border-top: 1px solid var(--hf-border);
      color: var(--hf-accent);
      font-size: 13px;
      font-weight: 500;
      font-family: inherit;
      cursor: pointer;
      transition: background 0.15s;
    }
    .add-row-btn:hover { background: var(--hf-surface-3); }

    .empty-state {
      padding: 40px;
      text-align: center;
      color: var(--hf-text-muted);
    }

    .modal-overlay {
      position: fixed;
      top: 0; left: 0; right: 0; bottom: 0;
      background: rgba(0, 0, 0, 0.7);
      display: flex;
      align-items: center;
      justify-content: center;
      z-index: 1000;
      backdrop-filter: blur(2px);
    }
    .modal {
      background: var(--hf-surface-2);
      border: 1px solid var(--hf-border-2);
      border-radius: 10px;
      padding: 24px;
      max-width: 540px;
      width: 90%;
      max-height: 90vh;
      overflow-y: auto;
      box-shadow: var(--hf-shadow-lg);
      color: var(--hf-text);
    }
    .modal-header {
      margin: 0 0 20px 0;
      font-size: 18px;
      font-weight: 600;
      color: var(--hf-text);
    }
    .modal-body { margin-bottom: 24px; }
    .modal-field { margin-bottom: 16px; }
    .modal-field label {
      display: block;
      font-size: 13px;
      font-weight: 500;
      color: var(--hf-text);
      margin-bottom: 6px;
    }
    .modal-field .hint {
      display: block;
      font-size: 12px;
      color: var(--hf-text-muted);
      margin-top: 4px;
      font-weight: 400;
    }
    .modal-field.boolean { display: flex; align-items: center; gap: 8px; }
    .modal-field.boolean label { margin: 0; order: 2; font-weight: 500; }
    .modal-field.boolean input[type="checkbox"] {
      margin: 0; width: 16px; height: 16px; flex-shrink: 0;
    }
    .modal-field input {
      width: 100%;
      box-sizing: border-box;
      padding: 9px 12px;
      font-size: 13px;
      background: var(--hf-bg);
      color: var(--hf-text);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      font-family: inherit;
      transition: border-color 0.15s, box-shadow 0.15s;
    }
    .modal-field input.mono {
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    }
    .modal-field input:focus {
      outline: none;
      border-color: var(--hf-accent);
      box-shadow: 0 0 0 3px var(--hf-focus-ring);
    }
    .modal-field-row {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 12px;
    }
    @media (max-width: 480px) {
      .modal-field-row { grid-template-columns: 1fr; gap: 0; }
    }
    .modal-error {
      margin-bottom: 16px;
      padding: 10px 14px;
      border-left: 4px solid var(--hf-err);
      background: rgba(239, 68, 68, 0.08);
      color: var(--hf-err);
      font-size: 13px;
      border-radius: 6px;
    }
    .modal-actions {
      display: flex;
      gap: 10px;
      justify-content: flex-end;
    }
    .btn {
      padding: 9px 16px;
      border-radius: 6px;
      border: 1px solid var(--hf-border-2);
      background: var(--hf-surface-2);
      color: var(--hf-text);
      font-size: 13px;
      font-weight: 500;
      cursor: pointer;
      transition: all 0.15s;
    }
    .btn:hover {
      background: var(--hf-surface-3);
      border-color: var(--hf-text-subtle);
    }
    .btn-primary {
      background: var(--hf-accent);
      color: #06281c;
      border-color: var(--hf-accent);
    }
    .btn-primary:hover {
      background: var(--hf-accent-hover);
      border-color: var(--hf-accent-hover);
    }
  `;

  constructor() {
    super();
    this.serverConfig = null;
    this.pendingConfig = null;
    this.appliedConfig = null;
    this.editIndex = null;
    this.editForm = null;
    this.editError = '';
  }

  // --- config access ----------------------------------------------------

  _list() {
    const raw = this.pendingConfig?.network?.['guest-networks']
             ?? this.serverConfig?.network?.['guest-networks'];
    return Array.isArray(raw) ? raw.map(this._normalize) : [];
  }

  _appliedList() {
    if (!this.appliedConfig || !Object.keys(this.appliedConfig).length) return null;
    const raw = this.appliedConfig?.network?.['guest-networks'];
    return Array.isArray(raw) ? raw.map(this._normalize) : [];
  }

  _normalize(gn) {
    return {
      id: gn.id || '',
      name: gn.name || '',
      'vlan-id': Number.isInteger(gn['vlan-id']) ? gn['vlan-id'] : null,
      subnet: gn.subnet || '',
      gateway: gn.gateway || '',
      'dhcp-range-start': gn['dhcp-range-start'] || '',
      'dhcp-range-end': gn['dhcp-range-end'] || '',
      'internet-access': gn['internet-access'] !== false,
      'lan-access': gn['lan-access'] === true,
      'inter-network-access': gn['inter-network-access'] === true,
    };
  }

  _emit(list) {
    const newConfig = {
      ...(this.pendingConfig || {}),
      network: {
        ...((this.pendingConfig && this.pendingConfig.network) || {}),
        'guest-networks': list,
      },
    };
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { config: newConfig, module: 'guest-networks' },
      bubbles: true,
      composed: true,
    }));
  }

  _stableKey(v) {
    return JSON.stringify(v, (k, val) =>
      (val && typeof val === 'object' && !Array.isArray(val))
        ? Object.keys(val).sort().reduce((o, kk) => { o[kk] = val[kk]; return o; }, {})
        : val);
  }

  _rowUndeployed(row) {
    const applied = this._appliedList();
    if (!Array.isArray(applied)) return false;
    const key = this._stableKey(row);
    return !applied.some(a => this._stableKey(a) === key);
  }

  _removedRows() {
    const applied = this._appliedList();
    if (!Array.isArray(applied)) return [];
    const live = this._list();
    const liveIds = new Set(live.map(r => r.id));
    return applied.filter(a => !liveIds.has(a.id));
  }

  // --- validation -------------------------------------------------------

  // Server-side validation (validation.py) is authoritative; this is
  // quick feedback for obvious mistakes so the user sees them before Apply.
  _validate(form, editIndex) {
    const list = this._list();
    const others = editIndex == null
      ? list
      : list.filter((_, i) => i !== editIndex);

    const id = (form.id || '').trim();
    if (!id) return 'ID is required.';
    if (!/^[a-z0-9]([a-z0-9-]{0,13}[a-z0-9])?$/.test(id)) {
      return 'ID must be lowercase letters, digits, or hyphens (max 15 chars).';
    }
    if (others.some(g => g.id === id)) {
      return 'Another network already uses this ID.';
    }

    const name = (form.name || '').trim();
    if (!name) return 'Name is required.';
    if (others.some(g => g.name === name)) {
      return 'Another network already uses this name.';
    }

    const vlanId = parseInt(form['vlan-id'], 10);
    if (!Number.isInteger(vlanId) || vlanId < 1 || vlanId > 4094) {
      return 'VLAN ID must be an integer between 1 and 4094.';
    }
    if (others.some(g => g['vlan-id'] === vlanId)) {
      return 'Another network already uses this VLAN ID.';
    }

    const subnet = (form.subnet || '').trim();
    const subnetMatch = subnet.match(/^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\/(\d{1,2})$/);
    if (!subnetMatch) return 'Subnet must be a CIDR like 10.3.0.0/24.';
    const prefix = parseInt(subnetMatch[2], 10);
    if (prefix < 8 || prefix > 30) {
      return 'Subnet prefix must be between /8 and /30.';
    }
    const subnetIp = this._ipToInt(subnetMatch[1]);
    if (subnetIp == null) return 'Subnet network address is invalid.';
    const mask = prefix === 0 ? 0 : (0xFFFFFFFF * 2 ** (32 - prefix)) % (2 ** 32);
    const netStart = subnetIp & mask;
    const netEnd = netStart + 2 ** (32 - prefix) - 1;

    const gw = this._ipToInt(form.gateway);
    if (gw == null) return 'Gateway must be a valid IPv4 address.';
    if (gw < netStart || gw > netEnd) {
      return 'Gateway must lie inside the subnet.';
    }

    const dStart = this._ipToInt(form['dhcp-range-start']);
    const dEnd = this._ipToInt(form['dhcp-range-end']);
    if (dStart == null) return 'DHCP range start must be a valid IPv4 address.';
    if (dEnd == null) return 'DHCP range end must be a valid IPv4 address.';
    if (dStart >= dEnd) return 'DHCP range start must be less than end.';
    if (dStart < netStart || dEnd > netEnd) {
      return 'DHCP range must lie inside the subnet.';
    }

    return null;
  }

  // Numeric form of an IPv4 address (multiplication, NOT bit-shift —
  // `<< 24` wraps to negative for octets >= 128). Returns null if not
  // a parseable IPv4.
  _ipToInt(ip) {
    if (!ip) return null;
    const m = ip.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
    if (!m) return null;
    const p = m.slice(1).map(Number);
    if (p.some(n => Number.isNaN(n) || n < 0 || n > 255)) return null;
    return p[0] * 2 ** 24 + p[1] * 2 ** 16 + p[2] * 2 ** 8 + p[3];
  }

  // --- edit lifecycle ---------------------------------------------------

  _startAdd() {
    this.editIndex = -1;
    this.editForm = {
      id: '',
      name: '',
      'vlan-id': '',
      subnet: '',
      gateway: '',
      'dhcp-range-start': '',
      'dhcp-range-end': '',
      'internet-access': true,
      'lan-access': false,
      'inter-network-access': false,
    };
    this.editError = '';
  }

  _startEdit(idx) {
    const row = this._list()[idx];
    if (!row) return;
    this.editIndex = idx;
    this.editForm = { ...row };
    this.editError = '';
  }

  _cancel() {
    this.editIndex = null;
    this.editForm = null;
    this.editError = '';
  }

  _save() {
    const editIdx = this.editIndex >= 0 ? this.editIndex : null;
    const err = this._validate(this.editForm, editIdx);
    if (err) { this.editError = err; return; }

    const record = {
      id: this.editForm.id.trim(),
      name: this.editForm.name.trim(),
      'vlan-id': parseInt(this.editForm['vlan-id'], 10),
      subnet: this.editForm.subnet.trim(),
      gateway: this.editForm.gateway.trim(),
      'dhcp-range-start': this.editForm['dhcp-range-start'].trim(),
      'dhcp-range-end': this.editForm['dhcp-range-end'].trim(),
      'internet-access': !!this.editForm['internet-access'],
      'lan-access': !!this.editForm['lan-access'],
      'inter-network-access': !!this.editForm['inter-network-access'],
    };

    const list = this._list();
    if (this.editIndex >= 0) list[this.editIndex] = record;
    else list.push(record);
    this._emit(list);
    this._cancel();
  }

  async _delete(idx) {
    const row = this._list()[idx];
    if (!row) return;
    const ok = await confirmDialog({
      title: 'Delete guest network?',
      message:
        'Remove "' + row.name + '" (' + row.id + ', VLAN ' + row['vlan-id'] + ')?\n\n' +
        'Devices currently assigned to this network on the LAN Clients ' +
        'page will lose their reservation when you Apply.',
      confirmText: 'Delete',
      variant: 'danger',
    });
    if (!ok) return;
    const list = this._list().filter((_, i) => i !== idx);
    this._emit(list);
  }

  _restore(row) {
    const list = [...this._list(), row];
    this._emit(list);
  }

  // --- render -----------------------------------------------------------

  _renderRow(row, idx) {
    const undeployed = this._rowUndeployed(row);
    return html`
      <tr class=${undeployed ? 'row-undeployed' : ''}>
        <td>${row.name}</td>
        <td class="mono">${row.id}</td>
        <td class="mono">${row['vlan-id']}</td>
        <td class="mono">${row.subnet}</td>
        <td class="mono">${row.gateway}</td>
        <td class="mono">${row['dhcp-range-start']} – ${row['dhcp-range-end']}</td>
        <td class="col-bool">
          ${row['internet-access']
            ? html`<span class="bool-yes">✓</span>`
            : html`<span class="bool-no">✗</span>`}
        </td>
        <td class="col-bool">
          ${row['lan-access']
            ? html`<span class="bool-yes">✓</span>`
            : html`<span class="bool-no">✗</span>`}
        </td>
        <td class="col-bool">
          ${row['inter-network-access']
            ? html`<span class="bool-yes">✓</span>`
            : html`<span class="bool-no">✗</span>`}
        </td>
        <td class="actions-cell">
          <span class="row-actions">
            <button class="btn-row" @click=${() => this._startEdit(idx)}>Edit</button>
            <button class="btn-row delete" @click=${() => this._delete(idx)}>Delete</button>
          </span>
        </td>
      </tr>
    `;
  }

  _renderRemovedRow(row) {
    return html`
      <tr class="row-removed" title="Removed — Apply to deploy">
        <td>${row.name}</td>
        <td class="mono">${row.id}</td>
        <td class="mono">${row['vlan-id']}</td>
        <td class="mono">${row.subnet}</td>
        <td class="mono">${row.gateway}</td>
        <td class="mono">${row['dhcp-range-start']} – ${row['dhcp-range-end']}</td>
        <td class="col-bool">
          ${row['internet-access']
            ? html`<span class="bool-yes">✓</span>`
            : html`<span class="bool-no">✗</span>`}
        </td>
        <td class="col-bool">
          ${row['lan-access']
            ? html`<span class="bool-yes">✓</span>`
            : html`<span class="bool-no">✗</span>`}
        </td>
        <td class="col-bool">
          ${row['inter-network-access']
            ? html`<span class="bool-yes">✓</span>`
            : html`<span class="bool-no">✗</span>`}
        </td>
        <td class="actions-cell">
          <span class="row-actions">
            <button class="btn-row" @click=${() => this._restore(row)}>↩ Restore</button>
          </span>
        </td>
      </tr>
    `;
  }

  _renderModal() {
    if (this.editIndex == null || !this.editForm) return '';
    const f = this.editForm;
    const isNew = this.editIndex < 0;
    const update = (k, v) => { this.editForm = { ...f, [k]: v }; };
    return html`
      <div class="modal-overlay" @click=${() => this._cancel()}>
        <div class="modal" @click=${(e) => e.stopPropagation()}>
          <h3 class="modal-header">
            ${isNew ? 'Add guest network' : 'Edit guest network'}
          </h3>
          <div class="modal-body">
            ${this.editError
              ? html`<div class="modal-error">${this.editError}</div>`
              : ''}

            <div class="modal-field-row">
              <div class="modal-field">
                <label>Name</label>
                <input type="text" .value=${f.name}
                       placeholder="Guest Wi-Fi"
                       @input=${(e) => update('name', e.target.value)}>
                <span class="hint">Display name shown across the admin UI.</span>
              </div>
              <div class="modal-field">
                <label>ID</label>
                <input class="mono" type="text" .value=${f.id}
                       placeholder="guest"
                       ?disabled=${!isNew}
                       @input=${(e) => update('id', e.target.value)}>
                <span class="hint">
                  ${isNew
                    ? 'Slug used as the VLAN interface name (immutable once saved).'
                    : 'Immutable once saved.'}
                </span>
              </div>
            </div>

            <div class="modal-field">
              <label>VLAN ID</label>
              <input class="mono" type="number" min="1" max="4094"
                     .value=${String(f['vlan-id'] ?? '')}
                     placeholder="202"
                     @input=${(e) => update('vlan-id', e.target.value)}>
              <span class="hint">
                802.1Q tag (1–4094). The downstream AP/switch must
                broadcast or trunk this tag for clients to reach the
                network.
              </span>
            </div>

            <div class="modal-field">
              <label>Subnet</label>
              <input class="mono" type="text" .value=${f.subnet}
                     placeholder="10.3.0.0/24"
                     @input=${(e) => update('subnet', e.target.value)}>
              <span class="hint">
                CIDR. Must not overlap the main LAN or any other guest
                network.
              </span>
            </div>

            <div class="modal-field">
              <label>Gateway (router IP on this VLAN)</label>
              <input class="mono" type="text" .value=${f.gateway}
                     placeholder="10.3.0.1"
                     @input=${(e) => update('gateway', e.target.value)}>
            </div>

            <div class="modal-field-row">
              <div class="modal-field">
                <label>DHCP range start</label>
                <input class="mono" type="text" .value=${f['dhcp-range-start']}
                       placeholder="10.3.0.100"
                       @input=${(e) => update('dhcp-range-start', e.target.value)}>
              </div>
              <div class="modal-field">
                <label>DHCP range end</label>
                <input class="mono" type="text" .value=${f['dhcp-range-end']}
                       placeholder="10.3.0.254"
                       @input=${(e) => update('dhcp-range-end', e.target.value)}>
              </div>
            </div>

            <div class="modal-field boolean">
              <input type="checkbox" id="ia-${this.editIndex}"
                     .checked=${f['internet-access']}
                     @change=${(e) => update('internet-access', e.target.checked)}>
              <label for="ia-${this.editIndex}">Allow internet access (WAN)</label>
            </div>
            <div class="modal-field boolean">
              <input type="checkbox" id="la-${this.editIndex}"
                     .checked=${f['lan-access']}
                     @change=${(e) => update('lan-access', e.target.checked)}>
              <label for="la-${this.editIndex}">Allow reaching the main LAN</label>
            </div>
            <div class="modal-field boolean">
              <input type="checkbox" id="ina-${this.editIndex}"
                     .checked=${f['inter-network-access']}
                     @change=${(e) => update('inter-network-access', e.target.checked)}>
              <label for="ina-${this.editIndex}">Allow reaching other guest networks</label>
            </div>
          </div>
          <div class="modal-actions">
            <button class="btn" @click=${() => this._cancel()}>Cancel</button>
            <button class="btn btn-primary" @click=${() => this._save()}>Save</button>
          </div>
        </div>
      </div>
    `;
  }

  render() {
    const rows = this._list();
    const removed = this._removedRows();

    return html`
      <div class="module-container">
        <h2>Guest Networks</h2>
        <div class="subtitle">
          Isolated VLANs for guests, IoT devices, or internet-blocked
          devices. Each network gets its own subnet, DHCP scope, and
          firewall isolation policy. Per-device assignment is on the
          LAN Clients page.
        </div>

        <div class="note">
          <strong>Hardware requirement:</strong> Reaching clients on a
          VLAN requires an 802.1Q-aware AP or managed switch downstream
          that maps each client onto the right tagged segment (e.g. a
          UniFi AP broadcasting a per-VLAN SSID, or a managed switch
          with VLAN-tagged ports). HomeFree configures the router side
          only.
        </div>

        <div class="panel">
          <div class="table-container">
            <table>
              <thead>
                <tr>
                  <th>Name</th>
                  <th>ID</th>
                  <th>VLAN</th>
                  <th>Subnet</th>
                  <th>Gateway</th>
                  <th>DHCP range</th>
                  <th class="col-bool">Internet</th>
                  <th class="col-bool">Main LAN</th>
                  <th class="col-bool">Inter-net</th>
                  <th style="text-align:right;">Actions</th>
                </tr>
              </thead>
              <tbody>
                ${rows.length === 0 && removed.length === 0
                  ? html`<tr><td colspan="10" class="empty-state">
                      No guest networks yet. Click "Add guest network" to create one.
                    </td></tr>`
                  : ''}
                ${rows.map((row, idx) => this._renderRow(row, idx))}
                ${removed.map(row => this._renderRemovedRow(row))}
              </tbody>
            </table>
          </div>
          <button class="add-row-btn" @click=${() => this._startAdd()}>
            + Add guest network
          </button>
        </div>

        ${this._renderModal()}
      </div>
    `;
  }
}

customElements.define('guest-networks-module', GuestNetworksModule);
