{ config, lib, pkgs, homefree-inputs, ... }:
let
  cfg = config.homefree;
  lan-address = config.homefree.network.lan-address;
  lan-subnet = config.homefree.network.lan-subnet;
  lan-subnet-prefix = lib.head (lib.splitString "/" lan-subnet);  # Extract "10.0.0.0" from "10.0.0.0/24"
  search-domains = [ cfg.system.domain cfg.system.localDomain ] ++ cfg.system.additionalDomains;
  proxiedDomains = config.homefree.proxied-domains;

  # Extract unique base domains from proxied domains (handle wildcards like *.example.com)
  proxiedBaseDomains = lib.unique (lib.map (domain:
    let
      parts = lib.splitString "." domain;
      cleanParts = lib.filter (p: p != "*") parts;
      len = lib.length cleanParts;
    in
      lib.concatStringsSep "." (lib.sublist (if len > 2 then len - 2 else 0) 2 cleanParts)
  ) (lib.flatten (lib.map (dm: dm.domains) proxiedDomains)));

  # Split DNS: only LAN-only internal TLDs (.lan, .homefree.lan).
  # The public domain (cypy.at) is intentionally excluded so that *.cypy.at
  # resolves via public DNS on any network — no VPN or LAN access required.
  # Private services (photos, music, etc.) are accessible via .lan names over VPN,
  # or directly on home WiFi where 10.0.0.1 is reachable.
  all-split-domains = lib.filter (d: d != cfg.system.domain) (lib.unique ([ cfg.system.localDomain ] ++ cfg.system.additionalDomains));
  ## See: https://headscale.net/stable/ref/acls/
  ## @TODO: Doesn't seem to work, may even block all traffic not explicitly approved.
  policy = pkgs.writeText "headscale-policy.json" ''
    {
      "hosts": {
        "homefree.lan": "${lan-address}/32"
      },
      "autoApprovers": {
        "routes": {
          "${lan-subnet}": [
            "homefree.lan"
          ]
        }
      }
    }
  '';

  headscaleEnabled = config.homefree.service-options.headscale.enable;

  ## headscale.service is Type=simple: systemd marks it "started" the
  ## instant the process forks, which is *before* it has opened its DB
  ## and bound the gRPC/HTTP listener (observed ~11s of setup — DERP
  ## region init etc. — between fork and "listening and serving HTTP").
  ## Any oneshot ordered `after headscale.service` that drives the
  ## headscale CLI therefore races that gap: the CLI connects to a
  ## not-yet-listening socket and dies with "context deadline exceeded"
  ## (its own 10s client timeout). At boot the oneshot just retries and
  ## eventually wins, but on a `nixos-rebuild switch` a failed oneshot
  ## makes switch-to-configuration return exit 4. The fix is a bounded
  ## readiness poll: hammer a cheap, side-effect-free CLI call (`users
  ## list`) until it succeeds before doing real work. This is the
  ## process-readiness-vs-unit-started pattern from
  ## docs/agent-notes/systemd-unit-patterns.md, applied to a daemon
  ## rather than a podman container. Shared by both mint units.
  waitForHeadscale = ''
    ## Wait up to ~120s for headscale to actually answer its API. We
    ## poll `users list` (read-only, no side effects) rather than trust
    ## systemd's "started". Falls through with a loud message if it
    ## never comes up — the caller's subsequent CLI call will then fail
    ## for real and surface the underlying problem.
    for i in $(${pkgs.coreutils}/bin/seq 1 60); do
      if ${pkgs.headscale}/bin/headscale users list -o json >/dev/null 2>&1; then
        break
      fi
      if [ "$i" = 60 ]; then
        echo "wait-for-headscale: headscale API still not answering after ~120s; proceeding anyway" >&2
      fi
      ${pkgs.coreutils}/bin/sleep 2
    done
  '';

  headplane-port = config.homefree.allocPort "headscale-headplane";

  ## Per-secret files for SOPS-managed secrets — same pattern as
  ## services/zitadel-podman.nix. The cookie secret is the one
  ## exception: it doesn't *need* to be SOPS-managed because losing it
  ## just invalidates active sessions, so we auto-generate it on first
  ## boot if absent (see headplaneCookiePreStart below). The OIDC creds
  ## and the headscale API key, in contrast, must be set deliberately.
  headplaneSecretsDir = "/var/lib/homefree-secrets/headscale";

  ## Anchors auto-generated secrets into encrypted /etc/nixos/secrets
  ## so they survive a restore — see lib/secrets-anchor.nix.
  anchor = import ../../lib/secrets-anchor.nix { inherit lib pkgs; };

  ## OIDC config is always rendered into the headplane YAML. The
  ## headplane.service unit gates on file presence via
  ## ConditionPathExists, so it stays inactive until
  ## zitadel-provision.service writes the three secret files
  ## (oidc-client-id, oidc-client-secret, headscale-api-key) and
  ## try-restarts the unit. Single-rebuild fresh-install UX —
  ## previously we used a build-time `oidcConfigured` flag here
  ## that required two rebuilds because Nix only re-evaluates
  ## pathExists at build time.

  ## Headplane is deployed whenever headscale is enabled. The cookie
  ## secret is auto-generated, so there's no chicken-and-egg problem:
  ## you can use the admin UI immediately to generate the
  ## `headscale apikeys create` value and configure OIDC after.
  deployHeadplane = headscaleEnabled;

  ## The cookie secret is auto-generated on first boot by the
  ## headplane-prepare-secrets.service oneshot defined further down,
  ## ensuring the file exists before LoadCredential reads it. Headplane
  ## requires *some* cookie secret to start; we don't want a fresh
  ## install to be locked out of its own admin UI just because the
  ## sysadmin hasn't visited the SOPS settings page yet.

  ## Secret values are exposed via systemd LoadCredential below; we
  ## point the *_path settings at the resolved paths under
  ## /run/credentials/<unit>/<name> to avoid env-var expansion in YAML.
  headplaneCredsDir = "/run/credentials/headplane.service";

  ## The nixpkgs `services.headscale` module installs a deliberately
  ## minimal /etc/headscale/config.yaml — just the unix-socket path and
  ## the disable-update-check flag — and passes the full settings to
  ## the daemon via `--config <store-path>` instead. Headplane, by
  ## contrast, expects the full config so it can render and validate
  ## it in the UI; pointing it at the stub makes it reject the file
  ## with "database / derp / dns / listen_addr / noise / prefixes /
  ## server_url must be present" errors. We regenerate the same content
  ## using the same YAML formatter and write it next to the stub.
  ##
  ## Headplane's validator additionally rejects explicit null values
  ## where it expects a string/array (e.g. `tls_cert_path: null`,
  ## `policy.path: null`, `dns.extra_records: null`). The headscale
  ## daemon happily accepts these as "unset", but headplane treats
  ## the field as ill-typed. Strip nulls recursively before serialising.
  ##
  ## Additionally, strip the tailscale-IP placeholders (192.0.2.1 /
  ## 2001:db8::1) from the headplane view. They're meaningful only to
  ## the runtime substitution oneshot; admins viewing the DNS config
  ## in Headplane shouldn't see TEST-NET-1 / docs-range addresses.
  ## Real tailscale IPs are not in nix-eval scope.
  resolverPlaceholderIpv4 = "192.0.2.1";
  resolverPlaceholderIpv6 = "2001:db8::1";
  isResolverPlaceholder = ip:
    ip == resolverPlaceholderIpv4 || ip == resolverPlaceholderIpv6;
  headscaleSettingsForHeadplane =
    let
      filtered = lib.filterAttrsRecursive (_: v: v != null) config.services.headscale.settings;
    in
      lib.recursiveUpdate filtered {
        dns.nameservers.global =
          lib.filter (ip: !(isResolverPlaceholder ip))
            (filtered.dns.nameservers.global or []);
      };
  ## Headplane-facing view — placeholders stripped (admins shouldn't see
  ## TEST-NET-1 / docs-range), nulls filtered (headplane's validator
  ## rejects null fields).
  headscaleConfigForHeadplane =
    (pkgs.formats.yaml {}).generate "headscale-for-headplane.yaml"
      headscaleSettingsForHeadplane;
  ## Substitution-source view — keeps the resolver placeholders
  ## (192.0.2.1 / 2001:db8::1) INTACT so the sed pass inside
  ## substituteResolverPlaceholders below has lines to match. This is the
  ## YAML the headscale daemon's runtime config is derived from; clients
  ## see the substituted result, not this file directly.
  ## Filter null fields only (headscale tolerates them, but parity with
  ## the headplane view keeps the two outputs structurally identical
  ## except for the placeholder lines).
  headscaleConfigWithPlaceholders =
    (pkgs.formats.yaml {}).generate "headscale-with-placeholders.yaml"
      (lib.filterAttrsRecursive (_: v: v != null) config.services.headscale.settings);

  ## Runtime config used by headscale.service: a writable copy of the
  ## nix-rendered yaml with the resolver placeholders substituted for
  ## the box's current tailscale IPs. See the substitution script and
  ## the headscale-substitute-resolver.service oneshot below for the
  ## "why" — Tailscale Android shows "DNS Unavailable" if the
  ## configured resolver isn't a tailnet-native address.
  headscaleRuntimeConfigPath = "/var/lib/headscale/runtime-config.yaml";
  headscaleResolverStatePath = "/var/lib/headscale/.cached-tailnet-resolver-ip";

  ## Substitute resolver placeholders in $1 → write to $2.
  ## Falls back to STRIPPING the placeholder lines when tailscale isn't
  ## up yet (first boot, before tailscaled-autoconnect has registered)
  ## so clients receive a clean resolver list rather than the documentation
  ## IPs. Output file is installed mode 0640 root:headscale so the
  ## headscale daemon (running as that group) can read it.
  substituteResolverPlaceholders = pkgs.writeShellScript "headscale-substitute-resolver" ''
    set -euo pipefail
    SRC="$1"
    DST="$2"

    TS_IPV4=$(${pkgs.tailscale}/bin/tailscale ip -4 2>/dev/null | ${pkgs.coreutils}/bin/head -n1 || true)
    TS_IPV6=$(${pkgs.tailscale}/bin/tailscale ip -6 2>/dev/null | ${pkgs.coreutils}/bin/head -n1 || true)

    TMP=$(${pkgs.coreutils}/bin/mktemp)
    ${pkgs.coreutils}/bin/cp "$SRC" "$TMP"

    if [ -n "$TS_IPV4" ]; then
      ${pkgs.gnused}/bin/sed -i "s|- ${resolverPlaceholderIpv4}$|- $TS_IPV4|" "$TMP"
    else
      ${pkgs.gnused}/bin/sed -i "/- ${resolverPlaceholderIpv4}$/d" "$TMP"
    fi

    if [ -n "$TS_IPV6" ]; then
      ${pkgs.gnused}/bin/sed -i "s|- ${resolverPlaceholderIpv6}$|- $TS_IPV6|" "$TMP"
    else
      ${pkgs.gnused}/bin/sed -i "/- ${resolverPlaceholderIpv6}$/d" "$TMP"
    fi

    ${pkgs.coreutils}/bin/install -m 0640 \
      -o root -g ${config.services.headscale.group or "headscale"} \
      "$TMP" "$DST"
    ${pkgs.coreutils}/bin/rm -f "$TMP"

    ## Also record the IPs we just baked in, so headscale-substitute-
    ## resolver can detect "no change since last apply" and skip a
    ## redundant headscale restart on rebuild. Without this, the
    ## ExecStartPre would substitute correctly on the rebuild's
    ## headscale restart, and then the oneshot would observe a missing
    ## cache file and try-restart again — back-to-back restarts.
    ${pkgs.coreutils}/bin/install -m 0640 \
      -o root -g ${config.services.headscale.group or "headscale"} \
      /dev/null ${headscaleResolverStatePath} 2>/dev/null || true
    printf 'ipv4=%s ipv6=%s' "$TS_IPV4" "$TS_IPV6" \
      > ${headscaleResolverStatePath}
  '';

  headplaneSettings = {
    server = {
      host = "127.0.0.1";
      port = headplane-port;
      cookie_secret_path = "${headplaneCredsDir}/headplane-cookie-secret";
      cookie_secure = true;
    };
    headscale = {
      url = "http://${lan-address}:${toString config.services.headscale.port}";
      config_path = "/etc/headscale/headplane-view.yaml";
      config_strict = true;
      ## Always set api_key_path — the headplane.service unit's
      ## ConditionPathExists gate prevents it from starting until
      ## the file actually exists on disk, so this never points at
      ## a missing file at runtime.
      api_key_path = "${headplaneCredsDir}/headscale-api-key";
    };
    integration = {
      proc.enabled = true;
      agent.enabled = false;
    };
    ## OIDC is always rendered into the YAML (no oidcConfigured
    ## gate). The actual SSO functionality kicks in once
    ## zitadel-provision.service writes the secret files and
    ## try-restarts headplane.service — at that point its
    ## ConditionPathExists gate flips to true and the unit starts
    ## with this OIDC config in effect. Single rebuild on a fresh
    ## install: install → zitadel-provision runs → headplane comes
    ## up with SSO. No second rebuild required.
    ##
    ## Headplane's option schema only supports `client_secret_path`
    ## (file-backed) but requires `client_id` inline. To avoid a
    ## fresh-install double-rebuild trap (eval-time `readFile` only
    ## sees a value on the second build), the YAML gets a placeholder
    ## and the real value is injected at runtime via the
    ## `HEADPLANE_OIDC__CLIENT_ID` env var written by
    ## headplane-prepare-secrets.service into headplane.env (see
    ## below). Headplane's env-override layer wins over YAML.
    oidc = {
      issuer = "https://sso.${cfg.system.domain}";
      client_id = "PLACEHOLDER_OVERRIDDEN_BY_ENV";
      client_secret_path = "${headplaneCredsDir}/oidc-client-secret";
      headscale_api_key_path = "${headplaneCredsDir}/headscale-api-key";
      disable_api_key_login = false;
      token_endpoint_auth_method = "client_secret_post";
      ## NOTE — Headplane admin-only gate (LIMITATION):
      ## Headplane has no internal admin/user concept, and the
      ## NixOS module wrapper currently doesn't expose Headplane's
      ## `oidc.user_groups` / `oidc.groups_claim` options that would
      ## let us restrict by role at the OIDC layer. As a result, ANY
      ## authenticated Zitadel user can currently reach Headplane's
      ## admin UI.
      ##
      ## Workaround options when this matters:
      ##   1. Put oauth2-proxy in front of Headplane at the Caddy
      ##      layer (with OAUTH2_PROXY_ALLOWED_GROUPS=homefree-admin),
      ##      double-gating but enforcing the role.
      ##   2. Bump the headplane flake input to a version whose
      ##      NixOS module exposes the role-filter options, then
      ##      restore the `user_groups`/`groups_claim` lines.
      ##   3. Patch the local NixOS module to surface those options
      ##      (small change — see
      ##      ../overlays/headplane-module-extra.nix as a starting
      ##      point if you go this route).
    };
  };

  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Headscale vpn service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "UI open to public on WAN port";
    };

    stun-port = lib.mkOption {
      type = lib.types.int;
      description = "DERP STUN relay port";
      default = 3478;
    };

    enable-public-derp-fallback = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Include Tailscale's public DERP relay servers as fallback.

        When enabled, clients can relay traffic through Tailscale's
        infrastructure if the embedded DERP server on this machine is
        unreachable (e.g. after a network switch causes a DNS circular
        dependency where MagicDNS needs the tunnel to resolve the
        headscale server, but the tunnel needs DERP to recover).
        The embedded DERP is always preferred when reachable; public
        servers are only used as a last resort.

        NOTE: This creates a dependency on Tailscale's infrastructure
        (controlplane.tailscale.com). Disable this if you require
        complete independence from Tailscale's services.
      '';
    };
  };
