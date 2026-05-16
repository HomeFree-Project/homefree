#!/usr/bin/env python3
"""
HomeFree Web Installer Backend - REST API
Simplified version without strawberry-graphql dependency
"""

import os
import sys
import logging
import json
from pathlib import Path
from typing import Optional
from datetime import datetime

# Ensure backend directory is in Python path for module imports
backend_dir = Path(__file__).parent.absolute()
if str(backend_dir) not in sys.path:
    sys.path.insert(0, str(backend_dir))

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from starlette.middleware.base import BaseHTTPMiddleware

# Import resolvers
from resolvers.system import SystemResolver
from resolvers.network import NetworkResolver
from resolvers.config import ConfigResolver
from resolvers.install import InstallResolver
from resolvers.services import ServicesResolver
from resolvers.abuse_blocking import AbuseBlockingResolver

# Import API routers
from resolvers.secrets import router as secrets_router
from resolvers.backups import router as backups_router

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Trusted-header auth middleware.
#
# Once the SSO bridge is fully provisioned (sentinel file present),
# every request is required to carry an X-Auth-Request-User header set
# by the upstream oauth2-proxy. Caddy's `forward_auth` block in
# services/admin-web.nix only forwards requests after oauth2-proxy
# accepts them, so the header is trustworthy *iff* the request came
# through Caddy. Direct connections to localhost:8000 bypass this —
# acceptable because the backend listens on loopback only.
#
# Pre-provisioning the sentinel doesn't exist (fresh install): the
# admin UI must remain reachable so the user can finish first-time
# setup. We open-fail in that mode rather than block.
#
# A small allowlist (PUBLIC_PATHS) covers endpoints that must work
# without auth even after provisioning: health checks, the
# service-state file used by the frontend overlay during rebuilds.
class TrustedHeaderAuthMiddleware(BaseHTTPMiddleware):
    SENTINEL = Path("/var/lib/homefree-secrets/.sso-provisioned")
    ADMIN_USERNAME_FILE = Path("/var/lib/homefree-admin/admin-username")
    ADMIN_ROLE = "homefree-admin"
    PUBLIC_PATHS = {
        "/health",
        "/api/service-state",
        "/api/closure-id",
        # The oauth2-proxy OIDC client_id is needed by the sign-out
        # link rendered on the access-denied page (the user is
        # authenticated but not the admin — they should still be
        # able to sign out). Not a secret: it's already visible on
        # every /authorize URL during the normal SSO flow.
        "/api/sso/oauth2-client-id",
        # /api/mode is the preflight every SPA boot makes from
        # index.html to detect installer vs admin shell. It's also
        # what the home.<domain> dashboard probes to know the
        # cookie is still valid before importing the SPA module.
        # The response carries no identity-bearing data — it's a
        # property of the box, not the user — so leaving it open
        # to any caller is safe and unblocks the user surface.
        "/api/mode",
    }
    ## Paths that any AUTHENTICATED user can hit — admin role is NOT
    ## required. These are the self-service endpoints powering
    ## home.<domain> (per-user dashboard): read your own profile,
    ## change your own name/password, list the apps you can launch.
    ##
    ## The middleware still requires a valid X-Auth-Request-User
    ## header (oauth2-proxy session). Identity for any write is
    ## resolved server-side from that header, never the request body
    ## — see _resolve_user_id_by_name() callers below.
    SELF_SERVICE_PATHS = {
        "/api/users/me",
        "/api/users/me/password",
        "/api/users/me/profile",
        "/api/services/visible-to-me",
        # The password policy (min length, complexity) is what the
        # user dashboard's "Change password" form validates against
        # before submitting. The endpoint exposes only policy
        # parameters, no per-user data — safe for any authenticated
        # caller, and required for the form to render its
        # requirement checklist.
        "/api/sso/password-policy",
    }
    ## oauth2-proxy v7's behavior:
    ##   - X-Auth-Request-Preferred-Username always carries the OIDC
    ##     `preferred_username` claim (Zitadel sets this to the bare
    ##     username, e.g. "erahhal").
    ##   - X-Auth-Request-User carries whatever USER_ID_CLAIM points
    ##     at, but in practice we've seen it stick to the OIDC `sub`
    ##     (Zitadel's numeric internal ID, e.g. "372429767272238115")
    ##     even after setting USER_ID_CLAIM=preferred_username.
    ##   - X-Auth-Request-Groups is set when OAUTH2_PROXY_OIDC_GROUPS_CLAIM
    ##     is configured (we point it at Zitadel's namespaced project-
    ##     role claim, so the header carries the role keys).
    ##
    ## Read the username header first; fall back to X-Auth-Request-User
    ## only if the preferred_username header is absent.
    USER_HEADER = "x-auth-request-preferred-username"
    USER_HEADER_FALLBACK = "x-auth-request-user"
    GROUPS_HEADER = "x-auth-request-groups"

    @staticmethod
    def _parse_groups(raw: str) -> set[str]:
        """Extract a flat set of role/group names from the
        X-Auth-Request-Groups header.

        oauth2-proxy's behavior when OIDC_GROUPS_CLAIM points at
        Zitadel's namespaced project-roles claim is unfortunate: it
        passes the raw JSON-stringified OBJECT through (not the keys
        of that object). For our setup the header looks like:

            X-Auth-Request-Groups: {"homefree-admin":{"<org_id>":"<domain>"}}

        We try three formats in order:
          1. JSON object — take its top-level keys (role names).
          2. JSON array of strings — pass through.
          3. Comma-separated string — split on commas (the
             oauth2-proxy default when the claim was a flat list).

        Falls open on parse failure (returns empty set) so a
        misformed header just means "no roles," not "fail loudly."
        """
        if not raw:
            return set()
        import json
        # oauth2-proxy may comma-join multiple values if the header
        # is set more than once. Try a JSON parse on the WHOLE
        # string first (the namespaced-claim case usually passes
        # through as a single JSON blob, no commas added).
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, dict):
                return {str(k) for k in parsed.keys()}
            if isinstance(parsed, list):
                return {str(x) for x in parsed if isinstance(x, str)}
        except (ValueError, TypeError):
            pass
        # Fallback: comma-split.
        return {g.strip() for g in raw.split(",") if g.strip()}

    async def dispatch(self, request: Request, call_next):
        # Bootstrap mode: SSO not yet provisioned → backend is open.
        # The admin must complete the installer flow which culminates
        # in zitadel-provision.service running, which touches the
        # sentinel. From the next request onward, this branch flips.
        if not self.SENTINEL.exists():
            return await call_next(request)

        # Always-allowed paths.
        if request.url.path in self.PUBLIC_PATHS:
            return await call_next(request)

        user = request.headers.get(self.USER_HEADER) \
            or request.headers.get(self.USER_HEADER_FALLBACK)
        if not user:
            # Direct hit on the backend (bypassing Caddy) or oauth2-
            # proxy didn't set the header. Reject so we never act on
            # an unauthenticated request post-provisioning.
            return JSONResponse(
                {"error": "unauthenticated", "detail": "missing X-Auth-Request-User"},
                status_code=401,
            )

        # Self-service paths bypass the admin-role check. They still
        # need an authenticated user (verified above) — the route
        # handlers themselves enforce the "you can only modify your
        # own record" invariant by resolving the target user id from
        # the auth header, not from request bodies.
        if request.url.path in self.SELF_SERVICE_PATHS:
            groups_raw = request.headers.get(self.GROUPS_HEADER, "")
            request.state.auth_user = user
            request.state.auth_groups = self._parse_groups(groups_raw)
            return await call_next(request)

        # Role-based admin gate. Presence of the `homefree-admin`
        # project role in the user's token is the canonical signal.
        # Fall back to the old username-equality check ONLY if the
        # groups header is entirely absent (which would mean the
        # oauth2-proxy / Zitadel role plumbing hasn't been deployed
        # yet — common on a partially-upgraded install). The
        # fallback ensures the admin user can still get in to
        # finish the upgrade.
        groups_raw = request.headers.get(self.GROUPS_HEADER, "")
        groups = self._parse_groups(groups_raw)
        is_admin = self.ADMIN_ROLE in groups
        admin_check_via = "groups" if groups_raw else "fallback-username"

        if not is_admin and admin_check_via == "fallback-username":
            try:
                if self.ADMIN_USERNAME_FILE.is_file():
                    expected = self.ADMIN_USERNAME_FILE.read_text().strip()
                    if expected and user == expected:
                        is_admin = True
                        logger.warning(
                            "Admitting '%s' via legacy username check "
                            "(no groups header). Re-run zitadel-provision "
                            "to enable role-based gating.",
                            user,
                        )
            except Exception as e:
                logger.warning("Admin username check failed: %s", e)

        if not is_admin:
            expected = None
            try:
                if self.ADMIN_USERNAME_FILE.is_file():
                    expected = self.ADMIN_USERNAME_FILE.read_text().strip() or None
            except Exception:
                pass
            logger.warning(
                "Admin UI access denied for user '%s' (groups: %s)",
                user, sorted(groups) or "none",
            )
            return JSONResponse(
                {
                    "error": "forbidden",
                    "code": "not_admin_user",
                    "detail": (
                        f"You are signed in as '{user}', but the "
                        f"HomeFree admin UI requires the "
                        f"'{self.ADMIN_ROLE}' role."
                    ),
                    "current_user": user,
                    "admin_user": expected,
                },
                status_code=403,
            )

        # Stash the authenticated user + groups for downstream
        # handlers that want them.
        request.state.auth_user = user
        request.state.auth_groups = groups
        return await call_next(request)


# Request logging middleware
#
# CRITICAL: Request bodies pass through here in cleartext. Any
# endpoint that accepts a password, secret, token, or similar
# credential MUST be path-matched in _SENSITIVE_PATH_PATTERNS so its
# body is redacted before logging. Field-level redaction of known
# key names (password / current_password / etc.) backs that up — if
# someone adds a new endpoint and forgets to register the path, the
# field-level pass still catches common credential fields.
#
# We log to systemd journal which goes to disk and is read by the
# admin team. Leaking a cleartext password to the journal is a
# severe incident — assume the journal is compromised threat-modelwise.
_SENSITIVE_PATH_PATTERNS = (
    "/password",        # any /api/users/.../password, /api/users/me/password
    "/api/config/user", # installer user setup
    "/secrets",         # any /api/secrets/... POST
    "/api/users",       # POST /api/users (create) carries a `password` field
)

# Key names whose values get redacted regardless of path. Lowercase
# match against JSON keys after parsing. This is the safety net.
_SENSITIVE_KEYS = {
    "password", "current_password", "new_password", "old_password",
    "confirm_password", "secret", "client_secret", "token", "pat",
    "api_key", "hashed_password", "passwd",
}

def _redact_body_for_log(path: str, body_str: str) -> str:
    """Return a log-safe rendering of `body_str`. If the path is
    flagged sensitive, swap the whole body for a placeholder. If not,
    parse as JSON and scrub known-sensitive keys to a constant string.
    Falls back to the placeholder on any parse error rather than
    risk leaking a malformed payload that contains a credential."""
    if any(p in path for p in _SENSITIVE_PATH_PATTERNS):
        return "<redacted: sensitive path>"
    try:
        parsed = json.loads(body_str)
    except Exception:
        return body_str
    def scrub(obj):
        if isinstance(obj, dict):
            return {
                k: ("***REDACTED***" if k.lower() in _SENSITIVE_KEYS else scrub(v))
                for k, v in obj.items()
            }
        if isinstance(obj, list):
            return [scrub(x) for x in obj]
        return obj
    return json.dumps(scrub(parsed), indent=2)

class RequestLoggingMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        # Capture request details
        method = request.method
        path = request.url.path
        timestamp = datetime.now().isoformat()

        # Read request body if present
        body = None
        if method in ["POST", "PUT", "PATCH"]:
            try:
                body_bytes = await request.body()
                if body_bytes:
                    body = body_bytes.decode('utf-8')
                    # Redact credentials BEFORE any pretty-printing —
                    # we never want a cleartext password to touch the
                    # logger, even transiently.
                    body = _redact_body_for_log(path, body)
            except:
                body = "<unable to read body>"

        # Log in a format that's easy to replay
        log_msg = f"\n{'='*80}\n"
        log_msg += f"API REQUEST CAPTURE [{timestamp}]\n"
        log_msg += f"Method: {method}\n"
        log_msg += f"Path: {path}\n"
        if body:
            log_msg += f"Body:\n{body}\n"
        log_msg += f"{'='*80}\n"
        logger.info(log_msg)

        # Also log in a machine-parseable format
        replay_data = {
            "timestamp": timestamp,
            "method": method,
            "path": path,
            "body": body
        }
        logger.info(f"REPLAY_DATA: {json.dumps(replay_data)}")

        # Continue with request
        response = await call_next(request)
        return response

# Create FastAPI app
app = FastAPI(title="HomeFree Web Installer API")

