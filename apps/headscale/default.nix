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

  # All domains that need split DNS: system domains + proxied domains
  all-split-domains = search-domains ++ proxiedBaseDomains;
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

  headplane-port = 3009;

  ## Per-secret files for SOPS-managed secrets — same pattern as
  ## services/zitadel-podman.nix. The cookie secret is the one
  ## exception: it doesn't *need* to be SOPS-managed because losing it
  ## just invalidates active sessions, so we auto-generate it on first
  ## boot if absent (see headplaneCookiePreStart below). The OIDC creds
  ## and the headscale API key, in contrast, must be set deliberately.
  headplaneSecretsDir = "/var/lib/homefree-secrets/headscale";

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
  headscaleSettingsForHeadplane =
    lib.filterAttrsRecursive (_: v: v != null) config.services.headscale.settings;
  headscaleFullConfigFile =
    (pkgs.formats.yaml {}).generate "headscale-full.yaml"
      headscaleSettingsForHeadplane;

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
    source = headscaleFullConfigFile;
    ## Headplane runs as the headscale user (per the upstream module),
    ## so make this readable by that group.
    mode = "0440";
    user = "headscale";
    group = "headscale";
  };

  services.headscale = lib.optionalAttrs headscaleEnabled {
    enable = true ;
    port = 8087;
    address = lan-address;
    settings = {
      server_url = "https://headscale.${cfg.system.domain}:443";
      # policy.path = policy;
      dns = {
        magic_dns = true;
        # override_local_dns = true;
        ## Must be different from server domain
        base_domain = "homefree.vpn";
        # search_domains = search-domains;
        ## Add
        ## Order matters in headscale 0.26+: the first reachable resolver is
        ## preferred, so put the LAN resolver first to get split-horizon and
        ## ad-blocking; the public resolvers are fallbacks for when the LAN
        ## resolver is unreachable.
        nameservers.global = [
          ## Internal DNS — has local domain names + ad-blocking via unbound
          lan-address
          ## Backup if LAN resolver is unreachable (e.g. before tunnel is up)
          "9.9.9.10"
          ## Secondary backup
          "1.1.1.1"
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
      derp = {
        ## Frequency to update DERP maps
        auto_update_enable = true;
        update_frequency = "5m";
        server = {
          enabled = true;
          region_id = 999;
          region_code = "headscale";
          region_name = "headscale Embedded DERP";
          stun_listen_addr = "0.0.0.0:${toString cfg.service-options.headscale.stun-port}";
          automatically_add_embedded_derp_region = true;
        };
        urls = if cfg.service-options.headscale.enable-public-derp-fallback
          then [ "https://controlplane.tailscale.com/derpmap/default" ]
          else [];
        paths = [];
      };
    };
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
  systemd.services.headscale-enable-routes = lib.optionalAttrs headscaleEnabled {
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
      if [ ! -s "${headplaneSecretsDir}/headplane-cookie-secret" ]; then
        ${pkgs.openssl}/bin/openssl rand -base64 32 | head -c 32 \
          > "${headplaneSecretsDir}/headplane-cookie-secret"
      fi
      chmod 600 "${headplaneSecretsDir}/headplane-cookie-secret"

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
    requires = [ "headscale.service" "dns-ready.service" "headplane-prepare-secrets.service" "headscale-mint-api-key.service" ];
    ## Headplane reads the headscale config file at startup; if we
    ## regenerate that file but the unit definition is otherwise
    ## unchanged, NixOS won't restart the unit on rebuild and the new
    ## config goes unread. Tie restarts to the file's store path.
    restartTriggers = [ headscaleFullConfigFile ];
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
      systemd-service-names = [ "headscale" ]
        ++ lib.optional deployHeadplane "headplane";
      admin = {
        urlPathOverride = "/admin";
      };
      sso = {
        kind = "native_oidc";
        notes = "Headscale native OIDC + Headplane admin UI. Admin via homefree-admin role.";
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

          # Handle DERP relay connections (requires HTTP upgrade)
          @derp {
            path /derp /derp/*
          }
          handle @derp {
            reverse_proxy http://${lan-address}:${toString config.services.headscale.port} {
              header_up Connection {http.request.header.Connection}
              header_up Upgrade {http.request.header.Upgrade}
            }
          }

          # Handle Tailscale control protocol (requires HTTP upgrade)
          @ts2021 {
            path /ts2021
          }
          handle @ts2021 {
            reverse_proxy http://${lan-address}:${toString config.services.headscale.port} {
              header_up Connection {http.request.header.Connection}
              header_up Upgrade {http.request.header.Upgrade}
            }
          }

          handle /admin* {
            ## Headplane binds on 127.0.0.1:3009 (server.host above); reach
            ## it via loopback rather than ${lan-address} where it doesn't listen.
            reverse_proxy http://127.0.0.1:3009
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
  ];
  # Cache headscale DNS locally to reduce DNS queries from tailscaled DERP retries
  # NOTE: Commented out - this overrides unbound DNS and prevents public resolution
  # networking.hosts = {
  #   "${lan-address}" = [ "headscale.homefree.host" "vpn.homefree.host" ];
  # };
  };
}
