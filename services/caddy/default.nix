{ config, lib, pkgs, ... }:
let
  lan-address = config.homefree.network.lan-address;
  proxiedHostConfig = lib.filter (service-config: service-config.reverse-proxy.enable == true) config.homefree.service-config;
  proxiedDomains = config.homefree.proxied-domains;
  trimTrailingSlash = s: lib.head (lib.match "(.*[^/])[/]*" s);

  ## NOTE: the admin-role-check `forward_auth` (with its friendly
  ## access-denied page) used to be defined inline here as
  ## `accessDeniedHtml` + `adminCheckDenyHandler`. It now lives in
  ## services/admin-web/default.nix as the `admin_api_admin_check`
  ## Caddy snippet, because the admin-api upstream port is rewritten
  ## at runtime by the blue/green flip. The two call sites below
  ## just `import admin_api_admin_check` (the snippet definition is
  ## brought in by the file-scope `import` of the runtime snippet).

  # Process proxied domains for standard reverse proxy (proxy handles TLS)
  processedProxiedDomains = lib.flatten (lib.map (domain-mapping:
    let
      httpEntries = if domain-mapping.target.http != null then
        lib.map (domain: {
          inherit domain;
          inherit (domain-mapping) public;
          inherit (domain-mapping.target) host;
          port = domain-mapping.target.http.port;
          ssl = false;
          ignore-self-signed-cert = false;
        }) domain-mapping.domains
      else [];

      httpsEntries = if domain-mapping.target.https != null then
        lib.map (domain: {
          inherit domain;
          inherit (domain-mapping) public;
          inherit (domain-mapping.target) host;
          port = domain-mapping.target.https.port;
          ssl = true;
          ignore-self-signed-cert = domain-mapping.target.https.ignore-self-signed-cert;
        }) domain-mapping.domains
      else [];
    in
      httpEntries ++ httpsEntries
  ) proxiedDomains);
