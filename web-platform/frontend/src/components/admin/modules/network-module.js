import { LitElement, html, css } from 'lit';
import '../../shared/config-section.js';
import '../../shared/form-field.js';
import { getNetworkInterfaces } from '../../../api/client.js';

/**
 * Network configuration module
 * Handles: WAN/LAN interfaces, router settings, DHCP, traffic control,
 * ad-blocking. Static-IP reservations are managed on the LAN Clients
 * page, which has live device context — see lan-clients-module.js.
 */
class NetworkModule extends LitElement {
  static properties = {
    config: { type: Object },
    undeployedPaths: { attribute: false },  // Set<dotted-path> not yet deployed
    interfaces: { type: Array },
    modified: { type: Boolean }
  };

  static styles = css`
    :host {
      display: block;
    }

    /* Width cap + centering is applied once, app-wide, on
       admin-app.js's .content-area > * — no per-module max-width. */
    .module-container {
      width: 100%;
    }

    /* minmax(0, 1fr) lets a column shrink below its content width;
       plain 1fr would overflow / clip the field on narrow screens. */
    .field-row {
      display: grid;
      grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
      gap: 20px;
    }

    @media (max-width: 768px) {
      .field-row {
        grid-template-columns: minmax(0, 1fr);
      }
    }

    /* Unified notification box — grey-tinted bg, colored left edge,
       colored heading, normal body text. */
    .warning-box {
      background: rgba(59, 130, 246, 0.08);
      border-left: 4px solid var(--hf-warn);
      padding: 14px 18px;
      border-radius: 8px;
      margin-bottom: 20px;
      color: var(--hf-text-muted);
      font-size: 13px;
      line-height: 1.5;
    }

    .warning-box strong {
      display: block;
      margin-bottom: 8px;
      font-size: 14px;
      color: var(--hf-text);
    }
  `;

  constructor() {
    super();
    this.config = {
      network: {
        'wan-interface': '',
        'lan-interface': '',
        'router-enable': false,
        'lan-address': '10.0.0.1',
        'lan-subnet': '10.0.0.0/24',
        'dhcp-range-start': '10.0.0.100',
        'dhcp-range-end': '10.0.0.200',
        'enable-unbound-adblock': false,
        'wan-bitrate-mbps-down': null,
        'wan-bitrate-mbps-up': null,
        'static-ips': [],
        // Static IP for the box itself in non-router mode. Address/subnet
        // reuse LAN Address / LAN Subnet above (they are the box's own IP
        // everywhere); these add the gateway + upstream DNS + which NIC.
        'static-ip-enable': false,
        'static-ip-interface': '',
        'static-ip-gateway': '',
        'static-ip-nameservers': [],
        // Static WAN IP for router mode (HomeFree behind another router /
        // double-NAT). Default DHCP on the WAN port unless enabled.
        'wan-static-enable': false,
        'wan-static-address': '',
        'wan-static-prefix-length': 24,
        'wan-static-gateway': ''
      }
    };
    this.interfaces = [];
    this.modified = false;
    this.undeployedPaths = new Set();
  }

  async connectedCallback() {
    super.connectedCallback();
    await this.loadNetworkInterfaces();
  }

  async loadNetworkInterfaces() {
    try {
      const result = await getNetworkInterfaces();
      this.interfaces = result.map(iface => ({
        value: iface.name,
        label: `${iface.name} (Ethernet)`
      }));
      // Force update after interfaces load to ensure select values are set
      this.requestUpdate();
    } catch (error) {
      console.error('Failed to load network interfaces:', error);
      // Fallback to empty list
      this.interfaces = [];
    }
  }

  updated(changedProperties) {
    super.updated(changedProperties);

    // If interfaces just loaded and we have config values, force re-render
    if (changedProperties.has('interfaces') && this.interfaces.length > 0) {
      this.requestUpdate();
    }
  }

