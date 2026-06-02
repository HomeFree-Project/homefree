import { LitElement, html, css } from 'lit';
import '../../shared/config-section.js';
import '../../shared/form-field.js';

/**
 * Privacy module.
 *
 * Single page that surfaces every box-wide knob controlling whether
 * (and where) the box reaches third-party services. Two sections:
 *
 *   1. External services — homefree.privacy.externalServices.* —
 *      the public-IP URL the alerts WAN-check uses, the DoH endpoint
 *      its DNS-leak check uses, and the optional elevation lookup
 *      URL the lat/lng picker proxies through admin-api. The first
 *      two have sensible defaults; the third is null (disabled) by
 *      default and the operator enables by pointing it at an
 *      upstream.
 *
 *   2. CDN / Edge fronting (Layer 7 of the surge-resilience stack)
 *      — homefree.services.landing-page.edge.* — opt-in third-party
 *      CDN in front of the public landing page. Operator-side
 *      setup (DNS, origin-pull, Transform Rule) is documented at
 *      docs/agent-notes/landing-page-edge-fronting.md.
 *
 * Both sections live here because they're the same shape — single-
 * source-of-truth for "does this box reach out, and to where" — and
 * because they should share a Privacy nav surface, not be scattered
 * across System / Networking / etc. The deeper rule (no asset loads
 * from third parties on any HomeFree-served PAGE) is enforced at
 * build time per AGENTS.md rule 8 and has no opt-in.
 */
