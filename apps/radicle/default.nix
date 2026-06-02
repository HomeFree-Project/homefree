{ config, lib, pkgs, ... }:
let
  ## Radicle's P2P protocol port (TCP only — see upstream
  ## nixos module: `radicle-node --listen <addr>:<port>` and
  ## `networking.firewall.allowedTCPPorts = [ ... ]`). The
  ## "8776 TCP+UDP" claim that floats around the wider docs
  ## appears to conflate radicle with some other tool.
  node-port = config.homefree.allocPort "radicle";
  ## radicle-httpd's nominal default is 8080, but that collides with
  ## UniFi's Tomcat on this box (`apps/unifi:104` binds 0.0.0.0:8080
  ## → the explorer's /api/v1/stats request gets answered by UniFi's
  ## 400 page). Move to 8777, adjacent to the node port and clear of
  ## the catalog's existing allocations.
  httpd-port = config.homefree.allocPort "radicle-httpd";

  containerDataPath = "/var/lib/radicle";
  radicleSecretsDir = "/var/lib/homefree-secrets/radicle";

  domain = config.homefree.system.domain;
  localDomain = config.homefree.system.localDomain;
  lan-address = config.homefree.network.lan-address;
  hostname = config.networking.hostName;

  anchor = import ../../lib/secrets-anchor.nix { inherit lib pkgs; };

  radicleImage = import ./image.nix { inherit pkgs lib; };

  ## Pre-built radicle-explorer SPA from nixpkgs. `withConfig`
  ## bakes a `config/local.json` into the Vite build so the
  ## SPA defaults to THIS node as its preferred seed when a
  ## visitor lands on the page — without it the explorer
  ## would show its upstream default seed list. nixpkgs already
  ## vendors the twemoji asset set into the build output, so
  ## rule 8 (all assets local) is satisfied without our patching.
  explorerSite = pkgs.radicle-explorer.withConfig {
    preferredSeeds = [{
      hostname = "radicle.${domain}";
      port = 443;
      scheme = "https";
    }];
  };

  ## Minimal radicle-node config.json. radicle-node's `--force`
  ## flag fills in defaults for anything not set, so we only
  ## need to declare the per-instance bits: the node's alias
  ## (visible to peers) and any externally-reachable addresses
  ## to announce. Full schema lives in radicle-node src/node/config.rs.
  nodeConfig = {
    node = {
      alias = hostname;
      externalAddresses = config.homefree.service-options.radicle.external-addresses;
      seedingPolicy =
        if config.homefree.service-options.radicle.seed-policy == "track-all"
        then { default = "allow"; scope = "all"; }
        else { default = "block"; };
    };
  };

  configFile = pkgs.writeText "radicle-config.json" (builtins.toJSON nodeConfig);

  preStart = ''
    set -eu
    mkdir -p ${containerDataPath}/keys ${containerDataPath}/storage ${containerDataPath}/node
    chmod 700 ${containerDataPath} ${containerDataPath}/keys

    ${anchor.preamble}

    ## Anchor the passphrase first — the key-generation step below
    ## reads it to encrypt the freshly-generated private key.
    ${anchor.anchorSecret {
      service = "radicle";
      key = "passphrase";
      dir = radicleSecretsDir;
      mode = "600";
      generate = "${pkgs.openssl}/bin/openssl rand -base64 32 | ${pkgs.coreutils}/bin/tr -d '\\n'";
    }}

    ## Anchor the Ed25519 private key. Radicle uses standard
    ## OpenSSH ed25519 format (see the nixpkgs radicle-node
    ## test, which generates the keypair with
    ## `ssh-keygen -t ed25519 -N "" -f keys/radicle`). We
    ## encrypt with the anchored passphrase so the on-disk
    ## private key is useless without secrets.yaml decryption.
    ${anchor.anchorSecret {
      service = "radicle";
      key = "private-key";
      fileName = "radicle";
      dir = radicleSecretsDir;
      mode = "600";
      generate = ''
        _tmpdir=$(mktemp -d)
        _pass=$(cat ${radicleSecretsDir}/passphrase)
        ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -N "$_pass" -C "radicle" -f "$_tmpdir/k" -q
        cat "$_tmpdir/k"
        rm -rf "$_tmpdir"
      '';
      ## secrets-anchor captures the generate stdout via `$(...)`,
      ## which strips ALL trailing newlines. An OpenSSH-format PEM
      ## without the trailing newline after `-----END OPENSSH
      ## PRIVATE KEY-----` fails ssh-keygen's openssh-format parser;
      ## ssh-keygen then falls through to libcrypto's PEM parser
      ## ("error in libcrypto: unsupported"). Restore the trailing
      ## newline every boot — idempotent (only writes when missing).
      extraInstall = ''
        if [ -n "$(${pkgs.coreutils}/bin/tail -c1 "$ANCHOR_SECRET_FILE")" ]; then
          printf '\n' >> "$ANCHOR_SECRET_FILE"
          ${pkgs.coreutils}/bin/chmod 600 "$ANCHOR_SECRET_FILE"
        fi
      '';
    }}

    ## Derive the matching public key from the anchored private
    ## key + passphrase every boot. `ssh-keygen -y` reads a
    ## private key and prints its public counterpart — no need
    ## to anchor radicle.pub separately.
    _pass=$(cat ${radicleSecretsDir}/passphrase)
    ${pkgs.openssh}/bin/ssh-keygen -y -P "$_pass" -f ${radicleSecretsDir}/radicle \
      > ${radicleSecretsDir}/radicle.pub
    chmod 644 ${radicleSecretsDir}/radicle.pub

    ## Materialize the keypair into $RAD_HOME/keys/ (the
    ## radicle-node container's RAD_HOME bind mount). Copy
    ## rather than bind-mount: keeps the secrets volume off the
    ## container's mount table and avoids podman's "mount over
    ## mount" ordering pitfalls.
    install -m 600 ${radicleSecretsDir}/radicle ${containerDataPath}/keys/radicle
    install -m 644 ${radicleSecretsDir}/radicle.pub ${containerDataPath}/keys/radicle.pub

    ## Drop the runtime config.json (Nix-generated, regenerated
    ## every rebuild from the user's homefree-config.json bindings).
    install -m 644 ${configFile} ${containerDataPath}/config.json

    ## Env-file for the systemd unit. Holds RAD_PASSPHRASE so the
    ## node can unlock its own key on start; using an env-file
    ## (vs an inline `-e RAD_PASSPHRASE=...`) keeps the
    ## passphrase out of `ps`/journal/proc env listings.
    install -m 600 /dev/null ${containerDataPath}/runtime.env
    printf 'RAD_PASSPHRASE=%s\n' "$_pass" > ${containerDataPath}/runtime.env
    chmod 600 ${containerDataPath}/runtime.env
  '';

  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Radicle decentralized git node";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Expose web UI on WAN and open P2P port 8776 to WAN";
    };

    seed-policy = lib.mkOption {
      type = lib.types.enum [ "track-all" "track-trusted" ];
      default = "track-trusted";
      description = ''
        Seeding policy. "track-trusted" (default) only seeds repositories
        the node operator explicitly follows. "track-all" seeds every repo
        that gossips through the node — appropriate for a public seed
        node, but uses substantially more disk + bandwidth.
      '';
    };

    external-addresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = [ "radicle.example.com:8776" ];
      description = ''
        Externally reachable peer addresses to announce on the network.
        Required for other peers to be able to initiate connections to
        this node when public = true. Format: host:port.
      '';
    };

    forgejo-mirror = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Mirror all non-empty public Forgejo repos on this box to Radicle
        every 5 minutes. One-way: Forgejo is the source of truth, Radicle
        is the P2P republish layer. Requires services.forgejo.enable.
        Pushes are signed by THIS box's Radicle NID; per-commit author
        attribution is preserved in the git commit objects.
      '';
    };
  };
