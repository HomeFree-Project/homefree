{ config, lib, pkgs, ... }:
let
  ## Radicle ships three cooperating pieces. We run all of them as
  ## separate podman containers off the official images:
  ##
  ##  - radicle-node:   the P2P seed node. Replicates repos over the
  ##                    Radicle network and exposes the git-remote
  ##                    transport on radicleP2pPort.
  ##  - radicle-httpd:  a read-only HTTP API over the local node's
  ##                    storage. The web explorer talks to this.
  ##  - radicle-explorer: the browser UI for browsing repos. A static
  ##                    SPA that points at radicle-httpd.
  ##
  ## The official images are published on ghcr.io. Pin a concrete
  ## tag so rebuilds are reproducible; bump deliberately.
  nodeImage     = "ghcr.io/radicle-dev/radicle-node:1.2.1";
  httpdImage    = "ghcr.io/radicle-dev/radicle-httpd:1.2.1";
  explorerImage = "ghcr.io/radicle-dev/radicle-explorer:1.2.1";

  ## Single shared data dir holding the Radicle home (RAD_HOME):
  ## node identity keypair, replicated repo storage, and node
  ## socket. The node owns it read-write; httpd mounts it read-only.
  containerDataPath = "/var/lib/radicle-podman";

  ## The node identity keypair (Ed25519) lives here, generated once
  ## in preStart and then mounted into the node's RAD_HOME. Kept
  ## under the homefree-secrets tree at mode 600 like every other
  ## service secret (matches Forgejo's secrets layout).
  radicleSecretsDir = "/var/lib/homefree-secrets/radicle";

  ## Ports.
  ##  - radicleP2pPort: the Radicle network transport. Must be
  ##    reachable from the WAN for the node to seed/fetch from peers,
  ##    so it's opened in the firewall below.
  ##  - httpdPort:      radicle-httpd's local HTTP API. LAN-only;
  ##    Caddy reverse-proxies the explorer's API calls here.
  ##  - explorerPort:   the static web UI. Caddy fronts this.
  radicleP2pPort = 8776;
  httpdPort      = 8780;
  explorerPort   = 8781;

  domain = config.homefree.system.domain;

  ## Generate the node identity once, idempotently. `rad auth` in a
  ## throwaway container writes the keypair + node config into a
  ## fresh RAD_HOME; we only invoke it if the key is missing, so
  ## restarts and rebuilds are no-ops.
  ##
  ## RAD_PASSPHRASE is set empty so the secret key is stored
  ## unencrypted — required for an unattended node that must start
  ## without an interactive passphrase prompt. The key file still
  ## sits at mode 600 under the homefree-secrets tree.
  preStart = ''
    set -eu
    mkdir -p ${containerDataPath}
    mkdir -p ${radicleSecretsDir}

    ## First-boot identity generation. The official radicle-node
    ## image ships the `rad` CLI; run it once against the secrets
    ## dir as RAD_HOME to mint the keypair + default config.json.
    if [ ! -s ${radicleSecretsDir}/keys/radicle ]; then
      echo "radicle preStart: generating node identity" >&2
      ${pkgs.podman}/bin/podman run --rm \
        -e RAD_HOME=/keys \
        -e RAD_PASSPHRASE="" \
        -e RAD_ALIAS="${config.homefree.system.adminUsername}" \
        -v ${radicleSecretsDir}:/keys \
        --entrypoint rad \
        ${nodeImage} auth --alias "${config.homefree.system.adminUsername}" \
        || echo "radicle preStart: identity generation failed (non-fatal)" >&2
    fi
    if [ -d ${radicleSecretsDir}/keys ]; then
      chmod 700 ${radicleSecretsDir}/keys
      [ -f ${radicleSecretsDir}/keys/radicle ] \
        && chmod 600 ${radicleSecretsDir}/keys/radicle
    fi

    ## Seed the RAD_HOME used by the running containers with the
    ## generated identity. The node keeps its replicated repo
    ## storage under containerDataPath/storage; the identity is
    ## copied (not symlinked) so the secrets dir stays the canonical
    ## backup source while the node writes storage independently.
    mkdir -p ${containerDataPath}/keys
    if [ -f ${radicleSecretsDir}/keys/radicle ] \
       && [ ! -f ${containerDataPath}/keys/radicle ]; then
      ${pkgs.coreutils}/bin/cp -a ${radicleSecretsDir}/keys/. \
        ${containerDataPath}/keys/
    fi
    [ -f ${radicleSecretsDir}/config.json ] \
      && ${pkgs.coreutils}/bin/cp -a ${radicleSecretsDir}/config.json \
           ${containerDataPath}/config.json || true

    ## The radicle images run as a non-root uid; make the data dir
    ## writable by it. uid 1000 is the `radicle` user in the
    ## official images.
    ${pkgs.coreutils}/bin/chown -R 1000:1000 ${containerDataPath} || true
  '';
