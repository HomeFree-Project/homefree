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
    PUBLIC_PATHS = {
        "/health",
        "/api/service-state",
        "/api/closure-id",
    }
    ## oauth2-proxy v7's behavior:
    ##   - X-Auth-Request-Preferred-Username always carries the OIDC
    ##     `preferred_username` claim (Zitadel sets this to the bare
    ##     username, e.g. "erahhal").
    ##   - X-Auth-Request-User carries whatever USER_ID_CLAIM points
    ##     at, but in practice we've seen it stick to the OIDC `sub`
    ##     (Zitadel's numeric internal ID, e.g. "372429767272238115")
    ##     even after setting USER_ID_CLAIM=preferred_username.
    ##
    ## Read the username header first; fall back to X-Auth-Request-User
    ## only if the preferred_username header is absent. This makes the
    ## comparison against /var/lib/homefree-admin/admin-username
    ## (which is the bare username) work in either case.
    USER_HEADER = "x-auth-request-preferred-username"
    USER_HEADER_FALLBACK = "x-auth-request-user"

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

        # Optional per-user gate: if we know the configured admin
        # username, require an exact match. Avoids "any Zitadel
        # account" being able to drive the admin UI just because
        # they happen to have an org account.
        try:
            if self.ADMIN_USERNAME_FILE.is_file():
                expected = self.ADMIN_USERNAME_FILE.read_text().strip()
                if expected and user != expected:
                    logger.warning(
                        "Admin UI access denied for user '%s' (expected '%s')",
                        user, expected,
                    )
                    return JSONResponse(
                        {"error": "forbidden", "detail": "not the admin user"},
                        status_code=403,
                    )
        except Exception as e:
            # Don't block on a transient FS error; log and continue.
            logger.warning("Admin username check failed (allowing request): %s", e)

        # Stash the authenticated user for downstream handlers that
        # want to log it.
        request.state.auth_user = user
        return await call_next(request)


# Request logging middleware
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
                    # Try to parse as JSON for pretty printing
                    try:
                        body_json = json.loads(body)
                        body = json.dumps(body_json, indent=2)
                    except:
                        pass
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