# Add request logging middleware (FIRST, before CORS)
app.add_middleware(RequestLoggingMiddleware)

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Trust-header auth: added LAST so it runs FIRST (Starlette stacks
# middleware LIFO — outermost = last added). Pre-provisioning this
# is a no-op; post-provisioning it rejects requests that don't carry
# the X-Auth-Request-User header set by oauth2-proxy via Caddy's
# forward_auth block.
app.add_middleware(TrustedHeaderAuthMiddleware)

# Register API routers
app.include_router(secrets_router)
app.include_router(backups_router)

# Startup event handler
@app.on_event("startup")
async def clear_service_restart_flag():
    """Clear service restart flag on startup to indicate service is operational"""
    try:
        service_state_file = Path("/var/lib/homefree-admin/service-state.json")
        state_data = {
            "admin_api_status": "operational",
            "timestamp": datetime.now().isoformat(),
            "message": "Admin API is running normally"
        }
        service_state_file.parent.mkdir(parents=True, exist_ok=True)
        service_state_file.write_text(json.dumps(state_data, indent=2))
        logger.info("Service state file updated to operational status")
    except Exception as e:
        logger.error(f"Error clearing service restart flag: {e}")

# Request/Response Models
class NetworkConfigRequest(BaseModel):
    wan_interface: str
    lan_interface: str

class HostnameRequest(BaseModel):
    hostname: str

class LocationRequest(BaseModel):
    timezone: str
    locale: str
    # Optional localization extras — all default to None to keep
    # backwards-compatibility with existing callers (admin UI, older
    # installers) that only send {timezone, locale}.
    country_code: Optional[str] = None
    language: Optional[str] = None
    currency: Optional[str] = None
    unit_system: Optional[str] = None
    elevation: Optional[int] = None
    latitude: Optional[float] = None
    longitude: Optional[float] = None

class KeyboardRequest(BaseModel):
    layout: str
    vconsole: str

class UserRequest(BaseModel):
    username: str
    fullname: str
    email: str
    password: str

class PartitioningRequest(BaseModel):
    config: str

class DevelopmentModeRequest(BaseModel):
    enabled: bool

class DomainRequest(BaseModel):
    domain: str

# Utility function to convert resolver objects to dicts
def to_dict(obj):
    """Convert dataclass/strawberry objects to dictionaries"""
    if hasattr(obj, '__dict__'):
        result = {}
        for key, value in obj.__dict__.items():
            if isinstance(value, list):
                result[key] = [to_dict(item) if hasattr(item, '__dict__') else item for item in value]
            elif hasattr(value, '__dict__'):
                result[key] = to_dict(value)
            else:
                result[key] = value
        return result
    return obj

# Root endpoint - serve frontend or simple HTML
@app.get("/")
async def root():
    """Root endpoint - serve frontend index.html or fallback HTML"""
    frontend_html = Path("/etc/homefree-installer/frontend/index.html")

    if frontend_html.exists():
        return FileResponse(str(frontend_html))

    # Fallback HTML if frontend not available
    return HTMLResponse(content="""
<!DOCTYPE html>
<html>
<head>
    <title>HomeFree Installer</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            display: flex;
            align-items: center;
            justify-content: center;
            min-height: 100vh;
            margin: 0;
        }
        .container {
            text-align: center;
            padding: 40px;
            background: rgba(255, 255, 255, 0.1);
            border-radius: 12px;
            backdrop-filter: blur(10px);
        }
        h1 { font-size: 48px; margin-bottom: 16px; }
        p { font-size: 18px; margin: 16px 0; opacity: 0.9; }
        .status {
            background: rgba(255, 255, 255, 0.2);
            padding: 16px;
            border-radius: 8px;
            margin-top: 24px;
        }
        a {
            color: white;
            text-decoration: underline;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 HomeFree Web Installer</h1>
        <p>Backend REST API is running!</p>
        <div class="status">
            <p><strong>Status:</strong> ✅ Connected</p>
            <p><strong>API Endpoints:</strong></p>
            <p><a href="/api/status">/api/status</a> - Backend status</p>
            <p><a href="/api/system">/api/system</a> - System information</p>
            <p><a href="/api/network/interfaces">/api/network/interfaces</a> - Network interfaces</p>
            <p><a href="/health">/health</a> - Health check</p>
        </div>
        <p style="margin-top: 24px; font-size: 14px; opacity: 0.7;">
            REST API ready for installation wizard.<br>
            Frontend will load here when available.
        </p>
    </div>
</body>
</html>
    """)

# Health check endpoint
@app.get("/health")
async def health():
    """Health check endpoint with service status"""
    try:
        service_state_file = Path("/var/lib/homefree-admin/service-state.json")
        if service_state_file.exists():
            state_data = json.loads(service_state_file.read_text())
            return {
                "status": "ok",
                "message": "HomeFree Installer Backend is running",
                "service_state": state_data
            }
    except Exception as e:
        logger.warning(f"Error reading service state file: {e}")

    # Fallback if state file doesn't exist or can't be read
    return {
        "status": "ok",
        "message": "HomeFree Installer Backend is running",
        "service_state": {
            "admin_api_status": "operational",
            "timestamp": datetime.now().isoformat()
        }
    }

@app.get("/api/status")
async def status():
    """Backend status endpoint"""
    return {
        "backend": "running",
        "version": "1.0-rest",
        "api_type": "REST",
        "message": "Backend operational with REST API"
    }

# System Information Endpoints

@app.get("/api/system")
async def get_system_info():
    """Get system information including hostname, CPU, memory, and disks"""
    try:
        system_info = SystemResolver.get_system_info()
        return JSONResponse(content=to_dict(system_info))
    except Exception as e:
        logger.error(f"Error getting system info: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/system/is-virtualized")
async def is_virtualized():
    """Check if the system is running in a virtual machine (QEMU/KVM)"""
    try:
        is_vm = SystemResolver.is_virtualized()
        return JSONResponse(content={"isVirtualized": is_vm})
    except Exception as e:
        logger.error(f"Error detecting virtualization: {e}")
        raise HTTPException(status_code=500, detail=str(e))

# Filesystem Endpoints

@app.get("/api/filesystem/browse")
async def browse_filesystem(path: str = "/"):
    """
    Browse server filesystem directories
    Security: Only allows access to whitelisted root paths
    Returns list of subdirectories for file picker UI
    """
    import os

    # Security: Only allow whitelisted root paths
    ALLOWED_ROOTS = ["/", "/home", "/mnt", "/var/lib", "/media", "/srv", "/opt"]

    try:
        # Resolve real path (follows symlinks, resolves ..)
        real_path = os.path.realpath(path)

        # Check if path is allowed for browsing
        # Allow if:
        # 1. Path is root "/"
        # 2. Path matches or is a child of a whitelisted root
        # 3. Path is a PARENT of a whitelisted root (e.g., /var is parent of /var/lib)
        def is_browseable(path):
            if path == "/":
                return True

            non_root_allowed = [r for r in ALLOWED_ROOTS if r != "/"]

            # Check if path is under a whitelisted root
            for root in non_root_allowed:
                if path == root or path.startswith(root + "/"):
                    return True

            # Check if path is a parent of a whitelisted root
            for root in non_root_allowed:
                if root.startswith(path + "/"):
                    return True

            return False

        if not is_browseable(real_path):
            raise HTTPException(
                status_code=403,
                detail=f"Access denied: Path must be under one of {', '.join(ALLOWED_ROOTS)}"
            )

        # Verify path exists and is a directory
        if not os.path.exists(real_path):
            raise HTTPException(status_code=404, detail="Path does not exist")

        if not os.path.isdir(real_path):
            raise HTTPException(status_code=400, detail="Path is not a directory")

        # Helper function to check if a path is selectable
        def is_selectable(path):
            """Check if a path can be selected (is in or under ALLOWED_ROOTS)"""
            if path == "/":
                return False  # Root itself cannot be selected
            non_root_allowed = [r for r in ALLOWED_ROOTS if r != "/"]
            return any(
                path == root or path.startswith(root + "/")
                for root in non_root_allowed
            )

        # List directories only (not files)
        entries = []
        try:
            for item in os.listdir(real_path):
                full_path = os.path.join(real_path, item)
                # Only include directories, skip files
                if os.path.isdir(full_path):
                    # Check if readable
                    if os.access(full_path, os.R_OK):
                        entries.append({
                            "name": item,
                            "path": full_path,
                            "selectable": is_selectable(full_path)
                        })
        except PermissionError:
            # If we can't list directory contents, return empty list
            pass

        # Sort entries by name
        entries.sort(key=lambda x: x["name"].lower())

        # Get parent directory (if not at root)
        parent = None
        if real_path != "/":
            parent_path = os.path.dirname(real_path)
            # Always allow parent since "/" is in ALLOWED_ROOTS and we validate on entry
            parent = parent_path

        return JSONResponse(content={
            "path": real_path,
            "parent": parent,
            "selectable": is_selectable(real_path),
            "entries": entries
        })

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error browsing filesystem at {path}: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/filesystem/mkdir")
async def create_directory(request: Request):
    """
    Create a new directory
    Security: Only allows creation under whitelisted root paths
    """
    import os

    # Reuse same security whitelist as browse endpoint
    ALLOWED_ROOTS = ["/", "/home", "/mnt", "/var/lib", "/media", "/srv", "/opt"]

    try:
        data = await request.json()
        path = data.get("path")

        if not path:
            raise HTTPException(status_code=400, detail="Path is required")

        # Resolve real path (follows symlinks, resolves ..)
        real_path = os.path.realpath(path)

        # Check if path is allowed (don't allow creating directories directly in root)
        non_root_allowed = [r for r in ALLOWED_ROOTS if r != "/"]
        is_allowed = any(
            real_path == root or real_path.startswith(root + "/")
            for root in non_root_allowed
        )

        if not is_allowed:
            raise HTTPException(
                status_code=403,
                detail=f"Access denied: Path must be under one of {', '.join(ALLOWED_ROOTS)}"
            )

        # Check if parent directory exists
        parent_dir = os.path.dirname(real_path)
        if not os.path.exists(parent_dir):
            raise HTTPException(status_code=400, detail="Parent directory does not exist")

        if not os.path.isdir(parent_dir):
            raise HTTPException(status_code=400, detail="Parent path is not a directory")

        # Check if directory already exists
        if os.path.exists(real_path):
            raise HTTPException(status_code=409, detail="Directory already exists")

        # Create directory
        os.makedirs(real_path, exist_ok=False)
        logger.info(f"Created directory: {real_path}")

        return JSONResponse(content={
            "success": True,
            "path": real_path
        })

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error creating directory at {path}: {e}")
        raise HTTPException(status_code=500, detail=str(e))

# Services Endpoints

@app.get("/api/services")
async def get_services():
    """Get list of services with their runtime status"""
    try:
        services = ServicesResolver.get_services()
        return JSONResponse(content=[to_dict(service) for service in services])
    except Exception as e:
        logger.error(f"Error getting services: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/services/options/schema")
async def get_service_options_schema():
    """Get schema of all configurable service options"""
    try:
        schema = ServicesResolver.get_service_options_schema()
        return JSONResponse(content={"schema": schema})
    except Exception as e:
        logger.error(f"Error getting service options schema: {e}")
        raise HTTPException(status_code=500, detail=str(e))


_ALLOWED_SERVICE_ACTIONS = {"start", "restart", "stop"}


class ServiceActionRequest(BaseModel):
    action: str


@app.post("/api/services/{label}/action")
async def post_service_action(label: str, body: ServiceActionRequest, request: Request):
    """Run systemctl start|restart|stop against every unit that backs
    a service label. Admin-role gated by the global auth middleware
    (TrustedHeaderAuthMiddleware) — but we re-check the role flag
    here belt-and-suspenders: a config slip that loosens the
    middleware shouldn't immediately hand out systemctl.

    Allowlist is the catalog itself — we only operate on units that
    appear under a known service label in all-services.json /
    service-config. Arbitrary unit names are rejected.
    """
    import subprocess

    groups = getattr(request.state, "auth_groups", set()) or set()
    if HOMEFREE_ADMIN_ROLE not in groups:
        raise HTTPException(status_code=403, detail="admin role required")

    action = body.action.lower().strip()
    if action not in _ALLOWED_SERVICE_ACTIONS:
        raise HTTPException(
            status_code=400,
            detail=f"action must be one of {sorted(_ALLOWED_SERVICE_ACTIONS)}",
        )

    units = ServicesResolver.get_units_for_label(label)
    if units is None:
        raise HTTPException(status_code=404, detail=f"unknown service: {label}")
    if not units:
        raise HTTPException(
            status_code=400,
            detail=f"service {label!r} has no systemd units to control",
        )

    ## Refuse to act on admin-api itself — stopping it from its own
    ## API would deadlock the request and leave the user with no way
    ## back. Stopping admin-web would do the same.
    if label in ("admin-api", "admin"):
        raise HTTPException(
            status_code=400,
            detail=f"refusing to {action} {label!r} from itself",
        )

    user = getattr(request.state, "auth_user", "?")
    logger.warning(
        "service action: user=%s label=%s action=%s units=%s",
        user, label, action, units,
    )

    results = []
    for unit in units:
        try:
            r = subprocess.run(
                ["systemctl", action, unit],
                capture_output=True, text=True, timeout=30,
            )
            results.append({
                "unit": unit,
                "returncode": r.returncode,
                "stderr": r.stderr.strip()[:500],
            })
        except subprocess.TimeoutExpired:
            results.append({"unit": unit, "returncode": -1, "stderr": "timeout"})
        except Exception as e:
            results.append({"unit": unit, "returncode": -1, "stderr": str(e)[:500]})

    ok = all(r["returncode"] == 0 for r in results)
    return JSONResponse(
        status_code=200 if ok else 500,
        content={"ok": ok, "label": label, "action": action, "results": results},
    )


## ─── Abuse blocking (fail2ban + nftables) ────────────────────────────
## All routes admin-gated by TrustedHeaderAuthMiddleware. The unban
## POST additionally re-checks the role for defence-in-depth, matching
## the pattern from /api/services/{label}/action.

@app.get("/api/abuse-blocking/status")
async def get_abuse_blocking_status():
    """fail2ban server + per-jail summary."""
    try:
        return JSONResponse(content=AbuseBlockingResolver.get_status())
    except Exception as e:
        logger.error(f"abuse-blocking status: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/abuse-blocking/banned")
async def get_abuse_blocking_banned():
    """Currently banned IPs, merged from f2b_banned4/6 and abusive_nets4."""
    try:
        return JSONResponse(content=AbuseBlockingResolver.get_banned_ips())
    except Exception as e:
        logger.error(f"abuse-blocking banned: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/abuse-blocking/counters")
async def get_abuse_blocking_counters():
    """Packets/bytes dropped per source (static, fail2ban v4, fail2ban v6),
    summed across input + forward chains."""
    try:
        return JSONResponse(content=AbuseBlockingResolver.get_drop_counters())
    except Exception as e:
        logger.error(f"abuse-blocking counters: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/abuse-blocking/top-traffic-sources")
async def get_abuse_blocking_top_traffic_sources(
    window: int = 3600,
    filter: str = "all",
    limit: int = 20,
    include_internal: bool = False,
):
    """Top-N source IPs by hit count in the last `window` seconds across
    Caddy access logs. `filter` is one of all|oauth|4xx|5xx.
    `include_internal=true` includes LAN / tailnet / ULA / loopback
    sources (off by default — those are typically your own client
    apps long-polling and crowd out anything actionable)."""
    ## Clamp inputs so a malicious-or-careless caller can't blow up
    ## the parse cost. Window > 1 day is meaningless (we only tail
    ## the last few MB of each log anyway).
    window = max(60, min(window, 86400))
    limit = max(1, min(limit, 100))
    try:
        return JSONResponse(content=AbuseBlockingResolver.get_top_traffic_sources(
            window_seconds=window, filter_kind=filter, limit=limit,
            include_internal=include_internal,
        ))
    except Exception as e:
        logger.error(f"abuse-blocking top-traffic-sources: {e}")
        raise HTTPException(status_code=500, detail=str(e))


class AbuseBlockingUnbanRequest(BaseModel):
    jail: str
    ip: str


@app.post("/api/abuse-blocking/unban")
async def post_abuse_blocking_unban(body: AbuseBlockingUnbanRequest, request: Request):
    """Unban one IP from one jail. Belt-and-suspenders admin-role
    re-check; the resolver validates jail (allowlist) and IP (parses
    via ipaddress) before reaching the shell."""
    groups = getattr(request.state, "auth_groups", set()) or set()
    if HOMEFREE_ADMIN_ROLE not in groups:
        raise HTTPException(status_code=403, detail="admin role required")

    user = getattr(request.state, "auth_user", "?")
    logger.warning(
        "abuse-blocking unban: user=%s jail=%s ip=%s",
        user, body.jail, body.ip,
    )

    ok, message = AbuseBlockingResolver.unban(body.jail, body.ip)
    return JSONResponse(
        status_code=200 if ok else 400,
        content={"ok": ok, "jail": body.jail, "ip": body.ip, "message": message},
    )


@app.get("/api/services/visible-to-me")
async def get_services_visible_to_me(request: Request):
    """List of services the authenticated user can launch from their
    dashboard. Powers the app grid on home.<domain>.

    Filter rules (everything is AND'd):
      - service is enabled
      - service has a resolvable URL (skip backend-only entries
        like admin-api, child template parents with no own URL)
      - service is not a child-instance parent template (parent=null
        survives; child-of-X passes through as long as it has its
        own URL)
      - service is browser-launchable: either it has oauth2=true
        (SSO gate, so this same session works), or it's public on
        the apex/subdomain without any auth (LAN-only without SSO
        is unreachable from a typical browser session anyway, but
        we still show it so the user knows what's running)
      - service is not admin-only (require-admin-role=true), unless
        the caller has the homefree-admin role
      - service has admin.show != false (filters out admin-api etc.)

    Returns {label, name, url, icon} per entry — a deliberately
    narrow shape, no systemd state, no config internals. The admin
    UI uses /api/services for the fuller picture.
    """
    import json
    groups = getattr(request.state, "auth_groups", set()) or set()
    is_admin = TrustedHeaderAuthMiddleware.ADMIN_ROLE in groups

    try:
        with open("/run/homefree/admin/config.json") as f:
            cfg = json.load(f)
    except Exception as e:
        logger.error("Failed to load admin config for visible-to-me: %s", e)
        raise HTTPException(status_code=500, detail="config unavailable")

    try:
        with open("/etc/nixos/homefree-config.json") as f:
            user_cfg = json.load(f)
    except Exception:
        user_cfg = {}
    enabled_by_label = {
        label: bool(svc.get("enable", False))
        for label, svc in (user_cfg.get("services") or {}).items()
    }

    # Metaservices that power the homefree shell itself — not "apps
    # to launch" from the user's perspective, so don't show them in
    # the app grid. Sign-out / admin link / manual link are surfaced
    # separately in the dashboard chrome.
    METASERVICES = {"home", "admin", "manual", "landing-page", "auth"}

    out = []
    for entry in cfg.get("services", []):
        sc = entry.get("service-config", {}) or {}
        rp = sc.get("reverse-proxy", {}) or {}
        label = sc.get("label") or ""
        url = entry.get("url") or ""

        if not url:
            continue
        if label in METASERVICES:
            continue
        if (sc.get("admin") or {}).get("show") is False:
            continue
        # Parent entries (instance templates) usually carry no URL
        # of their own; child instances have their own labels +
        # URLs and pass this check. Don't double-show a parent.
        # (We're already past the `not url` guard above, so a
        # parent with a URL still shows up — which is fine.)

        # Enabled gate. Three classes of service:
        #  1. User-configurable services (podman apps, etc.): keyed
        #     in homefree-config.json's `services` dict — show iff
        #     enable=true there.
        #  2. Built-in services (admin, home, landing-page, manual):
        #     not in homefree-config.json at all; enable lives on
        #     reverse-proxy.enable in the Nix-level service-config.
        #  3. Child instances (mediawiki_grimoire etc.): parent
        #     determines enablement via the instances array, but
        #     showing a dead tile is gentler than hiding something
        #     the user expects to see — let them through as long
        #     as a URL exists.
        parent = sc.get("parent")
        if not parent:
            if label in enabled_by_label:
                if not enabled_by_label[label]:
                    continue
            else:
                # Built-in service: trust reverse-proxy.enable
                if not rp.get("enable", False):
                    continue

        if rp.get("require-admin-role") and not is_admin:
            continue

        out.append({
            "label": label,
            # `name` is the function (e.g. "Ad Block"). `project_name`
            # is the brand (e.g. "AdGuard Home"). The user dashboard
            # shows name as the tile title and project_name beneath
            # as a subtitle — hides the subtitle when they're equal.
            "name": sc.get("name") or label,
            "project_name": sc.get("project-name") or "",
            "url": url,
            "icon": sc.get("icon"),
        })

    # Stable alphabetical order by display name.
    out.sort(key=lambda x: (x["name"] or "").lower())
    return JSONResponse(content=out)

# Network Endpoints

@app.get("/api/network/interfaces")
async def get_network_interfaces():
    """Get list of network interfaces"""
    try:
        interfaces = NetworkResolver.get_interfaces()
        return JSONResponse(content=[to_dict(iface) for iface in interfaces])
    except Exception as e:
        logger.error(f"Error getting network interfaces: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/network/configure")
async def configure_network(config: NetworkConfigRequest):
    """Configure WAN and LAN network interfaces"""
    try:
        result = NetworkResolver.set_config(config.wan_interface, config.lan_interface)
        return JSONResponse(content=to_dict(result))
    except Exception as e:
        logger.error(f"Error configuring network: {e}")
        raise HTTPException(status_code=500, detail=str(e))

# Locale/Timezone Endpoints

@app.get("/api/locale/timezones")
async def get_timezones():
    """Get available timezones grouped by region"""
    try:
        timezones = ConfigResolver.get_timezones()
        return JSONResponse(content=[to_dict(tz) for tz in timezones])
    except Exception as e:
        logger.error(f"Error getting timezones: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/locale/keyboard-layouts")
async def get_keyboard_layouts():
    """Get available keyboard layouts"""
    try:
        layouts = ConfigResolver.get_keyboard_layouts()
        return JSONResponse(content=[to_dict(layout) for layout in layouts])
    except Exception as e:
        logger.error(f"Error getting keyboard layouts: {e}")
        raise HTTPException(status_code=500, detail=str(e))

## ── Locale data from babel (POSIX locales, ISO 3166 countries, ISO
##    4217 currencies, BCP 47 languages). All of these used to be
##    short hand-maintained inline arrays in the frontend; routing
##    them through one source — the babel CLDR data — keeps the lists
##    accurate and gives us one place to filter/curate.
@app.get("/api/locale/locales")
async def get_locales():
    """All POSIX locale codes for which babel has data, returned in
    a form ready for a <select>: { value: 'en_US.UTF-8', label: 'English (United States)' }.
    """
    try:
        from babel import Locale, localedata
        out = []
        for tag in sorted(localedata.locale_identifiers()):
            try:
                loc = Locale.parse(tag)
            except Exception:
                continue
            name = loc.english_name
            if not name:
                continue
            out.append({
                "value": f"{tag}.UTF-8",
                "label": name,
                "bcp47": str(loc).replace("_", "-"),
            })
        return JSONResponse(content=out)
    except Exception as e:
        logger.error(f"Error getting locales: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/locale/countries")
async def get_countries():
    """ISO 3166-1 alpha-2 country codes with English names, alphabetized
    by name so dropdowns are scannable."""
    try:
        from babel import Locale
        en = Locale("en")
        out = [
            {"value": code, "label": name}
            for code, name in sorted(en.territories.items(), key=lambda kv: kv[1])
            if len(code) == 2 and code.isalpha()
        ]
        return JSONResponse(content=out)
    except Exception as e:
        logger.error(f"Error getting countries: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/locale/currencies")
async def get_currencies():
    """ISO 4217 currency codes. Labels are 'CODE — Name' so users can
    search by either."""
    try:
        from babel import Locale
        en = Locale("en")
        out = [
            {"value": code, "label": f"{code} — {name}"}
            for code, name in sorted(en.currencies.items())
            if len(code) == 3
        ]
        return JSONResponse(content=out)
    except Exception as e:
        logger.error(f"Error getting currencies: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/locale/languages")
async def get_languages():
    """BCP 47 base language tags with English names. These are the
    primary language subtags only (no region) — distinct from the
    locale list, which is region-qualified."""
    try:
        from babel import Locale
        en = Locale("en")
        out = [
            {"value": code, "label": name}
            for code, name in sorted(en.languages.items(), key=lambda kv: kv[1])
            if code.isalpha() and 2 <= len(code) <= 3
        ]
        return JSONResponse(content=out)
    except Exception as e:
        logger.error(f"Error getting languages: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/geocode")
async def geocode_address(q: str):
    """Forward `q` to OpenStreetMap Nominatim. We proxy server-side so
    the required User-Agent header is set (Nominatim rejects requests
    without it). Returns up to 5 hits as
    [{lat, lon, display_name}]. Caller should debounce."""
    try:
        import httpx
        q = (q or "").strip()
        if len(q) < 3:
            return JSONResponse(content=[])
        async with httpx.AsyncClient(timeout=10.0) as cx:
            r = await cx.get(
                "https://nominatim.openstreetmap.org/search",
                params={"format": "jsonv2", "q": q, "limit": 5},
                headers={
                    "User-Agent": "HomeFree-Admin/1.0 (+https://homefree.host)"
                },
            )
            r.raise_for_status()
            data = r.json()
        return JSONResponse(content=[
            {
                "lat": float(hit["lat"]),
                "lon": float(hit["lon"]),
                "display_name": hit.get("display_name", ""),
            }
            for hit in data
        ])
    except Exception as e:
        logger.error(f"Error geocoding '{q}': {e}")
        raise HTTPException(status_code=502, detail=f"Geocoding failed: {e}")

## ─── SSO state ─────────────────────────────────────────────────────────
## Reports per-service provisioning state from the on-disk sentinels
## written by zitadel-provision.service. The admin SSO page consumes
## this to show which services have completed OIDC bootstrap.
##
## Service labels come from the integrations table in
## services/zitadel-provision.nix (native OIDC apps) plus the
## Caddy-gated services that use homefree.sso.per-service.*.

SSO_SECRETS_DIR = "/var/lib/homefree-secrets"
SSO_GLOBAL_SENTINEL = f"{SSO_SECRETS_DIR}/.sso-provisioned"

# Path to the Nix-rendered service catalog. Written at activation by
# services/service-config-json.nix from the active homefree.service-
# config tree, so it's always in sync with the live system.
SERVICE_CONFIG_JSON_PATH = "/etc/homefree/service-config.json"

# SSO kind constants — these are the values service-config-json.nix
# emits under `entry.sso.kind`. Kept as Python constants here so
# downstream code that branches on kind stays readable.
SSO_KIND_NATIVE = "native_oidc"   # service has its own OIDC client
SSO_KIND_CADDY = "caddy_gated"    # Caddy oauth2-proxy gate in front
SSO_KIND_BRIDGE = "basic_auth"    # Caddy gate + Basic-Auth bridge
SSO_KIND_INFRA = "infra"          # the SSO infra itself (Zitadel,
                                  # oauth2-proxy) — hidden from the
                                  # SSO inventory
SSO_KIND_NONE = "none"            # not yet wired up


def _load_service_catalog():
    """Read the Nix-rendered service catalog from /etc/homefree.

    Returns a list of service-config entries (the same shape as the
    Nix submodule produces). Each entry has at minimum:
      - label, name, project-name
      - sso: {kind, notes, secrets-dir}
      - reverse-proxy, backup, systemd-service-names, etc.

    Falls back to an empty list if the file is missing or unreadable;
    callers should treat that as "no services configured."
    """
    import json
    try:
        with open(SERVICE_CONFIG_JSON_PATH) as f:
            return json.load(f) or []
    except Exception:
        return []

@app.get("/api/sso/state")
async def sso_state():
    """Return SSO bootstrap state for the admin SSO page.

    For each service in the catalog (rendered by the Nix module
    services/service-config-json.nix), reports:
      - sso_kind: how SSO is wired (or "none" if pending)
      - enabled: whether the service is enabled in the current config
      - provisioned: whether zitadel-provision has minted its OIDC app
        (only meaningful for native_oidc kinds)
      - has_client_id: convenience flag for native-OIDC services
    """
    import json
    import os

    provisioned = os.path.exists(SSO_GLOBAL_SENTINEL)

    # Read the live config to find which services are enabled.
    try:
        with open("/etc/nixos/homefree-config.json") as f:
            cfg = json.load(f)
        svc_cfg = cfg.get("services", {}) or {}
    except Exception:
        svc_cfg = {}

    # Catalog comes from /etc/homefree/service-config.json, written by
    # services/service-config-json.nix at activation. Single source of
    # truth — no per-service registries in this file anymore.
    catalog = _load_service_catalog()

    # Some service-config entries are internal/non-user-facing (e.g.
    # admin-api, an internal HTTP target with no login surface). They
    # set sso.kind = "none" implicitly because no .sso block is
    # declared. We surface ALL entries to the SSO admin page so
    # admins can see the full inventory and what's still pending.
    # Suppress only entries that have no reverse-proxy at all (pure
    # internal sidecars never reach the SSO page).

    services = []
    for entry in catalog:
        sso = entry.get("sso") or {}
        kind = sso.get("kind", SSO_KIND_NONE)

        # SSO infrastructure (Zitadel, oauth2-proxy) is not a consumer
        # of SSO — hide it from the inventory page.
        if kind == SSO_KIND_INFRA:
            continue

        rp = entry.get("reverse-proxy") or {}
        if not rp.get("enable", False) and not rp.get("subdomains"):
            # Sidecar with no user-visible URL — skip entirely.
            continue

        label = entry.get("label", "")
        # secrets-dir override; defaults to the label when absent.
        secrets_dir_name = sso.get("secrets-dir") or label
        secrets_dir = f"{SSO_SECRETS_DIR}/{secrets_dir_name}"

        # Provisioning state semantics differ by kind:
        #   - native_oidc: needs a per-service Zitadel OIDC app +
        #     .provisioned sentinel. "Provisioned" iff sentinel exists.
        #   - caddy_gated / basic_auth: no per-service Zitadel app to
        #     mint — they piggyback on the GLOBAL sentinel (oauth2-
        #     proxy is provisioned). Report `provisioned` as the
        #     global value so the UI shows green once SSO is up.
        #   - none: not implemented; always False.
        if kind == SSO_KIND_NATIVE:
            is_provisioned = os.path.exists(f"{secrets_dir}/.provisioned")
        elif kind in (SSO_KIND_CADDY, SSO_KIND_BRIDGE):
            is_provisioned = provisioned
        else:
            is_provisioned = False

        services.append({
            "label": label,
            # `name` from service-config is the human-readable display
            # name (e.g. "Password Manager"); fall back to label.
            "display": entry.get("name") or label,
            "sso_kind": kind,
            "notes": sso.get("notes", ""),
            "enabled": bool((svc_cfg.get(label) or {}).get("enable", False)),
            # Back-compat fields the existing frontend reads. Will be
            # phased out once the UI migrates to sso_kind exclusively.
            "native_oidc": kind == SSO_KIND_NATIVE,
            "caddy_gated": kind in (SSO_KIND_CADDY, SSO_KIND_BRIDGE),
            "provisioned": is_provisioned,
            "has_client_id": os.path.exists(f"{secrets_dir}/oidc-client-id"),
        })

    return JSONResponse(content={
        "provisioned": provisioned,
        "services": services,
    })

@app.get("/api/auth/admin-check")
async def auth_admin_check(request: Request):
    """Caddy forward_auth target for admin-only services.

    Caddy is the SSO gate in front of services that have no native
    OIDC support (AdGuard, WebDAV). oauth2-proxy already validated
    the session and set X-Auth-Request-* headers — but oauth2-proxy
    can't enforce role-based access for us, because Zitadel's
    namespaced project-roles claim comes through as a JSON-stringified
    object that oauth2-proxy's group parser doesn't extract keys
    from.

    So Caddy chains a SECOND forward_auth call here. Our middleware
    already does the role check (see TrustedHeaderAuthMiddleware
    above): if the user has the homefree-admin role we get here and
    return 200; if not, the middleware short-circuits with 403
    before we run.

    The body is intentionally minimal — Caddy's forward_auth only
    cares about the status code.
    """
    return JSONResponse(content={"ok": True})

@app.get("/api/sso/oauth2-client-id")
async def sso_oauth2_client_id():
    """Return the OIDC client_id of the oauth2-proxy app.

    Not a secret — it's already visible in every authenticated user's
    browser during the SSO flow (it's the `client_id` query param on
    /authorize). We expose it through a small endpoint so the frontend
    can build a fully-formed RP-Initiated Logout URL: Zitadel's
    end_session endpoint requires either an `id_token_hint` (which
    oauth2-proxy clears before it forwards the user) or a `client_id`
    matching a registered post_logout_redirect_uri. Without one,
    Zitadel ignores `post_logout_redirect_uri` and parks the user on
    its own "Logout successful" page with no way back.
    """
    path = f"{SSO_SECRETS_DIR}/zitadel/oidc-client-id"
    try:
        with open(path) as f:
            cid = f.read().strip()
        return {"client_id": cid}
    except FileNotFoundError:
        raise HTTPException(
            status_code=503,
            detail=("oauth2-proxy OIDC client_id not on disk. Has "
                    "zitadel-provision run? Expected: " + path),
        )

## ─── Zitadel user management ───────────────────────────────────────────
## All routes here are admin-only — they're already gated by the
## oauth2-proxy header check at the FastAPI middleware level, so we
## don't need to re-auth at the route. The backend talks to Zitadel
## with the bootstrap machine-user PAT minted at first boot
## (FirstInstance config in services/zitadel-podman.nix). That PAT has
## the IAM-OWNER role so it can manage users instance-wide.

ZITADEL_PAT_PATH = "/var/lib/zitadel/pat-bootstrap"

def _zitadel_base_url():
    """Read the host's domain from homefree-config.json so we don't
    have to hardcode it. The Zitadel container is reachable at
    https://sso.<domain>/ via the Caddy reverse proxy."""
    import json
    try:
        with open("/etc/nixos/homefree-config.json") as f:
            cfg = json.load(f)
        return f"https://sso.{cfg['system']['domain']}"
    except Exception:
        return "https://sso.homefree.host"

def _zitadel_headers():
    try:
        with open(ZITADEL_PAT_PATH) as f:
            pat = f.read().strip()
    except FileNotFoundError:
        raise HTTPException(
            status_code=503,
            detail=("Zitadel bootstrap PAT not found. Has zitadel-provision "
                    "run? Path: " + ZITADEL_PAT_PATH),
        )
    return {
        "Authorization": f"Bearer {pat}",
        "Content-Type": "application/json",
    }

# Zitadel role used to flag the HomeFree admin. We use a project role
# rather than the org-OWNER role so that "admin" in the HomeFree UI
# means "can manage HomeFree" without granting the user the ability to
# delete the Zitadel instance itself.
HOMEFREE_ADMIN_ROLE = "homefree-admin"

@app.get("/api/users")
async def list_users():
    """List human users in the default org. Excludes machine users
    (the provisioner, the PAM bridge) by filtering to TYPE_HUMAN.
    Includes is_admin per-user, computed from a single grant-search
    call so the page renders without N+1 round-trips."""
    import httpx
    base = _zitadel_base_url()
    async with httpx.AsyncClient(timeout=15.0, verify=False) as cx:
        # Users.
        r = await cx.post(
            f"{base}/management/v1/users/_search",
            headers=_zitadel_headers(),
            json={
                "queries": [
                    {"typeQuery": {"type": "TYPE_HUMAN"}},
                ],
            },
        )
        if r.status_code >= 400:
            raise HTTPException(status_code=r.status_code,
                                detail=f"Zitadel returned: {r.text}")
        users_data = r.json()

        # Admins = users with the homefree-admin role on the homefree
        # project. One grant-search call, intersect by user_id.
        admin_ids = set()
        try:
            project_id = await _get_homefree_project_id(cx, base)
            r = await cx.post(
                f"{base}/management/v1/users/grants/_search",
                headers=_zitadel_headers(),
                json={"queries": [{"projectIdQuery": {"projectId": project_id}}]},
            )
            if r.status_code < 400:
                for g in (r.json().get("result") or []):
                    if HOMEFREE_ADMIN_ROLE in (g.get("roleKeys") or []):
                        admin_ids.add(g.get("userId"))
        except HTTPException:
            # Project not provisioned yet — every user defaults to
            # non-admin until the project + role exist.
            pass

    users = []
    for u in users_data.get("result", []) or []:
        human = u.get("human") or {}
        profile = human.get("profile") or {}
        email = human.get("email") or {}
        uid = u.get("id")
        users.append({
            "id": uid,
            "username": u.get("userName"),
            "first_name": profile.get("firstName") or "",
            "last_name": profile.get("lastName") or "",
            "display_name": profile.get("displayName") or u.get("userName"),
            "email": email.get("email") or "",
            "email_verified": email.get("isVerified", False),
            "state": u.get("state"),
            "is_admin": uid in admin_ids,
        })
    return JSONResponse(content={"users": users})

class CreateUserRequest(BaseModel):
    username: str
    first_name: str = ""
    last_name: str = ""
    email: str
    password: str
    is_admin: bool = False

class SetAdminRequest(BaseModel):
    is_admin: bool

class UpdateUserRequest(BaseModel):
    """Profile updates — first/last/display name + email. Password
    changes go through a separate endpoint so we can require the
    current password when editing self."""
    first_name: Optional[str] = None
    last_name: Optional[str] = None
    email: Optional[str] = None

class SetPasswordRequest(BaseModel):
    """Admin-set password for *another* user. No current password
    required because admins don't know other users' passwords."""
    new_password: str

class ChangeOwnPasswordRequest(BaseModel):
    """Self password change. Requires current password as the
    proof-of-possession step the user asked for."""
    current_password: str
    new_password: str

def _homefree_admin_username():
    """The OS admin user (set during install). This user can't be
    deleted from the UI."""
    import json
    try:
        with open("/etc/nixos/homefree-config.json") as f:
            cfg = json.load(f)
        return cfg["system"]["adminUsername"]
    except Exception:
        return None


def _authed_username(request: Request) -> str:
    """Read the authenticated user's preferred_username from headers.
    The middleware has already validated the header exists post-
    provisioning; this helper centralises the lookup so /me handlers
    can't accidentally trust a body-provided username."""
    return (
        request.headers.get("x-auth-request-preferred-username")
        or request.headers.get("x-auth-request-user")
        or ""
    )


async def _resolve_user_id_by_name(cx, base: str, username: str) -> str:
    """Resolve a Zitadel user-id from a username, using the admin PAT.
    Used by self-service endpoints to map the authenticated header
    user → their Zitadel record without trusting a body-supplied id.

    Raises HTTPException on lookup failure or not-found."""
    r = await cx.post(
        f"{base}/management/v1/users/_search",
        headers=_zitadel_headers(),
        json={
            "queries": [{
                "userNameQuery": {
                    "userName": username,
                    "method": "TEXT_QUERY_METHOD_EQUALS",
                },
            }],
        },
    )
    if r.status_code >= 400:
        raise HTTPException(status_code=r.status_code,
                            detail=f"Zitadel user lookup: {r.text}")
    users = r.json().get("result") or []
    if not users:
        raise HTTPException(
            status_code=404,
            detail=f"User '{username}' not found in Zitadel",
        )
    return users[0]["id"]


@app.get("/api/users/me")
async def get_current_user(request: Request):
    """Return the currently-authenticated user's record. Auth comes
    from the oauth2-proxy header that gated this request.

    Includes the Zitadel profile fields (first/last/display name,
    email) so the user dashboard can prefill its edit form without a
    second round-trip. is_admin_role reflects the homefree-admin
    Zitadel project role (used by the dashboard to show or hide the
    "open admin" link)."""
    username = _authed_username(request)
    admin_username = _homefree_admin_username()
    groups = getattr(request.state, "auth_groups", set()) or set()
    is_admin_role = TrustedHeaderAuthMiddleware.ADMIN_ROLE in groups

    # Best-effort profile lookup. Failures are non-fatal — the rest
    # of the response is still useful (the dashboard just falls back
    # to "Unknown" labels). The Zitadel call uses the bootstrap PAT,
    # same as elsewhere in this module.
    profile = {}
    if username:
        import httpx
        base = _zitadel_base_url()
        try:
            async with httpx.AsyncClient(timeout=10.0, verify=False) as cx:
                user_id = await _resolve_user_id_by_name(cx, base, username)
                r = await cx.get(
                    f"{base}/management/v1/users/{user_id}",
                    headers=_zitadel_headers(),
                )
                if r.status_code < 400:
                    human = (r.json().get("user") or {}).get("human", {}) or {}
                    p = human.get("profile", {}) or {}
                    e = human.get("email", {}) or {}
                    profile = {
                        "user_id": user_id,
                        "first_name": p.get("firstName", ""),
                        "last_name": p.get("lastName", ""),
                        "display_name": p.get("displayName", ""),
                        "email": e.get("email", ""),
                    }
        except HTTPException:
            # _resolve_user_id_by_name 404 — user is in Zitadel only
            # if oauth2-proxy could authenticate them, so a 404 here
            # is unexpected. Log and return the bare envelope.
            logger.warning("Authenticated user '%s' not found in Zitadel",
                           username)
        except Exception as e:
            logger.warning("users/me profile lookup failed: %s", e)

    return JSONResponse(content={
        "username": username,
        "is_admin_user": bool(admin_username and username == admin_username),
        "admin_username": admin_username,
        "is_admin_role": is_admin_role,
        **profile,
    })

@app.post("/api/users")
async def create_user(req: CreateUserRequest):
    """Create a new human user. If is_admin is true, also adds them
    to the homefree-admin role on the homefree project (created
    on-demand if missing)."""
    import httpx
    base = _zitadel_base_url()
    err = None
    async with httpx.AsyncClient(timeout=15.0, verify=False) as cx:
        # Create human user. Zitadel requires firstName + lastName non-
        # empty for human users; default to the username if blank.
        body = {
            "userName": req.username,
            "profile": {
                "firstName": req.first_name or req.username,
                "lastName": req.last_name or req.username,
                "displayName": (
                    f"{req.first_name} {req.last_name}".strip()
                    or req.username
                ),
                "preferredLanguage": "en",
            },
            "email": {
                "email": req.email,
                "isEmailVerified": True,
            },
            "password": req.password,
            "passwordChangeRequired": False,
        }
        r = await cx.post(
            f"{base}/management/v1/users/human/_import",
            headers=_zitadel_headers(),
            json=body,
        )
        if r.status_code >= 400:
            raise HTTPException(status_code=r.status_code,
                                detail=f"Zitadel: {r.text}")
        created = r.json()
        user_id = created.get("userId")

        # Optionally grant admin. We'll handle that via a separate
        # endpoint to keep this one focused; for now just return the
        # new user id.
        if req.is_admin and user_id:
            # Defer to the set-admin handler logic inline.
            try:
                await _set_admin_role(cx, base, user_id, True)
            except HTTPException as e:
                err = f"User created but admin grant failed: {e.detail}"

    payload = {"id": user_id, "username": req.username}
    if err:
        payload["warning"] = err
    return JSONResponse(content=payload)

@app.delete("/api/users/{user_id}")
async def delete_user(user_id: str):
    """Delete a user. Refuses to delete the OS admin (homefree.system.
    adminUsername) — that user is special: the PAM bridge syncs OS
    password changes to their Zitadel record, and there's no other
    way to recreate them without re-running the installer."""
    import httpx
    base = _zitadel_base_url()
    admin_username = _homefree_admin_username()
    async with httpx.AsyncClient(timeout=15.0, verify=False) as cx:
        # Resolve username for the target to compare against the
        # admin-protected name. Zitadel ids are opaque; we need the
        # name to enforce the rule.
        if admin_username:
            r = await cx.get(
                f"{base}/management/v1/users/{user_id}",
                headers=_zitadel_headers(),
            )
            if r.status_code < 400:
                target_username = (r.json().get("user") or {}).get("userName")
                if target_username == admin_username:
                    raise HTTPException(
                        status_code=400,
                        detail=("Cannot delete the HomeFree admin user "
                                f"'{admin_username}'. Change the admin "
                                "in the installer config or via the "
                                "command line if you really need to."),
                    )

        r = await cx.delete(
            f"{base}/management/v1/users/{user_id}",
            headers=_zitadel_headers(),
        )
        if r.status_code >= 400:
            raise HTTPException(status_code=r.status_code,
                                detail=f"Zitadel: {r.text}")
    return JSONResponse(content={"success": True})

@app.patch("/api/users/{user_id}")
async def update_user(user_id: str, req: UpdateUserRequest):
    """Update a user's profile (first/last/display name, email).
    All fields are optional; only the ones that are not-None get
    written. Email change re-marks the email verified to keep the
    SSO login flow working without re-verification."""
    import httpx
    base = _zitadel_base_url()
    async with httpx.AsyncClient(timeout=15.0, verify=False) as cx:
        if (req.first_name is not None or req.last_name is not None):
            # Need to fetch existing names so we don't blank them when
            # the caller only sends one field. Zitadel's PUT replaces
            # the whole profile.
            r = await cx.get(
                f"{base}/management/v1/users/{user_id}",
                headers=_zitadel_headers(),
            )
            if r.status_code >= 400:
                raise HTTPException(status_code=r.status_code,
                                    detail=f"Zitadel: {r.text}")
            existing = (r.json().get("user") or {}).get("human", {}).get("profile", {})
            first = req.first_name if req.first_name is not None else existing.get("firstName", "")
            last = req.last_name if req.last_name is not None else existing.get("lastName", "")
            r = await cx.put(
                f"{base}/management/v1/users/{user_id}/profile",
                headers=_zitadel_headers(),
                json={
                    "firstName": first or "",
                    "lastName": last or "",
                    "displayName": f"{first} {last}".strip() or "",
                    "preferredLanguage": existing.get("preferredLanguage") or "en",
                },
            )
            if r.status_code >= 400:
                raise HTTPException(status_code=r.status_code,
                                    detail=f"Zitadel profile: {r.text}")

        if req.email is not None:
            r = await cx.put(
                f"{base}/management/v1/users/{user_id}/email",
                headers=_zitadel_headers(),
                json={"email": req.email, "isEmailVerified": True},
            )
            if r.status_code >= 400:
                raise HTTPException(status_code=r.status_code,
                                    detail=f"Zitadel email: {r.text}")

    return JSONResponse(content={"success": True})

## NOTE: The /api/users/me/* routes MUST come before the parametric
## /api/users/{user_id}/* routes. FastAPI matches in registration
## order and "me" would otherwise be captured as a user_id, sending
## the call to the admin-set handler with user_id="me" which fails
## as "Password not found" inside Zitadel.

@app.post("/api/users/me/profile")
async def update_own_profile(request: Request, req: UpdateUserRequest):
    """Self-service profile update — first/last/display name and email.
    Used by the per-user dashboard at home.<domain>.

    Identity resolution: the target user-id is derived from the
    oauth2-proxy preferred_username header server-side via
    _resolve_user_id_by_name(). The request body's userId is
    deliberately ignored even if the caller sends one.

    Email updates re-mark the address verified to keep the SSO login
    flow working without re-verification, mirroring the admin
    update_user() path. We pass through the same Zitadel calls — the
    only difference is the user-id source."""
    username = _authed_username(request)
    if not username:
        raise HTTPException(status_code=401, detail="No authenticated user")

    import httpx
    base = _zitadel_base_url()
    async with httpx.AsyncClient(timeout=15.0, verify=False) as cx:
        user_id = await _resolve_user_id_by_name(cx, base, username)

        if (req.first_name is not None or req.last_name is not None):
            # Fetch existing names so single-field updates don't blank
            # the other field — Zitadel's profile PUT replaces the
            # whole record.
            r = await cx.get(
                f"{base}/management/v1/users/{user_id}",
                headers=_zitadel_headers(),
            )
            if r.status_code >= 400:
                raise HTTPException(status_code=r.status_code,
                                    detail=f"Zitadel: {r.text}")
            existing = (r.json().get("user") or {}) \
                .get("human", {}).get("profile", {})
            first = req.first_name if req.first_name is not None \
                else existing.get("firstName", "")
            last = req.last_name if req.last_name is not None \
                else existing.get("lastName", "")
            r = await cx.put(
                f"{base}/management/v1/users/{user_id}/profile",
                headers=_zitadel_headers(),
                json={
                    "firstName": first or "",
                    "lastName": last or "",
                    "displayName": f"{first} {last}".strip() or "",
                    "preferredLanguage":
                        existing.get("preferredLanguage") or "en",
                },
            )
            if r.status_code >= 400:
                raise HTTPException(status_code=r.status_code,
                                    detail=f"Zitadel profile: {r.text}")

        if req.email is not None:
            r = await cx.put(
                f"{base}/management/v1/users/{user_id}/email",
                headers=_zitadel_headers(),
                json={"email": req.email, "isEmailVerified": True},
            )
            if r.status_code >= 400:
                raise HTTPException(status_code=r.status_code,
                                    detail=f"Zitadel email: {r.text}")

    return JSONResponse(content={"success": True})


@app.post("/api/users/me/password")
async def change_own_password(request: Request, req: ChangeOwnPasswordRequest):
    """Self-service password change.

    The management API's POST /users/{id}/password is admin-set: it
    overwrites the password unconditionally and doesn't actually
    verify a `currentPassword` field (passing one yields
    `Password not found COMMAND-G8dh3`). The auth API's self-service
    endpoint would verify, but requires the user's own session
    token — we only have the admin PAT.

    So we do verification via the sessions API: POST /v2/sessions
    with a `password` check returns success iff the password is
    correct. We create a transient session for that check, delete
    it immediately, then admin-set the new password through the
    management API.

    The new password is policy-checked the same as everywhere else.
    """
    from resolvers.config import validate_password
    err = validate_password(req.new_password)
    if err:
        raise HTTPException(status_code=400, detail=err)

    username = (
        request.headers.get("x-auth-request-preferred-username")
        or request.headers.get("x-auth-request-user")
        or ""
    )
    if not username:
        raise HTTPException(status_code=401, detail="No authenticated user")

    import httpx
    base = _zitadel_base_url()
    async with httpx.AsyncClient(timeout=15.0, verify=False) as cx:
        # 1. Resolve the user record by username (we need the id for
        #    the management password-set call below).
        r = await cx.post(
            f"{base}/management/v1/users/_search",
            headers=_zitadel_headers(),
            json={
                "queries": [{
                    "userNameQuery": {
                        "userName": username,
                        "method": "TEXT_QUERY_METHOD_EQUALS",
                    },
                }],
            },
        )
        if r.status_code >= 400:
            raise HTTPException(status_code=r.status_code,
                                detail=f"Zitadel user lookup: {r.text}")
        users = r.json().get("result") or []
        if not users:
            raise HTTPException(
                status_code=404,
                detail=f"User '{username}' not found in Zitadel",
            )
        user_id = users[0]["id"]

        # 2. Verify the current password via a transient session.
        #    The /v2/sessions endpoint runs the `password` check and
        #    returns 400 with "Password is invalid" if it's wrong.
        r = await cx.post(
            f"{base}/v2/sessions",
            headers=_zitadel_headers(),
            json={
                "checks": {
                    "user": {"loginName": username},
                    "password": {"password": req.current_password},
                },
            },
        )
        if r.status_code >= 400:
            # Zitadel returns CredentialsCheckError on bad password.
            # Surface a clean message rather than the raw payload.
            raise HTTPException(
                status_code=400,
                detail="Current password is incorrect.",
            )
        # Clean up the session so we don't leave verification artifacts
        # accumulating. Failures here are non-fatal — the new password
        # set has already succeeded by the time the user notices.
        session_id = (r.json() or {}).get("sessionId")
        session_token = (r.json() or {}).get("sessionToken")

        # 3. Admin-set the new password in Zitadel.
        #    noChangeRequired=true is REQUIRED — Zitadel's default
        #    for this endpoint flips passwordChangeRequired to true,
        #    which makes the user see a "change your password" prompt
        #    on their next sign-in. We just verified the current
        #    password and the user explicitly entered a new one, so
        #    that's strictly worse UX.
        r = await cx.post(
            f"{base}/management/v1/users/{user_id}/password",
            headers=_zitadel_headers(),
            json={
                "password": req.new_password,
                "noChangeRequired": True,
            },
        )
        if r.status_code >= 400:
            raise HTTPException(
                status_code=400,
                detail=f"Password change failed: {r.text}",
            )

        # 4. Best-effort session cleanup. The session delete requires
        #    the session's own token in the Authorization header
        #    (NOT the admin PAT — sessions delete themselves with
        #    their bearer token).
        if session_id and session_token:
            try:
                await cx.delete(
                    f"{base}/v2/sessions/{session_id}",
                    headers={
                        "Authorization": f"Bearer {session_token}",
                        "Content-Type": "application/json",
                    },
                )
            except Exception:
                pass

    # 5. Mirror to the local Linux account when the user is the OS
    #    admin (homefree.system.adminUsername). The PAM bridge in
    #    services/zitadel-pam-bridge.nix syncs OS→Zitadel via
    #    pam_exec; this is the reverse path Zitadel→OS so the shell
    #    password stays in sync with what the admin UI just set.
    #
    #    chpasswd writes /etc/shadow directly (not via PAM), so it
    #    won't loop back through the bridge.
    #
    #    Non-admin users have no OS account, so we skip them.
    admin_username = _homefree_admin_username()
    if admin_username and username == admin_username:
        try:
            _os_sync_password(username, req.new_password)
        except Exception as e:
            # Don't fail the request — Zitadel is updated; surface a
            # warning so the user knows to fix the OS side manually.
            logger.error(f"Failed to mirror password to OS account: {e}")
            return JSONResponse(content={
                "success": True,
                "warning": ("Password updated in Zitadel but OS sync "
                            "failed. SSH access may use the old password "
                            f"until you fix this manually: {e}"),
            })

    return JSONResponse(content={"success": True})


def _os_sync_password(username: str, new_password: str):
    """Update the Linux account password to match Zitadel. The admin-
    api runs as root (see services/admin-web.nix), so we can run
    chpasswd directly. We pass the password on stdin so the cleartext
    never appears in /proc/<pid>/cmdline."""
    import subprocess
    proc = subprocess.run(
        ["chpasswd"],
        input=f"{username}:{new_password}",
        text=True,
        capture_output=True,
        timeout=15,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"chpasswd exited {proc.returncode}: {proc.stderr.strip()}"
        )

@app.post("/api/users/{user_id}/password")
async def set_password(user_id: str, req: SetPasswordRequest):
    """Admin-set a target user's password. Used when an admin resets
    someone else's password from the Users page. The new password is
    validated against the same policy used elsewhere.

    user_id="me" is rejected here as a defensive check: route-order
    is supposed to prevent that (change_own_password is registered
    first), but if the order ever flips by accident, the explicit
    reject keeps the call from going to Zitadel with a literal "me"
    user id that yields the cryptic "Password not found" error."""
    if user_id == "me":
        raise HTTPException(
            status_code=400,
            detail="Use POST /api/users/me/password for self-service password change",
        )
    from resolvers.config import validate_password
    err = validate_password(req.new_password)
    if err:
        raise HTTPException(status_code=400, detail=err)
    import httpx
    base = _zitadel_base_url()
    target_username = None
    async with httpx.AsyncClient(timeout=15.0, verify=False) as cx:
        # Look up the target's username so we know whether to mirror
        # the change to the OS account afterward.
        r = await cx.get(
            f"{base}/management/v1/users/{user_id}",
            headers=_zitadel_headers(),
        )
        if r.status_code < 400:
            target_username = (r.json().get("user") or {}).get("userName")

        r = await cx.post(
            f"{base}/management/v1/users/{user_id}/password",
            headers=_zitadel_headers(),
            json={
                "password": req.new_password,
                # Admin-set passwords are usually for resets. Default
                # to NOT requiring a forced change on next login —
                # if the admin wants that they can re-set with the
                # flag explicitly via the Zitadel UI.
                "noChangeRequired": True,
            },
        )
        if r.status_code >= 400:
            raise HTTPException(status_code=r.status_code,
                                detail=f"Zitadel: {r.text}")

    # Mirror to OS if we just changed the homefree admin's password,
    # so SSH access stays in sync.
    admin_username = _homefree_admin_username()
    if (target_username and admin_username
            and target_username == admin_username):
        try:
            _os_sync_password(target_username, req.new_password)
        except Exception as e:
            logger.error(f"Failed to mirror password to OS account: {e}")
            return JSONResponse(content={
                "success": True,
                "warning": ("Password updated in Zitadel but OS sync "
                            "failed. SSH access may use the old password "
                            f"until you fix this manually: {e}"),
            })
    return JSONResponse(content={"success": True})

## (Request models and the @app.get("/api/users/me") endpoint that
## previously lived here were moved up to immediately follow
## CreateUserRequest so they're defined before the @app.* decorators
## that reference them at import time. Python's FastAPI decorator
## evaluation happens at module load, so a forward reference in a
## type annotation here would NameError on startup.)

async def _get_homefree_project_id(cx, base):
    """Look up the 'homefree' project's ID. The project is created
    by zitadel-provision.service on first boot; this fails fast if
    it isn't there yet (the admin UI shouldn't be reachable in that
    state anyway because the global sentinel won't exist)."""
    r = await cx.post(
        f"{base}/management/v1/projects/_search",
        headers=_zitadel_headers(),
        json={"queries": [{"nameQuery": {
            "name": "homefree",
            "method": "TEXT_QUERY_METHOD_EQUALS",
        }}]},
    )
    if r.status_code >= 400:
        raise HTTPException(status_code=r.status_code,
                            detail=f"Zitadel project lookup: {r.text}")
    result = r.json().get("result") or []
    if not result:
        raise HTTPException(
            status_code=503,
            detail=("'homefree' project not found in Zitadel. Has "
                    "zitadel-provision.service run yet?"),
        )
    return result[0]["id"]

async def _set_admin_role(cx, base, user_id, is_admin):
    """Grant or revoke the homefree-admin PROJECT role for the user.

    We use a project-scoped role rather than IAM_OWNER (Zitadel
    instance-wide) so that:
      - the role flows into OIDC tokens for downstream services
        (Zitadel asserts project roles in the id_token; instance
        memberships are NOT asserted in the OIDC payload).
      - admins of the HomeFree stack are *not* implicitly admins
        of Zitadel itself (an admin can manage HomeFree services
        without being able to break the SSO server).
    """
    project_id = await _get_homefree_project_id(cx, base)

    # Look up the user's existing grant on this project.
    r = await cx.post(
        f"{base}/management/v1/users/grants/_search",
        headers=_zitadel_headers(),
        json={"queries": [
            {"userIdQuery": {"userId": user_id}},
            {"projectIdQuery": {"projectId": project_id}},
        ]},
    )
    if r.status_code >= 400:
        raise HTTPException(status_code=r.status_code,
                            detail=f"Zitadel grant lookup: {r.text}")
    grants = r.json().get("result") or []
    existing_grant = grants[0] if grants else None
    has_role = bool(
        existing_grant
        and HOMEFREE_ADMIN_ROLE in (existing_grant.get("roleKeys") or [])
    )

    if is_admin and not has_role:
        if existing_grant:
            # Add the role to the existing grant (preserving any
            # other roles already on it).
            new_roles = sorted(
                set(existing_grant.get("roleKeys") or [])
                | {HOMEFREE_ADMIN_ROLE}
            )
            r = await cx.put(
                f"{base}/management/v1/users/{user_id}/grants/{existing_grant['id']}",
                headers=_zitadel_headers(),
                json={"roleKeys": new_roles},
            )
        else:
            r = await cx.post(
                f"{base}/management/v1/users/{user_id}/grants",
                headers=_zitadel_headers(),
                json={"projectId": project_id,
                      "roleKeys": [HOMEFREE_ADMIN_ROLE]},
            )
        if r.status_code >= 400:
            raise HTTPException(status_code=r.status_code,
                                detail=f"Zitadel grant set: {r.text}")
    elif not is_admin and has_role:
        remaining_roles = sorted(
            set(existing_grant.get("roleKeys") or [])
            - {HOMEFREE_ADMIN_ROLE}
        )
        if remaining_roles:
            # Keep the grant alive but remove just our role.
            r = await cx.put(
                f"{base}/management/v1/users/{user_id}/grants/{existing_grant['id']}",
                headers=_zitadel_headers(),
                json={"roleKeys": remaining_roles},
            )
        else:
            # No other roles → delete the grant entirely.
            r = await cx.delete(
                f"{base}/management/v1/users/{user_id}/grants/{existing_grant['id']}",
                headers=_zitadel_headers(),
            )
        if r.status_code >= 400:
            raise HTTPException(status_code=r.status_code,
                                detail=f"Zitadel grant unset: {r.text}")

@app.post("/api/users/{user_id}/admin")
async def set_user_admin(user_id: str, req: SetAdminRequest):
    """Grant or revoke admin (IAM_OWNER) for the user."""
    import httpx
    base = _zitadel_base_url()
    async with httpx.AsyncClient(timeout=15.0, verify=False) as cx:
        await _set_admin_role(cx, base, user_id, req.is_admin)
    return JSONResponse(content={"success": True})

@app.get("/api/users/{user_id}/admin")
async def get_user_admin(user_id: str):
    """Check whether the user has the homefree-admin project role."""
    import httpx
    base = _zitadel_base_url()
    async with httpx.AsyncClient(timeout=15.0, verify=False) as cx:
        project_id = await _get_homefree_project_id(cx, base)
        r = await cx.post(
            f"{base}/management/v1/users/grants/_search",
            headers=_zitadel_headers(),
            json={"queries": [
                {"userIdQuery": {"userId": user_id}},
                {"projectIdQuery": {"projectId": project_id}},
            ]},
        )
        if r.status_code >= 400:
            raise HTTPException(status_code=r.status_code,
                                detail=f"Zitadel: {r.text}")
        grants = r.json().get("result") or []
    is_admin = any(
        HOMEFREE_ADMIN_ROLE in (g.get("roleKeys") or []) for g in grants
    )
    return JSONResponse(content={"is_admin": is_admin})

## Password complexity policy lives in Zitadel and the admin can edit
## it from the Zitadel UI. We surface it to the frontend so the same
## rules apply on both ends (no client/server drift) and the UI can
## tell the user exactly what's required.
_PASSWORD_POLICY_CACHE = {"policy": None, "expires_at": 0.0}

@app.get("/api/sso/password-policy")
async def sso_password_policy():
    """Return Zitadel's current password complexity policy.

    Cached per-process for 60 seconds: the policy changes rarely
    (only when the admin edits it in Zitadel) but we don't want a
    stale value to hang around indefinitely. On Zitadel unreachable,
    return our hard-coded defaults so the UI degrades gracefully
    rather than blocking the user."""
    import os, time, httpx
    now = time.time()
    if _PASSWORD_POLICY_CACHE["policy"] and now < _PASSWORD_POLICY_CACHE["expires_at"]:
        return JSONResponse(content=_PASSWORD_POLICY_CACHE["policy"])

    fallback = {
        "min_length": 8,
        "max_length": 128,
        "has_uppercase": True,
        "has_lowercase": True,
        "has_number": True,
        "has_symbol": True,
        "source": "fallback",
    }
    if not os.path.exists(ZITADEL_PAT_PATH):
        return JSONResponse(content=fallback)

    base = _zitadel_base_url()
    try:
        async with httpx.AsyncClient(timeout=5.0, verify=False) as cx:
            r = await cx.get(
                f"{base}/management/v1/policies/password/complexity",
                headers=_zitadel_headers(),
            )
            r.raise_for_status()
            p = (r.json().get("policy") or {})
        policy = {
            "min_length": int(p.get("minLength", 8)),
            # Linux-side cap (mkpasswd/chpasswd can't handle >128).
            "max_length": 128,
            "has_uppercase": bool(p.get("hasUppercase", True)),
            "has_lowercase": bool(p.get("hasLowercase", True)),
            "has_number": bool(p.get("hasNumber", True)),
            "has_symbol": bool(p.get("hasSymbol", True)),
            "source": "zitadel",
        }
        _PASSWORD_POLICY_CACHE["policy"] = policy
        _PASSWORD_POLICY_CACHE["expires_at"] = now + 60
        return JSONResponse(content=policy)
    except Exception as e:
        logger.warning(f"Could not fetch Zitadel password policy: {e}")
        return JSONResponse(content=fallback)

@app.post("/api/sso/reprovision")
async def sso_reprovision():
    """Re-run zitadel-provision.service. Used when a service failed
    to provision on first boot — the unit is idempotent so re-running
    is safe."""
    import subprocess
    try:
        # Use systemctl restart rather than start: restart triggers
        # an ExecStart even if the unit is in active(exited) state
        # (which a successful oneshot leaves it in).
        r = subprocess.run(
            ["pkexec", "/etc/homefree-installer/pkexec-wrapper.sh",
             "systemctl", "restart", "zitadel-provision.service"],
            capture_output=True, text=True, timeout=60,
        )
        if r.returncode != 0:
            return JSONResponse(
                status_code=500,
                content={"success": False, "stderr": r.stderr or r.stdout},
            )
        return JSONResponse(content={"success": True})
    except Exception as e:
        return JSONResponse(
            status_code=500,
            content={"success": False, "error": str(e)},
        )

# Configuration Endpoints

@app.post("/api/config/hostname")
async def set_hostname(request: HostnameRequest):
    """Set system hostname"""
    try:
        result = ConfigResolver.set_hostname(request.hostname)
        return JSONResponse(content=to_dict(result))
    except Exception as e:
        logger.error(f"Error setting hostname: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/config/location")
async def set_location(request: LocationRequest):
    """Set timezone, locale, and the optional localization extras
    (country, language, currency, unit system, elevation, GPS)."""
    try:
        from services.config import ConfigService
        result = ConfigResolver.set_location(request.timezone, request.locale)
        ConfigService.set_localization(
            country_code=request.country_code,
            language=request.language,
            currency=request.currency,
            unit_system=request.unit_system,
            elevation=request.elevation,
            latitude=request.latitude,
            longitude=request.longitude,
        )
        return JSONResponse(content=to_dict(result))
    except Exception as e:
        logger.error(f"Error setting location: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/config/keyboard")
async def set_keyboard(request: KeyboardRequest):
    """Set keyboard layout"""
    try:
        result = ConfigResolver.set_keyboard(request.layout, request.vconsole)
        return JSONResponse(content=to_dict(result))
    except Exception as e:
        logger.error(f"Error setting keyboard: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/config/user")
async def set_user(request: UserRequest):
    """Set user account information"""
    try:
        result = ConfigResolver.set_user(request.username, request.fullname, request.email, request.password)
        return JSONResponse(content=to_dict(result))
    except Exception as e:
        logger.error(f"Error setting user: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/config/partitioning")
async def set_partitioning(request: PartitioningRequest):
    """Set partitioning configuration"""
    try:
        result = ConfigResolver.set_partitioning(request.config)
        return JSONResponse(content=to_dict(result))
    except Exception as e:
        logger.error(f"Error setting partitioning: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/config/summary")
async def get_install_summary():
    """Get installation configuration summary"""
    try:
        summary = ConfigResolver.get_install_summary()
        return JSONResponse(content=to_dict(summary))
    except Exception as e:
        logger.error(f"Error getting install summary: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/config/development-mode")
async def set_development_mode(request: DevelopmentModeRequest):
    """Enable or disable development mode"""
    try:
        result = ConfigResolver.set_development_mode(request.enabled)
        return JSONResponse(content=to_dict(result))
    except Exception as e:
        logger.error(f"Error setting development mode: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/config/development-mode")
async def get_development_mode():
    """Check if development mode is enabled"""
    try:
        from services.config import ConfigService
        is_dev_mode = ConfigService.is_development_mode()
        return JSONResponse(content={"enabled": is_dev_mode})
    except Exception as e:
        logger.error(f"Error getting development mode: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/config/domain")
async def set_domain(request: DomainRequest):
    """Set domain for HomeFree instance"""
    try:
        result = ConfigResolver.set_domain(request.domain)
        return JSONResponse(content=to_dict(result))
    except Exception as e:
        logger.error(f"Error setting domain: {e}")
        raise HTTPException(status_code=500, detail=str(e))

# Installation Endpoints

@app.post("/api/install/start")
async def start_installation():
    """Start the installation process"""
    try:
        result = InstallResolver.start_installation()
        return JSONResponse(content=to_dict(result))
    except Exception as e:
        logger.error(f"Error starting installation: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/install/status")
async def get_install_status():
    """Get current installation progress and status"""
    try:
        progress = InstallResolver.get_progress()
        return JSONResponse(content=to_dict(progress))
    except Exception as e:
        logger.error(f"Error getting install status: {e}")
        raise HTTPException(status_code=500, detail=str(e))

# System Control Endpoints

@app.post("/api/system/reboot")
async def reboot_system():
    """Reboot the system"""
    try:
        result = SystemResolver.reboot()
        return JSONResponse(content=to_dict(result))
    except Exception as e:
        logger.error(f"Error rebooting system: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/system/closure-id")
async def get_closure_id():
    """
    Return a fingerprint of the currently-deployed admin frontend.

    The frontend polls this and prompts the user to refresh ONLY when the
    served JS/CSS has actually changed. Previously we returned
    /run/current-system, which changes on ANY system change (including
    just toggling an unrelated service) and produced false-positive
    "new version available" banners.

    HOMEFREE_FRONTEND_PATH is set by the admin-api systemd unit
    (services/admin-web.nix) to the nix-store path of the frontend
    directory. The hash embedded in that path changes IFF the frontend
    files themselves change.
    """
    try:
        frontend_path = os.environ.get("HOMEFREE_FRONTEND_PATH")
        if frontend_path:
            return JSONResponse(content={"closure_id": frontend_path})

        # Fallback for older deployments without the env var.
        link = os.readlink("/run/current-system")
        return JSONResponse(content={"closure_id": link})
    except Exception as e:
        logger.error(f"Error computing frontend closure-id: {e}")
        raise HTTPException(status_code=500, detail=str(e))

# Admin Mode Endpoints

@app.get("/api/mode")
async def get_mode():
    """Get current application mode (installer or admin)"""
    try:
        from services.mode import ModeService
        mode = ModeService.get_mode()
        return JSONResponse(content={
            "mode": mode.value,
            "is_installer": ModeService.is_installer(),
            "is_admin": ModeService.is_admin()
        })
    except Exception as e:
        logger.error(f"Error detecting mode: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/config/current")
async def get_current_config():
    """Get current NixOS configuration (admin mode only)"""
    try:
        from services.mode import ModeService
        from services.config_reader import ConfigReader

        if not ModeService.is_admin():
            raise HTTPException(status_code=400, detail="Only available in admin mode")

        config = ConfigReader.read_config()
        return JSONResponse(content=config)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error reading config: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/config/validate")
async def validate_config(config: dict):
    """Validate configuration changes"""
    try:
        from services.validation import ValidationService
        from services.config_reader import ConfigReader

        # Get current config for network change warnings
        current_config = ConfigReader.read_config()

        # Validate new config
        is_valid, errors = ValidationService.validate_config(config)

        # Check for network change warnings
        warnings = []
        if 'network' in config:
            warnings = ValidationService.check_network_change_warning(
                current_config.get('network', {}),
                config['network']
            )

        from models import ValidationResult
        result = ValidationResult(
            valid=is_valid,
            errors=errors,
            warnings=warnings
        )

        return JSONResponse(content=to_dict(result))
    except Exception as e:
        logger.error(f"Error validating config: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/config/diff")
async def get_config_diff():
    """Get diff of configuration changes"""
    try:
        from services.mode import ModeService
        from services.nix_operations import NixOperations

        if not ModeService.is_admin():
            raise HTTPException(status_code=400, detail="Only available in admin mode")

        diff_result = NixOperations.generate_diff()

        from models import ConfigDiff
        result = ConfigDiff(
            has_changes=diff_result.get('has_changes', False),
            diff=diff_result.get('diff', '')
        )

        return JSONResponse(content=to_dict(result))
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error generating diff: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/config/preview")
async def preview_config_changes(config: dict):
    """Preview configuration changes with dry-activate"""
    try:
        from services.mode import ModeService
        from services.config_writer import ConfigWriter
        from services.nix_operations import NixOperations
        from services.validation import ValidationService
        from services.config_reader import ConfigReader

        if not ModeService.is_admin():
            raise HTTPException(status_code=400, detail="Only available in admin mode")

        # Validate first
        current_config = ConfigReader.read_config()
        is_valid, errors = ValidationService.validate_config(config)

        if not is_valid:
            from models import PreviewResult
            result = PreviewResult(
                success=False,
                changes=[],
                errors=errors,
                output="Validation failed",
                warnings=[]
            )
            return JSONResponse(content=to_dict(result))

        # Write config temporarily
        ConfigWriter.write_config(config)

        # Run dry-activate
        dry_run = NixOperations.dry_activate()

        # Check for network warnings
        warnings = []
        if 'network' in config:
            warnings = ValidationService.check_network_change_warning(
                current_config.get('network', {}),
                config['network']
            )

        from models import PreviewResult
        result = PreviewResult(
            success=dry_run['success'],
            changes=dry_run['changes'],
            errors=dry_run['errors'],
            output=dry_run['output'],
            warnings=warnings
        )

        return JSONResponse(content=to_dict(result))

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error previewing config: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/config/apply")
async def apply_config_changes(config: dict):
    """Apply configuration changes with nixos-rebuild switch"""
    try:
        from services.mode import ModeService
        from services.config_writer import ConfigWriter
        from services.nix_operations import NixOperations
        from services.validation import ValidationService

        if not ModeService.is_admin():
            raise HTTPException(status_code=400, detail="Only available in admin mode")

        # Check if a rebuild is already running
        rebuild_status = NixOperations.get_rebuild_status()
        if rebuild_status['running']:
            from models import ApplyResult
            result = ApplyResult(
                success=False,
                message="A rebuild is already in progress. Please wait for it to complete."
            )
            return JSONResponse(content=to_dict(result))

        # Validate first
        is_valid, errors = ValidationService.validate_config(config)

        if not is_valid:
            from models import ApplyResult
            result = ApplyResult(
                success=False,
                message=f"Validation failed: {', '.join(errors)}"
            )
            return JSONResponse(content=to_dict(result))

        # Write config
        if not ConfigWriter.write_config(config):
            from models import ApplyResult
            result = ApplyResult(
                success=False,
                message="Failed to write configuration file"
            )
            return JSONResponse(content=to_dict(result))

        # Start rebuild
        rebuild_result = NixOperations.rebuild_switch()

        from models import ApplyResult
        result = ApplyResult(
            success=rebuild_result['success'],
            message=rebuild_result['message'],
            pid=rebuild_result.get('pid')
        )

        return JSONResponse(content=to_dict(result))

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error applying config: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/config/save")
async def save_config_changes(config: dict):
    """
    Persist configuration changes to disk WITHOUT triggering a rebuild.

    Called by the frontend's debounced auto-save. Validates the payload, then
    writes /etc/nixos/homefree-config.json (with backup). On validation failure
    the file is NOT touched and the prior valid version is preserved on disk.
    """
    try:
        from services.mode import ModeService
        from services.config_writer import ConfigWriter
        from services.validation import ValidationService

        if not ModeService.is_admin():
            raise HTTPException(status_code=400, detail="Only available in admin mode")

        is_valid, errors = ValidationService.validate_config(config)
        if not is_valid:
            return JSONResponse(content={
                "success": False,
                "message": "Validation failed",
                "errors": errors,
            })

        if not ConfigWriter.write_config(config):
            return JSONResponse(content={
                "success": False,
                "message": "Failed to write configuration file",
                "errors": ["write failed"],
            })

        return JSONResponse(content={
            "success": True,
            "message": "Configuration saved",
            "errors": [],
        })

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error saving config: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/config/dirty")
async def get_config_dirty():
    """
    Indicate whether the on-disk config differs from the last applied state.

    Used by the frontend to enable/disable the Apply button. We track the
    "applied" state via /var/lib/homefree-admin/applied-config.json, which is
    written at the end of each successful rebuild. If that file is missing or
    its contents don't match /etc/nixos/homefree-config.json, the system is
    dirty (has unapplied changes).
    """
    try:
        from services.mode import ModeService

        if not ModeService.is_admin():
            raise HTTPException(status_code=400, detail="Only available in admin mode")

        config_path = Path("/etc/nixos/homefree-config.json")
        applied_path = Path("/var/lib/homefree-admin/applied-config.json")

        if not config_path.exists():
            return JSONResponse(content={"dirty": False, "reason": "no config file"})

        current = config_path.read_text()

        if not applied_path.exists():
            # No applied marker yet — assume dirty so the user can apply once.
            return JSONResponse(content={"dirty": True, "reason": "no applied marker"})

        applied = applied_path.read_text()
        if current != applied:
            return JSONResponse(content={"dirty": True, "reason": "differs"})

        # Config matches the last applied snapshot — but if the most recent
        # rebuild attempt failed, the system isn't actually in the desired
        # state. Surface that as "dirty" so Apply stays enabled for retry.
        latest_status_path = Path("/var/lib/homefree-admin/rebuild-logs/latest-status.json")
        if latest_status_path.exists():
            try:
                status = json.loads(latest_status_path.read_text())
                exit_code = status.get("exit_code")
                if exit_code is not None and exit_code != 0:
                    return JSONResponse(content={
                        "dirty": True,
                        "reason": "last rebuild failed",
                    })
            except Exception as e:
                logger.warning(f"Could not parse latest-status.json: {e}")

        return JSONResponse(content={"dirty": False, "reason": "in sync"})

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error checking config dirty state: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/config/rebuild-status")
async def get_rebuild_status(request: Request):
    """Get status of current rebuild operation.

    Supports `?include_history=1` for the page-load case: when a fresh
    frontend reattaches to an in-progress rebuild, it needs the full log
    so far, not just incremental output since the last poll.
    """
    try:
        from services.nix_operations import NixOperations

        status = NixOperations.get_rebuild_status()

        # Optionally include the full log file (not just incremental output).
        # Used by the frontend on first connect so reload doesn't lose history.
        include_history = request.query_params.get("include_history") in ("1", "true")
        if include_history:
            full = NixOperations.get_full_log()
            if full:
                status = {**status, "output": full}

        from models import RebuildStatus
        result = RebuildStatus(
            running=status['running'],
            output=status['output'],
            exit_code=status['exit_code'],
            success=status['exit_code'] == 0 if status['exit_code'] is not None else False,
            partial_success=status.get('partial_success', False)
        )

        return JSONResponse(content=to_dict(result))

    except Exception as e:
        logger.error(f"Error getting rebuild status: {e}")
        raise HTTPException(status_code=500, detail=str(e))

# Serve frontend static files
frontend_dir = Path("/etc/homefree-installer/frontend")
if frontend_dir.exists():
    # Mount frontend source files for development
    app.mount("/src", StaticFiles(directory=str(frontend_dir / "src")), name="frontend-src")
    logger.info(f"Serving frontend from: {frontend_dir}")

if __name__ == "__main__":
    import uvicorn
    logger.info("Starting HomeFree Web Installer Backend (REST API)")
    logger.info("All installation endpoints available at /api/*")

    uvicorn.run(
        app,
        host="0.0.0.0",
        port=8000,
        log_level="info"
    )
