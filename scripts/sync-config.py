#!/usr/bin/env python3
"""
Sync homefree-config.json with module.nix schema.

This script ensures that the JSON config file stays in sync with module.nix
by adding new services and removing obsolete ones while preserving user values.
"""

import json
import sys
import re
from typing import Any, Dict, Set, List, Tuple


def extract_service_names_from_module(module_file: str) -> List[str]:
    """
    Extract service names from module.nix by parsing the services section.
    Returns list of service names (e.g., ['adguard', 'jellyfin', ...])
    """
    services = []
    try:
        with open(module_file, 'r') as f:
            lines = f.readlines()

        # Find the services block
        in_services = False
        brace_depth = 0

        for i, line in enumerate(lines):
            stripped = line.strip()

            # Start of services block
            if re.match(r'^\s*services\s*=\s*\{', line):
                in_services = True
                brace_depth = 1
                continue

            if not in_services:
                continue

            # Depth as we *enter* this line (before applying the line's braces).
            # Top-level service entries are the ones that sit immediately inside
            # the `services = { ... }` block — i.e. depth == 1 on entry,
            # opening their own `{` to become depth 2.
            depth_before = brace_depth
            brace_depth += line.count('{') - line.count('}')

            # Exit services block when braces balance out
            if brace_depth <= 0:
                break

            # Look for service definition: servicename = {
            # Only count entries opened at depth 1 (immediate children of the
            # services block). Without this gate, nested sub-options like
            # `netbird.client = { ... }` get picked up as if they were
            # top-level services.
            if depth_before != 1:
                continue
            service_match = re.match(r'^\s*([\w-]+)\s*=\s*\{', line)
            if service_match:
                service_name = service_match.group(1)
                # Skip reserved/structural names
                if service_name in ['options', 'config', 'secrets', 'backup']:
                    continue
                # Look ahead to see if this has an 'enable' option
                for j in range(i+1, min(i+5, len(lines))):
                    if 'enable' in lines[j] and 'lib.mkOption' in lines[j]:
                        services.append(service_name)
                        break

        return sorted(set(services))
    except Exception as e:
        print(f"Warning: Could not extract services from module.nix: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        return []


def sync_config(module_file: str, current_config: Dict) -> Tuple[Dict, List[str]]:
    """
    Sync current config with module.nix.
    Returns (synced_config, changes).

    This focuses on the practical sync issues:
    1. Services: Ensure all services from module.nix exist in JSON
    2. Remove obsolete services not in module.nix
    3. Preserve all user-configured values
    """
    changes = []
    synced_config = json.loads(json.dumps(current_config))  # Deep copy

    # Extract services from module.nix
    module_services = extract_service_names_from_module(module_file)

    if not module_services:
        changes.append("! Warning: Could not extract services from module.nix, skipping service sync")
        return synced_config, changes

    # Ensure services section exists
    if 'services' not in synced_config:
        synced_config['services'] = {}
        changes.append("+ Added: services section")

    current_services = set(synced_config['services'].keys())
    module_services_set = set(module_services)

    # Find obsolete services (in JSON but not in module.nix)
    obsolete_services = current_services - module_services_set

    # Find new services (in module.nix but not in JSON)
    new_services = module_services_set - current_services

    # Remove obsolete services
    for service in obsolete_services:
        del synced_config['services'][service]
        changes.append(f"- Removed obsolete service: {service}")

    # Add new services with defaults
    for service in new_services:
        synced_config['services'][service] = {
            'enable': False,
            'public': False
        }
        changes.append(f"+ Added new service: {service} (enable=false, public=false)")

    # Ensure all existing sections have required structure
    required_sections = {
        'system': {
            'domain': 'homefree.host',
            'hostName': 'homefree',
            'timeZone': 'Etc/UTC',
            'defaultLocale': 'en_US.UTF-8',
            'countryCode': None,
            'keyMap': 'us',
            'adminUsername': 'homefree',
            'adminDescription': 'HomeFree Admin',
            'localDomain': 'lan',
            'additionalDomains': [],
            'authorizedKeys': []
        },
        'network': {
            'wan-interface': 'ens3',
            'lan-interface': 'ens5',
            'router-enable': False,
            'lan-address': '10.0.0.1',
            'lan-subnet': '10.0.0.0/24',
            'dhcp-range-start': '10.0.0.100',
            'dhcp-range-end': '10.0.0.254',
            'enable-adblock': False,
            'wan-bitrate-mbps-down': None,
            'wan-bitrate-mbps-up': None,
            'static-ips': []
        },
        'dns': {
            'overrides': [],
            'dynamic-dns': {
                'interval': '10m',
                'usev4': 'webv4, webv4=ipinfo.io/ip',
                'usev6': 'webv6, webv6=v6.ipinfo.io/ip',
                'zones': []
            },
            'cert-management': None
        },
        'mounts': [],
        'service-config': [],
        'proxied-domains': [],
        'backups': {
            'enable': False,
            'to-path': '',
            'extra-from-paths': [],
            'backblaze-enable': False,
            'backblaze-bucket': ''
        }
    }

    # Ensure required sections exist with all required keys
    for section, defaults in required_sections.items():
        if section not in synced_config:
            synced_config[section] = defaults
            changes.append(f"+ Added missing section: {section}")
        elif isinstance(defaults, dict):
            # Add any missing keys in existing section (dict-shaped sections only)
            for key, default_value in defaults.items():
                if key not in synced_config[section]:
                    synced_config[section][key] = default_value
                    changes.append(f"+ Added missing key: {section}.{key} = {json.dumps(default_value)}")

    return synced_config, changes


def main():
    if len(sys.argv) != 3:
        print("Usage: sync-config.py <module.nix> <config.json>", file=sys.stderr)
        sys.exit(1)

    module_file = sys.argv[1]
    config_file = sys.argv[2]

    try:
        with open(config_file) as f:
            current_config = json.load(f)

        synced_config, changes = sync_config(module_file, current_config)

        # Output results
        result = {
            'config': synced_config,
            'changes': changes
        }

        print(json.dumps(result, indent=2))

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
