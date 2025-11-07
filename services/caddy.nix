{ config, lib, pkgs, ... }:
let
  proxiedHostConfig = lib.filter (service-config: service-config.reverse-proxy.enable == true) config.homefree.service-config;
  proxiedDomains = config.homefree.proxied-domains;
  trimTrailingSlash = s: lib.head (lib.match "(.*[^/])[/]*" s);

  # Process proxied domains for layer4 HTTPS TCP proxy (SNI matching)
  layer4ProxiedDomains = lib.map (domain-mapping:
    let
      sslPorts = lib.filter (p: p.ssl == true) domain-mapping.target.ports;
    in {
      inherit (domain-mapping) domains public;
      inherit (domain-mapping.target) host;
      httpsPort = if sslPorts != [] then (lib.head sslPorts).number else null;
    }
  ) (lib.filter (d: lib.any (p: p.ssl == true) d.target.ports) proxiedDomains);

  # Process proxied domains for HTTP reverse proxy (Host header matching)
  httpProxiedDomains = lib.flatten (lib.map (domain-mapping:
    let
      nonSslPorts = lib.filter (p: p.ssl == false) domain-mapping.target.ports;
      httpPort = if nonSslPorts != [] then (lib.head nonSslPorts).number else null;
    in
      if httpPort != null then
        lib.map (domain: {
          inherit domain httpPort;
          inherit (domain-mapping) public;
          inherit (domain-mapping.target) host;
        }) domain-mapping.domains
      else []
  ) proxiedDomains);
in
{
  nixpkgs.overlays = [
    (import ../overlays/caddy-with-plugins.nix)
  ];

  systemd.services.caddy = {
    wants = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    ## Restart Caddy with Unbound DNS changes
    partOf = [ "unbound.service" ];
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

    package = pkgs.caddy-with-plugins;

    ## reload config while running instead of restarting. true by default.
    enableReload = true;

    ## Temporarily set to staging
    # acmeCA = "https://acme-staging-v02.api.letsencrypt.org/directory";

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

      # Add HTTP reverse proxy for proxied domains (uses Host header matching)
      (lib.listToAttrs (lib.map (entry:
        let
          # Create virtualHost for http://domain (listening on port 80)
          host-string = "http://${entry.domain}";
          log-name = lib.replaceStrings ["." "*"] ["_" "wildcard"] entry.domain;
        in {
          name = host-string;
          value = {
            logFormat = ''
              output file ${config.services.caddy.logDir}/access-proxied-${log-name}.log
            '';
            extraConfig = ''
              ${if !entry.public then "bind 10.0.0.1" else ""}

              # Transparent proxy - preserve all headers
              reverse_proxy http://${entry.host}:${toString entry.httpPort} {
                header_up Host {host}
                header_up X-Real-IP {remote_host}
                header_up X-Forwarded-For {remote_host}
                header_up X-Forwarded-Proto {scheme}
              }
            '';
          };
        }
      ) httpProxiedDomains))
    ];
  };

  # Create JSON config file for layer4 HTTPS TCP proxy (uses SNI matching)
  environment.etc."caddy/layer4-config.json" = lib.mkIf (layer4ProxiedDomains != []) {
    text = builtins.toJSON (
      let
        isPublic = lib.any (e: e.public) layer4ProxiedDomains;
      in {
        servers = {
          https-proxy = {
            listen = [ (if isPublic then ":443" else "10.0.0.1:443") ];
            routes = lib.filter (r: r != null) (lib.map (entry:
              if entry.httpsPort != null then {
                match = [{ tls = { sni = entry.domains; }; }];
                handle = [{
                  handler = "proxy";
                  upstreams = [{ dial = ["${entry.host}:${toString entry.httpsPort}"]; }];
                }];
              } else null
            ) layer4ProxiedDomains);
          };
        };
      }
    );
  };

  # Load layer4 config via Caddy admin API after main service starts
  systemd.services.caddy-layer4-loader = lib.mkIf (layer4ProxiedDomains != []) {
    description = "Load Caddy Layer4 TCP Proxy Configuration";
    after = [ "caddy.service" ];
    requires = [ "caddy.service" ];
    partOf = [ "caddy.service" ];  # Restart when caddy restarts
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Use /config/apps/layer4 to ADD the layer4 app without replacing the entire config
      ExecStart = "${pkgs.curl}/bin/curl -X POST http://localhost:2019/config/apps/layer4 -H 'Content-Type: application/json' -d @/etc/caddy/layer4-config.json";
      ExecStop = "${pkgs.curl}/bin/curl -X DELETE http://localhost:2019/config/apps/layer4";
    };
  };
}
