{ config, lib, pkgs, ... }:
let
  version = "15.0.1";
  containerDataPath = "/var/lib/forgejo";
  port = 3201;
  ssh-port = 3022;

  forgejoSecretsDir = "/var/lib/homefree-secrets/forgejo";
  domain = config.homefree.system.domain;

  ## Anchors auto-generated secrets into encrypted /etc/nixos/secrets
  ## so they survive a restore — see lib/secrets-anchor.nix.
  anchor = import ../../lib/secrets-anchor.nix { inherit lib pkgs; };

  ## SQL template to clear the GroupClaimName / AdminGroup fields
  ## on the existing Zitadel auth source row. Defined as a regular
  ## `"..."` Nix string so we don't have to escape apostrophes
  ## through the postStart `''..''` heredoc (each SQL empty-string
  ## `''` would become 6 apostrophes in `''..''`, unreadable).
  ## Contains a literal `__ID__` placeholder that postStart
  ## substitutes with the shell's $EXISTING_ID at runtime.
  clearAdminSyncSqlTemplate = "update login_source set cfg = json_set(json_set(cfg, '$.GroupClaimName', ''), '$.AdminGroup', '') where id=__ID__;";

  ## Where Forgejo's container expects to read secret values from.
  ## We mount the host-side secrets dir read-only at this path so the
  ## `..._FILE` env vars below resolve to readable paths inside the
  ## container without having to bake secrets into the image or pass
  ## them as plain env strings.
  forgejoContainerSecretsDir = "/run/secrets/forgejo";

  preStart = ''
    set -eu
    mkdir -p ${containerDataPath}
    mkdir -p ${forgejoSecretsDir}

    ${anchor.preamble}

    ## The three secrets needed to bypass Forgejo's install wizard,
    ## each anchored into encrypted /etc/nixos/secrets so it survives
    ## a restore (lib/secrets-anchor.nix).
    ##
    ## - secret-key: 64-char hex string Forgejo uses to derive internal
    ##   MACs and to decrypt stored 2FA secrets — regenerating it on a
    ##   restore would orphan every user's stored 2FA/token data.
    ## - internal-token: HS256-signed JWT secret for inter-process API
    ##   auth. Must be JWT-secret format (base64-of-random-bytes, what
    ##   `forgejo generate secret INTERNAL_TOKEN` produces, ~105 bytes).
    ## - admin-password: emergency escape hatch for the local admin
    ##   account; users normally log in via Zitadel.
    ${anchor.anchorSecret {
      service = "forgejo";
      key = "secret-key";
      dir = forgejoSecretsDir;
      generate = "${pkgs.openssl}/bin/openssl rand -hex 32";
    }}
    ${anchor.anchorSecret {
      service = "forgejo";
      key = "internal-token";
      dir = forgejoSecretsDir;
      generate = "${pkgs.openssl}/bin/openssl rand -base64 96 | ${pkgs.coreutils}/bin/tr -d '\\n'";
    }}
    ${anchor.anchorSecret {
      service = "forgejo";
      key = "admin-password";
      dir = forgejoSecretsDir;
      generate = "${pkgs.openssl}/bin/openssl rand -base64 24";
    }}

    ## Build a CA bundle the container can mount over its own
    ## /etc/ssl/certs/ca-certificates.crt. Caddy issues internal
    ## certs for sso.<domain> from a runtime-generated local CA
    ## that the stock Alpine bundle doesn't trust — without this
    ## `forgejo admin auth add-oauth` (and any subsequent OIDC
    ## discovery fetch) fails with "x509: certificate signed by
    ## unknown authority". Same pattern as netbird/nextcloud.
    {
      cat /etc/ssl/certs/ca-certificates.crt
      if [ -r /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt ]; then
        echo
        cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
      fi
    } > ${containerDataPath}/ca-bundle.crt
    chmod 644 ${containerDataPath}/ca-bundle.crt
  '';

  ## After Forgejo is up, register Zitadel as an OAuth auth source if
  ## both the OIDC secrets exist on disk AND there's no existing
  ## "Zitadel" auth source. Idempotent: re-runs are no-ops once the
  ## auth source is registered. The container ships `forgejo admin
  ## auth list-oauth` which we grep for the literal name.
  ##
  ## Runs as ExecStartPost in the systemd unit so it fires after
  ## every (re)start. zitadel-provision.service `restart`s
  ## podman-forgejo when it writes the OIDC secrets, which is what
  ## triggers the first-time registration.
  postStart = pkgs.writeShellScript "forgejo-poststart" ''
    set -u

    ## Wait up to 60s for forgejo to be ready inside the container.
    ## Both the admin-user CLI and the auth CLI need the app DB to
    ## be migrated, which doesn't finish until the web process is
    ## past first-request initialization.
    for i in $(seq 1 30); do
      if ${pkgs.podman}/bin/podman exec --user git forgejo \
           forgejo admin user list >/dev/null 2>&1; then
        break
      fi
      [ "$i" = 30 ] && {
        echo "forgejo postStart: forgejo CLI not responsive after 60s" >&2
        exit 0
      }
      sleep 2
    done

    ## Idempotently create the admin user. With INSTALL_LOCK=true
    ## (set in the container env) Forgejo skips the install wizard,
    ## but that means there's no admin user either. We bootstrap
    ## one here using the OS admin's username + email, with the
    ## auto-generated password from
    ## /var/lib/homefree-secrets/forgejo/admin-password.
    ##
    ## --must-change-password=false because Zitadel SSO will be the
    ## primary login path; the user shouldn't be forced through a
    ## password change for an account they may never use directly.
    ADMIN_USER="${config.homefree.system.adminUsername}"
    ADMIN_EMAIL="${config.homefree.system.adminEmail or "${config.homefree.system.adminUsername}@${domain}"}"
    if ! ${pkgs.podman}/bin/podman exec --user git forgejo \
           forgejo admin user list 2>/dev/null \
           | ${pkgs.gnugrep}/bin/grep -qE "^[0-9]+[[:space:]]+$ADMIN_USER\b"; then
      ADMIN_PASS=$(cat ${forgejoSecretsDir}/admin-password)
      echo "forgejo postStart: creating admin user '$ADMIN_USER'" >&2
      if ${pkgs.podman}/bin/podman exec --user git forgejo \
           forgejo admin user create \
             --username "$ADMIN_USER" \
             --password "$ADMIN_PASS" \
             --email "$ADMIN_EMAIL" \
             --admin \
             --must-change-password=false; then
        echo "forgejo postStart: admin user '$ADMIN_USER' created" >&2
      else
        echo "forgejo postStart: admin user creation failed (non-fatal)" >&2
      fi
    fi

    ## Bail quietly if SSO secrets aren't on disk yet — fresh install
    ## before zitadel-provision has run, or homefree.sso.per-service.
    ## forgejo.enable=false (in which case the secrets are gone after
    ## a wipe). Forgejo continues to serve unauthenticated traffic
    ## via its own login page.
    if [ ! -s "${forgejoSecretsDir}/oidc-client-id" ] \
       || [ ! -s "${forgejoSecretsDir}/oidc-client-secret" ]; then
      echo "forgejo postStart: no OIDC secrets yet, skipping Zitadel auth-source registration" >&2
      exit 0
    fi

    CID=$(cat ${forgejoSecretsDir}/oidc-client-id)
    CSEC=$(cat ${forgejoSecretsDir}/oidc-client-secret)

    ## Detect whether the Zitadel auth source already exists. If yes,
    ## update it (so config evolutions — new scopes, role-group
    ## mapping — land on upgraded instances). If no, create it.
    EXISTING_ID=$(${pkgs.podman}/bin/podman exec --user git forgejo \
      forgejo admin auth list 2>/dev/null \
      | ${pkgs.gnugrep}/bin/grep -E '^[0-9]+[[:space:]]+Zitadel\b' \
      | ${pkgs.gawk}/bin/awk '{print $1}' \
      | ${pkgs.coreutils}/bin/head -n1)

    ## Identity-only OIDC: no group-claim / admin-group sync. The
    ## admin user is bootstrapped via `forgejo admin user create
    ## --admin` above, and that admin flag in the Forgejo DB is the
    ## source of truth. Without --group-claim-name, Forgejo's OAuth
    ## handler skips the admin-sync step entirely, so a login with
    ## no group claim doesn't trigger the "demote to non-admin"
    ## path that fails with "can not delete the last admin user".
    ##
    ## Trade-off: role membership in Zitadel doesn't propagate to
    ## Forgejo admin status. See TODO.md "Zitadel→Forgejo role
    ## sync" for the path to re-enable this via Zitadel Actions.
    if [ -n "$EXISTING_ID" ]; then
      echo "forgejo postStart: updating existing Zitadel auth source (id=$EXISTING_ID)" >&2
      if ${pkgs.podman}/bin/podman exec --user git forgejo \
           forgejo admin auth update-oauth \
             --id "$EXISTING_ID" \
             --key "$CID" \
             --secret "$CSEC" \
             --auto-discover-url "https://sso.${domain}/.well-known/openid-configuration" \
             --scopes "openid email profile"; then
        echo "forgejo postStart: Zitadel auth source updated" >&2
      else
        echo "forgejo postStart: update failed (non-fatal)" >&2
      fi
      ## update-oauth treats empty --group-claim-name / --admin-group
      ## as "don't change" rather than "clear", so boxes upgraded from
      ## the previous role-sync config keep the old fields and
      ## continue triggering the admin-demote path. Clear them via
      ## direct SQL — JSON in the cfg column. Idempotent: a fresh
      ## install has empty strings already.
      ## SQL template defined in the let block (apostrophe escaping
      ## is awful inside the postStart double-single-quote heredoc).
      ## We substitute the shell's $EXISTING_ID into the __ID__ slot
      ## using a bash parameter-expansion replacement, which keeps
      ## the apostrophes intact.
      SQL_TEMPLATE=${lib.escapeShellArg clearAdminSyncSqlTemplate}
      SQL="''${SQL_TEMPLATE//__ID__/$EXISTING_ID}"
      ${pkgs.podman}/bin/podman exec --user git forgejo \
        sqlite3 /data/gitea/gitea.db "$SQL" \
        2>/dev/null || echo "forgejo postStart: SQL clear of admin-sync fields failed (non-fatal)" >&2
    else
      echo "forgejo postStart: registering Zitadel as OAuth source" >&2
      if ${pkgs.podman}/bin/podman exec --user git forgejo \
           forgejo admin auth add-oauth \
             --provider openidConnect \
             --name Zitadel \
             --key "$CID" \
             --secret "$CSEC" \
             --auto-discover-url "https://sso.${domain}/.well-known/openid-configuration" \
             --scopes "openid email profile"; then
        echo "forgejo postStart: Zitadel auth source registered" >&2
      else
        echo "forgejo postStart: registration failed (non-fatal)" >&2
      fi
    fi
  '';

  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Forgejo git service";
    };

    disable-registration = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Disable user registration";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };
  };
