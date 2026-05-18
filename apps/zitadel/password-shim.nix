{ config, lib, pkgs, ... }:
let
  cfg = config.homefree.service-options.zitadel-password-shim;

  ## OAuth2 token endpoint that validates Basic auth (sent by clients
  ## as username+password) against Zitadel's Session V2 API. Lets us
  ## use Radicale's built-in `oauth2` auth type (and any other
  ## service that supports ROPC) against Zitadel, which does NOT
  ## support the ROPC grant natively.
  ##
  ## Wire flow per /token request:
  ##   1. Parse grant_type=password & username & password from form body
  ##   2. POST /v2/sessions          { checks: { user: { loginName } } }
  ##   3. PATCH /v2/sessions/<id>    { checks: { password: { password } } }
  ##   4. DELETE /v2/sessions/<id>
  ##   5. Return 200 + opaque token on success, 401 on failure
  ##
  ## The "token" we return is meaningless — Radicale's oauth2 auth
  ## just checks that the token endpoint returned 200. We don't
  ## store sessions, don't issue real tokens, don't honor /userinfo.
  ## Pure verification proxy.

  domain = config.homefree.system.domain;
  zitadelLanAddr = config.homefree.network.lan-address;
  zitadelPort = 3241;

  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    fastapi
    uvicorn
    httpx
    ## FastAPI's Form(...) requires python-multipart at runtime; it's
    ## not pulled in by the fastapi package itself.
    python-multipart
  ]);

  shimScript = pkgs.writeText "zitadel-password-shim.py" ''
    """OAuth2-shaped password verifier wrapping Zitadel Session V2.

    Configured via env:
      LISTEN_HOST, LISTEN_PORT
      ZITADEL_URL         -- e.g. http://10.1.2.1:3241
      ZITADEL_HOST_HEADER -- e.g. sso.example.com
      ZITADEL_PAT_FILE    -- path to a file containing the bearer PAT
    """
    import base64, binascii, logging, os, secrets, sys, time
    import httpx
    from fastapi import FastAPI, Form, Header, HTTPException
    from fastapi.responses import JSONResponse, Response

    LISTEN_HOST = os.environ.get("LISTEN_HOST", "127.0.0.1")
    LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9988"))
    ZITADEL_URL = os.environ["ZITADEL_URL"].rstrip("/")
    ZITADEL_HOST = os.environ["ZITADEL_HOST_HEADER"]
    PAT_FILE    = os.environ["ZITADEL_PAT_FILE"]

    log = logging.getLogger("zitadel-password-shim")
    logging.basicConfig(level=logging.INFO, stream=sys.stderr,
        format="%(asctime)s %(levelname)s %(name)s %(message)s")

    app = FastAPI()


    def _load_pat() -> str:
        with open(PAT_FILE) as f:
            return f.read().strip()


    def _zit_headers() -> dict:
        return {
            "Authorization": f"Bearer {_load_pat()}",
            "Host": ZITADEL_HOST,
            "Content-Type": "application/json",
        }


    class IdpUnavailable(Exception):
        """Raised when Zitadel itself could not be reached / answered
        malformed — distinct from 'credentials are wrong'."""


    async def _verify(username: str, password: str) -> bool:
        """Validate username+password against Zitadel's Session V2 API.

        Returns True on valid credentials, False on bad credentials.
        Raises IdpUnavailable if Zitadel is unreachable or its response
        is malformed (caller should surface 503, not 401).

        Per the Zitadel v2 session API:
          POST /v2/sessions        creates a session keyed to a loginName
          PATCH /v2/sessions/<id>  attaches a password check
        If the password check returns 2xx, the credentials are valid.
        We immediately DELETE the session afterward — single-use, we
        don't need it.
        """
        async with httpx.AsyncClient(timeout=10.0) as cx:
            try:
                create = await cx.post(
                    f"{ZITADEL_URL}/v2/sessions",
                    headers=_zit_headers(),
                    json={"checks": {"user": {"loginName": username}}},
                )
            except httpx.RequestError as e:
                log.error("zitadel session create transport error: %s", e)
                raise IdpUnavailable()

            if not (200 <= create.status_code < 300):
                # User not found / org-level lockout / etc. — auth failure.
                log.info("session create failed for %r: %s %s",
                         username, create.status_code, create.text[:200])
                return False

            create_body = create.json()
            session_id = create_body.get("sessionId")
            session_token = create_body.get("sessionToken")
            if not session_id or not session_token:
                log.error("session create missing id/token in response: %s", create_body)
                raise IdpUnavailable()

            # PATCH attaches the password challenge. Auth is the PAT
            # (NOT the per-session sessionToken — Zitadel docs note
            # the sessionToken on update is deprecated and ignored).
            # 403 on PATCH while POST returned 201 means we were
            # sending the wrong credential here.
            try:
                check = await cx.patch(
                    f"{ZITADEL_URL}/v2/sessions/{session_id}",
                    headers=_zit_headers(),
                    json={"checks": {"password": {"password": password}}},
                )
            except httpx.RequestError as e:
                log.error("zitadel session update transport error: %s", e)
                # Best-effort cleanup before returning
                _ = await cx.delete(
                    f"{ZITADEL_URL}/v2/sessions/{session_id}",
                    headers=_zit_headers(),
                )
                raise IdpUnavailable()

            ok = 200 <= check.status_code < 300
            # Log non-2xx details so a future "bad password" vs
            # "API call broke" isn't ambiguous.
            if not ok:
                log.info("password check non-2xx for %r: %s %s",
                         username, check.status_code, check.text[:200])

            # Always delete the session, success or not. Single-use semantics.
            try:
                await cx.delete(
                    f"{ZITADEL_URL}/v2/sessions/{session_id}",
                    headers=_zit_headers(),
                )
            except Exception as e:
                # Leaked session — Zitadel will eventually time it out.
                log.warning("session delete failed for %s: %s", session_id, e)

            return ok


    @app.post("/token")
    async def token(
        grant_type: str = Form(...),
        username:   str = Form(...),
        password:   str = Form(...),
        client_id:     str = Form(None),
        client_secret: str = Form(None),
        scope:         str = Form(None),
    ):
        """RFC6749 password-grant endpoint. Used by Radicale's built-in
        `oauth2` auth type (form POST: grant_type=password&username&password)."""
        # We only implement the password grant. Other grants get 400 per RFC6749.
        if grant_type != "password":
            return JSONResponse(
                status_code=400,
                content={"error": "unsupported_grant_type",
                         "error_description": f"grant_type={grant_type!r} not supported"},
            )

        if not username or not password:
            return JSONResponse(
                status_code=400,
                content={"error": "invalid_request",
                         "error_description": "username and password required"},
            )

        try:
            ok = await _verify(username, password)
        except IdpUnavailable:
            raise HTTPException(status_code=503,
                detail="upstream identity provider unavailable")

        if not ok:
            return JSONResponse(
                status_code=401,
                content={"error": "invalid_grant",
                         "error_description": "bad credentials"},
            )

        # Issue an opaque token. Radicale's oauth2 auth doesn't use the
        # token for anything beyond "did we get one"; we don't bother
        # building a JWT.
        access_token = secrets.token_urlsafe(32)
        log.info("authenticated %r (token grant)", username)
        return {
            "access_token": access_token,
            "token_type": "Bearer",
            "expires_in": 3600,
        }


    ## HTTP Basic Auth verification endpoint.
    ##
    ## Designed to sit behind a Caddy `forward_auth`: Caddy replays a
    ## non-browser API client's original request (carrying an
    ## `Authorization: Basic ...` header) to this endpoint. We decode
    ## the credentials, validate them against Zitadel, and on success
    ## echo the username back as `X-Auth-Request-Preferred-Username` so
    ## Caddy's `copy_headers` can lift it onto the upstream request —
    ## the upstream then authenticates the request from that header.
    ##
    ## `forward_auth` replays the client's original METHOD, so this is
    ## registered for both GET (Subsonic clients) and POST. A 401
    ## carries `WWW-Authenticate: Basic` so a client knows to send (or
    ## re-prompt for) credentials.
    _BASIC_REALM = "homefree-sso"


    async def _verify_basic(authorization: str) -> Response:
        if not authorization or not authorization.lower().startswith("basic "):
            return Response(
                status_code=401, content="missing basic credentials",
                headers={"WWW-Authenticate": f'Basic realm="{_BASIC_REALM}"'},
            )
        b64 = authorization[len("basic "):].strip()
        try:
            decoded = base64.b64decode(b64, validate=True).decode("utf-8")
        except (binascii.Error, UnicodeDecodeError):
            return Response(
                status_code=401, content="malformed basic credentials",
                headers={"WWW-Authenticate": f'Basic realm="{_BASIC_REALM}"'},
            )
        if ":" not in decoded:
            return Response(
                status_code=401, content="malformed basic credentials",
                headers={"WWW-Authenticate": f'Basic realm="{_BASIC_REALM}"'},
            )
        username, password = decoded.split(":", 1)
        if not username or not password:
            return Response(
                status_code=401, content="empty username or password",
                headers={"WWW-Authenticate": f'Basic realm="{_BASIC_REALM}"'},
            )

        try:
            ok = await _verify(username, password)
        except IdpUnavailable:
            return Response(status_code=503,
                            content="upstream identity provider unavailable")

        if not ok:
            return Response(
                status_code=401, content="bad credentials",
                headers={"WWW-Authenticate": f'Basic realm="{_BASIC_REALM}"'},
            )

        log.info("authenticated %r (basic verify)", username)
        # 200 + the SSO username as a header. Caddy lifts this onto the
        # upstream request via `copy_headers X-Auth-Request-Preferred-Username`.
        return Response(
            status_code=200, content="ok",
            headers={"X-Auth-Request-Preferred-Username": username},
        )


    @app.get("/verify-basic")
    async def verify_basic_get(authorization: str = Header(None)):
        return await _verify_basic(authorization)


    @app.post("/verify-basic")
    async def verify_basic_post(authorization: str = Header(None)):
        return await _verify_basic(authorization)


    @app.get("/healthz")
    async def healthz():
        return {"ok": True}


    if __name__ == "__main__":
        import uvicorn
        uvicorn.run(app, host=LISTEN_HOST, port=LISTEN_PORT,
                    log_level="info", access_log=False)
  '';
