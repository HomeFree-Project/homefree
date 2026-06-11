{ config, lib, pkgs, ... }:
let
  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable WebDAV service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };
  };

  version = "v5.11.10";
  containerDataPath = "/var/lib/webdav";
  port = config.homefree.allocPort "webdav";

  ## hacdias/webdav is a single Go binary. Listens on 6060 (non-
  ## privileged) so no CAP_NET_BIND_SERVICE is needed; just drop
  ## root and chown the data dir.
  webdavUid = 806;
  webdavGid = 806;

  preStart = ''
    mkdir -p ${containerDataPath}/data

    if [ ! -f ${containerDataPath}/.chowned-${toString webdavUid} ]; then
      chown -R ${toString webdavUid}:${toString webdavGid} ${containerDataPath}
      touch ${containerDataPath}/.chowned-${toString webdavUid}
    fi
  '';

  config-file = pkgs.writeText "config.yml" ''
    address: 0.0.0.0
    port: 6060

    # TLS-related settings if you want to enable TLS directly.
    tls: false
    # cert: cert.pem
    # key: key.pem

    # Prefix to apply to the WebDAV path-ing. Default is '/'.
    prefix: /

    # Enable or disable debug logging. Default is 'false'.
    debug: false

    # Disable sniffing the files to detect their content type. Default is 'false'.
    noSniff: false

    # Whether the server runs behind a trusted proxy or not. When this is true,
    # the header X-Forwarded-For will be used for logging the remote addresses
    # of logging attempts (if available).
    behindProxy: true

    # The directory that will be able to be accessed by the users when connecting.
    # This directory will be used by users unless they have their own 'directory' defined.
    # Default is '.' (current directory).
    directory: /data

    # The default permissions for users. This is a case insensitive option. Possible
    # permissions: C (Create), R (Read), U (Update), D (Delete). You can combine multiple
    # permissions. For example, to allow to read and create, set "RC". Default is "R".
    permissions: CRUD

    # The default permissions rules for users. Default is none. Rules are applied
    # from last to first, that is, the first rule that matches the request, starting
    # from the end, will be applied to the request. Rule paths are always relative to
    # the user's directory.
    rules: []

    # The behavior of redefining the rules for users. It can be:
    # - overwrite: when a user has rules defined, these will overwrite any global
    #   rules already defined. That is, the global rules are not applicable to the
    #   user.
    # - append: when a user has rules defined, these will be appended to the global
    #   rules already defined. That is, for this user, their own specific rules will
    #   be checked first, and then the global rules.
    # Default is 'overwrite'.
    rulesBehavior: overwrite

    # Logging configuration
    log:
      # Logging format ('console', 'json'). Default is 'console'.
      format: console
      # Enable or disable colors. Default is 'true'. Only applied if format is 'console'.
      colors: true
      # Logging outputs. You can have more than one output. Default is only 'stderr'.
      outputs:
      - stderr

    # CORS configuration
    cors:
      # Whether or not CORS configuration should be applied. Default is 'false'.
      enabled: false
      credentials: true
      allowed_headers:
        - Depth
      allowed_hosts:
        - http://localhost:8080
      allowed_methods:
        - GET
      exposed_headers:
        - Content-Length
        - Content-Range

    # The list of users. If the list is empty, then there will be no authentication.
    # Otherwise, basic authentication will automatically be configured.
    #
    # If you're delegating the authentication to a different service, you can proxy
    # the username using basic authentication, and then disable webdav's password
    # check using the option:
    #
    noPassword: true
    # users:
    #   # Example 'admin' user with plaintext password.
    #   - username: admin
    #     password: admin
    #   # Example 'john' user with bcrypt encrypted password, with custom directory.
    #   # You can generate a bcrypt-encrypted password by using the 'webdav bcrypt'
    #   # command lint utility.
    #   - username: john
    #     password: "{bcrypt}$2y$10$zEP6oofmXFeHaeMfBNLnP.DO8m.H.Mwhd24/TOX2MWLxAExXi4qgi"
    #     directory: /another/path
    #   # Example user whose details will be picked up from the environment.
    #   - username: "{env}ENV_USERNAME"
    #     password: "{env}ENV_PASSWORD"
    #   - username: basic
    #     password: basic
    #     # Override default permissions.
    #     permissions: CRUD
    #     rules:
    #       # With this rule, the user CANNOT access {user directory}/some/files.
    #       - path: /some/file
    #         permissions: none
    #       # With this rule, the user CAN create, read, update and delete within
    #       # {user directory}/public/access.
    #       - path: /public/access/
    #         permissions: CRUD
    #       # With this rule, the user CAN read and update all files ending with .js.
    #       # It uses a regular expression.
    #       - regex: "^.+.js$"
    #         permissions: RU
  '';
in
{
  options.homefree.services.webdav = userOptions;
  options.homefree.service-options.webdav = userOptions // {
    label = lib.mkOption {
      type = lib.types.str;
      default = "webdav";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "WebDAV";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "hacdias webdav";
      internal = true;
      description = "Project name";
    };
  };

  config = {
  ## Container via the app-platform primitive (modules/app-platform.nix). webdav
  ## mkdir's the CHILD data dir (bind-mounted at /data) but chowns + markers the
  ## PARENT, so dataDir (mkdir) and chownDir (chown target) differ.
  homefree.containers.webdav = lib.mkIf config.homefree.service-options.webdav.enable {
    image = "hacdias/webdav:${version}";
    ## Single Go binary on non-privileged 6060 — drop root.
    runAs = { mode = "rootless"; uid = webdavUid; gid = webdavGid; };
    dataDir = "${containerDataPath}/data";
    chownDir = containerDataPath;

    ports = [
      "0.0.0.0:${toString port}:6060"
    ];

    volumes = [
      "/etc/localtime:/etc/localtime:ro"
      "${containerDataPath}/data:/data"
      "${config-file}:/config.yml:ro"
    ];

    environment = {
      TZ = config.homefree.system.timeZone;
    };
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.webdav) label name project-name;
      port-request = 5334;
      enable = config.homefree.service-options.webdav.enable;
      systemd-service-names = [
        "podman-webdav"
      ];
      sso = {
        kind = "basic_auth";
        ## Dev context (intentionally not surfaced in the admin UI):
        ## Caddy SSO gate + per-request HTTP Basic Auth bridge for
        ## WebDAV clients.
      };
      reverse-proxy = {
        enable = config.homefree.service-options.webdav.enable;
        subdomains = [ "webdav" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.webdav.public;
        oauth2 = true;
        # basic-auth = true;
        ## Admin-only — WebDAV currently serves a single shared
        ## backing user; restricting to admins is the safe default
        ## until per-user provisioning is implemented.
        require-admin-role = true;
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
          description = "Enable WebDAV service";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make service accessible from WAN";
        }
      ];
    }];
  };
}
