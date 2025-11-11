#!/usr/bin/env python3
"""
HomeFree Web Installer Backend - REST API
Simplified version without strawberry-graphql dependency
"""

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

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

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

# Request/Response Models
class NetworkConfigRequest(BaseModel):
    wan_interface: str
    lan_interface: str

class HostnameRequest(BaseModel):
    hostname: str

class LocationRequest(BaseModel):
    timezone: str
    locale: str

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
    """Health check endpoint"""
    return {"status": "ok", "message": "HomeFree Installer Backend is running"}

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
    """Set timezone and locale"""
    try:
        result = ConfigResolver.set_location(request.timezone, request.locale)
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

@app.get("/api/config/rebuild-status")
async def get_rebuild_status():
    """Get status of current rebuild operation"""
    try:
        from services.nix_operations import NixOperations

        status = NixOperations.get_rebuild_status()

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
