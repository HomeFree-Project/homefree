import { LitElement, html, css } from 'lit';

/**
 * Wiring walkthrough step.
 *
 * Shown right after the network/eth-port selection. Purely instructional —
 * no secret entry, so the kiosk copy-paste limitation does not apply. It walks
 * the operator through the physical setup their selected mode requires:
 *
 *   - Router mode (default): modem in bridge/passthrough mode -> HomeFree WAN
 *     port; HomeFree LAN port -> switch / Wi-Fi access point (AP in bridge
 *     mode). HomeFree is the router and firewall for the home network.
 *
 *   - App-server mode (future): router/firewall disabled, the box sits behind
 *     an existing router on the home LAN. A single uplink, no bridge-mode
 *     instructions. Not yet wired into the installer — the branch is here so
 *     it is a drop-in once `data.routerEnable === false` is produced upstream.
 *
 * Per-ISP bridge-mode text mirrors
 * services/landing-page/site/src/manual/hardware-setup.md (one source of truth).
 */
class WiringStep extends LitElement {
  static properties = {
    data: { type: Object },
  };

  static styles = css`
    :host { display: block; }

    .container {
      max-width: 720px;
      margin: 0 auto;
    }

    h2 {
      font-size: 28px;
      color: #333;
      margin-bottom: 8px;
    }

    .intro {
      font-size: 15px;
      color: #666;
      line-height: 1.6;
      margin-bottom: 24px;
    }

    .diagram {
      background: #f8f9fa;
      border: 1px solid #e3e6ea;
      border-radius: 8px;
      padding: 20px;
      margin-bottom: 24px;
    }

    .diagram svg { display: block; width: 100%; height: auto; }

    .steps {
      counter-reset: wiring;
      list-style: none;
      padding: 0;
      margin: 0 0 24px;
    }

    .steps li {
      position: relative;
      padding: 12px 0 12px 44px;
      border-bottom: 1px solid #eef0f2;
      color: #444;
      font-size: 15px;
      line-height: 1.5;
    }

    .steps li:last-child { border-bottom: none; }

    .steps li::before {
      counter-increment: wiring;
      content: counter(wiring);
      position: absolute;
      left: 0;
      top: 12px;
      width: 28px;
      height: 28px;
      border-radius: 50%;
      background: #667eea;
      color: white;
      font-weight: bold;
      font-size: 14px;
      display: flex;
      align-items: center;
      justify-content: center;
    }

    .isp {
      background: #fff8e6;
      border-left: 4px solid #f5bf42;
      border-radius: 6px;
      padding: 16px 20px;
      margin-bottom: 16px;
    }

    .isp h3 {
      margin: 0 0 10px;
      font-size: 15px;
      color: #333;
    }

    .isp dl { margin: 0; }
    .isp dt { font-weight: 600; color: #444; margin-top: 8px; font-size: 14px; }
    .isp dd { margin: 2px 0 0; color: #666; font-size: 14px; line-height: 1.5; }

    .note {
      font-size: 14px;
      color: #888;
      font-style: italic;
    }

    /* Marks a step / diagram element that is optional. */
    .optional-tag {
      display: inline-block;
      font-size: 11px;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      color: #667eea;
      background: #eef0ff;
      border-radius: 4px;
      padding: 2px 7px;
      margin-left: 6px;
      vertical-align: middle;
    }
  `;

  /**
   * Router mode is the current default. App-server mode is a planned future
   * mode; treat an explicit `routerEnable === false` as the signal for it.
   * Until upstream produces that flag, this always evaluates to router mode.
   */
  get isRouterMode() {
    return this.data?.routerEnable !== false;
  }

  render() {
    return html`
      <div class="container">
        ${this.isRouterMode ? this.renderRouterMode() : this.renderAppServerMode()}
      </div>
    `;
  }

