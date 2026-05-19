import { LitElement, html, css } from 'lit';
import { getLanClients } from '../../../api/client.js';
import { confirmDialog } from '../../shared/confirm-dialog.js';

/**
 * LAN Clients module.
 *
 * Inventory of devices on the local network, built backend-side by
 * merging dnsmasq's DHCP lease file with the kernel neighbour
 * (ARP/NDP) table — see resolvers/dashboard.py. DHCP leases supply
 * hostname + lease expiry; the neighbour table tells us which devices
 * are reachable *right now* and catches static-IP devices that never
 * took a lease.
 *
 * The page also surfaces the `network.static-ips` reservation list,
 * joined onto the discovered devices by MAC. Each row gets a "Make
 * static" / "Edit" / "Remove static" action so reservations can be
 * managed in place. Those edits flow through the standard config
 * pipeline: a `config-change` event updates pendingConfig, and the
 * reservation takes effect on the next Apply (same as the Network
 * page's table editor). Live discovery is read-only and self-
 * refreshing (10s); polling stops on disconnect.
 */
class LanClientsModule extends LitElement {
  static properties = {
    serverConfig: { type: Object },
    pendingConfig: { type: Object },
    data: { type: Object, state: true },
    loading: { type: Boolean, state: true },
    error: { type: String, state: true },
    filter: { type: String, state: true },        // all | online | static
    editMac: { type: String, state: true },       // MAC of the row being edited
    editForm: { type: Object, state: true },      // { hostname, ip, wanAccess }
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
    }