in
{
  imports = [ ./forgejo-mirror.nix ];

  options.homefree.services.radicle = userOptions;

  options.homefree.service-options.radicle = userOptions // {
    label = lib.mkOption {
      type = lib.types.str;
      default = "radicle";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Radicle";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Radicle";
      internal = true;
      description = "Project name";
    };
  };

  config = {
    ## Install the `rad` CLI on the host so the usual workflow
    ## (`rad init`, `rad push`, `rad issue`, `rad patch`) is one
    ## command away from any shell on the box. Matches what the
    ## upstream nixos module does; the CLI just needs RAD_HOME
    ## pointed at the box's data dir.
    environment.systemPackages =
      lib.optional config.homefree.service-options.radicle.enable pkgs.radicle-node;

    ## Make `rad` on the host default to the same RAD_HOME the
    ## containers use, so an operator typing `rad self` reads
    ## the same node identity (rather than spinning up a
    ## per-user empty one in $HOME/.radicle).
    environment.variables =
      lib.optionalAttrs config.homefree.service-options.radicle.enable {
        RAD_HOME = containerDataPath;
      };

    virtualisation.oci-containers.containers =
      lib.optionalAttrs config.homefree.service-options.radicle.enable {

        radicle-node = {
          imageFile = radicleImage;
          image = "homefree/radicle:local";

          autoStart = true;

          ports = [
            ## Radicle P2P — TCP only. WAN ingress is gated on
            ## reverse-proxy.public via router.nix:82.
            "0.0.0.0:${toString node-port}:${toString node-port}"
          ];

          volumes = [
            "/etc/localtime:/etc/localtime:ro"
            "${containerDataPath}:/root/.radicle"
          ];

          environmentFiles = [ "${containerDataPath}/runtime.env" ];

          environment = {
            TZ = config.homefree.system.timeZone;
            RAD_HOME = "/root/.radicle";
            RUST_LOG = "info";
          };

          cmd = [
            "radicle-node"
            "--force"
            "--listen" "0.0.0.0:${toString node-port}"
          ];
        };

        radicle-httpd = {
          imageFile = radicleImage;
          image = "homefree/radicle:local";

          autoStart = true;
          dependsOn = [ "radicle-node" ];

          ports = [
            ## Bind httpd to the LAN address only — Caddy
            ## reverse-proxies from there to the public domain.
            ## httpd is a read-only gateway over the node's
            ## storage; exposing it on 0.0.0.0 directly would
            ## duplicate what Caddy already does on 443.
            "${lan-address}:${toString httpd-port}:${toString httpd-port}"
          ];

          volumes = [
            "/etc/localtime:/etc/localtime:ro"
            ## RW mount: httpd needs to connect() to the radicle-node
            ## Unix control socket under $RAD_HOME/node/, and Unix-
            ## socket connect requires WRITE permission on the socket
            ## inode. A :ro mount strips that perm at the FS layer and
            ## endpoints like /api/v1/stats fail with EACCES.
            "${containerDataPath}:/root/.radicle"
          ];

          environment = {
            TZ = config.homefree.system.timeZone;
            RAD_HOME = "/root/.radicle";
            RUST_LOG = "info";
          };

          cmd = [
            "radicle-httpd"
            "--listen" "0.0.0.0:${toString httpd-port}"
          ];
        };
      };

    systemd.services.podman-radicle-node =
      lib.mkIf config.homefree.service-options.radicle.enable {
        after = [ "dns-ready.service" ];
        wants = [ "dns-ready.service" ];
        serviceConfig = {
          ExecStartPre = [
            "!${pkgs.writeShellScript "radicle-prestart" preStart}"
          ];
        };
      };

    systemd.services.podman-radicle-httpd =
      lib.mkIf config.homefree.service-options.radicle.enable {
        after = [ "dns-ready.service" "podman-radicle-node.service" ];
        wants = [ "dns-ready.service" ];
      };

    homefree.service-config = [{
      inherit (config.homefree.service-options.radicle) label name project-name;
      enable = config.homefree.service-options.radicle.enable;
      port-request = 8776;

      systemd-service-names = [
        "podman-radicle-node"
        "podman-radicle-httpd"
      ];

      sso = {
        ## Radicle has NO user-auth surface — identity is purely
        ## cryptographic (Ed25519 keypair), and the web UI is
        ## read-only by design (all mutations happen via the
        ## `rad` CLI on the box itself). Marking applicable=false
        ## tells the admin UI's SSO health screen to render
        ## "Not applicable" rather than "Not yet integrated".
        kind = "none";
        applicable = false;
      };

      reverse-proxy = {
        enable = config.homefree.service-options.radicle.enable;
        subdomains = [ "radicle" "rad" ];
        http-domains = [ "homefree.lan" localDomain ];
        https-domains = [ domain ];
        public = config.homefree.service-options.radicle.public;

        ## Serve the pre-built radicle-explorer SPA at the root.
        ## The /api/* handler in extraCaddyConfig below routes
        ## API calls through to radicle-httpd. Same pattern as
        ## services/admin-web (SPA + sibling JSON API).
        static-path = "${explorerSite}";

        extraCaddyConfig = ''
          ## radicle-explorer talks to the JSON API at /api/*;
          ## reverse-proxy those to radicle-httpd.
          @rad_api path /api/*
          handle @rad_api {
            reverse_proxy http://${lan-address}:${toString httpd-port}
          }

          ## SPA fallback. radicle-explorer is a client-side-routed
          ## SPA: URLs like /seeds/<host>/<rid> and /<rid>/tree/...
          ## have no corresponding file in the static build — the
          ## SPA's JS router resolves them after /index.html boots.
          ## Without this rewrite, a browser reload on any deep
          ## link 404s from Caddy's file_server.
          ##
          ## Matchers:
          ##   not path /api/*  — leave API calls untouched. Caddy's
          ##     directive ordering runs `rewrite` BEFORE `handle`,
          ##     so without this guard /api/v1/foo would be rewritten
          ##     to /index.html before the API handler ever saw it.
          ##   not file         — only fire when no static file exists
          ##     at the request path. /assets/<hash>.js, /favicon.ico,
          ##     /index.html itself etc. are real files and continue
          ##     to flow through to file_server normally. `file` uses
          ##     the `root` set in the parent static-path block.
          @rad_spa {
            not path /api/*
            not file
          }
          rewrite @rad_spa /index.html
        '';
      };

      firewall = {
        open-ports = {
          ## Radicle P2P — TCP only. router.nix:82 only emits
          ## the WAN ingress rule when reverse-proxy.public is
          ## true, so a single user-facing `public` toggle gates
          ## both the web UI's HTTPS exposure and the P2P port.
          tcp = [ node-port ];
        };
      };

      backup = {
        paths = [
          ## RAD_HOME — repos (storage/), node state (node/),
          ## the keypair (keys/), and config.json. The keypair
          ## ALSO lives in encrypted /etc/nixos/secrets via the
          ## anchor; this entry is the bulk-data backup.
          containerDataPath
        ];
      };

      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable Radicle decentralized git node";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Expose web UI on WAN and open P2P port 8776 to WAN";
        }
        {
          path = "seed-policy";
          type = "string";
          default = "track-trusted";
          description = "Seeding policy: track-trusted (only followed repos) or track-all (public seed)";
        }
        {
          path = "external-addresses";
          type = "listOf str";
          default = [];
          description = "Externally reachable peer addresses to announce (host:8776)";
        }
        {
          path = "forgejo-mirror";
          type = "bool";
          default = false;
          description = "Mirror Forgejo public non-empty repos to Radicle every 5 minutes (one-way)";
        }
      ];
    }
    {
      label = "radicle-httpd";
      name = "Radicle HTTPD";
      project-name = "Radicle";
      enable = config.homefree.service-options.radicle.enable;
      port-request = null;
      reverse-proxy.enable = false;
      admin.show = false;
      systemd-service-names = [];
    }];
  };
}