  // --- Router mode ---------------------------------------------------------
  renderRouterMode() {
    return html`
      <h2>Connect your hardware</h2>
      <p class="intro">
        In router mode, HomeFree is the router and firewall for your home.
        Your internet modem must be in <strong>bridge</strong> (or
        <strong>passthrough</strong>) mode so HomeFree handles the connection
        directly. Follow the diagram and steps below before continuing.
      </p>

      <div class="diagram">${this.routerSvg()}</div>

      <p class="note">
        The switch in the dashed box is optional. If you only use Wi-Fi,
        plug your Wi-Fi access point straight into HomeFree's LAN port. Add
        a switch when you have wired devices, or more things to plug in than
        HomeFree's single LAN port allows.
      </p>

      <ol class="steps">
        <li>
          Put your <strong>modem</strong> into bridge / passthrough mode
          (see your provider below) and disable its built-in Wi-Fi.
        </li>
        <li>
          Run an Ethernet cable from the modem to HomeFree's
          <strong>WAN</strong> port (the interface you selected as WAN).
        </li>
        <li>
          Connect your <strong>Wi-Fi access point</strong> to HomeFree's
          <strong>LAN</strong> port and set it to
          <strong>bridge / access-point mode</strong> (its own routing and
          DHCP turned off — HomeFree provides those).
        </li>
        <li>
          <span class="optional-tag">Optional</span>
          To connect wired devices, or more than one thing, put an
          <strong>unmanaged Ethernet switch</strong> on HomeFree's LAN port
          and plug the access point and wired devices into the switch
          instead.
        </li>
        <li>
          Power on the modem first, wait ~2 minutes, then power on HomeFree.
        </li>
      </ol>

      <div class="isp">
        <h3>Setting your modem to bridge mode</h3>
        <dl>
          <dt>Spectrum / Charter</dt>
          <dd>
            Usually already in bridge mode. Connect HomeFree, then
            power-cycle the modem so it hands the connection over.
          </dd>
          <dt>Xfinity / Verizon / most others</dt>
          <dd>
            Enable bridge mode in the provider's app or admin page, and
            turn off the modem's Wi-Fi.
          </dd>
          <dt>AT&amp;T Fiber</dt>
          <dd>
            Use "IP Passthrough" in the gateway settings: Allocation Mode →
            Passthrough, Passthrough Mode → DHCPS-fixed, and set the fixed
            MAC to HomeFree's WAN port MAC. Disable the gateway's packet
            filters and firewall.
          </dd>
        </dl>
      </div>

      <p class="note">
        Skipping or mis-wiring this won't stop the install, but HomeFree
        won't have working internet or be able to serve your network until
        the modem is bridged and cables match the diagram.
      </p>
    `;
  }

  // --- App-server mode (future) -------------------------------------------
  renderAppServerMode() {
    return html`
      <h2>Connect your hardware</h2>
      <p class="intro">
        In app-server mode, HomeFree's router and firewall are disabled and
        the box sits behind your existing router. It needs just one network
        connection to your home LAN.
      </p>

      <div class="diagram">${this.appServerSvg()}</div>

      <ol class="steps">
        <li>
          Run an Ethernet cable from your existing router (or a switch on
          your home network) to HomeFree's network port.
        </li>
        <li>
          Leave your existing router in charge of DHCP and internet — no
          bridge mode is needed.
        </li>
        <li>
          Power on HomeFree. It will pick up an address from your router.
        </li>
      </ol>

      <p class="note">
        No modem changes are required in app-server mode.
      </p>
    `;
  }

