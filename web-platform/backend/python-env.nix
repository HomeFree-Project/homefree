# Shared backend Python dependency set.
#
# Single source of truth for the admin/installer backend's runtime deps,
# imported by:
#   - services/admin-web/default.nix  (the service's pythonEnv)
#   - checks/default.nix              (the backend import-all gate — so the
#                                       gate exercises the SAME closure the
#                                       service actually runs under)
#
# Keep in sync with web-platform/backend/requirements.txt. Usage:
#   pkgs.python3.withPackages (import ./python-env.nix)
ps: with ps; [
  fastapi
  uvicorn
  psutil
  pyudev
  pydantic
  pyyaml
  babel
  httpx
  ## GeoIP lookups for the Abuse Blocking page's traffic-source table.
  ## Reads the DB-IP mmdb maintained by modules/geoip.nix.
  geoip2
]
