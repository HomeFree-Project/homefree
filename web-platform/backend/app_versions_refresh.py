#!/usr/bin/env python3
"""
HomeFree app-versions refresher — oneshot entrypoint.

Walks /run/homefree/admin/container-images.json, queries each
container image's upstream registry for the latest semver tag, and
writes the merged result to /var/lib/homefree-admin/app-versions-cache.json.

Invoked by:
  * The homefree-app-versions-refresh.timer (daily; see
    services/admin-web/default.nix).
  * Indirectly by the admin-api's manual /api/apps/versions/refresh
    endpoint — which calls refresh_all() in-process rather than
    shelling out here, but uses the same logic.

Has no daemon lifecycle: runs the refresh once, then exits.
"""

import asyncio
import logging
import sys
from pathlib import Path

# Make the resolver importable when this script is launched directly
# from the wrapper in services/admin-web/default.nix.
backend_dir = Path(__file__).parent.absolute()
if str(backend_dir) not in sys.path:
    sys.path.insert(0, str(backend_dir))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger("app_versions_refresh")


async def main() -> int:
    from resolvers.app_versions import refresh_all

    try:
        cache = await refresh_all()
    except Exception as e:  # noqa: BLE001
        logger.error("refresh failed: %s", e)
        return 1
    n_total = len(cache)
    n_resolved = sum(1 for v in cache.values() if v.get("latest_tag"))
    logger.info(
        "app-versions refresh complete: %d/%d images resolved",
        n_resolved,
        n_total,
    )
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
