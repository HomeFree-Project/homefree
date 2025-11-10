"""
Services information resolvers
"""

import json
import subprocess
import logging
from pathlib import Path
from typing import List, Dict, Any, Optional, Set

from models import ServiceStatus

logger = logging.getLogger(__name__)

CONFIG_JSON_PATH = "/run/homefree/admin/config.json"
HOMEFREE_CONFIG_PATH = "/etc/nixos/homefree-config.json"

# Complete list of all services defined in module.nix
# This is the authoritative list of services that can be configured
ALL_SERVICES = [
    "adguard",
    "authentik",
    "baikal",
    "cryptpad",
    "forgejo",
    "freshrss",
    "frigate",
    "gitea",
    "grocy",
    "headscale",
    "homeassistant",
    "homebox",
    "immich",
    "jellyfin",
    "joplin",
    "kanidm",
    "lidarr",
    "linkwarden",
    "logseq",
    "matrix",
    "mediawiki",
    "minecraft",
    "nextcloud",
    "nzbget",
    "ollama",
    "radicale",
    "screeenly",
    "snipe-it",
    "unifi",
    "vaultwarden",
    "webdav",
    "zitadel",
]


class ServicesResolver:
    @staticmethod
    def get_services() -> List[ServiceStatus]:
        """Get list of all services with their runtime status and configuration"""

        # Read configurations
        homefree_config = ServicesResolver._read_homefree_config()
        services_config_map = ServicesResolver._read_service_config_map()

        services_status = []
        processed_labels = set()

        # First, process all services from homefree config
        for service_label in ALL_SERVICES:
            service_settings = homefree_config.get("services", {}).get(service_label, {})
            enabled = service_settings.get("enable", False)
            public = service_settings.get("public", False)

            # Get service-config data if available
            service_config_data = services_config_map.get(service_label, {})
            service_config = service_config_data.get("service-config", {})

            # Extract service info
            name = service_config.get("name", service_label.replace("-", " ").title())
            project_name = service_config.get("project-name", name)
            systemd_service_names = service_config.get("systemd-service-names", [])
            url = service_config_data.get("url", None)

            # Get runtime status from systemd only if enabled
            if enabled and systemd_service_names:
                active_state, sub_state = ServicesResolver._get_systemd_status(systemd_service_names)
            else:
                active_state, sub_state = "inactive", "dead"

            service_status = ServiceStatus(
                label=service_label,
                name=name,
                project_name=project_name,
                enabled=enabled,
                public=public,
                active_state=active_state,
                sub_state=sub_state,
                systemd_services=systemd_service_names,
                url=url
            )

            services_status.append(service_status)
            processed_labels.add(service_label)

        # Now process any additional services from service-config that aren't in the main list
        # (like admin, landing-page, etc.)
        for service_label, service_config_data in services_config_map.items():
            if service_label in processed_labels:
                continue

            service_config = service_config_data.get("service-config", {})

            # These are special services (admin, landing-page, etc.) - assume always enabled
            enabled = True
            public = service_config.get("reverse-proxy", {}).get("public", False)

            # Extract service info
            name = service_config.get("name", service_label.replace("-", " ").title())
            project_name = service_config.get("project-name", name)
            systemd_service_names = service_config.get("systemd-service-names", [])
            url = service_config_data.get("url", None)

            # Get runtime status from systemd
            if systemd_service_names:
                active_state, sub_state = ServicesResolver._get_systemd_status(systemd_service_names)
            else:
                active_state, sub_state = "unknown", "unknown"

            service_status = ServiceStatus(
                label=service_label,
                name=name,
                project_name=project_name,
                enabled=enabled,
                public=public,
                active_state=active_state,
                sub_state=sub_state,
                systemd_services=systemd_service_names,
                url=url
            )

            services_status.append(service_status)
            processed_labels.add(service_label)

        # Sort: running services first, then by name
        def sort_key(service):
            is_running = service.active_state == "active" and service.sub_state == "running"
            return (not is_running, service.name.lower())

        services_status.sort(key=sort_key)

        return services_status

    @staticmethod
    def _read_homefree_config() -> Dict[str, Any]:
        """Read main homefree configuration with all services"""
        try:
            config_path = Path(HOMEFREE_CONFIG_PATH)
            if not config_path.exists():
                logger.warning(f"Homefree config not found at {HOMEFREE_CONFIG_PATH}")
                return {}

            with open(config_path, 'r') as f:
                return json.load(f)
        except Exception as e:
            logger.error(f"Error reading homefree config: {e}")
            return {}

    @staticmethod
    def _read_service_config_map() -> Dict[str, Dict[str, Any]]:
        """Read service-config data and create a map by label"""
        try:
            config_path = Path(CONFIG_JSON_PATH)
            if not config_path.exists():
                logger.warning(f"Service config not found at {CONFIG_JSON_PATH}")
                return {}

            with open(config_path, 'r') as f:
                data = json.load(f)
                services_list = data.get("services", [])

                # Create a map: label -> service data
                service_map = {}
                for service_data in services_list:
                    service_config = service_data.get("service-config", {})
                    label = service_config.get("label", "")
                    if label:
                        service_map[label] = service_data

                return service_map
        except Exception as e:
            logger.error(f"Error reading service config: {e}")
            return {}

    @staticmethod
    def _get_systemd_status(service_names: List[str]) -> tuple[str, str]:
        """
        Get systemd status for a list of services.
        Returns the "worst" status (failed > inactive > active).
        """
        if not service_names:
            return "unknown", "unknown"

        worst_active = "active"
        worst_sub = "running"

        # Status priority (higher number = worse)
        active_priority = {
            "active": 0,
            "activating": 1,
            "reloading": 2,
            "deactivating": 3,
            "inactive": 4,
            "failed": 5,
            "maintenance": 6,
            "unknown": 7
        }

        sub_priority = {
            "running": 0,
            "exited": 1,
            "start": 2,
            "stop": 3,
            "reloading": 4,
            "auto-restart": 5,
            "dead": 6,
            "failed": 7,
            "unknown": 8
        }

        for service_name in service_names:
            try:
                # Query systemd for service status
                result = subprocess.run(
                    ['systemctl', 'show', service_name,
                     '--property=ActiveState,SubState'],
                    capture_output=True,
                    text=True,
                    timeout=5
                )

                if result.returncode == 0:
                    # Parse output like:
                    # ActiveState=active
                    # SubState=running
                    lines = result.stdout.strip().split('\n')
                    active_state = "unknown"
                    sub_state = "unknown"

                    for line in lines:
                        if line.startswith('ActiveState='):
                            active_state = line.split('=', 1)[1].lower()
                        elif line.startswith('SubState='):
                            sub_state = line.split('=', 1)[1].lower()

                    # Update worst status
                    current_active_priority = active_priority.get(active_state, 999)
                    worst_active_priority = active_priority.get(worst_active, 0)

                    if current_active_priority > worst_active_priority:
                        worst_active = active_state
                        worst_sub = sub_state
                    elif current_active_priority == worst_active_priority:
                        # Same active state, check sub state
                        current_sub_priority = sub_priority.get(sub_state, 999)
                        worst_sub_priority = sub_priority.get(worst_sub, 0)
                        if current_sub_priority > worst_sub_priority:
                            worst_sub = sub_state

                else:
                    logger.warning(f"Failed to get status for {service_name}: {result.stderr}")
                    worst_active = "unknown"
                    worst_sub = "unknown"

            except subprocess.TimeoutExpired:
                logger.error(f"Timeout querying systemd for {service_name}")
                worst_active = "unknown"
                worst_sub = "unknown"
            except Exception as e:
                logger.error(f"Error getting status for {service_name}: {e}")
                worst_active = "unknown"
                worst_sub = "unknown"

        return worst_active, worst_sub