in
{
  # Service to create DNS token env file readable by caddy user
  systemd.services.caddy-dns-token = lib.mkIf (config.homefree.dns.remote.cert-management.dns-01.secrets.api-token != null) {
    description = "Create Caddy DNS API Token for caddy user";
    wantedBy = [ "caddy.service" ];
    before = [ "caddy.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p /run/caddy-secrets
      cp ${toString config.homefree.dns.remote.cert-management.dns-01.secrets.api-token} /run/caddy-secrets/dns-api-token
      chown caddy:caddy /run/caddy-secrets/dns-api-token
      chmod 400 /run/caddy-secrets/dns-api-token
    '';
  };

  # Service to install Caddy's root CA into system trust store in development mode
  systemd.services.caddy-trust-root-ca = lib.mkIf config.homefree.development {
    description = "Install Caddy root CA certificate";
    wantedBy = [ "multi-user.target" ];
    after = [ "caddy.service" ];
    requires = [ "caddy.service" ];
    path = with pkgs; [ coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Wait for Caddy to generate the root CA (up to 30 seconds)
      for i in {1..30}; do
        if [ -f /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt ]; then
          break
        fi
        sleep 1
      done

      # Install the root CA into the system trust store
      if [ -f /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt ]; then
        # Copy to the system CA certificates directory
        mkdir -p /etc/ssl/certs
        cp /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt /etc/ssl/certs/caddy-root-ca.pem
        chmod 644 /etc/ssl/certs/caddy-root-ca.pem

        # Get the certificate hash for symlinking (OpenSSL format)
        CERT_HASH=$(${pkgs.openssl}/bin/openssl x509 -in /etc/ssl/certs/caddy-root-ca.pem -noout -hash)

        # Create the hash symlink that OpenSSL/NSS expects
        if [ -n "$CERT_HASH" ]; then
          ln -sf /etc/ssl/certs/caddy-root-ca.pem /etc/ssl/certs/$CERT_HASH.0
          echo "Caddy root CA installed: /etc/ssl/certs/caddy-root-ca.pem (hash: $CERT_HASH)"
        else
          echo "Warning: Failed to get certificate hash"
          exit 1
        fi
      else
        echo "Warning: Caddy root CA not found at /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt"
        exit 1
      fi
    '';
  };

  nixpkgs.overlays = [
    (import ../../overlays/caddy-with-plugins.nix)
  ] ++ lib.optional (config.homefree.dns.remote.cert-management.dns-01.secrets.api-token != null) (final: prev: {
    caddy-with-dns-token = prev.writeShellScriptBin "caddy" ''
      if [ -f /run/caddy-secrets/dns-api-token ]; then
        export DNS_API_TOKEN=''$(cat /run/caddy-secrets/dns-api-token)
      fi
      exec ${final.caddy-with-plugins}/bin/caddy "$@"
    '';
  });

  ## ── Caddy runtime secrets bridge ─────────────────────────────────
  ## Builds /run/caddy-secrets/runtime.env with whatever values Caddy
  ## needs to interpolate via {env.NAME} at request time:
  ##
  ##   - ADGUARD_BASIC_AUTH=<base64(user:pass)>: injected as an
  ##     `Authorization: Basic ...` header on every request forwarded
  ##     to AdGuard. Without it, users who passed the oauth2-proxy
  ##     gate still see AdGuard's local login form because AdGuard
  ##     has no native OIDC support.
  ##
  ##   - OAUTH2_PROXY_CLIENT_ID=<id>: the OIDC client_id of the
  ##     oauth2-proxy app on Zitadel. Used in upstream-logout-paths
  ##     redirects so Zitadel honors post_logout_redirect_uri (which
  ##     it ignores when no client_id/id_token_hint is supplied —
  ##     stranding the user on Zitadel's "Logout successful" page).
  ##     Not a secret: it's already visible in every authenticated
  ##     user's browser during the SSO flow.
  ##
  ## Gated on the corresponding secret files existing — if AdGuard
  ## or Zitadel haven't provisioned yet, the relevant var is written
  ## empty so Caddy starts cleanly.
  systemd.services.caddy-adguard-basic-auth = lib.mkIf
    (config.homefree.services.adguard.enable or false) {
    description = "Build Caddy runtime env (Basic-Auth bridge + OIDC client_id)";
    wantedBy = [ "caddy.service" ];
    before = [ "caddy.service" ];
    after = [ "podman-adguardhome.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [ coreutils ];
    script = ''
      mkdir -p /run/caddy-secrets
      ADGUARD_SECRETS=/var/lib/homefree-secrets/adguard
      ADMIN_FILE=/var/lib/homefree-admin/admin-username
      ZITADEL_CLIENT_ID_FILE=/var/lib/homefree-secrets/zitadel/oidc-client-id
      ENV_FILE=/run/caddy-secrets/adguard-basic-auth.env

      # Truncate first; we'll append each line as it becomes
      # available so a missing dependency only blanks that one var.
      : > "$ENV_FILE"

      if [ -s "$ADGUARD_SECRETS/admin-password" ] && [ -s "$ADMIN_FILE" ]; then
        USERNAME=$(cat "$ADMIN_FILE")
        PASS=$(cat "$ADGUARD_SECRETS/admin-password")
        AUTH=$(printf '%s:%s' "$USERNAME" "$PASS" | base64 -w0)
        printf 'ADGUARD_BASIC_AUTH=%s\n' "$AUTH" >> "$ENV_FILE"
      else
        # Not yet provisioned — write an empty value so Caddy's
        # {env.ADGUARD_BASIC_AUTH} interpolation doesn't fail.
        printf 'ADGUARD_BASIC_AUTH=\n' >> "$ENV_FILE"
      fi

      if [ -s "$ZITADEL_CLIENT_ID_FILE" ]; then
        printf 'OAUTH2_PROXY_CLIENT_ID=%s\n' \
          "$(cat "$ZITADEL_CLIENT_ID_FILE")" >> "$ENV_FILE"
      else
        printf 'OAUTH2_PROXY_CLIENT_ID=\n' >> "$ENV_FILE"
      fi

      chown root:caddy "$ENV_FILE"
      chmod 640 "$ENV_FILE"
      ## NOTE: do NOT run `systemctl reload caddy.service` here.
      ## This unit declares `wantedBy = caddy.service` + `before =
      ## caddy.service`, so systemd treats a reload-during-start as a
      ## dependency cycle and kills *this* unit with SIGTERM. Caddy
      ## reads EnvironmentFile fresh on every (re)start, so on first
      ## boot it'll just pick up the value we wrote above when systemd
      ## starts it next in the dependency chain.
      ##
      ## Credential ROTATION (when AdGuard's preStart regenerates the
      ## password) is handled by the AdGuard side: that script
      ## restarts THIS unit, which rewrites the env file, then the
      ## AdGuard preStart issues a separate reload of caddy.service.
      ## See services/adguardhome-podman.nix.
    '';
  };

  systemd.services.caddy = {
    after = [ "dns-ready.service" ]
      ++ lib.optional (config.homefree.services.adguard.enable or false)
           "caddy-adguard-basic-auth.service";
    wants = [ "dns-ready.service" ]
      ++ lib.optional (config.homefree.services.adguard.enable or false)
           "caddy-adguard-basic-auth.service";
    requires = [ "dns-ready.service" ];
    ## Restart Caddy with Unbound DNS changes
    ## NOTE: Commented out - creates circular dependency with unbound's partOf below.
    ## This causes 90-second delays when restarting unbound (caddy times out on SIGTERM).
    ## NixOS already handles config-triggered restarts via X-Restart-Triggers/X-Reload-Triggers.
    ## Was added for a reason - watch for issues after disabling.
    # partOf = [ "unbound.service" ];

    serviceConfig = lib.mkMerge [
      ## Grant capability to bind to privileged ports when using wrapper
      (lib.mkIf
        (config.homefree.dns.remote.cert-management.dns-01.secrets.api-token != null)
        { AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ]; })
      ## Load AdGuard Basic-Auth credential when AdGuard is enabled.
      ## The leading `-` makes the env file optional — if the bridge
      ## service hasn't run yet, Caddy still starts.
      (lib.mkIf (config.homefree.services.adguard.enable or false)
        { EnvironmentFile = "-/run/caddy-secrets/adguard-basic-auth.env"; })
    ];
  };

  ## Restart Unbound DNS with caddy changes
  ## NOTE: Commented out partOf - creates circular dependency with caddy's partOf above.
  ## This causes 90-second delays when restarting unbound (caddy times out on SIGTERM).
  ## NixOS already handles config-triggered restarts via X-Restart-Triggers/X-Reload-Triggers.
  ## Was added for a reason - watch for issues after disabling.
  systemd.services.unbound = {
    # partOf = [ "caddy.service" ];
    before = [ "caddy.service" ] ++ (if config.homefree.services.adguard.enable == true then [ "adguardhome-podman.service" ] else []);
  };

  ## Restart Adguard DNS with caddy changes
  systemd.services.adguardhome = if config.homefree.services.adguard.enable == true then {
    partOf = [ "unbound.service" ];
  } else {};

  services.caddy = {
    enable = true;

    package = if (config.homefree.dns.remote.cert-management.dns-01.secrets.api-token != null)
              then pkgs.caddy-with-dns-token
              else pkgs.caddy-with-plugins;

    ## reload config while running instead of restarting. true by default.
    enableReload = true;

    ## Temporarily set to staging
    # acmeCA = "https://acme-staging-v02.api.letsencrypt.org/directory";

    # Global configuration for DNS-01 challenge
    globalConfig = lib.optionalString (config.homefree.dns.remote.cert-management.dns-01.provider != null && !config.homefree.development) ''
      cert_issuer acme {
        dns ${config.homefree.dns.remote.cert-management.dns-01.provider} {$DNS_API_TOKEN}
        resolvers ${lib.concatStringsSep " " config.homefree.dns.remote.cert-management.dns-01.resolvers}
        propagation_delay 180s
      }
    ''
    + lib.optionalString config.homefree.development ''
      # Development mode: disable ACME and use only self-signed certificates
      local_certs
    '';

    ## File-scope import of the admin-api upstream snippet. This
    ## registers the `admin_api_proxy` and `admin_api_admin_check`
    ## snippet *definitions* used by the admin / home / finish-setup
    ## vhosts. The file is materialised at runtime (port substituted
    ## for the active blue/green colour) by admin-api-snippet.service
    ## before caddy starts, and rewritten in place by the blue/green
    ## flip. Caddy `extraConfig` lands at file scope, after the global
    ## options block and before the vhosts — exactly where snippet
    ## definitions must live.
    ##
    ## NB: this makes /run/homefree/admin-api-upstream.caddy a hard
    ## dependency of Caddy's config parse; admin-api-snippet.service
    ## has `before = caddy.service` to guarantee it exists.
    extraConfig = "import /run/homefree/admin-api-upstream.caddy";

    virtualHosts = lib.mkMerge [
      (lib.listToAttrs (lib.flatten (lib.map (service-config:
      let
        reverse-proxy-config = service-config.reverse-proxy;
        http-urls = lib.flatten (lib.map (subdomain: (lib.map (domain: "http://${subdomain}.${domain}") reverse-proxy-config.http-domains)) reverse-proxy-config.subdomains);
        https-urls = lib.flatten (lib.map (subdomain: (lib.map (domain: "https://${subdomain}.${domain}") reverse-proxy-config.https-domains)) reverse-proxy-config.subdomains);
        ## Literal site addresses appended verbatim — no subdomain cross-
        ## product. Used to serve a service on a bare IP (the finish-setup
        ## wizard is reached at http://<lan-ip>/ so the captive portal can
        ## redirect to an IP, never a client-resolved hostname).
        extra-http-urls = reverse-proxy-config.extra-http-hosts or [];
        http-urls-root-domain = if reverse-proxy-config.rootDomain == true then (lib.map (domain: "http://${domain}") reverse-proxy-config.http-domains) else [];
        https-urls-root-domain = if reverse-proxy-config.rootDomain == true then (lib.map (domain: "https://${domain}") reverse-proxy-config.https-domains) else [];

        # In development mode with mixed protocols, split into two virtualhosts
        needsSplit = config.homefree.development &&
                     (lib.length http-urls + lib.length http-urls-root-domain) > 0 &&
                     (lib.length https-urls + lib.length https-urls-root-domain) > 0;

        ## Canonical HTTPS host for this service — the first https:// URL,
        ## stripped of scheme (e.g. "admin.example.com"). Used to (a) detect
        ## when Caddy has issued the cert and (b) build the HTTP->HTTPS
        ## redirect target. Empty when the service has no HTTPS URL.
        allHttpsUrls = https-urls ++ https-urls-root-domain;
        canonicalHttpsUrl = if allHttpsUrls != [] then lib.head allHttpsUrls else "";
        canonicalHttpsHost = lib.removePrefix "https://" canonicalHttpsUrl;

        ## HTTP-until-cert behaviour: while this service has no issued TLS
        ## cert, its http:// URLs serve the app directly (so a fresh box is
        ## reachable on the LAN before DNS-01 runs). Once Caddy has written
        ## the cert, http:// requests 301 to the canonical https:// host.
        ## The cert file is detected at REQUEST time via a `file` matcher
        ## with a glob over Caddy's ACME storage, so no rebuild is needed to
        ## flip the behaviour — the redirect activates the moment the cert
        ## lands. Only meaningful in production for a service that has both
        ## http:// and https:// URLs.
        certRedirectEnabled = !config.homefree.development
                              && canonicalHttpsHost != ""
                              && (http-urls ++ http-urls-root-domain ++ extra-http-urls) != [];
        certRedirectConfig = lib.optionalString certRedirectEnabled ''
          ## --- HTTP -> HTTPS once setup is done AND the cert exists -------
          ## Three conditions, all required (AND):
          ##
          ## 1. scheme is http:// — never redirect an https:// request onto
          ##    itself (that would loop).
          ##
          ## 2. .setup-complete exists — the finish-setup wizard has
          ##    finished. The wizard is served over plain HTTP on the LAN
          ##    and POLLS /api/config/rebuild-status across its OWN rebuild.
          ##    If we redirected HTTP->HTTPS the moment the DNS-01 cert was
          ##    issued (which happens DURING that rebuild's activation), the
          ##    wizard's in-flight poll would be 301'd to https://<host> — a
          ##    host the laptop may not resolve and a cert it may not yet
          ##    trust — and the wizard would freeze on "Starting…" never
          ##    seeing the terminal status. Gating on .setup-complete keeps
          ##    the HTTP origin stable for the whole wizard lifetime; the
          ##    wizard's final step writes that sentinel, so the redirect
          ##    goes live on the very next request — exactly when it's safe.
          ##
          ## 3. the cert file exists — Caddy has issued the cert for the
          ##    canonical host. The glob covers any ACME CA directory name
          ##    (LE prod/staging, ZeroSSL).
          ##
          ## All three conditions live in ONE `expression` matcher so they
          ## are AND-ed and the `redir` stays a top-level directive — it
          ## simply does nothing when the matcher is false and the request
          ## falls through to file_server / reverse_proxy as normal. (A
          ## `handle`/`route` wrapper would instead SWALLOW non-matching
          ## requests and return an empty 200.) CEL's `file()` function
          ## does request-time existence checks, so no rebuild flips the
          ## gate. `file()` returns true if ANY listed path exists; we call
          ## it twice and AND the results, and the cert path uses a glob to
          ## cover any ACME CA directory name (LE prod/staging, ZeroSSL).
          @http_redirect_https expression {http.request.scheme} == "http" && file({"try_files": ["/var/lib/homefree-secrets/.setup-complete"]}) && file({"try_files": ["/var/lib/caddy/.local/share/caddy/certificates/*/${canonicalHttpsHost}/${canonicalHttpsHost}.crt"]})
          redir @http_redirect_https https://${canonicalHttpsHost}{uri} 301
        '';

        # Helper function to create virtualhost value
        makeVirtualHostValue = includeHttps:
          let
            urls = if needsSplit then
              (if includeHttps
               then https-urls ++ https-urls-root-domain
               else http-urls ++ http-urls-root-domain ++ extra-http-urls)
            else
              http-urls ++ https-urls ++ http-urls-root-domain ++ https-urls-root-domain ++ extra-http-urls;
            host-string = lib.concatStringsSep ", " urls;
          in {
        name = host-string;
        value = {
          logFormat = ''
            output file ${config.services.caddy.logDir}/access-${service-config.label}.log
          '';
          ## @TODO: Remove headers and check if still works
          extraConfig = ''
          ''
          + (if config.homefree.development && includeHttps then ''
            # Development mode: use internal CA for HTTPS
            tls internal

          '' else "")
          ## Security headers for reverse-proxy (non-static) sites only.
          ## static-path sites get their security headers merged into the
          ## single no-store `header` block further down — emitting this
          ## block too would put TWO unmatched `header` directives in one
          ## site, which Caddy resolves ambiguously (it may keep only one,
          ## and if it keeps THIS one the no-store/cache headers are lost).
          + (if reverse-proxy-config.static-path == null then ''
            header {
              # Add general security headers
              Strict-Transport-Security "max-age=31536000; includeSubdomains"
              X-Content-Type-Options "nosniff"
              X-Frame-Options "SAMEORIGIN"
              Referrer-Policy "strict-origin-when-cross-origin"
              X-XSS-Protection "1; mode=block"
            }
          '' else "")
          ## Redirect http:// to https:// once the service's cert exists.
          ## Inert (empty string) until then, so a fresh box stays reachable
          ## over plain HTTP on the LAN. See certRedirectConfig above.
          + certRedirectConfig
          + (if reverse-proxy-config.public == false && !config.homefree.development then ''
            bind ${lan-address}
          '' else "")
          + (if reverse-proxy-config.subdir != null then ''
            rewrite / ${trimTrailingSlash reverse-proxy-config.subdir}{uri}
          '' else "")
          ## @TODO: throw an error if more than one host is using the same port
          + (if reverse-proxy-config.static-path != null then ''
            ${if reverse-proxy-config.oauth2 == true then ''
              ## SSO gate (static-served path). Every request inside
              ## this site goes through oauth2-proxy validation via
              ## forward_auth.
              ##
              ## CRITICAL: `forward_auth` is a TOP-LEVEL directive,
              ## not wrapped in `handle` or `route`. Caddy's
              ## directive ordering places `forward_auth` BEFORE
              ## `handle`/`route` — when wrapped in `route`, the
              ## directive runs at the `route` slot (very late),
              ## so `handle /api/*` blocks fire first and never
              ## see the auth header. Top-level keeps it at the
              ## proper ordering position.
              ##
              ## Design notes:
              ##  - `file` matcher is evaluated at REQUEST time, so
              ##    pre-provisioning (sentinel absent) the gate is
              ##    skipped entirely — no double-rebuild on fresh
              ##    install (see commit history for rationale).
              ##  - On 401, `handle_response` short-circuits with a
              ##    302 to /oauth2/start; the browser does the OIDC
              ##    dance and lands back here with a valid cookie.
              ##  - On 2xx, `copy_headers` writes X-Auth-Request-*
              ##    onto the inbound request, then control falls
              ##    through to whatever handler matches downstream
              ##    (file_server, the @api reverse_proxy, etc.).
              ##  - The gate ALSO requires .setup-complete to exist.
              ##    The finish-setup wizard runs over plain HTTP on the
              ##    LAN and polls /api/config/rebuild-status across its
              ##    own rebuild — the rebuild that provisions SSO and
              ##    creates .sso-provisioned. If the gate activated the
              ##    instant .sso-provisioned appeared, that poll would
              ##    be 302'd to auth.<domain> and the wizard would hang
              ##    forever, never seeing the build finish. Gating on
              ##    .setup-complete keeps the WHOLE admin UI open over
              ##    HTTP until the wizard's final step writes that
              ##    sentinel — which is also the SSO-bypass contract in
              ##    admin-api's middleware. Both files are checked at
              ##    REQUEST time via CEL file(), so no rebuild flips it.
              @sso_gate expression `file({"root": "/", "try_files": ["/var/lib/homefree-secrets/.sso-provisioned"]}) && file({"root": "/", "try_files": ["/var/lib/homefree-secrets/.setup-complete"]})`
              forward_auth @sso_gate http://${lan-address}:4180 {
                uri /oauth2/auth
                copy_headers X-Auth-Request-User X-Auth-Request-Preferred-Username X-Auth-Request-Email X-Auth-Request-Access-Token X-Auth-Request-Groups
                @bad_status status 401
                handle_response @bad_status {
                  redir https://auth.${config.homefree.system.domain}/oauth2/start?rd={scheme}://{host}{uri} 302
                }
              }
              ${if reverse-proxy-config.require-admin-role or false then ''
                ## Second forward_auth: enforce homefree-admin role.
                ## oauth2-proxy already validated the session above;
                ## now ask admin-api whether this user has the
                ## homefree-admin project role (its middleware parses
                ## Zitadel's namespaced role-claim JSON; oauth2-proxy
                ## can't) and 403s non-admins. The `admin_api_admin_check`
                ## snippet carries the forward_auth (pointed at the
                ## active blue/green port), the X-Auth-Request-* header
                ## passthrough, and the friendly 403 page. It references
                ## the @sso_gate matcher defined just above — keep that
                ## ordering, snippet expansion is textual.
                import admin_api_admin_check
              '' else ""}
            '' else ""}
            root * ${reverse-proxy-config.static-path}

            ## THE stale-cache fix. The frontend is served from /nix/store,
            ## where every file's mtime is the Unix epoch. Caddy's
            ## file_server derives its ETag and Last-Modified from that
            ## mtime, so a browser that cached a file under an OLDER config
            ## (one that sent validators) keeps sending conditional requests
            ## — If-Modified-Since / If-None-Match — and file_server, seeing
            ## the request's date is newer than the epoch mtime, answers
            ## `304 Not Modified`. The browser then serves its STALE copy,
            ## even after a rebuild, even on shift-reload (which does not
            ## reliably re-fetch transitively-imported ES modules — i.e.
            ## the entire admin UI). The `no-store` header below cannot
            ## help: file_server decides the 304 before headers are applied,
            ## and no-store only blocks FUTURE storage, it can't evict the
            ## already-poisoned entry.
            ##
            ## Stripping the conditional-request headers BEFORE file_server
            ## sees them forces a full `200` with a body every time. That
            ## lets the no-store response actually land and the browser
            ## drops the poisoned entry. request_header is ordered before
            ## file_server by Caddy regardless of where it sits textually.
            request_header -If-Modified-Since
            request_header -If-None-Match
            file_server

            # Enable Gzip compression
            encode gzip

            # HTML files - No caching to ensure fresh content, AND
            # opt out of bfcache so signing out can't leave the user
            # on a restored in-memory page snapshot. bfcache is
            # blocked by no-store specifically (no-cache alone is not
            # enough — Firefox will still bfcache no-cache responses).
            # See:
            # https://developer.mozilla.org/docs/Web/API/Window/pageshow_event#firefox_bfcache
            # Caching: DISABLE IT ENTIRELY for every file this site
            # serves. These are HomeFree's admin / app surfaces — the
            # HTML and JS are live code, not static content.
            #
            # CRITICAL — why no-store and NOT no-cache:
            #   `no-cache` means "store it, but revalidate before use".
            #   The frontend is served from /nix/store, where every file
            #   has mtime = epoch. Caddy's file_server derives ETag and
            #   Last-Modified from that mtime, so they are IDENTICAL
            #   across rebuilds. With no-cache + ETag, the browser keeps
            #   the old file, sends If-None-Match, Caddy answers 304
            #   Not Modified, and the browser serves the STALE JS — even
            #   after a rebuild, even on shift-reload. The only thing
            #   that worked around it was DevTools "Disable cache".
            #
            #   `no-store` forbids storing the response at all, so there
            #   is no cached copy to revalidate and no 304 path. We also
            #   strip ETag / Last-Modified so the validators that drive
            #   304s don't exist. This is the ONLY correct setting for
            #   an app surface, and it also blocks bfcache (matters for
            #   the post-sign-out restored-DOM case).
            #
            # One unmatched `header` covers EVERY response — no
            # per-extension matchers to leave a file type uncovered.
            # Cache headers + security headers are merged into this
            # single block: two separate unmatched `header` directives
            # in one site is ambiguous (Caddy may keep only one), so
            # everything goes here.
            header {
              # --- Caching: disabled entirely (see rationale above) ---
              Cache-Control "no-store"
              -ETag
              -Last-Modified
              -Pragma
              # --- Security headers ---
              -Server
              Strict-Transport-Security "max-age=31536000; includeSubdomains"
              X-Content-Type-Options "nosniff"
              X-Frame-Options "SAMEORIGIN"
              Referrer-Policy "strict-origin-when-cross-origin"
              X-XSS-Protection "1; mode=block"
            }
          '' else (
          (if reverse-proxy-config.oauth2 == true then ''
            ## SSO gate (reverse-proxy site). Request-time `file`
            ## matcher peeks at the sentinel: pre-provisioning the
            ## gate is skipped, so the rendered config is correct
            ## from day one of a fresh install (no double rebuild).
            ## Post-provisioning every request runs through
            ## oauth2-proxy /oauth2/auth via forward_auth; on 401
            ## handle_response converts it into a 302 to
            ## /oauth2/start. See the static-path branch above for
            ## the full design rationale (same shape, same trade-
            ## offs, same security properties).
            @sso_gate {
              file {
                root /
                try_files /var/lib/homefree-secrets/.sso-provisioned
              }
              ${if reverse-proxy-config.dav-bypass or false then ''
                ## DAV bypass: skip the SSO gate for traffic that
                ## clearly comes from a CalDAV/CardDAV client. Two
                ## fingerprints:
                ##   1. Authorization: Basic ... header — every DAV
                ##      client sends credentials on every request.
                ##   2. DAV-only HTTP methods — even an OPTIONS or
                ##      PROPFIND without auth (initial discovery) is
                ##      from a client, not a browser.
                ## Browsers without Basic auth on the admin UI still
                ## fall through the SSO gate normally.
                not header Authorization "Basic *"
                not method PROPFIND PROPPATCH REPORT MKCALENDAR MKCOL COPY MOVE LOCK UNLOCK
              '' else ""}
              ${lib.optionalString (reverse-proxy-config.sso-bypass-paths or [] != []) ''
                ## SSO-gate path bypass. The service declared these
                ## path patterns in reverse-proxy.sso-bypass-paths —
                ## typically API paths used by non-browser clients that
                ## cannot complete an interactive OAuth login. Such
                ## requests skip the gate and reach the upstream
                ## directly (to use its native credentials); browser
                ## traffic to other paths still falls through the gate.
                ${lib.concatMapStringsSep "\n                "
                  (p: "not path ${p}")
                  reverse-proxy-config.sso-bypass-paths}
              ''}
            }
            forward_auth @sso_gate http://${lan-address}:4180 {
              uri /oauth2/auth
              copy_headers X-Auth-Request-User X-Auth-Request-Preferred-Username X-Auth-Request-Email X-Auth-Request-Access-Token X-Auth-Request-Groups
              @bad_status status 401
              handle_response @bad_status {
                redir https://auth.${config.homefree.system.domain}/oauth2/start?rd={scheme}://{host}{uri} 302
              }
            }
            ${if reverse-proxy-config.require-admin-role or false then ''
              ## Second forward_auth: enforce homefree-admin role
              ## via admin-api. See the static-path branch above
              ## for the design rationale. admin_api_admin_check is
              ## the runtime snippet pointing at the active colour.
              import admin_api_admin_check
            '' else ""}
          '' else "")
          +
          (let
            logoutPaths = reverse-proxy-config.upstream-logout-paths or [];
          in if logoutPaths != [] then ''
            ## Upstream sign-out interception. Without this, hitting
            ## the upstream's own logout endpoint clears its session
            ## — but Caddy's inject-basic-auth-env header reauths on
            ## the next request, so the user can never actually
            ## leave. Intercept the path and bounce into the SSO
            ## sign-out chain:
            ##
            ##   1. /oauth2/sign_out on auth.<domain>: oauth2-proxy
            ##      clears its cookie, then redirects to `rd` (URL-
            ##      encoded Zitadel end_session URL).
            ##   2. /oidc/v1/end_session on sso.<domain>: Zitadel
            ##      ends the SSO session and redirects to
            ##      post_logout_redirect_uri (THIS site's root).
            ##
            ## The `client_id` query param on end_session is critical:
            ## without it, Zitadel ignores post_logout_redirect_uri
            ## and parks the user on its own "Logout successful" page
            ## with no way back. We get the client_id from the env
            ## var OAUTH2_PROXY_CLIENT_ID, populated by
            ## caddy-adguard-basic-auth.service from
            ## /var/lib/homefree-secrets/zitadel/oidc-client-id.
            ##
            ## The triple-encoded post_logout_redirect_uri (https
            ## → https%3A → https%253A) is because the URL is nested
            ## three deep: Caddy's redir value, then oauth2-proxy's
            ## `rd` param, then end_session's
            ## `post_logout_redirect_uri` param. Each layer adds a
            ## round of encoding to the next.
            @upstream_logout {
              path ${lib.concatMapStringsSep " " (p: ''"${p}"'') logoutPaths}
            }
            redir @upstream_logout https://auth.${config.homefree.system.domain}/oauth2/sign_out?rd=https%3A%2F%2Fsso.${config.homefree.system.domain}%2Foidc%2Fv1%2Fend_session%3Fclient_id%3D{env.OAUTH2_PROXY_CLIENT_ID}%26post_logout_redirect_uri%3Dhttps%253A%252F%252F{host}%252F 302
          '' else "")
          +
          (if reverse-proxy-config.basic-auth == true then ''
            # Route WebDAV+Basic Auth requests to Python proxy
            @webdav_with_basic {
              header Authorization "Basic *"
            }

            @webdav_methods {
              method PROPFIND PROPPATCH MKCOL COPY MOVE LOCK UNLOCK
            }

            # Handle WebDAV with Basic Auth
            route @webdav_with_basic {
              reverse_proxy ${lan-address}:8764 {
                # Pass the original host header
                header_up Host {host}
                header_up X-Forwarded-Host {host}
                header_up X-Forwarded-Proto {scheme}
              }
            }

            # Handle WebDAV-specific methods even without Basic Auth
            route @webdav_methods {
              reverse_proxy ${lan-address}:8764 {
                header_up Host {host}
                header_up X-Forwarded-Host {host}
                header_up X-Forwarded-Proto {scheme}
              }
            }
          '' else "")
          +
          ''
            handle {
              reverse_proxy ${if reverse-proxy-config.ssl == true then "https" else "http"}://${reverse-proxy-config.host}:${toString reverse-proxy-config.port} {
          ''
          + (
            ## Emit ONE transport block combining TLS-skip-verify
            ## and/or keepalive-off, depending on what's enabled.
            ## Caddy parses `transport http` as a single directive
            ## per reverse_proxy — repeating it would be a parse
            ## error, so we combine here.
            let
              tlsSkip = reverse-proxy-config.ssl == true && reverse-proxy-config.ssl-no-verify;
              koOff = reverse-proxy-config.disable-keepalive or false;
              body =
                (if tlsSkip then ''
                  tls
                  tls_insecure_skip_verify
                '' else "")
                + (if koOff then ''
                  keepalive off
                  versions 1.1
                '' else "");
            in
              if tlsSkip || koOff
              then "                transport http {\n${body}                }\n"
              else ""
          )
          + (if reverse-proxy-config.oauth2 == true then ''
                header_up Host {host}
                header_up X-Real-IP {remote}
                # header_up X-Forwarded-For {remote}
                # header_up X-Forwarded-Proto {scheme}
          '' else "")
          + (if reverse-proxy-config.inject-basic-auth-env != null then ''
                ## Inject HTTP Basic Auth on every upstream request.
                ## The env var holds the base64-encoded credential
                ## (see module.nix:inject-basic-auth-env). Used for
                ## services with no OIDC support, where the upstream
                ## still wants a credential but the user already
                ## passed the SSO gate.
                ##
                ## Use `header_up >Authorization` (replace, with the
                ## `>` prefix) so an inbound Authorization header from
                ## the client is overwritten rather than appended to.
                ## Plain `header_up Authorization` *adds* a second
                ## Authorization header alongside any existing one,
                ## which most servers handle by reading the first
                ## (inbound) value and ignoring ours.
                header_up >Authorization "Basic {env.${reverse-proxy-config.inject-basic-auth-env}}"
          '' else "")
          +
          ''
              }
          ''
          ## Note: there used to be an inner `forward_auth` here for
          ## the oauth2 path. It's been removed — the top-level
          ## `route @sso_gate` block above already validates every
          ## request before it reaches this reverse_proxy, so a
          ## second forward_auth on the upstream call was redundant
          ## (and didn't do redirect-on-401 anyway).
          + (if reverse-proxy-config.basic-auth == true then ''
              forward_auth ${lan-address}:3241 {
                uri /oauth/v2/introspect
                copy_headers Authorization
              }
          '' else "")
          +
          ''
            }
          ''))
          + (if reverse-proxy-config.extraCaddyConfig != null then reverse-proxy-config.extraCaddyConfig else "");
        };
      };
      in
        # Return either one or two virtualhosts depending on whether we need to split
        if needsSplit then
          [ (makeVirtualHostValue false) (makeVirtualHostValue true) ]
        else
          [ (makeVirtualHostValue false) ]
      ) proxiedHostConfig)))

      # Add reverse proxy for proxied domains (proxy handles TLS certificates)
      (lib.listToAttrs (lib.map (entry:
        let
          # Create virtualHost with http:// and https:// (Caddy will handle ACME for https)
          protocol = if entry.ssl then "https" else "http";
          host-string = "${protocol}://${entry.domain}";
          log-name = lib.replaceStrings ["." "*"] ["_" "wildcard"] "${entry.domain}-${toString entry.port}";
          backend-protocol = if entry.ssl then "https" else "http";
        in {
          name = host-string;
          value = {
            logFormat = ''
              output file ${config.services.caddy.logDir}/access-proxied-${log-name}.log
            '';
            extraConfig = ''
              ${if !entry.public then "bind ${lan-address}" else ""}

              ${if entry.ssl && lib.hasInfix "*" entry.domain then ''
              # Use DNS-01 challenge for wildcard domains
              tls {
              ''
              + (if config.homefree.development then ''
                internal
              '' else lib.optionalString (config.homefree.dns.remote.cert-management.dns-01.provider != null) ''
                dns ${config.homefree.dns.remote.cert-management.dns-01.provider} {$DNS_API_TOKEN}
                resolvers ${lib.concatStringsSep " " config.homefree.dns.remote.cert-management.dns-01.resolvers}
                propagation_delay 180s
              '')
              +
              ''
              }
              '' else if entry.ssl && config.homefree.development then ''
              # Development mode: use internal CA for HTTPS
              tls internal
              '' else ""}

              # Proxy handles TLS termination for HTTPS backends
              reverse_proxy ${backend-protocol}://${entry.host}:${toString entry.port} {
                header_up Host {http.request.host}
                header_up X-Real-IP {remote_host}
                header_up X-Forwarded-For {remote_host}
                header_up X-Forwarded-Proto {scheme}
                ${if entry.ssl then ''
                transport http {
                  tls
                  ${if entry.ignore-self-signed-cert then "tls_insecure_skip_verify" else ""}
                  tls_server_name {http.request.host}
                }
                '' else ""}
              }
            '';
          };
        }
      ) processedProxiedDomains))
    ];
  };

}