in
{
  ## nixpkgs ships its own headplane module (services/networking/headplane.nix)
  ## but it's pinned to nixpkgs's headplane version (0.6.x). Disable it so
  ## the upstream flake module — which tracks 0.7+ and adds option fields the
  ## nixpkgs version doesn't — wins without colliding.
  disabledModules = [ "services/networking/headplane.nix" ];
  imports = [
    homefree-inputs.headplane.nixosModules.headplane
  ];

  options.homefree.services.headscale = userOptions;
  options.homefree.service-options.headscale = userOptions // {
    label = lib.mkOption {
      type = lib.types.str;
      default = "headscale";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "VPN (Headscale)";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Headscale";
      internal = true;
      description = "Project name";
    };

    ## Headscale's secrets (tailscale-key, headplane-cookie-secret,
    ## oidc-client-{id,secret}, headscale-api-key) are filled in
    ## automatically by HomeFree — zitadel-provision.service writes
    ## the OIDC pair; headplane-prepare-secrets, headscale-mint-api-
    ## key, and headscale-mint-tailscale-key services mint the
    ## others. preStart scripts and systemd LoadCredential read the
    ## files directly from /var/lib/homefree-secrets/headscale/,
    ## bypassing the Nix-config layer entirely. No option declarations
    ## here.
  };

  config = {
  ## OIDC client descriptor for Headplane — unconditional per modules/sso-clients.nix.
  homefree.sso.clients = [{
    svc = "headscale";
    internal_name = "homefree-headplane";
    app_type = "OIDC_APP_TYPE_WEB";
    auth_method = "OIDC_AUTH_METHOD_TYPE_POST";
    response_types = [ "OIDC_RESPONSE_TYPE_CODE" ];
    grant_types = [ "OIDC_GRANT_TYPE_AUTHORIZATION_CODE" "OIDC_GRANT_TYPE_REFRESH_TOKEN" ];
    redirect_uris = [ "https://vpn.${cfg.system.domain}/admin/oidc/callback" ];
    post_logout_uris = [ "https://vpn.${cfg.system.domain}/admin" ];
    needs_pat = false;
    post_restart_units = [ "headplane.service" ];
  }];

  ## Pull pkgs.headplane (and pkgs.headplane-agent) from the upstream
  ## flake — newer than nixpkgs. Applying unconditionally is harmless;
  ## the package is only referenced when headscale is enabled.
  nixpkgs.overlays = [ homefree-inputs.headplane.overlays.default ];

  environment.systemPackages = lib.optionals headscaleEnabled [
    pkgs.headscale
    pkgs.tailscale
  ];

  ## Expose the full headscale config to Headplane at a separate path,
  ## leaving the nixpkgs-managed /etc/headscale/config.yaml stub alone
  ## (some headscale CLI invocations depend on its minimal shape).
  environment.etc."headscale/headplane-view.yaml" = lib.mkIf deployHeadplane {
    source = headscaleConfigForHeadplane;
    ## Headplane runs as the headscale user (per the upstream module),
    ## so make this readable by that group.
    mode = "0440";
    user = "headscale";
    group = "headscale";
  };

  services.headscale = lib.optionalAttrs headscaleEnabled {
    enable = true ;
    port = config.homefree.allocPort "headscale";
    address = lan-address;
    settings = {
      server_url = "https://headscale.${cfg.system.domain}:443";
      # policy.path = policy;
      dns = {
        magic_dns = true;
        ## true = Tailscale definitively owns ALL DNS on the device, always
        ## routing through the engine. Global nameservers (Quad9/Cloudflare)
        ## handle public domains; split zones handle .lan. No dependency on
        ## carrier DNS or override_local_dns inconsistency across Android versions.
        override_local_dns = true;
        ## Must be different from server domain
        base_domain = "homefree.vpn";
        # search_domains = search-domains;
        ## Order matters in headscale 0.26+: the first reachable resolver is
        ## preferred, so put the LAN resolver first to get split-horizon and
        ## ad-blocking; the public resolvers are fallbacks for when the LAN
        ## resolver is unreachable.
        ##
        ## The two leading entries are PLACEHOLDERS (TEST-NET-1 192.0.2.1 and
        ## docs-range 2001:db8::1) — at headscale startup, the substitution
        ## script rewrites them to the box's current tailscale IPv4/IPv6, or
        ## strips them if tailscaled hasn't registered yet. They sit FIRST so
        ## tailscale clients probing the configured resolvers find a
        ## tailnet-native address and don't show "DNS Unavailable" (Tailscale
        ## Android's probe rejects subnet-routed LAN IPs like 10.0.0.1 even
        ## though queries via the subnet route succeed). The tailscale-side
        ## listener is the tailscale-dns-bridge dnsmasq forwarder, which
        ## forwards to AdGuard so filtering stays consistent.
        nameservers.global = [
          ## Placeholder — substituted to the box's tailscale IPv4 at runtime.
          resolverPlaceholderIpv4
          ## Placeholder — substituted to the box's tailscale IPv6 at runtime.
          resolverPlaceholderIpv6
          ## Internal DNS — has local domain names + ad-blocking via unbound
          lan-address
          ## Backup if LAN resolver is unreachable (e.g. before tunnel is up)
          "9.9.9.10"
          ## Secondary backup
          "9.9.9.9"
        ];
        ## Needed to resolve internal domains (includes proxied domains for Headscale VPN access)
        nameservers.split = lib.listToAttrs (lib.map (domain:
          {
            name = domain;
            value = [
              lan-address
            ];
          }
        ) all-split-domains);
      };
      prefixes = {
        ## Some VPNs use addresses that overlap. Reduce the size of the network
        ## from 10.64.0.0/10
        v4 = "100.64.0.0/24";
        v6 = "fd7a:115c:a1e0::/48";
      };
      derp = let
        ## The auto-update mechanism is *only* meaningful when we're
        ## actually fetching a remote DERP list (`urls`). With urls=[]
        ## there is nothing to fetch; leaving auto_update_enabled=true
        ## (upstream default) makes headscale still tick the refresh
        ## timer, churn the local DERP map, and broadcast netmap
        ## updates to every client every `update_frequency` — which
        ## destabilises mobile clients' control-plane long-poll
        ## (observed: phone goes "offline" in headscale view ~10m
        ## after each cycle, Tailscale Android raises a spurious
        ## "DNS unavailable" banner). Both keys are set because
        ## `auto_update_enable` was renamed to `auto_update_enabled`
        ## upstream and we'd otherwise inherit the renamed key's
        ## default-true and end up with both values in the YAML.
        usePublicDerp = cfg.service-options.headscale.enable-public-derp-fallback;
      in {
        auto_update_enable = usePublicDerp;
        auto_update_enabled = usePublicDerp;
        ## Even *with* the public DERP list enabled, Tailscale's map
        ## content changes a handful of times a year; refreshing every
        ## 5 minutes just pushes byte-identical maps to every client
        ## and causes spurious "derp-region-redefined" cycles. 24h is
        ## plenty — the worst case is a public-fallback DERP IP change
        ## going unnoticed until the next refresh or rebuild, which
        ## doesn't matter when the embedded region 999 is the primary
        ## path anyway.
        update_frequency = "24h";
        server = {
          enabled = true;
          region_id = 999;
          region_code = "headscale";
          region_name = "headscale Embedded DERP";
          stun_listen_addr = "0.0.0.0:${toString cfg.service-options.headscale.stun-port}";
          automatically_add_embedded_derp_region = true;
        };
        urls = if usePublicDerp
          then [ "https://controlplane.tailscale.com/derpmap/default" ]
          else [];
        paths = [];
      };

      ## Log level. Default is "info"; bumped to "debug" so the DERP
      ## server logs every client connect/disconnect with the reason
      ## (write timeout, normal close, etc.) — needed to root-cause
      ## the "derp.Recv: EOF every 1-30 min" issue. The reverse-proxy
      ## tweaks in the Caddy block below are the conservative fix
      ## for the suspected cause; this log level lets us verify.
      ## See docs/agent-notes (when written) for diagnosis context.
      ## Revert to "info" once the root cause is confirmed and fixed.
      log.level = "debug";
    };
  };

  ## headscale fetches the public DERPMap from controlplane.tailscale.com
  ## at startup (derp.urls), which needs working external DNS. Without
  ## ordering, the unit races AdGuard's image-pull window and dies with
  ## "lookup controlplane.tailscale.com: no such host" — 5 restarts in
  ## ~30 s hits start-limit-hit and the unit stays dead until manual
  ## intervention. `dns-ready.service` is the system-wide gate for this
  ## (see services/unbound/default.nix and
  ## docs/agent-notes/dns-ready-ordering.md); just `after`/`wants` it,
  ## same pattern as Caddy and every container app.
  ##
  ## `wants`, not `requires` — a DNS restart later in the system's life
  ## should not drag headscale down with it. `requires` would cascade
  ## a transient DNS-stack restart into a VPN-coordinator outage.
  ##
  ## Also bump the start-limit window so a slow first boot (Docker Hub
  ## pull + DERPMap fetch can together exceed the default 5×5 s window)
  ## doesn't permanently fail the unit.
  systemd.services.headscale = lib.mkIf headscaleEnabled {
    after = [ "dns-ready.service" ];
    wants = [ "dns-ready.service" ];
    ## Re-render the writable runtime config on every (re)start so the
    ## tailscale-IP substitution stays current. On first boot, before
    ## tailscaled-autoconnect has run, the substitution script strips
    ## the placeholders and headscale starts with just the LAN + public
    ## resolvers (identical to pre-fix behaviour). Once tailscaled is up
    ## and the substitute-resolver oneshot fires, headscale is
    ## try-restarted and this ExecStartPre runs again with the real IP.
    serviceConfig = {
      RestartSec = lib.mkForce "15s";
      ExecStartPre = [
        ## Upstream sets StateDirectory=headscale which gives us
        ## /var/lib/headscale 0750 root:headscale, but only after
        ## ExecStartPre runs. With `+` prefix this snippet runs as
        ## root regardless of User=, so we can pre-create the dir
        ## ourselves to ensure substituteResolverPlaceholders has
        ## somewhere to write.
        "+${pkgs.writeShellScript "headscale-prepare-runtime-config" ''
          set -euo pipefail
          ${pkgs.coreutils}/bin/mkdir -p /var/lib/headscale
          ${pkgs.coreutils}/bin/chown root:${config.services.headscale.group} \
            /var/lib/headscale
          ${substituteResolverPlaceholders} \
            ${headscaleConfigWithPlaceholders} \
            ${headscaleRuntimeConfigPath}
        ''}"
      ];
    };
    ## Override the upstream `script` to point --config at the runtime
    ## (substituted) file rather than the immutable nix-store yaml.
    ## We don't use postgres so the upstream's password-file branch is
    ## irrelevant; just exec directly.
    script = lib.mkForce ''
      exec ${pkgs.headscale}/bin/headscale serve --config ${headscaleRuntimeConfigPath}
    '';
    ## StartLimitBurst / StartLimitIntervalSec are [Unit]-section directives in
    ## systemd, not [Service]. Putting them under serviceConfig renders them
    ## into the wrong section and systemd silently ignores them
    ## ("Unknown key 'StartLimitIntervalSec' in section [Service], ignoring.").
    ## They must go under unitConfig to actually take effect.
    unitConfig = {
      StartLimitBurst = lib.mkForce 10;
      StartLimitIntervalSec = lib.mkForce 300;
    };
  };

  ## After tailscaled-autoconnect has registered with headscale and the
  ## local interface has a tailnet address, re-substitute the placeholders
  ## in the runtime config and bump headscale so the new netmap (with the
  ## real tailscale IP as the leading resolver) gets pushed to clients.
  ##
  ## Idempotent: a small state file caches the last-substituted IPs and we
  ## skip the headscale restart when nothing has changed. Without this
  ## check, every boot would unnecessarily disconnect every tailscale
  ## client for ~5s.
  systemd.services.headscale-substitute-resolver = lib.mkIf headscaleEnabled {
    description = "Substitute box's tailscale IP into headscale resolver list and reload headscale";
    after = [ "tailscaled-autoconnect.service" "headscale.service" ];
    wants = [ "tailscaled-autoconnect.service" ];
    requires = [ "headscale.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
    };
    script = ''
      set -euo pipefail

      TS_IPV4=$(${pkgs.tailscale}/bin/tailscale ip -4 2>/dev/null | ${pkgs.coreutils}/bin/head -n1 || true)
      TS_IPV6=$(${pkgs.tailscale}/bin/tailscale ip -6 2>/dev/null | ${pkgs.coreutils}/bin/head -n1 || true)

      if [ -z "$TS_IPV4" ] && [ -z "$TS_IPV6" ]; then
        echo "headscale-substitute-resolver: tailscaled has no IP yet, nothing to substitute"
        exit 0
      fi

      CACHE=${headscaleResolverStatePath}
      DESIRED="ipv4=$TS_IPV4 ipv6=$TS_IPV6"
      CURRENT=""
      if [ -r "$CACHE" ]; then
        CURRENT=$(${pkgs.coreutils}/bin/cat "$CACHE")
      fi

      if [ "$DESIRED" = "$CURRENT" ]; then
        echo "headscale-substitute-resolver: tailscale IPs unchanged ($DESIRED), no restart"
        exit 0
      fi

      echo "headscale-substitute-resolver: substituting $DESIRED into runtime config"
      ${substituteResolverPlaceholders} \
        ${headscaleConfigWithPlaceholders} \
        ${headscaleRuntimeConfigPath}
      printf '%s' "$DESIRED" > "$CACHE"
      ${pkgs.coreutils}/bin/chmod 0640 "$CACHE"

      ## try-restart so we don't accidentally START headscale if it was
      ## intentionally stopped. After this, the headscale-prepare-
      ## runtime-config ExecStartPre will re-substitute on the new
      ## start, picking up the same IPs.
      ${pkgs.systemd}/bin/systemctl try-restart headscale.service
    '';
  };

  ## @TODO: Figure out how to automatically approve exit node without using the web UI
  ##
  ## authKeyFile is pinned to a stable path that headscale-mint-tailscale-key.service
  ## populates on every start (mint-if-missing or mint-if-not-in-DB). The
  ## SOPS-managed tailscale-key option is left for advanced overrides but is
  ## NOT required for first-boot — the mint service makes onboarding fully
  ## declarative.
  services.tailscale = lib.optionalAttrs headscaleEnabled {
    enable = true;
    authKeyFile = "${headplaneSecretsDir}/tailscale-key";
    useRoutingFeatures = "server";
    extraUpFlags = [
      ## Connect directly to local headscale (bypasses Caddy proxy issues)
      "--login-server=http://${lan-address}:${toString config.services.headscale.port}"
      # "--advertise-routes=${lan-subnet},100.64.0.0/24"
      "--advertise-routes=${lan-subnet}"
      "--advertise-exit-node"
    ];
    extraSetFlags = [
      # "--advertise-routes=${lan-subnet},100.64.0.0/24"
      "--advertise-routes=${lan-subnet}"
      "--advertise-exit-node"
      # "--netfilter-mode=nodivert"
    ];
  };

  ## Auto-approve the LAN subnet route advertised by the local tailscale
  ## client (the router host itself).
  ##
  ## Headscale 0.27+ removed `headscale routes list/enable`. The new API is
  ## `headscale nodes list-routes` (per-node view of advertised + approved
  ## routes) and `headscale nodes approve-routes -i <ID> -r <CIDRs>` which
  ## takes a node identifier and the comma-separated list of approved CIDRs.
  ## We find the node by hostname (the router advertises homefree.lan via
  ## tailscale up) and approve our LAN subnet on that node.
  systemd.services.headscale-enable-routes = lib.mkIf headscaleEnabled {
    description = "Approve the LAN subnet route advertised by the local tailscale client";
    ## Run after tailscaled-autoconnect has finished registering the
    ## host node (it advertises the LAN subnet via --advertise-routes).
    ## headscale.service is needed for the CLI to talk to the daemon.
    after = [ "headscale.service" "tailscaled-autoconnect.service" ];
    requires = [ "headscale.service" "tailscaled-autoconnect.service" ];
    ## wantedBy makes this actually run on boot. Without it the unit
    ## sits inactive forever and node routes never get approved.
    wantedBy = [ "multi-user.target" ];
    enable = true;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "headscale";
    };
    script = ''
      HEADSCALE=${pkgs.headscale}/bin/headscale
      JQ=${pkgs.jq}/bin/jq
      TAILSCALE=${pkgs.tailscale}/bin/tailscale

      ## Match the headscale node entry to the LOCAL tailscaled by
      ## node_key — robust against multiple `homefree`-named nodes
      ## (e.g. an old offline registration lingering after a re-
      ## onboard). Self-healing: looks up the current local node
      ## key on every run.
      LOCAL_NODE_KEY=$($TAILSCALE status --json 2>/dev/null \
        | $JQ -r '.Self.PublicKey // empty')

      if [ -z "$LOCAL_NODE_KEY" ]; then
        echo "headscale-enable-routes: local tailscaled has no node key yet"
        exit 0
      fi

      ## Headscale stores node_key as `nodekey:<hex>` — same format as
      ## tailscale's .Self.PublicKey, so exact-match works.
      NODE_ID=$($HEADSCALE nodes list-routes -o json \
        | $JQ -r --arg k "$LOCAL_NODE_KEY" \
            '.[] | select(.node_key == $k) | .id' \
        | ${pkgs.coreutils}/bin/head -n1)

      if [ -z "$NODE_ID" ]; then
        echo "headscale-enable-routes: no headscale node matches local node_key $LOCAL_NODE_KEY"
        exit 0
      fi

      $HEADSCALE nodes approve-routes -i "$NODE_ID" -r "${lan-subnet}"
    '';
  };

  ## DERP EOF observability — small rollup that summarises every 10 min
  ## how many `derp.Recv: EOF` events tailscaled has logged since the
  ## previous tick. Without this, the EOFs are a single line buried in
  ## the journal; the rollup makes them grep-able and gives a clear
  ## before/after signal when tuning the Caddy /derp block above.
  ##
  ## Output (visible via `journalctl -u headscale-derp-eof-rollup`):
  ##   "DERP EOFs in last 600s: <n>  (1-min cadence: <rate>/min)"
  ## A value of 0 across consecutive ticks means the fix worked.
  systemd.services.headscale-derp-eof-rollup = lib.mkIf headscaleEnabled {
    description = "Rollup of tailscaled DERP EOF events (diagnosis aid)";
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ## journalctl read access — root keeps this simple. Output goes
      ## back to the journal under THIS unit's name.
    };
    script = ''
      WINDOW_SEC=600
      COUNT=$(${pkgs.systemd}/bin/journalctl -u tailscaled.service \
                --since "$WINDOW_SEC seconds ago" --no-pager 2>/dev/null \
              | ${pkgs.gnugrep}/bin/grep -c "derp.Recv: EOF" || true)
      RATE_PER_MIN=$(( COUNT * 60 / WINDOW_SEC ))
      echo "DERP EOFs in last ''${WINDOW_SEC}s: $COUNT  (~$RATE_PER_MIN/min)"
    '';
  };

  systemd.timers.headscale-derp-eof-rollup = lib.mkIf headscaleEnabled {
    description = "Rollup of tailscaled DERP EOF events every 10 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitInactiveSec = "10min";
      Unit = "headscale-derp-eof-rollup.service";
    };
  };

  ## DNS bridge for Tailscale clients.
  ##
  ## PROBLEM. Tailscale clients periodically probe the box's
  ## Tailscale-interface IP on port 53 as a "configured DNS reachable?"
  ## health check. Headscale pushes `lan-address` (10.0.0.1) as the
  ## resolver, and queries to 10.0.0.1:53 DO arrive (via the
  ## advertised 10.0.0.0/24 subnet route), but the probe ALSO checks
  ## the box's Tailscale-side address (e.g. 100.64.0.2:53). AdGuard
  ## binds only on `lan-address` + loopback (see apps/adguard) — it
  ## intentionally avoids 0.0.0.0 to keep clear of podman's
  ## aardvark-dns on 10.88.0.1:53 — so the Tailscale-IP probe gets
  ## connection-refused and surfaces "DNS unavailable" in the
  ## Tailscale client UI even when actual lookups still work.
  ##
  ## SOLUTION. A tiny dnsmasq running with `--bind-dynamic
  ## --interface=tailscale0` listens on whatever IPs tailscaled
  ## assigns to that interface, with NO static config knob — the IP
  ## isn't known at Nix eval time (headscale chooses it at
  ## registration). dnsmasq watches the interface for address
  ## add/remove events and rebinds, so the listener follows the IP
  ## even across reprovisions. All queries are forwarded to AdGuard
  ## on 127.0.0.1:53, keeping filtering + upstream consistent with
  ## non-Tailscale clients.
  ##
  ## --no-resolv / --no-hosts: dnsmasq must NOT consult /etc/resolv.conf
  ## or /etc/hosts; it's purely a forwarder. CAP_NET_BIND_SERVICE
  ## ambient cap lets it bind 53 while running as `nobody`.
  systemd.services.tailscale-dns-bridge = lib.mkIf headscaleEnabled {
    description = "DNS forwarder on tailscale0 → AdGuard (127.0.0.1:53)";
    after = [ "tailscaled.service" "tailscaled-autoconnect.service" ];
    requires = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.dnsmasq}/bin/dnsmasq"
        "--no-daemon"
        "--port=53"
        "--bind-dynamic"
        "--interface=tailscale0"
        "--no-resolv"
        "--no-hosts"
        "--server=127.0.0.1#53"
        ## Defensive: never bind on these even if --bind-dynamic
        ## could see them — AdGuard / aardvark-dns already own
        ## port 53 there and dnsmasq starting up faster than them
        ## could otherwise win the bind race. lan-interface comes
        ## from homefree.network so this is portable across
        ## instances (no hardcoded `enp102s0` / similar).
        "--except-interface=lo"
        "--except-interface=${config.homefree.network.lan-interface}"
        "--except-interface=podman0"
      ];
      Restart = "always";
      RestartSec = "5s";
      User = "nobody";
      Group = "nobody";
      AmbientCapabilities = "CAP_NET_BIND_SERVICE";
      CapabilityBoundingSet = "CAP_NET_BIND_SERVICE";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictRealtime = true;
      ## After the bridge comes up (tailscale0 has an address), nudge
      ## the substitute-resolver oneshot so headscale's runtime config
      ## reflects the current tailscale IP. The oneshot's cache check
      ## makes this a no-op when the IP hasn't changed, so this is
      ## cheap on routine restarts. Catches the rare case of a
      ## tailnet reset that re-assigns the box a new IP.
      ##
      ## `+` prefix runs as root regardless of User=nobody. `--no-block`
      ## so a slow oneshot can't stall the bridge start.
      ExecStartPost = [
        "+${pkgs.systemd}/bin/systemctl restart --no-block headscale-substitute-resolver.service"
      ];
      ## tailscale0 may not exist yet on first startup if tailscaled
      ## is still establishing. dnsmasq exits on missing interface,
      ## but Restart=always brings it back; once tailscaled raises
      ## tailscale0 the next start succeeds and --bind-dynamic
      ## adopts the IP.
    };
  };

  ## Headplane is the Headscale admin UI. From 0.7 it ships a NixOS
  ## module (imported above) and runs as a native systemd service rather
  ## than a podman container. It picks up its YAML config from
  ## /etc/headplane/config.yaml (written by the upstream module from the
  ## settings attrset below) and reads four runtime secrets from systemd
  ## credentials populated via LoadCredential.
  services.headplane = lib.mkIf deployHeadplane {
    enable = true;
    settings = headplaneSettings;
  };

  ## Belt-and-suspenders: enforce the secrets directory mode and
  ## owner on every rebuild via systemd-tmpfiles. The
  ## `headplane-prepare-secrets` oneshot below also sets these, but
  ## systemd doesn't re-run oneshots when their content hasn't
  ## changed — and historically the Python backend's secret-writer
  ## was clobbering this dir back to 0700 (it's fixed now, but the
  ## tmpfiles rule catches any future regression). `z` (vs. `Z`)
  ## adjusts the dir itself without recursing into files, so we
  ## don't fight individual file modes (config.yaml is 0640,
  ## headscale-api-key is 0600, etc.).
  systemd.tmpfiles.rules = lib.mkIf deployHeadplane [
    "z ${headplaneSecretsDir} 0750 root ${config.services.headscale.group} - -"
  ];

  ## Standalone oneshot that auto-generates the cookie secret before
  ## headplane.service starts. LoadCredential= is processed by PID 1
  ## *before* ExecStartPre runs, so we can't generate the file from
  ## within headplane.service itself — by the time ExecStartPre would
  ## run, LoadCredential has already failed with status 243.
  ##
  ## We deliberately do NOT use RemainAfterExit here: switch-to-
  ## configuration won't restart a oneshot that's still "active"
  ## from a previous boot, so dir-perm resets that happen DURING
  ## activation (anything that touches /var/lib/homefree-secrets/
  ## via Python or otherwise can land between tmpfiles and the next
  ## unit) wouldn't get re-fixed. Without RemainAfterExit the unit
  ## goes back to inactive after success and re-runs on every
  ## rebuild. `requires=` on a oneshot is satisfied by the last
  ## exit being 0, so headplane.service still gates on us correctly.
  ##
  ## Belt-and-suspenders: headplane.service also has an
  ## ExecStartPre that asserts dir perms on every start (see
  ## below). That covers the case where the dir gets reset
  ## AFTER prepare-secrets ran but BEFORE headplane starts.
  ## Idempotent: only writes missing files.
  systemd.services.headplane-prepare-secrets = lib.mkIf deployHeadplane {
    description = "Prepare Headplane runtime secrets and rendered config";
    wantedBy = [ "headplane.service" ];
    before = [ "headplane.service" ];
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      set -eu
      mkdir -p ${headplaneSecretsDir}
      ## Headplane runs as the `headscale` group and needs to read the
      ## rendered config.yaml below. Make the dir group-traversable
      ## (still root-only by default since other files are mode 600).
      chown root:${config.services.headscale.group} ${headplaneSecretsDir}
      chmod 750 ${headplaneSecretsDir}

      ## Cookie secret, anchored into encrypted /etc/nixos/secrets so it
      ## survives a restore (lib/secrets-anchor.nix). mkdirMode=null:
      ## the dir mode/owner is set deliberately just above (0750
      ## root:headscale) and must not be clobbered to 0700.
      ${anchor.preamble}
      ${anchor.anchorSecret {
        service = "headscale";
        key = "headplane-cookie-secret";
        dir = headplaneSecretsDir;
        mkdirMode = null;
        generate = "${pkgs.openssl}/bin/openssl rand -base64 32 | head -c 32";
      }}

      ## Render a runtime copy of /etc/headplane/config.yaml with
      ## the real OIDC client_id substituted in. Avoids the eval-time
      ## `readFile` double-rebuild trap. Cannot use the env-var
      ## override (HEADPLANE_OIDC__CLIENT_ID) because Headplane's
      ## env parser type-infers all-digit values as numbers, and
      ## Zitadel client_ids are 18-digit snowflakes — they parse as
      ## numbers and fail the `string` validator at startup.
      ##
      ## ConditionPathExists on headplane.service prevents start
      ## until oidc-client-id is on disk, so this branch always has
      ## a value to substitute.
      RUNTIME_CONFIG=${headplaneSecretsDir}/config.yaml
      install -m 600 /dev/null "$RUNTIME_CONFIG"
      CID=$(tr -d '\n' < "${headplaneSecretsDir}/oidc-client-id")
      ## Substitute the placeholder with a quoted string. The
      ## YAML emitter for our Nix config writes the placeholder as
      ## `client_id: PLACEHOLDER_OVERRIDDEN_BY_ENV` (unquoted, parsed
      ## as string only because the value contains underscores).
      ## After substitution the value is 18 digits and YAML would
      ## otherwise parse it as a Number, failing Headplane's
      ## `string` validator. Force-quote in the replacement.
      ${pkgs.gnused}/bin/sed \
        "s|PLACEHOLDER_OVERRIDDEN_BY_ENV|\"$CID\"|g" \
        /etc/headplane/config.yaml > "$RUNTIME_CONFIG"
      chmod 640 "$RUNTIME_CONFIG"
      chown root:${config.services.headscale.group} "$RUNTIME_CONFIG"
    '';
  };

  ## Mint a long-lived headscale API key for Headplane to use when
  ## talking to headscale's gRPC API. Without this Headplane can
  ## display nodes but can't mutate them (add/remove pre-auth keys,
  ## expire devices, etc.) — and our LoadCredential gate refuses
  ## to start headplane until this file exists.
  ##
  ## Runs after headscale.service so the CLI can talk to the live
  ## daemon. Self-healing: re-mints if the on-disk key is missing OR
  ## isn't present in headscale's DB (e.g. after a headscale DB
  ## reset). Without the DB-presence check, a stale file persists
  ## forever and headplane responds to every OIDC callback with
  ## "Failed to link Headscale user" + "Logging out due to expired
  ## API key" — looks like SSO is broken when it's really an auth
  ## bootstrap problem.
  ##
  ## 999d expiry matches the headscale CLI documentation example;
  ## headscale doesn't support truly non-expiring keys.
  systemd.services.headscale-mint-api-key = lib.mkIf deployHeadplane {
    description = "Mint a headscale API key for Headplane";
    after = [ "headscale.service" ];
    requires = [ "headscale.service" ];
    wantedBy = [ "headplane.service" ];
    before = [ "headplane.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      ${waitForHeadscale}
      mkdir -p ${headplaneSecretsDir}
      KEY_FILE=${headplaneSecretsDir}/headscale-api-key

      NEEDS_MINT=0
      if [ ! -s "$KEY_FILE" ]; then
        NEEDS_MINT=1
      else
        ## Extract the public prefix (everything before the last `-`
        ## of the `hskey-api-<prefix>-<secret>` format) and confirm
        ## headscale's DB still recognises it. `apikeys list` exits 0
        ## but emits no row when the key is gone.
        EXISTING=$(${pkgs.coreutils}/bin/tr -d '\n' < "$KEY_FILE")
        PREFIX=$(printf '%s' "$EXISTING" | ${pkgs.coreutils}/bin/cut -c1-23)
        if ! ${pkgs.headscale}/bin/headscale apikeys list 2>/dev/null \
             | ${pkgs.gnugrep}/bin/grep -qF "$PREFIX"; then
          echo "headscale-mint-api-key: stored key not in DB, re-minting" >&2
          NEEDS_MINT=1
        fi
      fi

      if [ "$NEEDS_MINT" = "1" ]; then
        ## headscale apikeys create prints a single line: the new key.
        ${pkgs.headscale}/bin/headscale apikeys create --expiration 999d \
          | ${pkgs.coreutils}/bin/tail -n1 \
          > "$KEY_FILE"
      fi
      chmod 600 "$KEY_FILE"
    '';
  };

  ## Mint a reusable headscale pre-auth key so the local tailscale client
  ## can self-onboard into the tailnet under user `server`. Same self-
  ## healing pattern as the API key: re-mint if the on-disk file is
  ## missing OR its key isn't recognised by headscale (e.g. after a
  ## headscale DB reset). Without this, the host's tailscaled stays
  ## "Logged out", no LAN subnet route is advertised, and clients on
  ## the tailnet (phones, laptops) can't reach 10.0.0.0/24 services.
  ##
  ## Pre-auth keys are single-use-by-design at registration time, but
  ## `--reusable` lets the same key onboard the host again if its node
  ## record is ever wiped without rebuilding. 999d expiry mirrors the
  ## API-key choice.
  ##
  ## The `server` headscale user is created by zitadel-provision /
  ## headscale-init flows; the CLI here errors if it's missing, which
  ## is the correct failure mode (mint must not silently mint into a
  ## new accidentally-created user).
  systemd.services.headscale-mint-tailscale-key = lib.mkIf deployHeadplane {
    description = "Mint a headscale pre-auth key for the local tailscale client";
    after = [ "headscale.service" ];
    requires = [ "headscale.service" ];
    wantedBy = [ "tailscaled-autoconnect.service" ];
    before = [ "tailscaled-autoconnect.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      ${waitForHeadscale}
      mkdir -p ${headplaneSecretsDir}
      KEY_FILE=${headplaneSecretsDir}/tailscale-key
      USERNAME=server
      JQ=${pkgs.jq}/bin/jq

      ## Ensure the `server` user exists; create on first boot so the
      ## mint below has somewhere to land. Idempotent. JSON output to
      ## avoid ANSI-color parsing.
      USER_ID=$(${pkgs.headscale}/bin/headscale users list -o json 2>/dev/null \
        | $JQ -r --arg n "$USERNAME" '.[] | select(.name == $n) | .id' \
        | ${pkgs.coreutils}/bin/head -n1)
      if [ -z "$USER_ID" ]; then
        ${pkgs.headscale}/bin/headscale users create "$USERNAME" >&2
        USER_ID=$(${pkgs.headscale}/bin/headscale users list -o json 2>/dev/null \
          | $JQ -r --arg n "$USERNAME" '.[] | select(.name == $n) | .id' \
          | ${pkgs.coreutils}/bin/head -n1)
      fi
      if [ -z "$USER_ID" ]; then
        echo "headscale-mint-tailscale-key: failed to resolve user $USERNAME id" >&2
        exit 1
      fi

      NEEDS_MINT=0
      if [ ! -s "$KEY_FILE" ]; then
        NEEDS_MINT=1
      else
        EXISTING=$(${pkgs.coreutils}/bin/tr -d '\n' < "$KEY_FILE")
        ## preauthkeys list is global; filter by user via jq and check
        ## that our stored key still appears (not expired/used-and-
        ## consumed for non-reusable, etc.). Reusable keys persist
        ## across registrations, so the in-DB check protects against
        ## headscale-DB-reset cases.
        IN_DB=$(${pkgs.headscale}/bin/headscale preauthkeys list -o json 2>/dev/null \
          | $JQ -r --arg k "$EXISTING" --argjson uid "$USER_ID" \
              '.[] | select(.user.id == $uid and .key == $k) | .key' \
          | ${pkgs.coreutils}/bin/head -n1)
        if [ -z "$IN_DB" ]; then
          echo "headscale-mint-tailscale-key: stored key not in DB, re-minting" >&2
          NEEDS_MINT=1
        fi
      fi

      if [ "$NEEDS_MINT" = "1" ]; then
        ## preauthkeys create -o json emits {"key": "..."} so we can
        ## pull the value cleanly without ANSI noise.
        ${pkgs.headscale}/bin/headscale preauthkeys create \
            --user "$USER_ID" \
            --reusable \
            --expiration 999d \
            -o json \
          | $JQ -r '.key' \
          > "$KEY_FILE"
      fi
      chmod 600 "$KEY_FILE"
    '';
  };

  ## LoadCredential bridges the SOPS-managed per-secret files into the
  ## headplane.service mount namespace at /run/credentials/headplane.service/<name>.
  ## The headplaneSettings YAML above points the *_path fields at exactly
  ## those resolved paths. We only load OIDC-related credentials when
  ## OIDC is actually configured — LoadCredential of a non-existent
  ## file is fatal at unit start.
  systemd.services.headplane = lib.mkIf deployHeadplane {
    after = [ "headscale.service" "dns-ready.service" "headplane-prepare-secrets.service" "headscale-mint-api-key.service" ];
    requires = [ "headscale.service" "headplane-prepare-secrets.service" "headscale-mint-api-key.service" ];
    wants = [ "dns-ready.service" ];
    ## Headplane reads two YAML files at startup whose store paths can
    ## change without the unit definition changing — meaning NixOS
    ## won't restart the unit on rebuild and the new config goes
    ## unread. Tie restarts to BOTH store paths:
    ##   * headscale-for-headplane.yaml — headscale's settings as seen
    ##     by headplane (DERP region IDs, IP prefixes, etc.).
    ##   * /etc/headplane/config.yaml — headplane's own config,
    ##     including 'server.port' which the port-allocator can shift
    ##     when the auto-pool's alphabetical assignment moves. Without
    ##     this trigger, an allocator-reshuffled headplane port keeps
    ##     binding the OLD number, and the new tenant of that number
    ##     (e.g. grocy) fails to start with EADDRINUSE.
    restartTriggers = [
      headscaleConfigForHeadplane
      config.environment.etc."headplane/config.yaml".source
    ];
    ## Don't try to start until BOTH OIDC secrets are on disk. A
    ## fresh install briefly has no headplane until
    ## zitadel-provision.service writes the files and `try-restart`s
    ## us. Without this gate, LoadCredential below would fail with
    ## status 243/CREDENTIALS on every (re)start until the user
    ## clicks "rebuild" a second time. ConditionPathExists is
    ## checked by systemd before any unit start, so failures here
    ## don't burn restart-counter attempts.
    unitConfig.ConditionPathExists = [
      "${headplaneSecretsDir}/oidc-client-id"
      "${headplaneSecretsDir}/oidc-client-secret"
      "${headplaneSecretsDir}/headscale-api-key"
    ];
    ## Headplane sits behind Caddy at https://vpn.<domain>/admin.
    ## Without server.base_url set, headplane defaults to
    ## http://localhost:3000 and emits broken OIDC redirect_uris and
    ## absolute-URL form actions. HEADPLANE_SERVER__BASE_URL is a
    ## plain string so the env-parser doesn't type-coerce it.
    ##
    ## HEADPLANE_CONFIG_PATH points at the runtime-rendered config
    ## written by headplane-prepare-secrets.service (which substitutes
    ## the real OIDC client_id for the placeholder).
    environment = {
      HEADPLANE_SERVER__BASE_URL = "https://vpn.${cfg.system.domain}";
      HEADPLANE_CONFIG_PATH = "${headplaneSecretsDir}/config.yaml";
    };
    serviceConfig = {
      ## Always load credentials — the ConditionPathExists gate
      ## above means we never reach LoadCredential without the
      ## files present.
      LoadCredential = [
        "headplane-cookie-secret:${headplaneSecretsDir}/headplane-cookie-secret"
        "oidc-client-secret:${headplaneSecretsDir}/oidc-client-secret"
        "headscale-api-key:${headplaneSecretsDir}/headscale-api-key"
      ];

      ## Re-assert the secrets-dir mode every single time headplane
      ## starts. Belt-and-suspenders: prepare-secrets already does
      ## this, but a unit chain that touches /var/lib/homefree-
      ## secrets/ (Python admin-api, future tooling, manual
      ## intervention) can land between prepare-secrets and us and
      ## reset the mode to 0700. headplane runs as user/group
      ## `headscale` and silently fails with "Could not access
      ## config file" if it can't traverse the parent dir.
      ##
      ## The `+` prefix runs this ExecStartPre as root regardless of
      ## the unit's User=/Group= (without it, headplane.service's
      ## User=headscale would propagate to ExecStartPre too, and
      ## chown'ing the dir to root:headscale would fail with EPERM).
      ##
      ## Idempotent: chmod/chown are no-ops if the perms already match.
      ExecStartPre = "+${pkgs.writeShellScript "headplane-assert-perms" ''
        set -eu
        ${pkgs.coreutils}/bin/chown root:${config.services.headscale.group} \
          ${headplaneSecretsDir}
        ${pkgs.coreutils}/bin/chmod 0750 ${headplaneSecretsDir}
      ''}";
    };
  };

  homefree.service-config = lib.optionals headscaleEnabled [
    {
      inherit (cfg.service-options.headscale) label name project-name;
      port-request = 8087;
      ## Host app (NixOS-native, no OCI image): current version is the
      ## nixpkgs build; latest comes from upstream GitHub Releases.
      version-tracking = {
        strategy = "nixpkgs";
        repo = "juanfont/headscale";
        current-version = pkgs.headscale.version;
      };
      systemd-service-names = [ "headscale" ]
        ++ lib.optional deployHeadplane "headplane";
      admin = {
        urlPathOverride = "/admin";
      };
      sso = {
        kind = "native_oidc";
        ## Dev context (intentionally not surfaced in the admin UI):
        ## Headscale native OIDC + Headplane admin UI. Admin via
        ## homefree-admin role.
      };
      reverse-proxy = {
        enable = true;
        ## @TODO: Use "vpn" as default
        subdomains = [ "vpn" "headscale" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = lan-address;
        port = config.services.headscale.port;
        public = true;
        extraCaddyConfig = ''
          # Fake DERP latency check (headscale doesn't implement this endpoint)
          handle /derp/latency-check {
            respond 200
          }

          # Handle DERP relay connections (requires HTTP upgrade).
          #
          # The DERP server (embedded Tailscale code) sends a keepalive
          # frame every 60s ± 5s jitter to every connected client. Each
          # write to the client uses tcpWriteTimeout, which defaults to
          # 2 seconds (DefaultTCPWiteTimeout in derp_server.go — note
          # the upstream typo). If ANY single keepalive write can't be
          # flushed to the client within 2s — because Caddy was
          # buffering, the upstream pool decided the connection was
          # "idle" and pruned it, or backpressure stalled the write —
          # the DERP server force-closes the connection and the client
          # logs `derp.Recv: EOF`. That is the failure mode we see
          # every 1-30 min in tailscaled logs.
          #
          # The block below lays out every Caddy knob that touches
          # long-lived upgraded connections, set conservatively so
          # nothing on our side can introduce a 2s+ stall:
          #   transport http versions 1.1: DERP requires HTTP/1.1
          #     Upgrade; h2 negotiation would break it.
          #   read_timeout / write_timeout 0: no upstream timeouts.
          #     Caddy's default is "until upstream closes" but explicit
          #     is safer.
          #   keepalive 24h, dial_timeout 5s: keep the upstream socket
          #     alive across keepalives; only fail dialing if upstream
          #     is genuinely unreachable.
          #   flush_interval -1: do not coalesce writes from upstream;
          #     each keepalive flushes immediately. Caddy auto-detects
          #     Upgrade and does this anyway, but explicit makes it
          #     auditable.
          @derp {
            path /derp /derp/*
          }
          handle @derp {
            reverse_proxy http://${lan-address}:${toString config.services.headscale.port} {
              transport http {
                versions 1.1
                read_timeout 0
                write_timeout 0
                dial_timeout 5s
                keepalive 24h
              }
              flush_interval -1
              header_up Connection {http.request.header.Connection}
              header_up Upgrade {http.request.header.Upgrade}
            }
          }

          # Handle Tailscale control protocol (requires HTTP upgrade).
          #
          # /ts2021 carries the long-lived noise control connection
          # used by tailscale ≥1.32 — clients hold it open and the
          # server long-polls map updates over it, with a NoOp
          # keepalive every ~60s as a liveness signal. Same shape as
          # /derp above: HTTP/1.1 Upgrade, no upstream timeouts,
          # immediate flush so the keepalive isn't buffered. Without
          # this transport block, Caddy defaults silently cut the
          # connection — observed as the phone's node cycling
          # "node added" / "node online" in headscale every few
          # seconds, even though data-plane wireguard packets keep
          # flowing. Tailscale Android surfaces the resulting
          # control-plane gap as "DNS unavailable" (it can't
          # validate its DNS config is current).
          @ts2021 {
            path /ts2021
          }
          handle @ts2021 {
            reverse_proxy http://${lan-address}:${toString config.services.headscale.port} {
              transport http {
                versions 1.1
                read_timeout 0
                write_timeout 0
                dial_timeout 5s
                keepalive 24h
              }
              flush_interval -1
              header_up Connection {http.request.header.Connection}
              header_up Upgrade {http.request.header.Upgrade}
            }
          }

          handle /admin* {
            ## Headplane binds on 127.0.0.1:${toString headplane-port}
            ## (port comes from the central allocator so it can shift
            ## between rebuilds — must not be hardcoded). Reach it via
            ## loopback rather than ${lan-address} where it doesn't listen.
            reverse_proxy http://127.0.0.1:${toString headplane-port}
          }

          ## Land users at the Headplane admin UI when they visit
          ## https://vpn.<domain>/ in a browser. Headplane is hard-coded
          ## to its /admin basename (see vite/react-router config in the
          ## upstream package), so this is a cosmetic redirect rather than
          ## a path remount. We match `/` exactly so headscale's other
          ## endpoints (/key, /derp/*, /ts2021, /machine/*, etc.) still
          ## reach the headscale daemon below.
          @root_only path /
          redir @root_only /admin/ 302
        '';
      };
      firewall = {
        open-ports = {
          tcp = [
            ## Allow Headscale DERP connections
            cfg.service-options.headscale.stun-port
          ];
          udp = [
            ## Allow Headscale DERP connections
            cfg.service-options.headscale.stun-port
            # Headscale connections
            41641
          ];
        };
      };
      backup = {
        paths = [
          "/var/lib/headscale"
        ];
      };
      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable Headscale VPN service";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make service accessible from WAN";
        }
        {
          path = "stun-port";
          type = "int";
          default = 3478;
          description = "DERP STUN relay port";
        }
        {
          path = "enable-public-derp-fallback";
          type = "bool";
          default = false;
          description = "Fall back to Tailscale public DERP if embedded relay is unreachable";
        }
        {
          path = "secrets";
          type = "submodule";
          description = "Headplane Zitadel SSO + API credentials. Optional — when all three OIDC fields are set the admin UI is locked behind Zitadel login; when empty, the admin UI is open behind Caddy/oauth2-proxy.";
          sops-managed = true;
          submodule-fields = [
            {
              path = "headplane-cookie-secret";
              type = "str";
              nullable = true;
              default = null;
              description = "32-byte session secret used by Headplane to sign cookies. Auto-generated on first boot if not set; setting it here just lets you carry the same value across re-installs.";
              sops-managed = true;
            }
            {
              path = "oidc-client-id";
              type = "str";
              nullable = true;
              default = null;
              description = "OIDC Client ID for the Headplane application in Zitadel.";
              sops-managed = true;
            }
            {
              path = "oidc-client-secret";
              type = "str";
              nullable = true;
              default = null;
              description = "OIDC client secret paired with the client ID above.";
              sops-managed = true;
            }
            {
              path = "headscale-api-key";
              type = "str";
              nullable = true;
              default = null;
              description = "Headscale API key for Headplane to query the gRPC API. Create with: headscale apikeys create --expiration 999d";
              sops-managed = true;
            }
          ];
        }
      ];
    }
    ## Phantom entry: claims Headplane's host port (3009) under its own
    ## label so the allocator deconflicts it alongside everything else.
    {
      label = "headscale-headplane";
      enable = config.homefree.service-options.headscale.enable;
      port-request = null;
      reverse-proxy.enable = false;
      admin.show = false;
      systemd-service-names = [];
    }
  ];
  # Cache headscale DNS locally to reduce DNS queries from tailscaled DERP retries
  # NOTE: Commented out - this overrides unbound DNS and prevents public resolution
  # networking.hosts = {
  #   "${lan-address}" = [ "headscale.homefree.host" "vpn.homefree.host" ];
  # };
  };
}