    .cards {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
      gap: 12px;
      margin-bottom: 16px;
    }
    .card {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border);
      border-radius: 10px;
      padding: 14px 16px;
    }
    .card-label {
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      color: var(--hf-text-muted);
      margin-bottom: 6px;
    }
    .card-value {
      font-size: 22px;
      font-weight: 600;
      color: var(--hf-text);
    }
    .card-value.ok     { color: var(--hf-ok); }
    .card-value.accent { color: var(--hf-accent); }

    .toolbar {
      display: flex;
      gap: 8px;
      margin-bottom: 12px;
      align-items: center;
      flex-wrap: wrap;
    }
    /* Compact table-row button — matches the shared table-editor
       .btn-row (Edit / Delete): 5px 12px / 12px / radius 6px. */
    .action-button {
      background: var(--hf-surface-2);
      color: var(--hf-text);
      border: 1px solid var(--hf-border-2);
      padding: 5px 12px;
      border-radius: 6px;
      font-size: 12px;
      font-weight: 500;
      font-family: inherit;
      cursor: pointer;
      transition: all 0.15s;
    }
    .action-button:hover:not(:disabled) {
      background: var(--hf-surface-3);
      border-color: var(--hf-text-subtle);
    }
    .action-button:disabled { opacity: 0.5; cursor: default; }
    .action-button.active {
      border-color: var(--hf-accent);
      color: var(--hf-accent);
    }
    .action-button.primary {
      background: var(--hf-accent);
      color: #06281c;
      border-color: var(--hf-accent);
    }
    .action-button.primary:hover:not(:disabled) {
      background: var(--hf-accent-hover);
      border-color: var(--hf-accent-hover);
    }
    /* Danger — red text always (matches table-editor .btn-row.delete). */
    .action-button.danger {
      color: var(--hf-err);
      border-color: color-mix(in srgb, var(--hf-err) 45%, transparent);
    }
    .action-button.danger:hover:not(:disabled) {
      background: color-mix(in srgb, var(--hf-err) 14%, transparent);
      border-color: var(--hf-err);
    }

    .panel {
      background: var(--hf-surface);
      border: 1px solid var(--hf-border);
      border-radius: 10px;
      padding: 4px 0;
      overflow-x: auto;
    }
    /* table-layout: fixed so column widths come from the explicit
       th widths below, NOT from cell content. Without it, swapping a
       cell's text for an <input> when a row enters edit mode would
       re-balance every column and shift the table. min-width keeps
       the fixed columns from crushing on narrow screens — the table
       scrolls inside .panel (overflow-x:auto) instead. */
    table {
      width: 100%;
      /* Fixed columns: 90+130+150+110+160+200 = 840px + Hostname
         ~150px minimum. */
      min-width: 990px;
      border-collapse: collapse;
      table-layout: fixed;
      font-size: 13px;
    }
    th, td {
      text-align: left;
      padding: 9px 14px;
      border-bottom: 1px solid var(--hf-border);
      white-space: nowrap;
    }
    /* Text cells: clip an over-long value with an ellipsis rather
       than letting it widen the column. NOT applied to the actions
       cell — clipping interactive buttons would hide a still-
       clickable control (e.g. "Remove static" truncated to "...").  */
    td:not(.actions) {
      overflow: hidden;
      text-overflow: ellipsis;
    }
    /* Every row is exactly this tall — a normal row and its
       edit-mode version both settle to this height, so flipping a
       row into edit mode shifts nothing below it. */
    td { height: 40px; }
    th {
      font-size: 11px;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      color: var(--hf-text-muted);
      font-weight: 600;
    }
    /* Explicit column widths — Status, Hostname, IP, MAC, DHCP lease,
       Type, Actions. Hostname has no width so it absorbs the slack.
       Actions is wide enough for "Edit" + "Remove static" side by
       side so neither button is ever clipped. */
    th:nth-child(1) { width: 90px; }
    th:nth-child(3) { width: 130px; }
    th:nth-child(4) { width: 150px; }
    th:nth-child(5) { width: 110px; }
    th:nth-child(6) { width: 160px; }
    th:nth-child(7) { width: 200px; }
    tr:last-child td { border-bottom: none; }
    td.mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    td.actions { text-align: right; white-space: nowrap; }
    td.actions .action-button { margin-left: 6px; }

    .dot {
      display: inline-block;
      width: 8px;
      height: 8px;
      border-radius: 50%;
      margin-right: 6px;
      vertical-align: middle;
    }
    .dot.up   { background: var(--hf-ok); }
    .dot.down { background: var(--hf-border-2); }

    .tag {
      font-size: 11px;
      padding: 1px 7px;
      border-radius: 10px;
      border: 1px solid var(--hf-border-2);
      color: var(--hf-text-muted);
      white-space: nowrap;
    }
    .tag.static {
      border-color: var(--hf-accent);
      color: var(--hf-accent);
    }
    .tag.noinet {
      border-color: var(--hf-err);
      color: var(--hf-err);
    }

    /* Inline edit row — the editable cells become inputs in place, so
       the row stays column-aligned with the rest of the table. */
    .edit-row td {
      background: var(--hf-surface-2);
    }
    /* An input that fills its table cell. border-box keeps the
       padding/border inside the column width so nothing overflows. */
    .cell-input {
      width: 100%;
      box-sizing: border-box;
      background: var(--hf-surface);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      color: var(--hf-text);
      padding: 5px 8px;
      font-size: 13px;
      font-family: inherit;
    }
    .cell-input.mono {
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    }
    .cell-input:focus {
      outline: none;
      border-color: var(--hf-accent);
    }
    /* Internet-access checkbox in the Type column. */
    .wan-toggle {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      font-size: 12px;
      color: var(--hf-text);
      cursor: pointer;
    }
    /* Validation error — its own full-width row under the edit row.
       height:auto so it sizes to the message, not the 40px row grid. */
    .edit-error-row td {
      height: auto;
      background: var(--hf-surface-2);
      color: var(--hf-err);
      font-size: 12px;
      white-space: normal;
      padding-top: 0;
    }

    /* Unified notification box — grey-tinted bg, colored left edge. */
    .error-message {
      background: rgba(59, 130, 246, 0.08);
      border-left: 4px solid var(--hf-err);
      color: var(--hf-text-muted);
      border-radius: 8px;
      padding: 14px 18px;
      font-size: 13px;
      line-height: 1.5;
      margin-bottom: 16px;
    }
    .error-message strong { color: var(--hf-text); }
    .empty, .loading {
      color: var(--hf-text-muted);
      font-size: 13px;
      padding: 24px 14px;
    }
  `;

  constructor() {
    super();
    this.serverConfig = null;
    this.pendingConfig = null;
    this.data = null;
    this.loading = true;
    this.error = '';
    this.filter = 'all';
    this.editMac = null;
    this.editForm = null;
    this.editError = '';
    this._poll = null;
  }

  connectedCallback() {
    super.connectedCallback();
    this._refresh();
    this._poll = setInterval(() => this._refresh(), 10000);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this._poll) { clearInterval(this._poll); this._poll = null; }
  }

  async _refresh() {
    try {
      this.data = await getLanClients();
      this.error = '';
    } catch (e) {
      if (!this.data) this.error = e.message || 'Failed to load LAN clients';
    } finally {
      this.loading = false;
    }
  }

  // --- static-ips config access -----------------------------------------

  /**
   * The effective static-ips list — pending edits win over server
   * state, mirroring how the Network page reads config. Returns a
   * fresh array of normalised records.
   */
  _staticIps() {
    const raw = this.pendingConfig?.network?.['static-ips']
             ?? this.serverConfig?.network?.['static-ips'];
    if (!Array.isArray(raw)) return [];
    return raw.map(e => ({
      'mac-address': (e['mac-address'] || '').toLowerCase(),
      hostname: e.hostname || '',
      ip: e.ip || '',
      'wan-access': e['wan-access'] !== false,
    }));
  }

  /** Emit a config-change patch with the new static-ips list. */
  _emitStaticIps(list) {
    const newConfig = {
      ...(this.pendingConfig || {}),
      network: {
        ...((this.pendingConfig && this.pendingConfig.network) || {}),
        'static-ips': list,
      },
    };
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { config: newConfig, module: 'lan-clients' },
      bubbles: true,
      composed: true,
    }));
  }

  // --- merged rows -------------------------------------------------------

  /**
   * Join discovered devices with the static-ips list, keyed by MAC.
   * A row may originate from discovery, from a reservation, or both.
   */
  _rows() {
    const byMac = new Map();

    for (const c of (this.data?.clients || [])) {
      const mac = (c.mac || '').toLowerCase();
      byMac.set(mac, {
        mac,
        hostname: c.hostname || null,
        ip: c.ip || null,
        leaseExpiry: c.lease_expiry,
        online: !!c.online,
        discovered: true,
        static: null,
      });
    }

    for (const s of this._staticIps()) {
      const mac = s['mac-address'];
      const existing = byMac.get(mac);
      if (existing) {
        existing.static = s;
      } else {
        // Reserved device that isn't currently talking — still listed
        // so its reservation can be edited or removed.
        byMac.set(mac, {
          mac,
          hostname: s.hostname || null,
          ip: s.ip || null,
          leaseExpiry: null,
          online: false,
          discovered: false,
          static: s,
        });
      }
    }

    // Plain ascending IP-address order. Stable as devices go on/offline
    // between polls — online state is shown by the status dot, so it
    // doesn't drive row order. Rows with no (or non-IPv4) address sort
    // last, then tie-break on MAC so the order is fully deterministic.
    const rows = [...byMac.values()];
    rows.sort((a, b) => {
      const d = this._ipKey(a.ip) - this._ipKey(b.ip);
      return d !== 0 ? d : a.mac.localeCompare(b.mac);
    });
    return rows;
  }

  /**
   * Numeric sort key for an IPv4 address. Built with arithmetic, not
   * bit-shifts: `p[0] << 24` overflows into a *negative* signed 32-bit
   * int for any first octet >= 128 (192.168.*, 172.*), which scrambles
   * the order. Multiplication keeps it a positive JS number.
   */
  _ipKey(ip) {
    if (!ip || ip.includes(':')) return Number.MAX_SAFE_INTEGER;
    const p = ip.split('.').map(Number);
    if (p.length !== 4 || p.some(n => Number.isNaN(n) || n < 0 || n > 255)) {
      return Number.MAX_SAFE_INTEGER;
    }
    return p[0] * 2 ** 24 + p[1] * 2 ** 16 + p[2] * 2 ** 8 + p[3];
  }

  // --- edit actions ------------------------------------------------------

  /** Open the inline form, pre-filled from the device + any reservation. */
  _startEdit(row) {
    const s = row.static;
    this.editMac = row.mac;
    this.editForm = {
      hostname: (s ? s.hostname : row.hostname) || '',
      ip: (s ? s.ip : row.ip) || '',
      wanAccess: s ? s['wan-access'] : true,
    };
    this.editError = '';
  }

  _cancelEdit() {
    this.editMac = null;
    this.editForm = null;
    this.editError = '';
  }

  /** Validate + commit the inline form into static-ips. */
  _saveEdit() {
    const mac = this.editMac;
    const hostname = (this.editForm.hostname || '').trim();
    const ip = (this.editForm.ip || '').trim();

    if (!hostname || !/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/i.test(hostname)) {
      this.editError = 'Enter a valid hostname (letters, digits, hyphens).';
      return;
    }
    if (!this._looksLikeIpv4(ip)) {
      this.editError = `Not a valid IPv4 address: ${ip || '(empty)'}`;
      return;
    }
    // Guard against colliding with another reservation.
    const others = this._staticIps().filter(s => s['mac-address'] !== mac);
    if (others.some(s => s.ip === ip)) {
      this.editError = `Another reservation already uses ${ip}.`;
      return;
    }
    if (others.some(s => s.hostname.toLowerCase() === hostname.toLowerCase())) {
      this.editError = `Another reservation already uses the hostname "${hostname}".`;
      return;
    }

    const record = {
      'mac-address': mac,
      hostname,
      ip,
      'wan-access': !!this.editForm.wanAccess,
    };
    // Replace any existing entry for this MAC, else append.
    const list = this._staticIps();
    const idx = list.findIndex(s => s['mac-address'] === mac);
    if (idx >= 0) list[idx] = record;
    else list.push(record);

    this._emitStaticIps(list);
    this._cancelEdit();
  }

  // Removing a static reservation is destructive — it drops the
  // IP/hostname binding for that device. Confirm before doing it so a
  // stray click (the action buttons sit right next to "Edit") can't
  // silently delete a reservation.
  async _removeStatic(row) {
    const label = row.hostname
      ? `"${row.hostname}" (${row.ip || row.mac})`
      : (row.ip || row.mac);
    const ok = await confirmDialog({
      title: 'Remove static reservation?',
      message:
        `Remove the static reservation for ${label}?\n\n` +
        `The device keeps its current connection but will get a ` +
        `dynamic DHCP address on its next lease — its IP may change.`,
      confirmText: 'Remove',
      variant: 'danger',
    });
    if (!ok) {
      return;
    }
    this._emitStaticIps(
      this._staticIps().filter(s => s['mac-address'] !== row.mac)
    );
  }

  // Lightweight client-side IPv4 check — the Nix activation does the
  // authoritative validation (incl. the in-subnet rule).
  _looksLikeIpv4(s) {
    const m = (s || '').match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
    if (!m) return false;
    return m.slice(1).every(o => {
      const v = parseInt(o, 10);
      return v >= 0 && v <= 255;
    });
  }

  // --- formatting --------------------------------------------------------

  _fmtExpiry(epoch) {
    if (!epoch) return '—';
    const delta = epoch - Date.now() / 1000;
    if (delta <= 0) return 'expired';
    const h = Math.floor(delta / 3600);
    const m = Math.floor((delta % 3600) / 60);
    if (h >= 24) return `${Math.floor(h / 24)}d ${h % 24}h`;
    if (h > 0) return `${h}h ${m}m`;
    return `${m}m`;
  }

  // --- render ------------------------------------------------------------

  // Render the row being edited as a real per-column <tr>: the
  // editable columns (Hostname, IP, internet-access) become inputs
  // in place, the rest of the cells keep their normal read-only
  // content, so the row stays aligned with the table around it.
  // A second full-width <tr> carries any validation error.
  _renderEditRow(row) {
    const f = this.editForm;
    return html`
      <tr class="edit-row">
        <td>
          <span class="dot ${row.online ? 'up' : 'down'}"></span>
          ${row.online ? 'online' : 'offline'}
        </td>
        <td>
          <input class="cell-input" type="text" .value=${f.hostname}
                 placeholder="hostname"
                 @input=${e => { this.editForm = { ...f, hostname: e.target.value }; }}>
        </td>
        <td>
          <input class="cell-input mono" type="text" .value=${f.ip}
                 placeholder="0.0.0.0"
                 @input=${e => { this.editForm = { ...f, ip: e.target.value }; }}>
        </td>
        <td class="mono">${row.mac}</td>
        <td>${row.static ? '— reserved —' : this._fmtExpiry(row.leaseExpiry)}</td>
        <td>
          <label class="wan-toggle" for="wan-access-${this.editMac}">
            <input type="checkbox" id="wan-access-${this.editMac}"
                   .checked=${f.wanAccess}
                   @change=${e => { this.editForm = { ...f, wanAccess: e.target.checked }; }}>
            Internet access
          </label>
        </td>
        <td class="actions">
          <button class="action-button primary" @click=${() => this._saveEdit()}>
            Save
          </button>
          <button class="action-button" @click=${() => this._cancelEdit()}>
            Cancel
          </button>
        </td>
      </tr>
      ${this.editError
        ? html`
            <tr class="edit-error-row">
              <td colspan="7">${this.editError}</td>
            </tr>
          `
        : ''}
    `;
  }

  _renderRow(row) {
    const isStatic = !!row.static;
    const noInternet = isStatic && row.static['wan-access'] === false;

    return html`
      <tr>
        <td>
          <span class="dot ${row.online ? 'up' : 'down'}"></span>
          ${row.online ? 'online' : 'offline'}
        </td>
        <td>${row.hostname || html`<span class="tag">unknown</span>`}</td>
        <td class="mono">${row.ip || '—'}</td>
        <td class="mono">${row.mac}</td>
        <td>${isStatic ? '— reserved —' : this._fmtExpiry(row.leaseExpiry)}</td>
        <td>
          ${isStatic
            ? html`<span class="tag static">static</span>`
            : html`<span class="tag">dynamic</span>`}
          ${noInternet ? html`<span class="tag noinet">no internet</span>` : ''}
          ${!row.discovered
            ? html`<span class="tag">not seen</span>`
            : ''}
        </td>
        <td class="actions">
          ${isStatic
            ? html`
                <button class="action-button" @click=${() => this._startEdit(row)}>
                  Edit
                </button>
                <button class="action-button danger" @click=${() => this._removeStatic(row)}>
                  Remove static
                </button>
              `
            : html`
                <button class="action-button" @click=${() => this._startEdit(row)}>
                  Make static
                </button>
              `}
        </td>
      </tr>
    `;
  }

  render() {
    if (this.loading && !this.data) {
      return html`<div class="module-container">
        <div class="loading">Loading LAN clients…</div>
      </div>`;
    }
    if (this.error && !this.data) {
      return html`<div class="module-container">
        <div class="error-message"><strong>Error:</strong> ${this.error}</div>
      </div>`;
    }

    const rows = this._rows();
    const onlineCount = rows.filter(r => r.online).length;
    const staticCount = rows.filter(r => r.static).length;

    let shown = rows;
    if (this.filter === 'online') shown = rows.filter(r => r.online);
    else if (this.filter === 'static') shown = rows.filter(r => r.static);

    return html`
      <div class="module-container">
        <h2>LAN Clients</h2>
        <div class="subtitle">
          Devices on the local network, from DHCP leases and the kernel
          neighbour table — joined with static-IP reservations.
          Reservation changes apply on the next Apply.
        </div>

        <div class="cards">
          <div class="card">
            <div class="card-label">Known devices</div>
            <div class="card-value">${rows.length}</div>
          </div>
          <div class="card">
            <div class="card-label">Online now</div>
            <div class="card-value ok">${onlineCount}</div>
          </div>
          <div class="card">
            <div class="card-label">Static reservations</div>
            <div class="card-value accent">${staticCount}</div>
          </div>
        </div>

        <div class="toolbar">
          <button class="action-button ${this.filter === 'all' ? 'active' : ''}"
                  @click=${() => { this.filter = 'all'; }}>
            All (${rows.length})
          </button>
          <button class="action-button ${this.filter === 'online' ? 'active' : ''}"
                  @click=${() => { this.filter = 'online'; }}>
            Online (${onlineCount})
          </button>
          <button class="action-button ${this.filter === 'static' ? 'active' : ''}"
                  @click=${() => { this.filter = 'static'; }}>
            Static (${staticCount})
          </button>
          <button class="action-button" @click=${() => this._refresh()}>
            Refresh
          </button>
        </div>

        <div class="panel">
          ${shown.length === 0
            ? html`<div class="empty">No devices to show.</div>`
            : html`
              <table>
                <thead>
                  <tr>
                    <th>Status</th>
                    <th>Hostname</th>
                    <th>IP address</th>
                    <th>MAC address</th>
                    <th>DHCP lease</th>
                    <th>Type</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  ${shown.map(row => this.editMac === row.mac
                    ? this._renderEditRow(row)
                    : this._renderRow(row))}
                </tbody>
              </table>
            `}
        </div>
      </div>
    `;
  }
}

customElements.define('lan-clients-module', LanClientsModule);
