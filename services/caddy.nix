{ config, lib, pkgs, ... }:
let
  lan-address = config.homefree.network.lan-address;
  proxiedHostConfig = lib.filter (service-config: service-config.reverse-proxy.enable == true) config.homefree.service-config;
  proxiedDomains = config.homefree.proxied-domains;
  trimTrailingSlash = s: lib.head (lib.match "(.*[^/])[/]*" s);

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
    (import ../overlays/caddy-with-plugins.nix)
  ] ++ lib.optional (config.homefree.dns.remote.cert-management.dns-01.secrets.api-token != null) (final: prev: {
    caddy-with-dns-token = prev.writeShellScriptBin "caddy" ''
      if [ -f /run/caddy-secrets/dns-api-token ]; then
        export DNS_API_TOKEN=''$(cat /run/caddy-secrets/dns-api-token)
      fi
      exec ${final.caddy-with-plugins}/bin/caddy "$@"
    '';
  });

  systemd.services.caddy = {
    after = [ "dns-ready.service" ];
    wants = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    ## Restart Caddy with Unbound DNS changes
    ## NOTE: Commented out - creates circular dependency with unbound's partOf below.
    ## This causes 90-second delays when restarting unbound (caddy times out on SIGTERM).
    ## NixOS already handles config-triggered restarts via X-Restart-Triggers/X-Reload-Triggers.
    ## Was added for a reason - watch for issues after disabling.
    # partOf = [ "unbound.service" ];

    # Grant capability to bind to privileged ports when using wrapper
    serviceConfig = lib.mkIf (config.homefree.dns.remote.cert-management.dns-01.secrets.api-token != null) {
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
    };
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
      ## NOTE: No global acme_dns - let non-wildcard domains use HTTP-01 (default)
      ## Wildcard domains have per-virtualhost tls blocks with DNS-01
      # acme_dns ${config.homefree.dns.remote.cert-management.dns-01.provider} {env.DNS_API_TOKEN}
    ''
    + lib.optionalString config.homefree.development ''
      # Development mode: disable ACME and use only self-signed certificates
      local_certs
    '';

    virtualHosts = lib.mkMerge [
      (lib.listToAttrs (lib.flatten (lib.map (service-config:
      let
        reverse-proxy-config = service-config.reverse-proxy;
        http-urls = lib.flatten (lib.map (subdomain: (lib.map (domain: "http://${subdomain}.${domain}") reverse-proxy-config.http-domains)) reverse-proxy-config.subdomains);
        https-urls = lib.flatten (lib.map (subdomain: (lib.map (domain: "https://${subdomain}.${domain}") reverse-proxy-config.https-domains)) reverse-proxy-config.subdomains);
        http-urls-root-domain = if reverse-proxy-config.rootDomain == true then (lib.map (domain: "http://${domain}") reverse-proxy-config.http-domains) else [];
        https-urls-root-domain = if reverse-proxy-config.rootDomain == true then (lib.map (domain: "https://${domain}") reverse-proxy-config.https-domains) else [];

        # In development mode with mixed protocols, split into two virtualhosts
        needsSplit = config.homefree.development &&
                     (lib.length http-urls + lib.length http-urls-root-domain) > 0 &&
                     (lib.length https-urls + lib.length https-urls-root-domain) > 0;

        # Helper function to create virtualhost value
        makeVirtualHostValue = includeHttps:
          let
            urls = if needsSplit then
              (if includeHttps
               then https-urls ++ https-urls-root-domain
               else http-urls ++ http-urls-root-domain)
            else
              http-urls ++ https-urls ++ http-urls-root-domain ++ https-urls-root-domain;
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
          + ''
            header {
              # Add general security headers
              Strict-Transport-Security "max-age=31536000; includeSubdomains"
              X-Content-Type-Options "nosniff"
              X-Frame-Options "SAMEORIGIN"
              Referrer-Policy "strict-origin-when-cross-origin"
              X-XSS-Protection "1; mode=block"
            }
          ''
          + (if reverse-proxy-config.public == false && !config.homefree.development then ''
            bind ${lan-address}
          '' else "")
          + (if reverse-proxy-config.subdir != null then ''
            rewrite / ${trimTrailingSlash reverse-proxy-config.subdir}{uri}
          '' else "")
          ## @TODO: throw an error if more than one host is using the same port
          + (if reverse-proxy-config.static-path != null then ''
            root * ${reverse-proxy-config.static-path}
            file_server

            # Enable Gzip compression
            encode gzip

            # HTML files - No caching to ensure fresh content
            @html {
            file
              path *.html
            }
            header @html {
              # Disable caching for HTML
              Cache-Control "no-cache, must-revalidate"
              # Add ETag for conditional requests
              ETag
              # Add Last-Modified header
              +Last-Modified
            }

            # CSS files - No aggressive caching for development/admin UIs
            @css {
              file
              path *.css
            }
            header @css {
              # No caching - always revalidate
              Cache-Control "no-cache, must-revalidate"
              ETag
              +Last-Modified
              Vary Accept-Encoding
            }

            # Assets (CSS, JS, images)
            @assets {
              file
              path *.js *.png *.jpg *.jpeg *.gif *.svg *.woff *.woff2
            }
            header @assets {
              # No aggressive caching - always revalidate for JS
              Cache-Control "no-cache, must-revalidate"
              # Add ETag for conditional requests
              ETag
              # Add Last-Modified header
              +Last-Modified
              # Add Vary header to handle different client capabilities
              Vary Accept-Encoding
            }

            # General headers
            header {
              # Remove Server header for security
              -Server
              # Add general security headers
              Strict-Transport-Security "max-age=31536000; includeSubdomains"
              X-Content-Type-Options "nosniff"
              X-Frame-Options "SAMEORIGIN"
              Referrer-Policy "strict-origin-when-cross-origin"
              X-XSS-Protection "1; mode=block"
            }
          '' else (
          (if reverse-proxy-config.oauth2 == true then ''
            # Simple approach: check for cookie, redirect if missing
            @no_auth {
              not header Cookie *oauth2_proxy*
            }

            # Redirect unauthenticated users to OAuth2-Proxy
            handle @no_auth {
              redir https://auth.${config.homefree.system.domain}/oauth2/start?rd={scheme}://{host}{uri} 302
            }
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
          + (if reverse-proxy-config.ssl == true && reverse-proxy-config.ssl-no-verify then ''
                transport http {
                  tls
                  tls_insecure_skip_verify
                }
          '' else "")
          + (if reverse-proxy-config.oauth2 == true then ''
                header_up Host {host}
                header_up X-Real-IP {remote}
                # header_up X-Forwarded-For {remote}
                # header_up X-Forwarded-Proto {scheme}
          '' else "")
          +
          ''
              }
          ''
          + (if reverse-proxy-config.oauth2 == true then ''
              forward_auth http://${lan-address}:4180 {
                uri /oauth2/auth
                copy_headers X-Auth-Request-User X-Auth-Request-Email X-Auth-Request-Access-Token
              }
          '' else "")
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
                dns ${config.homefree.dns.remote.cert-management.dns-01.provider} {env.DNS_API_TOKEN}
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