  handleFieldChange(field, value) {
    // Update config
    const newConfig = { ...this.config };
    const path = field.split('.');

    let current = newConfig;
    for (let i = 0; i < path.length - 1; i++) {
      current = current[path[i]];
    }
    current[path[path.length - 1]] = value;

    this.config = newConfig;
    this.modified = true;

    // Emit change event to parent
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { config: newConfig },
      bubbles: true,
      composed: true
    }));
  }

  // Router-mode toggle. Enabling router mode makes the static-IP settings
  // inert (the router profile owns the interfaces), so clear the opt-in in
  // the same change — otherwise a hidden, stale `static-ip-enable: true`
  // lingers in the saved config and only surfaces as a build-time warning.
  handleRouterToggle(value) {
    const newConfig = { ...this.config, network: { ...this.config.network } };
    newConfig.network['router-enable'] = value;
    if (value) newConfig.network['static-ip-enable'] = false;

    this.config = newConfig;
    this.modified = true;
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { config: newConfig },
      bubbles: true,
      composed: true
    }));
  }

  // True when `path` (a dotted config path) holds a change not yet deployed.
  _undeployed(path) {
    return this.undeployedPaths?.has(path) || false;
  }

  // Comma-separated text field -> trimmed, non-empty array (for the
  // nameservers list, which the loader expects as an array).
  _parseList(value) {
    return (value || '')
      .split(',')
      .map((v) => v.trim())
      .filter((v) => v.length > 0);
  }

  render() {
    const { network } = this.config;

    return html`
      <div class="module-container">
        <!-- Warning Box -->
        <div class="warning-box">
          <strong>⚠️ Warning</strong>
          Changing network settings may cause loss of connectivity. Ensure you have physical access to the system or an alternative connection method before making changes.
        </div>

        <!-- Router Configuration -->
        <config-section
          title="Router Configuration"
          description="Enable router functionality and configure network interfaces"
        >
          <form-field
            label="Enable Router Mode"
            type="boolean"
            .value=${network['router-enable']}
            help="Enable HomeFree to act as a router with NAT and firewall"
            ?undeployed=${this._undeployed('network.router-enable')}
            @field-change=${(e) => this.handleRouterToggle(e.detail.value)}
          ></form-field>

          ${network['router-enable'] ? html`
            <div class="field-row">
              <form-field
                label="WAN Interface"
                type="select"
                .value=${network['wan-interface']}
                .options=${this.interfaces}
                placeholder="Select WAN interface..."
                help="Interface connected to your modem/ISP"
                required
                ?undeployed=${this._undeployed('network.wan-interface')}
                @field-change=${(e) => this.handleFieldChange('network.wan-interface', e.detail.value)}
              ></form-field>

              <form-field
                label="LAN Interface"
                type="select"
                .value=${network['lan-interface']}
                .options=${this.interfaces}
                placeholder="Select LAN interface..."
                help="Interface connected to your local network"
                required
                ?undeployed=${this._undeployed('network.lan-interface')}
                @field-change=${(e) => this.handleFieldChange('network.lan-interface', e.detail.value)}
              ></form-field>
            </div>
          ` : ''}
        </config-section>

        <!-- WAN Static IP (router mode only — behind another router / double-NAT) -->
        ${network['router-enable'] ? html`
          <config-section
            title="WAN Static IP"
            description="The WAN port uses DHCP by default. Set a static WAN IP if HomeFree sits behind another router (double-NAT) that port-forwards to it."
          >
            <form-field
              label="Use a Static WAN IP"
              type="boolean"
              .value=${network['wan-static-enable']}
              help="Off = the WAN port gets its address from the upstream router via DHCP."
              ?undeployed=${this._undeployed('network.wan-static-enable')}
              @field-change=${(e) => this.handleFieldChange('network.wan-static-enable', e.detail.value)}
            ></form-field>

            ${network['wan-static-enable'] ? html`
              <div class="field-row">
                <form-field
                  label="WAN IP Address"
                  type="text"
                  .value=${network['wan-static-address']}
                  placeholder="192.168.1.50"
                  help="The fixed address on the upstream router's network."
                  required
                  ?undeployed=${this._undeployed('network.wan-static-address')}
                  @field-change=${(e) => this.handleFieldChange('network.wan-static-address', e.detail.value)}
                ></form-field>

                <form-field
                  label="Prefix Length"
                  type="number"
                  .value=${network['wan-static-prefix-length']}
                  placeholder="24"
                  help="The upstream subnet's prefix, e.g. 24."
                  ?undeployed=${this._undeployed('network.wan-static-prefix-length')}
                  @field-change=${(e) => this.handleFieldChange('network.wan-static-prefix-length', e.detail.value ? parseInt(e.detail.value) : 24)}
                ></form-field>
              </div>

              <form-field
                label="Gateway"
                type="text"
                .value=${network['wan-static-gateway']}
                placeholder="192.168.1.1"
                help="The upstream router's IP — the box's default route."
                ?undeployed=${this._undeployed('network.wan-static-gateway')}
                @field-change=${(e) => this.handleFieldChange('network.wan-static-gateway', e.detail.value)}
              ></form-field>
            ` : ''}
          </config-section>
        ` : ''}

        <!-- LAN Configuration (router mode only — the box is the DHCP server) -->
        ${network['router-enable'] ? html`
          <config-section
            title="LAN Configuration"
            description="Configure the local network address and DHCP server"
          >
            <div class="field-row">
              <form-field
                label="LAN Address"
                type="text"
                .value=${network['lan-address']}
                placeholder="10.0.0.1"
                help="IP address of this router on the LAN"
                required
                ?undeployed=${this._undeployed('network.lan-address')}
                @field-change=${(e) => this.handleFieldChange('network.lan-address', e.detail.value)}
              ></form-field>

              <form-field
                label="LAN Subnet"
                type="text"
                .value=${network['lan-subnet']}
                placeholder="10.0.0.0/24"
                help="Network subnet in CIDR notation"
                required
                ?undeployed=${this._undeployed('network.lan-subnet')}
                @field-change=${(e) => this.handleFieldChange('network.lan-subnet', e.detail.value)}
              ></form-field>
            </div>

            <div class="field-row">
              <form-field
                label="DHCP Range Start"
                type="text"
                .value=${network['dhcp-range-start']}
                placeholder="10.0.0.100"
                help="First IP in DHCP pool"
                required
                ?undeployed=${this._undeployed('network.dhcp-range-start')}
                @field-change=${(e) => this.handleFieldChange('network.dhcp-range-start', e.detail.value)}
              ></form-field>

              <form-field
                label="DHCP Range End"
                type="text"
                .value=${network['dhcp-range-end']}
                placeholder="10.0.0.200"
                help="Last IP in DHCP pool"
                required
                ?undeployed=${this._undeployed('network.dhcp-range-end')}
                @field-change=${(e) => this.handleFieldChange('network.dhcp-range-end', e.detail.value)}
              ></form-field>
            </div>
          </config-section>
        ` : ''}

        <!-- Static IP (non-router mode only — the box is a server on someone else's LAN) -->
        ${!network['router-enable'] ? html`
          <config-section
            title="Static IP"
            description="Network configuration for this box when it runs behind your own router (router mode off)."
          >
            <form-field
              label="Use a Static IP"
              type="boolean"
              .value=${network['static-ip-enable']}
              help="Off = the box takes its address from your router via DHCP."
              ?undeployed=${this._undeployed('network.static-ip-enable')}
              @field-change=${(e) => this.handleFieldChange('network.static-ip-enable', e.detail.value)}
            ></form-field>

            ${network['static-ip-enable'] ? html`
              <form-field
                label="Interface"
                type="select"
                .value=${network['static-ip-interface']}
                .options=${this.interfaces}
                placeholder="Select interface..."
                help="The NIC connected to your LAN (defaults to the LAN interface)."
                ?undeployed=${this._undeployed('network.static-ip-interface')}
                @field-change=${(e) => this.handleFieldChange('network.static-ip-interface', e.detail.value)}
              ></form-field>

              <div class="field-row">
                <form-field
                  label="IP Address"
                  type="text"
                  .value=${network['lan-address']}
                  placeholder="192.168.1.50"
                  help="This box's fixed address on your LAN."
                  required
                  ?undeployed=${this._undeployed('network.lan-address')}
                  @field-change=${(e) => this.handleFieldChange('network.lan-address', e.detail.value)}
                ></form-field>

                <form-field
                  label="Subnet"
                  type="text"
                  .value=${network['lan-subnet']}
                  placeholder="192.168.1.0/24"
                  help="Your LAN subnet in CIDR notation."
                  required
                  ?undeployed=${this._undeployed('network.lan-subnet')}
                  @field-change=${(e) => this.handleFieldChange('network.lan-subnet', e.detail.value)}
                ></form-field>
              </div>

              <div class="field-row">
                <form-field
                  label="Gateway"
                  type="text"
                  .value=${network['static-ip-gateway']}
                  placeholder="192.168.1.1"
                  help="Your router's LAN address."
                  ?undeployed=${this._undeployed('network.static-ip-gateway')}
                  @field-change=${(e) => this.handleFieldChange('network.static-ip-gateway', e.detail.value)}
                ></form-field>

                <form-field
                  label="DNS Servers"
                  type="text"
                  .value=${(network['static-ip-nameservers'] || []).join(', ')}
                  placeholder="192.168.1.1"
                  help="Comma-separated upstream DNS servers."
                  ?undeployed=${this._undeployed('network.static-ip-nameservers')}
                  @field-change=${(e) => this.handleFieldChange('network.static-ip-nameservers', this._parseList(e.detail.value))}
                ></form-field>
              </div>
            ` : ''}
          </config-section>
        ` : ''}

        <!-- Traffic Control (router mode only — shapes the box's WAN link) -->
        ${network['router-enable'] ? html`
          <config-section
            title="Traffic Control"
            description="Optional bandwidth limits for QoS (leave empty to disable)"
          >
            <div class="field-row">
              <form-field
                label="WAN Download Speed (Mbps)"
                type="number"
                .value=${network['wan-bitrate-mbps-down']}
                placeholder="100"
                help="Your ISP's download speed (optional)"
                ?undeployed=${this._undeployed('network.wan-bitrate-mbps-down')}
                @field-change=${(e) => this.handleFieldChange('network.wan-bitrate-mbps-down', e.detail.value ? parseInt(e.detail.value) : null)}
              ></form-field>

              <form-field
                label="WAN Upload Speed (Mbps)"
                type="number"
                .value=${network['wan-bitrate-mbps-up']}
                placeholder="20"
                help="Your ISP's upload speed (optional)"
                ?undeployed=${this._undeployed('network.wan-bitrate-mbps-up')}
                @field-change=${(e) => this.handleFieldChange('network.wan-bitrate-mbps-up', e.detail.value ? parseInt(e.detail.value) : null)}
              ></form-field>
            </div>
          </config-section>
        ` : ''}

        <!-- Ad Blocking -->
        <config-section
          title="System Ad Blocking"
          description="Built-in ad and tracker blocking at the system level. Not necessary when AdGuard Home is running — AdGuard already provides network-wide ad blocking with a friendlier interface."
        >
          <form-field
            label="Enable System Ad Blocking"
            type="boolean"
            .value=${network['enable-unbound-adblock']}
            help="Leave off if AdGuard Home is enabled."
            ?undeployed=${this._undeployed('network.enable-unbound-adblock')}
            @field-change=${(e) => this.handleFieldChange('network.enable-unbound-adblock', e.detail.value)}
          ></form-field>
        </config-section>
      </div>
    `;
  }
}

customElements.define('network-module', NetworkModule);
