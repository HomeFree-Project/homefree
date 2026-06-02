## ntfy-sh push notification service.
##
## ─── Why this exists ──────────────────────────────────────────────────
## Stage A of the Alerts framework (see modules/homefree-config-loader.nix
## and services/alerts/, when those land). The alerts engine publishes
## events to a single topic on this server; a paired phone with the ntfy
## app subscribes to the same topic and gets a push. No human ever logs
## into ntfy — it is wire-level infrastructure between the engine and
## the device.
##
## ─── Security model: topic-as-bearer ─────────────────────────────────
## ntfy runs WITHOUT any built-in auth (no users, no tokens, no acl).
## The security boundary is the *topic name* itself, an unguessable
## UUID generated at activation and anchored into the encrypted
## sops-managed secrets store. Anyone with the topic URL can publish
## AND subscribe, so the URL is treated as a bearer-token-equivalent
## (the admin UI shows it as a QR code for one-shot phone onboarding,
## same as any other 1-of-1 secret).
##
## Why not Caddy oauth2 gating: phone ntfy clients hold a long-lived
## SSE subscription and cannot carry browser SSO cookies. An oauth2
## gate would block the primary use case.
##
## Why not ntfy's own auth-file: it introduces a local username/password
## surface, against AGENTS.md rule 3 (SSO-only — no local accounts).
## Topic-as-secret threads that needle: the topic UUID is configuration,
## not credentials, and there is no login surface anywhere.
##
## Threats this leaves on the table: if the topic UUID leaks, anyone on
## the internet can read alerts ("a disk on box X is at 51°C") and spam
## the topic with noise pushes. The first is low-sensitivity, the second
## is rate-limited by ntfy (visitor-request-limit). Rotation is a topic
## regeneration — the alerts engine re-reads the file, the admin UI
## shows the new QR, phones re-pair.

{ config, lib, pkgs, ... }:
let
  cfg = config.homefree.service-options.ntfy;

  ## Same userOptions are mirrored into both `homefree.services.ntfy`
  ## (the JSON-binding target consumed by the loader) and
  ## `homefree.service-options.ntfy` (with internal metadata added).
  ## Pattern matches apps/grocy/default.nix and friends.
  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable the self-hosted ntfy-sh push notification server.
        Used as a channel by `homefree.alerts` (Stage B). Off by
        default so unrelated boxes are not surprised by an extra
        listening service after a HomeFree update.
      '';
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Expose ntfy on the WAN at `ntfy.<domain>`. Required if you
        want phones to receive pushes when they are off the LAN.
        When false, ntfy is reachable only on the LAN — phones must
        be on the home Wi-Fi to receive alerts.
      '';
    };
  };

  anchor = import ../../lib/secrets-anchor.nix { inherit lib pkgs; };

  ## Default ntfy listen port. Kept on localhost; Caddy is the WAN-
  ## facing endpoint. 2586 matches the upstream default so a
  ## hand-running ntfy CLI talks to the same port without surprise.
  port = 2586;
  domain = config.homefree.system.domain;
in
{
  options.homefree.services.ntfy = userOptions;

  options.homefree.service-options.ntfy = userOptions // {
    label = lib.mkOption {
      type = lib.types.str;
      default = "ntfy";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "ntfy";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "ntfy";
      internal = true;
      description = "Project name";
    };
  };

  config = lib.mkIf cfg.enable {
    services.ntfy-sh = {
      enable = true;
      settings = {
        base-url = "https://ntfy.${domain}";
        listen-http = "127.0.0.1:${toString port}";
        ## Trust X-Forwarded-* from Caddy so ntfy's per-IP rate-limit
        ## buckets key on the real client IP, not 127.0.0.1 (which
        ## would lump every request behind the proxy into one bucket
        ## and trip the limit constantly).
        behind-proxy = true;
      };
    };

    ## Generate the bearer-equivalent topic UUID at activation and
    ## anchor it into encrypted sops storage so a restore to fresh
    ## hardware re-materializes the SAME value. Without anchoring, a
    ## restore would mint a new topic and every paired phone would
    ## silently stop receiving alerts (subscribed to a defunct topic
    ## the engine no longer publishes to).
    systemd.services.ntfy-prepare-secrets = {
      description = "Generate / restore ntfy alert-topic secret";
      wantedBy = [ "multi-user.target" ];
      before = [ "ntfy-sh.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ${anchor.preamble}
        ${anchor.anchorSecret {
          service = "ntfy";
          key = "topic";
          dir = "/var/lib/homefree-secrets/ntfy";
          mode = "640";
          generate = "${pkgs.util-linux}/bin/uuidgen";
        }}
      '';
    };

    homefree.service-config = [{
      inherit (cfg) label name project-name;
      enable = cfg.enable;

      sso = {
        ## Push-notification transport between the alerts engine and a
        ## paired phone. Same posture as oauth2-proxy itself: this IS
        ## infrastructure, not an SSO consumer — hidden from the SSO
        ## admin page. Authentication is via topic-as-bearer (see file
        ## header), so no Zitadel involvement.
        kind = "infra";
      };

      systemd-service-names = [ "ntfy-sh" ];

      reverse-proxy = {
        enable = cfg.enable;
        subdomains = [ "ntfy" ];
        http-domains = [ config.homefree.system.localDomain "homefree.lan" ];
        https-domains = [ domain ];
        host = "127.0.0.1";
        port = port;
        ## No SSO gate — ntfy clients cannot carry browser cookies
        ## (see file header). The topic UUID is the bearer.
        oauth2 = false;
        public = cfg.public;
      };

      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable the ntfy-sh push notification service";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Expose ntfy on the WAN so phones can receive pushes off-LAN";
        }
      ];
    }];
  };
}