  // --- SVG diagrams --------------------------------------------------------
  routerSvg() {
    // modem -> WAN -> HomeFree -> LAN -> Wi-Fi AP, with an OPTIONAL switch
    // (drawn in a dashed "optional" box) that can sit on the LAN port to
    // fan out to the AP plus wired devices. The straight modem->HomeFree->AP
    // path reads on its own for a Wi-Fi-only home; the dashed group teaches
    // the switch option without forcing a choice.
    return html`
      <svg viewBox="0 0 700 300" xmlns="http://www.w3.org/2000/svg"
           role="img"
           aria-label="Router-mode wiring diagram. Modem connects to
             HomeFree's WAN port; HomeFree's LAN port connects to a Wi-Fi
             access point. An optional Ethernet switch can sit on the LAN
             port to also connect wired devices.">
        <defs>
          <style>
            .box { fill: #ffffff; stroke: #667eea; stroke-width: 2; }
            .hf  { fill: #eef0ff; stroke: #4c51bf; stroke-width: 2.5; }
            .lbl { font: 600 13px sans-serif; fill: #333; }
            .sub { font: 11px sans-serif; fill: #888; }
            .wire { stroke: #4c51bf; stroke-width: 2.5; fill: none; }
            .port { font: 700 10px sans-serif; fill: #4c51bf; }
            /* Optional elements: dashed, slightly muted. */
            .opt-box  { fill: #fafbff; stroke: #9aa3e8; stroke-width: 2;
                        stroke-dasharray: 5 4; }
            .opt-wire { stroke: #9aa3e8; stroke-width: 2;
                        stroke-dasharray: 5 4; fill: none; }
            .opt-lbl  { font: 700 10px sans-serif; fill: #667eea;
                        letter-spacing: 0.04em; }
          </style>
        </defs>

        <!-- Modem -->
        <rect class="box" x="20" y="36" width="110" height="56" rx="8"/>
        <text class="lbl" x="75" y="61" text-anchor="middle">Modem</text>
        <text class="sub" x="75" y="78" text-anchor="middle">bridge mode</text>

        <!-- wire modem -> HomeFree WAN -->
        <path class="wire" d="M130 64 H 230"/>
        <text class="port" x="180" y="56" text-anchor="middle">WAN</text>

        <!-- HomeFree -->
        <rect class="hf" x="230" y="28" width="150" height="72" rx="10"/>
        <text class="lbl" x="305" y="58" text-anchor="middle">HomeFree</text>
        <text class="sub" x="305" y="76" text-anchor="middle">router + firewall</text>

        <!-- wire HomeFree LAN -> Wi-Fi AP (the basic, Wi-Fi-only path) -->
        <path class="wire" d="M380 64 H 510"/>
        <text class="port" x="445" y="56" text-anchor="middle">LAN</text>

        <!-- Wi-Fi AP -->
        <rect class="box" x="510" y="36" width="150" height="56" rx="8"/>
        <text class="lbl" x="585" y="61" text-anchor="middle">Wi-Fi access point</text>
        <text class="sub" x="585" y="78" text-anchor="middle">bridge / AP mode</text>

        <!-- ===== Optional switch group (dashed) ===== -->
        <!-- Dashed enclosure -->
        <rect class="opt-box" x="250" y="150" width="430" height="130" rx="10"/>
        <text class="opt-lbl" x="266" y="170">OPTIONAL — ADD A SWITCH FOR WIRED DEVICES</text>

        <!-- Branch off the LAN wire at HomeFree's edge, drop down, then run
             right into the switch's LEFT edge. Data enters the switch on
             the left and fans out on the right — clean left-to-right flow. -->
        <path class="opt-wire" d="M385 64 V 224 H 430"/>

        <!-- Switch (input on the left, outputs on the right) -->
        <rect class="opt-box" x="430" y="196" width="110" height="56" rx="8"/>
        <text class="lbl" x="485" y="228" text-anchor="middle">Switch</text>

        <!-- switch -> Wi-Fi AP (out the right edge) -->
        <path class="opt-wire" d="M540 212 H 580"/>
        <rect class="opt-box" x="580" y="190" width="90" height="44" rx="8"/>
        <text class="lbl" x="625" y="216" text-anchor="middle">Wi-Fi AP</text>

        <!-- switch -> wired devices (out the right edge) -->
        <path class="opt-wire" d="M540 236 H 580"/>
        <rect class="opt-box" x="580" y="240" width="90" height="34" rx="8"/>
        <text class="lbl" x="625" y="261" text-anchor="middle">Wired</text>
      </svg>
    `;
  }

  appServerSvg() {
    // existing router -> HomeFree (single uplink)
    return html`
      <svg viewBox="0 0 560 140" xmlns="http://www.w3.org/2000/svg"
           role="img" aria-label="App-server-mode wiring diagram">
        <defs>
          <style>
            .box { fill: #ffffff; stroke: #667eea; stroke-width: 2; }
            .hf  { fill: #eef0ff; stroke: #4c51bf; stroke-width: 2.5; }
            .lbl { font: 600 13px sans-serif; fill: #333; }
            .sub { font: 11px sans-serif; fill: #888; }
            .wire { stroke: #4c51bf; stroke-width: 2.5; fill: none; }
          </style>
        </defs>

        <rect class="box" x="30" y="44" width="150" height="56" rx="8"/>
        <text class="lbl" x="105" y="68" text-anchor="middle">Existing router</text>
        <text class="sub" x="105" y="85" text-anchor="middle">DHCP + internet</text>

        <path class="wire" d="M180 72 H 360"/>

        <rect class="hf" x="360" y="40" width="160" height="64" rx="10"/>
        <text class="lbl" x="440" y="68" text-anchor="middle">HomeFree</text>
        <text class="sub" x="440" y="85" text-anchor="middle">app-server mode</text>
      </svg>
    `;
  }
}

customElements.define('wiring-step', WiringStep);