in
{
  options.homefree.service-options.radicle = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Radicle peer-to-peer code collaboration service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the web explorer to public on WAN port";
    };

    # Metadata - always available, not user-configurable
    label = lib.mkOption {
      type = lib.types.str;
      default = "radicle";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Code Collaboration (Radicle)";
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
    virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.radicle.enable {
      ## The P2P seed node. Owns the Radicle home read-write and
      ## exposes the network transport on radicleP2pPort.
      radicle-node = {
        image = nodeImage;
        autoStart = true;

        ports = [
          "0.0.0.0:${toString radicleP2pPort}:${toString radicleP2pPort}"
        ];

        volumes = [
          "/etc/localtime:/etc/localtime:ro"
          "${containerDataPath}:/radicle"
        ];

        environment = {
          TZ = config.homefree.system.timeZone;
          RAD_HOME = "/radicle";
          RAD_PASSPHRASE = "";
        };

        ## Listen on all interfaces inside the container so the
        ## published port reaches the Radicle network.
        cmd = [ "--listen" "0.0.0.0:${toString radicleP2pPort}" ];
      };

      ## Read-only HTTP API over the node's storage. Mounts the
      ## shared Radicle home read-only — it never writes.
      radicle-httpd = {
        image = httpdImage;
        autoStart = true;

        dependsOn = [ "radicle-node" ];

        ports = [
          "0.0.0.0:${toString httpdPort}:${toString httpdPort}"
        ];

        volumes = [
          "/etc/localtime:/etc/localtime:ro"
          "${containerDataPath}:/radicle:ro"
        ];

        environment = {
          TZ = config.homefree.system.timeZone;
          RAD_HOME = "/radicle";
        };

        cmd = [ "--listen" "0.0.0.0:${toString httpdPort}" ];
      };

      ## Static web UI. Points at the public httpd URL so the
      ## browser (not the container) can reach the API.
      radicle-explorer = {
        image = explorerImage;
        autoStart = true;

        dependsOn = [ "radicle-httpd" ];

        ports = [
          "0.0.0.0:${toString explorerPort}:80"
        ];

        environment = {
          TZ = config.homefree.system.timeZone;
        };
      };
    };

    systemd.services.podman-radicle-node = lib.optionalAttrs config.homefree.service-options.radicle.enable {
      after = [ "dns-ready.service" ];
      requires = [ "dns-ready.service" ];
      serviceConfig = {
        ExecStartPre = [ "!${pkgs.writeShellScript "radicle-prestart" preStart}" ];
      };
    };

    homefree.service-config = [{
      inherit (config.homefree.service-options.radicle) label name project-name;
      systemd-service-names = [
        "podman-radicle-node"
        "podman-radicle-httpd"
        "podman-radicle-explorer"
      ];
      sso = {
        ## Radicle is identity-based: access control is the node's
        ## own Ed25519 keypair, not username/password. The web
        ## explorer is a read-only browser over public repo data,
        ## so we gate it behind the Caddy oauth2-proxy SSO layer
        ## to keep it off the open internet by default.
        kind = "caddy_gated";
        notes = "Radicle uses cryptographic node identities, not passwords. The web explorer is read-only and gated behind the homefree SSO layer; pushing to repos uses the `rad` CLI with the node keypair.";
      };
      reverse-proxy = {
        enable = config.homefree.service-options.radicle.enable;
        subdomains = [ "radicle" "code" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = explorerPort;
        public = config.homefree.service-options.radicle.public;
        ## The explorer SPA makes XHR calls to the httpd API. Route
        ## /api/* (and the httpd-served raw endpoints) to
        ## radicle-httpd; everything else falls through to the
        ## explorer static site via the shared template's catch-all
        ## reverse_proxy.
        extraCaddyConfig = ''
          @radicle_api path /api/*
          handle @radicle_api {
            reverse_proxy http://${config.homefree.network.lan-address}:${toString httpdPort}
          }
        '';
      };
      firewall = {
        open-ports = {
          ## The Radicle P2P transport must be WAN-reachable for the
          ## node to seed to and fetch from network peers.
          tcp = [ radicleP2pPort ];
        };
      };
      backup = {
        paths = [
          ## Replicated repo storage + node config.
          containerDataPath
          ## The canonical node identity keypair. Losing this means
          ## losing the node's network identity permanently.
          radicleSecretsDir
        ];
      };
      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable Radicle peer-to-peer code collaboration service";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make the web explorer accessible from WAN";
        }
      ];
    }];
  };
}
