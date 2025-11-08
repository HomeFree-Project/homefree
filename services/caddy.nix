{ config, lib, pkgs, ... }:
let
  proxiedHostConfig = lib.filter (service-config: service-config.reverse-proxy.enable == true) config.homefree.service-config;
  proxiedDomains = config.homefree.proxied-domains;
  trimTrailingSlash = s: lib.head (lib.match "(.*[^/])[/]*" s);

  # Process proxied domains for standard reverse proxy (proxy handles TLS)
  processedProxiedDomains = lib.flatten (lib.map (domain-mapping:
    lib.flatten (lib.map (port-config:
      lib.map (domain: {
        inherit domain;
        inherit (domain-mapping) public;
        inherit (domain-mapping.target) host;
        port = port-config.number;
        ssl = port-config.ssl;
      }) domain-mapping.domains
    ) domain-mapping.target.ports)
  ) proxiedDomains);
in
{
  # Service to create DNS token env file readable by caddy user
  systemd.services.caddy-dns-token = lib.mkIf (config.homefree.network.dns.dns-01.secrets.api-token != null) {
    description = "Create Caddy DNS API Token for caddy user";
    wantedBy = [ "caddy.service" ];
    before = [ "caddy.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p /run/caddy-secrets
      cp ${toString config.homefree.network.dns.dns-01.secrets.api-token} /run/caddy-secrets/dns-api-token
      chown caddy:caddy /run/caddy-secrets/dns-api-token
      chmod 400 /run/caddy-secrets/dns-api-token
    '';
  };

  nixpkgs.overlays = [
    (import ../overlays/caddy-with-plugins.nix)
  ] ++ lib.optional (config.homefree.network.dns.dns-01.secrets.api-token != null) (final: prev: {
    caddy-with-dns-token = prev.writeShellScriptBin "caddy" ''
      export DNS_API_TOKEN=''$(cat /run/caddy-secrets/dns-api-token)
      exec ${final.caddy-with-plugins}/bin/caddy "$@"
    '';
  });

  systemd.services.caddy = {
    wants = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    ## Restart Caddy with Unbound DNS changes
    partOf = [ "unbound.service" ];

    # Grant capability to bind to privileged ports when using wrapper
    serviceConfig = lib.mkIf (config.homefree.network.dns.dns-01.secrets.api-token != null) {
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
    };
  };

  ## Restart Unbound DNS with caddy changes
  systemd.services.unbound = {
    partOf = [ "caddy.service" ];
    before = [ "caddy.service" ] ++ (if config.homefree.services.adguard.enable == true then [ "adguardhome-podman.service" ] else []);
  };

  ## Restart Adguard DNS with caddy changes
  systemd.services.adguardhome = if config.homefree.services.adguard.enable == true then {
    partOf = [ "unbound.service" ];
  } else {};

  services.caddy = {
    enable = true;

    package = if (config.homefree.network.dns.dns-01.secrets.api-token != null)
              then pkgs.caddy-with-dns-token
              else pkgs.caddy-with-plugins;

    ## reload config while running instead of restarting. true by default.
    enableReload = true;

    ## Temporarily set to staging
    # acmeCA = "https://acme-staging-v02.api.letsencrypt.org/directory";

    # Global configuration for DNS-01 challenge
    globalConfig = lib.optionalString (config.homefree.network.dns.dns-01.provider != null) ''
      acme_dns ${config.homefree.network.dns.dns-01.provider} {env.DNS_API_TOKEN}
    '';

    virtualHosts = lib.mkMerge [
      (lib.listToAttrs (lib.map (service-config:
      let
        reverse-proxy-config = service-config.reverse-proxy;
        http-urls = lib.flatten (lib.map (subdomain: (lib.map (domain: "http://${subdomain}.${domain}") reverse-proxy-config.http-domains)) reverse-proxy-config.subdomains);
        https-urls = lib.flatten (lib.map (subdomain: (lib.map (domain: "https://${subdomain}.${domain}") reverse-proxy-config.https-domains)) reverse-proxy-config.subdomains);
        http-urls-root-domain = if reverse-proxy-config.rootDomain == true then (lib.map (domain: "http://${domain}") reverse-proxy-config.http-domains) else [];
        https-urls-root-domain = if reverse-proxy-config.rootDomain == true then (lib.map (domain: "https://${domain}") reverse-proxy-config.https-domains) else [];
        urls = http-urls ++ https-urls ++ http-urls-root-domain ++ https-urls-root-domain;
        host-string = lib.concatStringsSep ", " urls;
      in {
        name = host-string;
        value = {
          logFormat = ''
            output file ${config.services.caddy.logDir}/access-${service-config.label}.log
          '';
          ## @TODO: Remove headers and check if still works
          extraConfig = ''
            header {
              # Add general security headers
              Strict-Transport-Security "max-age=31536000; includeSubdomains"
              X-Content-Type-Options "nosniff"
              X-Frame-Options "SAMEORIGIN"
              Referrer-Policy "strict-origin-when-cross-origin"
              X-XSS-Protection "1; mode=block"
            }
          ''
          + (if reverse-proxy-config.public == false then ''
            bind 10.0.0.1
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

            # CSS files - Aggressive caching with revalidation
            @css {
              file
              path *.css
            }
            header @css {
              # Cache for 1 year, but allow revalidation
              Cache-Control "public, max-age=31536000, stale-while-revalidate=86400"
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
              # Cache for 1 hour, but allow revalidation
              Cache-Control "public, max-age=3600, must-revalidate"
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
              reverse_proxy 10.0.0.1:8764 {
                # Pass the original host header
                header_up Host {host}
                header_up X-Forwarded-Host {host}
                header_up X-Forwarded-Proto {scheme}
              }
            }

            # Handle WebDAV-specific methods even without Basic Auth
            route @webdav_methods {
              reverse_proxy 10.0.0.1:8764 {
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
              forward_auth http://10.0.0.1:4180 {
                uri /oauth2/auth
                copy_headers X-Auth-Request-User X-Auth-Request-Email X-Auth-Request-Access-Token
              }
          '' else "")
          + (if reverse-proxy-config.basic-auth == true then ''
              forward_auth 10.0.0.1:3241 {
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
      }
      ) proxiedHostConfig))

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
              ${if !entry.public then "bind 10.0.0.1" else ""}

              ${if entry.ssl && lib.hasInfix "*" entry.domain then ''
              # Use DNS-01 challenge for wildcard domains
              tls {
              ''
              + lib.optionalString (config.homefree.network.dns.dns-01.provider != null) ''
                dns ${config.homefree.network.dns.dns-01.provider} {env.DNS_API_TOKEN}
              ''
              +
              ''
                propagation_delay 180s
              }
              '' else ""}

              # Proxy handles TLS, backend can have invalid certs
              reverse_proxy ${backend-protocol}://${entry.host}:${toString entry.port} {
                header_up Host {host}
                header_up X-Real-IP {remote_host}
                header_up X-Forwarded-For {remote_host}
                header_up X-Forwarded-Proto {scheme}
                ${if entry.ssl then ''
                transport http {
                  tls
                  tls_insecure_skip_verify
                  tls_server_name ${entry.domain}
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