class PrivacyModule extends LitElement {
  static properties = {
    config: { type: Object },
    appliedConfig: { attribute: false },
    undeployedPaths: { attribute: false },
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
      line-height: 1.55;
    }
    .help-box strong { color: var(--hf-text); }
    .help-box > strong:first-child {
      display: block;
      margin-bottom: 6px;
      font-size: 14px;
    }
    .help-box code {
      background: var(--hf-surface-2);
      padding: 1px 5px;
      border-radius: 3px;
      font-family: var(--hf-font-mono, monospace);
      font-size: 12px;
    }
    .field-grid {
      display: grid;
      grid-template-columns: 1fr;
      gap: 14px;
      margin: 4px 0 8px 0;
    }
    @media (min-width: 720px) {
      .field-grid.two-col { grid-template-columns: 1fr 1fr; }
    }
    .cidr-block label {
      display: block;
      font-size: 13px;
      font-weight: 500;
      color: var(--hf-text);
      margin-bottom: 4px;
    }
    .cidr-block textarea {
      width: 100%;
      min-height: 92px;
      padding: 9px 12px;
      font-size: 12px;
      font-family: var(--hf-font-mono, monospace);
      border: 1px solid var(--hf-border-2);
      border-radius: 6px;
      background: var(--hf-bg);
      color: var(--hf-text);
      box-sizing: border-box;
      resize: vertical;
    }
    .cidr-block .help {
      font-size: 12px;
      color: var(--hf-text-muted);
      margin-top: 4px;
      line-height: 1.45;
    }
    .cidr-block[data-undeployed='true'] textarea {
      border-color: var(--hf-warn, #c2870a);
      box-shadow: 0 0 0 2px rgba(194, 135, 10, 0.12);
    }
    .section-note {
      font-size: 12px;
      color: var(--hf-text-muted);
      margin: -4px 0 12px 0;
      line-height: 1.5;
    }
    .section-note a { color: var(--hf-accent); }
  `;

  constructor() {
    super();
    this.config = {};
    this.appliedConfig = null;
    this.undeployedPaths = new Set();
  }

  _undeployed(path) {
    return this.undeployedPaths?.has(path) || false;
  }

  // --- Mutators ----------------------------------------------------
  //
  // Each handler emits a config-change event carrying the WHOLE
  // sub-tree it owns (privacy.*, or services.landing-page.*), so
  // admin-app's shallow merge in getMergedConfig() doesn't drop
  // sibling keys. See the alerts-module pattern; same shape.

  _setPrivacyField(group, value) {
    const prev = this.config.privacy?.externalServices || {};
    const nextPrivacy = {
      ...(this.config.privacy || {}),
      externalServices: {
        ...prev,
        [group]: { ...(prev[group] || {}), url: value },
      },
    };
    this.config = { ...this.config, privacy: nextPrivacy };
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { module: 'privacy', config: { privacy: nextPrivacy } },
      bubbles: true,
      composed: true,
    }));
  }

  _setEdgeField(field, value) {
    const services = { ...(this.config.services || {}) };
    const current = services['landing-page'] || {};
    const currentEdge = current.edge || {};
    services['landing-page'] = {
      ...current,
      edge: { ...currentEdge, [field]: value },
    };
    this.config = { ...this.config, services };
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { module: 'privacy', config: { services } },
      bubbles: true,
      composed: true,
    }));
  }

  _setHeadscaleField(field, value) {
    const services = { ...(this.config.services || {}) };
    const current = services.headscale || {};
    services.headscale = { ...current, [field]: value };
    this.config = { ...this.config, services };
    this.dispatchEvent(new CustomEvent('config-change', {
      detail: { module: 'privacy', config: { services } },
      bubbles: true,
      composed: true,
    }));
  }

  // --- Section renderers ------------------------------------------

  _renderExternalServices() {
    const ext = this.config.privacy?.externalServices || {};
    const publicIp = ext.publicIp?.url ?? '';
    const doh = ext.doh?.url ?? '';
    const elevation = ext.elevation?.url ?? '';

    return html`
      <config-section
        title="External services"
        description="Every third-party endpoint the box may contact as part of a feature."
      >
        <div class="section-note">
          Asset loads on web pages (fonts, scripts, images) are
          NEVER fetched from third parties on any HomeFree-served
          page; that's enforced at build time and has no toggle.
          The settings here are for FEATURES that need an external
          data source by nature: WAN-reachability checks, DNS-leak
          detection against a public resolver, optional elevation
          lookup for the lat/lng picker. All such calls are
          proxied through admin-api when configured, so it's the
          BOX's egress IP that touches the upstream, never the
          visitor's browser.
        </div>
        <div class="field-grid">
          <form-field
            label="Public IP URL"
            type="text"
            .value=${publicIp}
            placeholder="https://ipinfo.io/ip"
            help="Plain-text endpoint that returns the box's egress IP. Used by the alerts WAN-reachability watcher."
            ?undeployed=${this._undeployed('privacy.externalServices.publicIp.url')}
            @field-change=${(e) => this._setPrivacyField('publicIp', e.detail.value)}
          ></form-field>
          <form-field
            label="DoH endpoint"
            type="text"
            .value=${doh}
            placeholder="https://cloudflare-dns.com/dns-query"
            help="DNS-over-HTTPS JSON endpoint. Used by the alerts DNS-leak check to compare against your local resolver."
            ?undeployed=${this._undeployed('privacy.externalServices.doh.url')}
            @field-change=${(e) => this._setPrivacyField('doh', e.detail.value)}
          ></form-field>
          <form-field
            label="Elevation lookup URL (optional)"
            type="text"
            .value=${elevation}
            placeholder="disabled — leave empty"
            help="Open-Meteo URL template with {lat} / {lon} placeholders. Empty = elevation lookup feature is disabled (the lat/lng picker still works for manual entry). Example: https://api.open-meteo.com/v1/elevation?latitude={lat}&longitude={lon}"
            ?undeployed=${this._undeployed('privacy.externalServices.elevation.url')}
            @field-change=${(e) => this._setPrivacyField('elevation', e.detail.value)}
          ></form-field>
        </div>
      </config-section>
    `;
  }

  _renderEdgeFronting() {
    const edge = this.config.services?.['landing-page']?.edge || {};
    const enabled = edge.enable === true;
    const provider = edge.provider || 'cloudflare';
    const trustedProxiesText = Array.isArray(edge.trustedProxies)
      ? edge.trustedProxies.join('\n')
      : '';
    const originSecretEnv = edge.originSharedSecretEnv ?? '';

    return html`
      <config-section
        title="CDN / Edge fronting"
        description="Opt-in: put a third-party CDN in front of the public landing page (Layer 7 of the surge-resilience stack)."
      >
        <div class="section-note">
          The on-box defences (vendored assets, hashed-asset
          caching, per-IP connection caps, Caddy rate-limit, cgroup
          bounds) handle a Hacker News hit on a box with reasonable
          uplink. They cannot help on a 25-50 Mbps residential
          up-link &mdash; once the pipe saturates, only an edge with
          more bandwidth than yours can keep the site up. Enabling
          this option configures the ORIGIN side only; you still
          have to do the CDN-side setup (DNS, origin-pull,
          Transform Rule injecting the shared secret).
          See <code>docs/agent-notes/landing-page-edge-fronting.md</code>
          for the operator walkthrough.
        </div>

        <div class="field-grid two-col">
          <form-field
            label="Enable edge fronting"
            type="boolean"
            .value=${enabled}
            help="When on: trusts the provider's CIDRs to set X-Forwarded-For, requires the shared-secret header on every request, and emits Vary: Cookie."
            ?undeployed=${this._undeployed('services.landing-page.edge.enable')}
            @field-change=${(e) => this._setEdgeField('enable', !!e.detail.value)}
          ></form-field>
          <form-field
            label="Provider"
            type="select"
            .value=${provider}
            .options=${[
              { value: 'cloudflare', label: 'Cloudflare' },
              { value: 'bunny', label: 'bunny.net' },
              { value: 'custom', label: 'Custom (set CIDRs below)' },
            ]}
            help="Determines the built-in trusted_proxies CIDR list. Custom requires the list below."
            ?disabled=${!enabled}
            ?undeployed=${this._undeployed('services.landing-page.edge.provider')}
            @field-change=${(e) => this._setEdgeField('provider', e.detail.value)}
          ></form-field>
        </div>

        <div
          class="cidr-block"
          data-undeployed=${String(this._undeployed('services.landing-page.edge.trustedProxies'))}
          style="margin-top: 14px"
        >
          <label>Additional trusted-proxy CIDRs (one per line)</label>
          <textarea
            ?disabled=${!enabled}
            .value=${trustedProxiesText}
            placeholder="${provider === 'custom'
              ? '198.51.100.0/24\n2001:db8::/32'
              : 'Leave empty to use the provider built-ins only.'}"
            @input=${(e) => {
              const list = e.target.value
                .split(/[\n,]/)
                .map((s) => s.trim())
                .filter(Boolean);
              this._setEdgeField('trustedProxies', list);
            }}
          ></textarea>
          <div class="help">
            ${provider === 'custom'
              ? 'Required: paste your CDN provider\'s edge CIDRs here.'
              : 'Concatenated with the built-in list for the selected provider. Usually empty.'}
          </div>
        </div>

