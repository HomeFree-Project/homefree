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
ALL_SERVICES_JSON_PATH = "/run/homefree/admin/all-services.json"
SERVICE_METADATA_JSON_PATH = "/run/homefree/admin/service-metadata.json"
SERVICE_OPTIONS_SCHEMA_PATH = "/run/homefree/admin/service-options-schema.json"


class ServicesResolver:
    @staticmethod
    def get_services() -> List[ServiceStatus]:
        """Get list of all services with their runtime status and configuration"""

        # Read configurations
        all_services = ServicesResolver._read_all_services()
        homefree_config = ServicesResolver._read_homefree_config()
        services_config_map = ServicesResolver._read_service_config_map()

        services_status = []
        processed_labels = set()

        # First, process all services from the generated list
        for service_label in all_services:
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
            parent = service_config.get("parent", None)
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
                url=url,
                parent=parent
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
            parent = service_config.get("parent", None)
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
                url=url,
                parent=parent
            )

            services_status.append(service_status)
            processed_labels.add(service_label)

        # Calculate aggregate status for parent services (those with no systemd services)
        parent_services = {s.label: s for s in services_status if not s.systemd_services}
        for parent_label, parent_service in parent_services.items():
            # Find all child services
            children = [s for s in services_status if s.parent == parent_label]

            if children:
                # Only consider ENABLED children for status aggregation
                # Disabled children are intentionally stopped and shouldn't affect parent status
                enabled_children = [s for s in children if s.enabled]

                # Check if there are any disabled children (for partial flag)
                has_disabled = len(enabled_children) < len(children)

                if not enabled_children:
                    # All children disabled - parent should be inactive
                    parent_service.active_state = "inactive"
                    parent_service.sub_state = "dead"
                    parent_service.partial = False
                else:
                    # Aggregate status logic for enabled children only:
                    # - active/running if ALL enabled children are active/running
                    # - failed if ANY enabled child is failed
                    # - inactive/dead if ALL enabled children are inactive/dead
                    # - activating if ANY enabled child is activating and none are failed

                    all_running = all(s.active_state == "active" and s.sub_state == "running" for s in enabled_children)
                    any_failed = any(s.active_state == "failed" or s.sub_state == "failed" for s in enabled_children)
                    all_inactive = all(s.active_state == "inactive" and s.sub_state == "dead" for s in enabled_children)
                    any_activating = any(s.active_state == "activating" for s in enabled_children)

                    if all_running:
                        parent_service.active_state = "active"
                        parent_service.sub_state = "running"
                        parent_service.partial = has_disabled  # Mark as partial if some children disabled
                    elif any_failed:
                        parent_service.active_state = "failed"
                        parent_service.sub_state = "failed"
                        parent_service.partial = False  # Failed state takes priority over partial
                    elif all_inactive:
                        parent_service.active_state = "inactive"
                        parent_service.sub_state = "dead"
                        parent_service.partial = False
                    elif any_activating:
                        parent_service.active_state = "activating"
                        parent_service.sub_state = "start"
                        parent_service.partial = has_disabled
                    else:
                        # Mixed states among enabled children
                        parent_service.active_state = "active"
                        parent_service.sub_state = "degraded"
                        parent_service.partial = False  # Degraded means actual problems, not just partial

        # Sort: running services first, then starting/transitioning, then disabled/stopped, then by name
        def sort_key(service):
            is_running = service.active_state == "active" and service.sub_state == "running"
            is_transitioning = (
                service.active_state in ("activating", "reloading", "deactivating") or
                service.sub_state in ("start", "stop", "reloading", "auto-restart")
            )
            is_disabled = not service.enabled or (service.active_state == "inactive" and service.sub_state == "dead")

            # Priority: 0 = running, 1 = transitioning/starting, 2 = disabled/stopped, 3 = other
            if is_running:
                priority = 0
            elif is_transitioning:
                priority = 1
            elif is_disabled:
                priority = 2
            else:
                priority = 3

            return (priority, service.name.lower())

        services_status.sort(key=sort_key)

        return services_status

    @staticmethod
    def _read_all_services() -> List[str]:
        """Read list of all available services from generated JSON file"""
        try:
            config_path = Path(ALL_SERVICES_JSON_PATH)
            if not config_path.exists():
                logger.warning(f"All services list not found at {ALL_SERVICES_JSON_PATH}, using empty list")
                return []

            with open(config_path, 'r') as f:
                services = json.load(f)
                logger.info(f"Loaded {len(services)} services from {ALL_SERVICES_JSON_PATH}")
                return services
        except Exception as e:
            logger.error(f"Error reading all services list: {e}")
            return []

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

    @staticmethod
    def get_service_options_schema() -> Dict[str, Dict[str, Any]]:
        """
        Get service options schema from generated JSON file.
        Returns a mapping of service labels to their configurable options.
        """
        try:
            schema_path = Path(SERVICE_OPTIONS_SCHEMA_PATH)
            if not schema_path.exists():
                logger.warning(f"Service options schema not found at {SERVICE_OPTIONS_SCHEMA_PATH}")
                return {}

            with open(schema_path, 'r') as f:
                schema = json.load(f)
                logger.info(f"Loaded service options schema for {len(schema)} services")
                return schema
        except Exception as e:
            logger.error(f"Error loading service options schema: {e}")
            return {}