in
{
  ## The shim is internal infrastructure — it has no user-facing
  ## surface. It runs whenever any service that depends on it is on
  ## (Radicale's oauth2 auth; any service using
  ## `reverse-proxy.basic-auth-sso-paths`, e.g. the Navidrome flake's
  ## Subsonic API). Activation is driven by the internal `consumers`
  ## list below — no `enable` option on purpose: services with an
  ## `enable` option get picked up by the admin-web catalog scan and
  ## appear on the Services page, which is wrong for a runtime bridge
  ## that the user doesn't control.
  options.homefree.service-options.zitadel-password-shim = {
    listen-port = lib.mkOption {
      type = lib.types.int;
      default = 9988;
      description = ''
        Port the shim listens on. Bound to 0.0.0.0 so containers
        on the podman bridge network can reach it via the host LAN
        address; firewall rules keep it off the WAN.
      '';
    };

    consumers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      internal = true;
      description = ''
        Services that require the password shim to run. The shim's
        systemd unit activates iff this list is non-empty.

        A service that needs the shim (Radicale's `oauth2` auth, or
        a service using `reverse-proxy.basic-auth-sso-paths`) adds
        its own name here from its `config` block. This keeps the
        shim's activation decoupled from any single service — an
        in-repo app or an external custom flake can both turn it on,
        and the lists merge.
      '';
    };
  };

  config = lib.mkIf (config.homefree.service-options.zitadel-password-shim.consumers != []) {
    ## The shim needs a PAT scoped to call Zitadel's Session V2 API
    ## (POST /v2/sessions, PATCH /v2/sessions/<id>, DELETE
    ## /v2/sessions/<id>). That endpoint requires the
    ## `urn:zitadel:iam:role:IAM_LOGIN_CLIENT` role — ORG_OWNER is
    ## NOT enough; it'll get back "membership not found (AUTHZ-cdgFk)"
    ## on every session create.
    ##
    ## Zitadel's bootstrap job already mints exactly such a PAT at
    ## /var/lib/zitadel/bootstrap/login-client.pat — intended for
    ## login UIs and any other service that needs Session V2 access.
    ## We reuse it. The file is owned by the zitadel user with 0644.
    ##
    ## @TODO Better: have zitadel-provision mint a dedicated machine
    ## user with IAM_LOGIN_CLIENT role per shim consumer. For now
    ## the bootstrap PAT works and follows least surprise.
    systemd.services.zitadel-password-shim = {
      description = "OAuth2-shape password verifier wrapping Zitadel Session V2";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "podman-zitadel.service" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        DynamicUser = false;
        User = "root";
        ## Wait up to 5 minutes for the bootstrap PAT to be written.
        ## On a fresh install this lands during the initial zitadel
        ## bootstrap; on a running system it's already there.
        ExecStartPre = pkgs.writeShellScript "zitadel-password-shim-wait-pat" ''
          PAT_FILE=/var/lib/zitadel/bootstrap/login-client.pat
          for i in $(seq 1 60); do
            [ -s "$PAT_FILE" ] && exit 0
            sleep 5
          done
          echo "zitadel-password-shim: PAT file $PAT_FILE never appeared" >&2
          exit 1
        '';
        ExecStart = "${pythonEnv}/bin/python ${shimScript}";
        Environment = [
          "LISTEN_HOST=0.0.0.0"
          "LISTEN_PORT=${toString cfg.listen-port}"
          "ZITADEL_URL=http://${zitadelLanAddr}:${toString zitadelPort}"
          "ZITADEL_HOST_HEADER=sso.${domain}"
          "ZITADEL_PAT_FILE=/var/lib/zitadel/bootstrap/login-client.pat"
        ];
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