        <div class="field-grid" style="margin-top: 14px">
          <form-field
            label="Origin shared-secret env var name"
            type="text"
            .value=${originSecretEnv}
            placeholder="EDGE_ORIGIN_SECRET"
            help="Name of an environment variable Caddy loads from /etc/default/caddy. The CDN must inject the same value as the X-Edge-Origin-Auth header on every origin pull, else Caddy returns 403. Leaving this empty disables the origin-bypass check (strongly discouraged — without it the CDN gives no real protection)."
            ?disabled=${!enabled}
            ?undeployed=${this._undeployed('services.landing-page.edge.originSharedSecretEnv')}
            @field-change=${(e) => this._setEdgeField('originSharedSecretEnv', e.detail.value || null)}
          ></form-field>
        </div>
      </config-section>
    `;
  }

  _renderVpnRelay() {
    const headscale = this.config.services?.headscale || {};
    const headscaleEnabled = headscale.enable === true;
    const usePublicDerp = headscale['enable-public-derp-fallback'] === true;

    return html`
      <config-section
        title="VPN relay fallback (Tailscale DERP)"
        description="Whether the headscale VPN may relay through Tailscale's public DERP servers when the box's embedded relay can't be reached."
      >
        <div class="section-note">
          The box always runs its own embedded DERP relay; clients
          that can reach the box (almost always the case for a
          phone↔home tunnel) never touch Tailscale's infrastructure.
          The fallback only matters in the rare double-roaming case
          where two clients can't reach each other directly AND can't
          reach the embedded relay. When this is OFF, headscale also
          stops periodically fetching the public DERP map from
          <code>controlplane.tailscale.com</code> &mdash; no egress
          to Tailscale at all, and no periodic control-plane churn
          that causes mobile clients to drop their long-poll.
        </div>
        <div class="field-grid">
          <form-field
            label="Allow Tailscale public DERP fallback"
            type="boolean"
            .value=${usePublicDerp}
            ?disabled=${!headscaleEnabled}
            help=${headscaleEnabled
              ? 'OFF: complete independence from Tailscale (embedded DERP only). ON: refresh map once every 24h.'
              : 'Headscale is not enabled on this box. Enable it under Services first to use this option.'}
            ?undeployed=${this._undeployed('services.headscale.enable-public-derp-fallback')}
            @field-change=${(e) => this._setHeadscaleField('enable-public-derp-fallback', !!e.detail.value)}
          ></form-field>
        </div>
      </config-section>
    `;
  }

  render() {
    return html`
      <div class="module-container">
        <div class="help-box">
          <strong>Privacy &amp; external services</strong>
          One page for every box-wide knob controlling whether (and
          where) the box reaches third parties. The HomeFree
          promise is that the box doesn't leak by default; this is
          where you audit and adjust the exceptions.
        </div>

        ${this._renderExternalServices()}
        ${this._renderVpnRelay()}
        ${this._renderEdgeFronting()}
      </div>
    `;
  }
}

customElements.define('privacy-module', PrivacyModule);
