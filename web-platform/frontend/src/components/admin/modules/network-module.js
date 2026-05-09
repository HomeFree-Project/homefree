import { LitElement, html, css } from 'lit';
import '../../shared/config-section.js';
import '../../shared/form-field.js';
import '../../shared/table-editor.js';
import { getNetworkInterfaces } from '../../../api/client.js';

/**
 * Network configuration module
 * Handles: WAN/LAN interfaces, router settings, DHCP, static IPs, ad-blocking
 */
class NetworkModule extends LitElement {
  static properties = {
    config: { type: Object },
    interfaces: { type: Array },
    modified: { type: Boolean }
  };

  static styles = css`
    :host {
      display: block;
    }

    .module-container {
      width: 100%;
    }

    .field-row {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 20px;
    }

    @media (max-width: 768px) {
      .field-row {
        grid-template-columns: 1fr;
      }
    }

    .warning-box {
      background: rgba(245, 158, 11, 0.1);
      border-left: 4px solid var(--hf-warn);
      padding: 16px;
      border-radius: 8px;
      margin-bottom: 20px;
      color: var(--hf-warn);
      max-width: 1200px;
    }

    .warning-box strong {
      display: block;
      margin-bottom: 8px;
      font-size: 16px;
    }
  `;

  constructor() {
    super();
    this.config = {
      network: {
        wan_interface: '',
        lan_interface: '',
        router_enable: false,
        lan_address: '10.0.0.1',
        lan_subnet: '10.0.0.0/24',
        dhcp_range_start: '10.0.0.100',
        dhcp_range_end: '10.0.0.200',
        enable_adblock: false,
        wan_bitrate_mbps_down: null,
        wan_bitrate_mbps_up: null,
        static_ips: []
      }
    };
    this.interfaces = [];
    this.modified = false;
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

  handleStaticIpsChange(e) {
    this.handleFieldChange('network.static_ips', e.detail.data);
  }

  render() {
    const { network } = this.config;

    // Static IP table columns
    const staticIpColumns = [
      { key: 'mac_address', label: 'MAC Address', type: 'text', placeholder: '00:11:22:33:44:55' },
      { key: 'hostname', label: 'Hostname', type: 'text', placeholder: 'device-name' },
      { key: 'ip', label: 'IP Address', type: 'text', placeholder: '10.0.0.50' },
      { key: 'wan_access', label: 'WAN Access', type: 'boolean' }
    ];

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
            .value=${network.router_enable}
            help="Enable HomeFree to act as a router with NAT and firewall"
            @field-change=${(e) => this.handleFieldChange('network.router_enable', e.detail.value)}
          ></form-field>

          <div class="field-row">
            <form-field
              label="WAN Interface"
              type="select"
              .value=${network.wan_interface}
              .options=${this.interfaces}
              placeholder="Select WAN interface..."
              help="Interface connected to your modem/ISP"
              required
              @field-change=${(e) => this.handleFieldChange('network.wan_interface', e.detail.value)}
            ></form-field>

            <form-field
              label="LAN Interface"
              type="select"
              .value=${network.lan_interface}
              .options=${this.interfaces}
              placeholder="Select LAN interface..."
              help="Interface connected to your local network"
              required
              @field-change=${(e) => this.handleFieldChange('network.lan_interface', e.detail.value)}
            ></form-field>
          </div>
        </config-section>

        <!-- LAN Configuration -->
        <config-section
          title="LAN Configuration"
          description="Configure the local network address and DHCP server"
        >
          <div class="field-row">
            <form-field
              label="LAN Address"
              type="text"
              .value=${network.lan_address}
              placeholder="10.0.0.1"
              help="IP address of this router on the LAN"
              required
              @field-change=${(e) => this.handleFieldChange('network.lan_address', e.detail.value)}
            ></form-field>

            <form-field
              label="LAN Subnet"
              type="text"
              .value=${network.lan_subnet}
              placeholder="10.0.0.0/24"
              help="Network subnet in CIDR notation"
              required
              @field-change=${(e) => this.handleFieldChange('network.lan_subnet', e.detail.value)}
            ></form-field>
          </div>

          <div class="field-row">
            <form-field
              label="DHCP Range Start"
              type="text"
              .value=${network.dhcp_range_start}
              placeholder="10.0.0.100"
              help="First IP in DHCP pool"
              required
              @field-change=${(e) => this.handleFieldChange('network.dhcp_range_start', e.detail.value)}
            ></form-field>

            <form-field
              label="DHCP Range End"
              type="text"
              .value=${network.dhcp_range_end}
              placeholder="10.0.0.200"
              help="Last IP in DHCP pool"
              required
              @field-change=${(e) => this.handleFieldChange('network.dhcp_range_end', e.detail.value)}
            ></form-field>
          </div>
        </config-section>

        <!-- Static IP Assignments -->
        <config-section
          title="Static IP Assignments"
          description="Reserve specific IP addresses for devices by MAC address"
        >
          <table-editor
            .columns=${staticIpColumns}
            .data=${network.static_ips || []}
            addLabel="Add Static IP"
            @data-change=${this.handleStaticIpsChange}
          ></table-editor>
        </config-section>

        <!-- Traffic Control -->
        <config-section
          title="Traffic Control"
          description="Optional bandwidth limits for QoS (leave empty to disable)"
        >
          <div class="field-row">
            <form-field
              label="WAN Download Speed (Mbps)"
              type="number"
              .value=${network.wan_bitrate_mbps_down}
              placeholder="100"
              help="Your ISP's download speed (optional)"
              @field-change=${(e) => this.handleFieldChange('network.wan_bitrate_mbps_down', e.detail.value ? parseInt(e.detail.value) : null)}
            ></form-field>

            <form-field
              label="WAN Upload Speed (Mbps)"
              type="number"
              .value=${network.wan_bitrate_mbps_up}
              placeholder="20"
              help="Your ISP's upload speed (optional)"
              @field-change=${(e) => this.handleFieldChange('network.wan_bitrate_mbps_up', e.detail.value ? parseInt(e.detail.value) : null)}
            ></form-field>
          </div>
        </config-section>

        <!-- Ad Blocking -->
        <config-section
          title="Ad Blocking"
          description="Network-wide advertisement and tracker blocking via DNS"
        >
          <form-field
            label="Enable Ad Blocking"
            type="boolean"
            .value=${network.enable_adblock}
            help="Block ads and trackers for all devices on the network"
            @field-change=${(e) => this.handleFieldChange('network.enable_adblock', e.detail.value)}
          ></form-field>
        </config-section>
      </div>
    `;
  }
}

customElements.define('network-module', NetworkModule);
