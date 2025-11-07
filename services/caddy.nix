{ config, lib, pkgs, ... }:
let
  proxiedHostConfig = lib.filter (service-config: service-config.reverse-proxy.enable == true) config.homefree.service-config;
  proxiedDomains = config.homefree.proxied-domains;
  trimTrailingSlash = s: lib.head (lib.match "(.*[^/])[/]*" s);

  # Separate proxied domains into HTTPS (layer4) and HTTP (layer7)
  # Collect all unique port numbers and group domain mappings by port
  layer4ProxiedDomains = lib.flatten (lib.map (domain-mapping:
    lib.map (port-config: {
      inherit (domain-mapping) domains public;
      inherit (domain-mapping.target) host;
      port = port-config.number;
    }) (lib.filter (p: p.ssl == true) domain-mapping.target.ports)
  ) proxiedDomains);

  layer7ProxiedDomains = lib.flatten (lib.map (domain-mapping:
    lib.map (port-config: {
      inherit (domain-mapping) domains public;
      inherit (domain-mapping.target) host;
      port = port-config.number;
      ssl = port-config.ssl;
    }) (lib.filter (p: p.ssl == false) domain-mapping.target.ports)
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

      # Process HTTP (layer7) proxied-domains
      (lib.listToAttrs (lib.map (domain-port:
        let
          # Add port suffix to each domain (e.g., example.com:80)
          domains-with-port = lib.map (domain: "${domain}:${toString domain-port.port}") domain-port.domains;
          host-string = lib.concatStringsSep ", " domains-with-port;
          # Create a safe filename by replacing special characters
          log-name = lib.replaceStrings [" " "," "." "*" ":"] ["_" "" "_" "wildcard" "_"] host-string;
        in {
          name = host-string;
          value = {
            logFormat = ''
              output file ${config.services.caddy.logDir}/access-proxied-http-${log-name}.log
            '';
            extraConfig = ''
              ${if !domain-port.public then "bind 10.0.0.1" else ""}

              # HTTP reverse proxy - preserve all headers
              reverse_proxy http://${domain-port.host}:${toString domain-port.port} {
                header_up Host {host}
                header_up X-Real-IP {remote_host}
                header_up X-Forwarded-For {remote_host}
                header_up X-Forwarded-Proto {scheme}
              }
            '';
          };
        }
      ) layer7ProxiedDomains))
    ];
  };

  # Create JSON config file for layer4 TCP proxy (this version only supports JSON, not Caddyfile)
  environment.etc."caddy/layer4-config.json" = lib.mkIf (layer4ProxiedDomains != []) {
    text = builtins.toJSON {
      apps = {
        layer4 = {
          servers = lib.listToAttrs (
            # Group by port number
            lib.mapAttrsToList (port: entries:
              let
                portNum = toString port;
                firstEntry = lib.head entries;
              in {
                name = "proxied-port-${portNum}";
                value = {
                  listen = [
                    (if firstEntry.public then ":${portNum}" else "10.0.0.1:${portNum}")
                  ];
                  routes = lib.map (entry: {
                    match = [{
                      tls = {
                        sni = entry.domains;
                      };
                    }];
                    handle = [{
                      handler = "proxy";
                      upstreams = [{
                        dial = ["${entry.host}:${toString entry.port}"];
                      }];
                    }];
                  }) entries;
                };
              }
            ) (lib.groupBy (e: toString e.port) layer4ProxiedDomains)
          );
        };
      };
    };
  };

  # Load layer4 config via Caddy admin API after main service starts
  systemd.services.caddy-layer4-loader = lib.mkIf (layer4ProxiedDomains != []) {
    description = "Load Caddy Layer4 TCP Proxy Configuration";
    after = [ "caddy.service" ];
    requires = [ "caddy.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.curl}/bin/curl -X POST http://localhost:2019/load -H 'Content-Type: application/json' -d @/etc/caddy/layer4-config.json";
      ExecStop = "${pkgs.curl}/bin/curl -X DELETE http://localhost:2019/id/layer4";
    };
  };
}