in
{
  options.homefree.services.forgejo = userOptions;

  options.homefree.service-options.forgejo = userOptions // {
    # Metadata - always available, not user-configurable
    label = lib.mkOption {
      type = lib.types.str;
      default = "forgejo";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Git";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Forgejo";
      internal = true;
      description = "Project name";
    };
  };

  config = {
    environment.systemPackages = [
      ## Installs "forgejo" executable
      pkgs.forgejo
    ];

    virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.forgejo.enable {
    forgejo = {
      image = "codeberg.org/forgejo/forgejo:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:${toString port}"
        "0.0.0.0:${toString ssh-port}:${toString ssh-port}"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}:/data"
        ## Mount the host secrets dir read-only so `..._FILE` env
        ## vars below can resolve to files inside the container.
        "${forgejoSecretsDir}:${forgejoContainerSecretsDir}:ro"
        ## Trust Caddy's local CA so `forgejo admin auth add-oauth`
        ## and the runtime OIDC discovery fetch succeed. See
        ## ca-bundle synthesis in preStart.
        "${containerDataPath}/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;

        ## Skip the install wizard entirely. Without this Forgejo
        ## boots with INSTALL_LOCK=false in app.ini and serves the
        ## "Initial Configuration" form on every fresh start. With
        ## this set, Forgejo expects SECRET_KEY + INTERNAL_TOKEN +
        ## a working DB config to be present at startup — all of
        ## which we provide via the FORGEJO__security__* env vars
        ## below and the bundled sqlite default. The first user
        ## becomes the site admin (no separate "make me admin"
        ## step needed). Admin user creation happens in postStart
        ## via `forgejo admin user create`.
        FORGEJO__security__INSTALL_LOCK = "true";

        ## Both secrets generated in preStart, mounted under
        ## ${forgejoContainerSecretsDir} via the volume above.
        ## The `..._FILE` suffix tells Forgejo to read the value
        ## from the file path rather than treating the env var as
        ## the literal value — keeps secrets out of `ps`/proc env
        ## listings.
        FORGEJO__security__SECRET_KEY__FILE = "${forgejoContainerSecretsDir}/secret-key";
        FORGEJO__security__INTERNAL_TOKEN__FILE = "${forgejoContainerSecretsDir}/internal-token";

        ## app.ini server config
        FORGEJO__server__HTTP_PORT = toString port;
        FORGEJO__server__DOMAIN = "git.${config.homefree.system.domain}";
        FORGEJO__server__MINIMUM_KEY_SIZE_CHECK = "false";
        FORGEJO__server__START_SSH_SERVER = "true";
        ## Container internal port
        FORGEJO__server__SSH_LISTEN_PORT = toString ssh-port;
        ## External port
        FORGEJO__server__SSH_PORT = toString ssh-port;
        FORGEJO__server__ROOT_URL = "https://git.${config.homefree.system.domain}";

        ## app.ini service config
        ##
        ## When OIDC is the intended login path, registration must
        ## be enabled at the service level (DISABLE_REGISTRATION=
        ## false) so the OAuth flow can auto-create accounts —
        ## otherwise Forgejo serves the /user/link_account page
        ## with no submit button and the user is stuck. The
        ## ALLOW_ONLY_EXTERNAL_REGISTRATION + SHOW_REGISTRATION_BUTTON
        ## flags below close off the local signup form so the
        ## "registration enabled" status doesn't leak through to
        ## the UI. Net effect matches the user-visible
        ## `disable-registration` intent: no public sign-ups, just
        ## SSO-driven account creation.
        FORGEJO__service__DISABLE_REGISTRATION = "false";
        FORGEJO__service__ALLOW_ONLY_EXTERNAL_REGISTRATION = "true";
        FORGEJO__service__SHOW_REGISTRATION_BUTTON =
          if config.homefree.service-options.forgejo.disable-registration == true then "false" else "true";
        FORGEJO__service__REGISTER_EMAIL_CONFIRM = "false";

        ## OIDC-driven account creation + auto-link.
        ##  - ENABLE_AUTO_REGISTRATION: skips the link_account page
        ##    and creates a local account on first OAuth login.
        ##    Requires DISABLE_REGISTRATION=false above.
        ##  - USERNAME=nickname: Forgejo's goth client populates the
        ##    `nickname` field from the OIDC `preferred_username`
        ##    claim (which Zitadel sends by default). Using this as
        ##    the local username keeps the OS/Zitadel/Forgejo
        ##    usernames in sync.
        ##  - ACCOUNT_LINKING=auto: when a local account already
        ##    exists with the same username (the admin we bootstrap
        ##    in postStart), silently link the OAuth identity to
        ##    it instead of prompting. Resolution order: username
        ##    first, then email.
        ##  - OPENID_CONNECT_SCOPES: matches what we ask for in
        ##    `add-oauth --scopes "openid email profile"` so the ID
        ##    token has the claims we need to populate the local
        ##    user record (preferred_username, email, name).
        FORGEJO__oauth2_client__ENABLE_AUTO_REGISTRATION = "true";
        FORGEJO__oauth2_client__USERNAME = "nickname";
        FORGEJO__oauth2_client__ACCOUNT_LINKING = "auto";
        FORGEJO__oauth2_client__REGISTER_EMAIL_CONFIRM = "false";
        FORGEJO__oauth2_client__OPENID_CONNECT_SCOPES = "openid profile email";
        FORGEJO__oauth2_client__UPDATE_AVATAR = "true";

        ## Hide the local password form on the sign-in page. Combined
        ## with the /user/login → /user/oauth2/Zitadel rewrite in
        ## Caddy (extraCaddyConfig below), this delivers a true
        ## zero-click SSO experience: visit git.<domain> → bounce to
        ## Zitadel → done.
        ##
        ## Trade-offs:
        ##  - ENABLE_INTERNAL_SIGNIN=false (Forgejo ≥10.0): hides
        ##    the username/password form. The local admin account
        ##    still exists (we create it in postStart) and can be
        ##    used via `forgejo admin user change-password` from
        ##    inside the container as an emergency recovery path.
        ##  - ENABLE_BASIC_AUTHENTICATION=false: blocks `git push`
        ##    over HTTPS with raw passwords. Users must mint a
        ##    personal access token (Settings → Applications →
        ##    Generate New Token) and use that as the password in
        ##    git's credential prompt. Tokens still work as Basic
        ##    auth credentials, so existing tooling that knows how
        ##    to use a PAT keeps working.
        FORGEJO__service__ENABLE_INTERNAL_SIGNIN = "false";
        FORGEJO__service__ENABLE_BASIC_AUTHENTICATION = "false";

        ## app.ini migrations config
        FORGEJO__migrations__ALLOWED_DOMAINS = "*";
        FORGEJO__migrations__ALLOW_LOCALNETWORKS = "true";
        FORGEJO__migrations__SKIP_TLS_VERIFY = "true";

        ## app.ini actions config
        FORGEJO__actions__ENABLED = "true";
        FORGEJO__actions__DEFAULT_ACTIONS_URL = "github";

        ## app.ini mailer config
        # FORGEJO__mailer__ENABLED = "true";
        # FORGEJO__mailer__SMTP_ADDR = "mail.example.com";
        # FORGEJO__mailer__FROM = "noreply@${srv.DOMAIN}";
        # FORGEJO__mailer__USER = "noreply@${srv.DOMAIN}";

        ## Database config
        # FORGEJO__database__DB_TYPE = "postgres";
        # FORGEJO__database__HOST = "db:5432";
        # FORGEJO__database__NAME = "forgejo";
        # FORGEJO__database__USER = "forgejo";
        # FORGEJO__database__PASSWD = "forgejo";
      };
    };
  };

    systemd.services.podman-forgejo = lib.optionalAttrs config.homefree.service-options.forgejo.enable {
    after = [ "dns-ready.service" ];
    wants = [ "dns-ready.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "forgejo-prestart" preStart}" ];
      ExecStartPost = [ "!${postStart}" ];
    };
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.forgejo) label name project-name;
      systemd-service-names = [
        "podman-forgejo"
      ];
      sso = {
        kind = "native_oidc";
        ## Dev context (intentionally not surfaced in the admin UI):
        ## Native OIDC; homefree-admin role maps to Forgejo admin via
        ## oauth_admins_role.
      };
      reverse-proxy = {
        enable = config.homefree.service-options.forgejo.enable;
        subdomains = [ "git" "forgejo" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.forgejo.public;
        ## Force every visit to /user/login to bounce straight to
        ## the Zitadel OAuth flow. Combined with the
        ## ENABLE_INTERNAL_SIGNIN=false / ENABLE_BASIC_AUTHENTICATION=
        ## false env vars set on the container, this gives a true
        ## zero-click SSO experience: visit git.<domain> →
        ## redirect to /user/login → redirect to Zitadel → done.
        ##
        ## The OAuth source name "Zitadel" must match the --name
        ## argument in `forgejo admin auth add-oauth` (see the
        ## postStart hook). Forgejo's OAuth callback path
        ## /user/oauth2/<name>/callback is also Zitadel-aware, so
        ## we don't need to rewrite anything else.
        ##
        ## Emergency escape: if Zitadel breaks, comment out this
        ## extraCaddyConfig and re-run scripts/build.sh. The local
        ## form will reappear once ENABLE_INTERNAL_SIGNIN is also
        ## flipped back to true (default).
        extraCaddyConfig = ''
          ## Top-level `redir` (NOT wrapped in handle/route). The
          ## shared caddy.nix template emits a catch-all
          ## `handle { reverse_proxy ... }` for this site; if the
          ## redir lived inside its own `handle` block, Caddy's
          ## first-match semantics would let the catch-all eat the
          ## request before our matcher fired. As a top-level
          ## directive `redir` is sorted by Caddy's directive
          ## ordering — which places it *before* `handle` — so it
          ## takes effect first.
          ##
          ## {query} is Caddy's full original query string ("a=1&b=2"
          ## without the leading ?). Forgejo's standard deep-link
          ## flow sets `?redirect_to=<path>` on /user/login so it
          ## can return the user to the page they tried to reach.
          ## Forwarding the entire query string preserves that.
          @forgejo_login path /user/login
          redir @forgejo_login /user/oauth2/Zitadel?{query} 302
        '';
      };
      firewall = {
        open-ports = {
          tcp = [ ssh-port ];
        };
      };
      backup = {
        paths = [
          containerDataPath
        ];
      };
      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable Forgejo git hosting service";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make service accessible from WAN";
        }
        {
          path = "disable-registration";
          type = "bool";
          default = true;
          description = "Disable user registration";
        }
      ];
    }];
  };
}

