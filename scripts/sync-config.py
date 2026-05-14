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


def extract_service_schema_from_module(module_file: str) -> Dict[str, Set[str]]:
    """
    Walk module.nix's `services = { ... }` block and return a mapping
    of every declared top-level service to the set of subkeys it
    declares (e.g. `enable`, `public`, `media-path`, `instances`,
    `secrets`, etc.).

    Used for:
      1. Knowing which services exist (the dict's keys) — replaces
         the old `extract_service_names_from_module`.
      2. Knowing which subkeys are valid per service so we can drop
         stale ones from JSON. Without this, an orphan key in JSON
         like `mediawiki.secrets = {}` makes the build fail at Nix
         eval time with an opaque "option does not exist" error.

    The parser is intentionally textual and conservative — it only
    detects subkeys declared via `<name> = lib.mkOption { ... }` or
    `<name> = { ... }` (the latter for nested groupings like
    `secrets = { ... }` in service blocks that contain multiple
    `mkOption`s). Submodule-internal options (per-instance attrs
    inside a `listOf submodule {...}`) are not walked because
    Nix's submodule type enforces those at eval time on its own.
    """
    schema: Dict[str, Set[str]] = {}
    try:
        with open(module_file, 'r') as f:
            lines = f.readlines()

        in_services = False
        brace_depth = 0
        current_svc = None  # Name of the service whose body we're inside.

        for i, line in enumerate(lines):
            # Start of services block
            if not in_services and re.match(r'^\s*services\s*=\s*\{', line):
                in_services = True
                brace_depth = 1
                continue

            if not in_services:
                continue

            depth_before = brace_depth
            brace_depth += line.count('{') - line.count('}')

            if brace_depth <= 0:
                break

            # Top-level service entry: depth 1 → opens to depth 2.
            if depth_before == 1:
                m = re.match(r'^\s*([\w-]+)\s*=\s*\{', line)
                if m:
                    name = m.group(1)
                    if name in ('options', 'config', 'secrets', 'backup'):
                        current_svc = None
                        continue
                    # Look ahead to confirm this has an `enable` mkOption —
                    # otherwise it's some other top-level attrset that
                    # happens to live inside `services = {`.
                    has_enable = any(
                        'enable' in lines[j] and 'lib.mkOption' in lines[j]
                        for j in range(i + 1, min(i + 5, len(lines)))
                    )
                    if has_enable:
                        current_svc = name
                        schema.setdefault(current_svc, set())
                    else:
                        current_svc = None
                    continue

            # Subkey inside a service body: depth 2 → either opens a
            # mkOption (depth 3) or a nested attrset.
            if current_svc and depth_before == 2:
                m = re.match(r'^\s*([\w-]+)\s*=\s*(?:lib\.mkOption|\{)', line)
                if m:
                    schema[current_svc].add(m.group(1))

            # Close of current service body returns to depth 1.
            if current_svc and brace_depth == 1:
                current_svc = None

        return schema
    except Exception as e:
        print(f"Warning: Could not parse module.nix schema: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        return {}


def extract_service_names_from_module(module_file: str) -> List[str]:
    """Compatibility wrapper. Returns a sorted list of service names."""
    return sorted(extract_service_schema_from_module(module_file).keys())


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

    # Pull the full service schema from module.nix. Names are used for the
    # service-level add/remove sweep; per-service subkey sets are used to
    # drop stale option keys that no longer correspond to a declared option.
    module_schema = extract_service_schema_from_module(module_file)

    if not module_schema:
        changes.append("! Warning: Could not extract services from module.nix, skipping service sync")
        return synced_config, changes

    module_services_set = set(module_schema.keys())

    # Ensure services section exists
    if 'services' not in synced_config:
        synced_config['services'] = {}
        changes.append("+ Added: services section")

    current_services = set(synced_config['services'].keys())

    # Find obsolete services (in JSON but not in module.nix)
    obsolete_services = current_services - module_services_set

    # Find new services (in module.nix but not in JSON)
    new_services = module_services_set - current_services

    # Remove obsolete services
    for service in sorted(obsolete_services):
        del synced_config['services'][service]
        changes.append(f"- Removed obsolete service: {service}")

    # Add new services with defaults
    for service in sorted(new_services):
        synced_config['services'][service] = {
            'enable': False,
            'public': False
        }
        changes.append(f"+ Added new service: {service} (enable=false, public=false)")

    # Drop stale subkeys: JSON has a key under `services.<name>` that
    # isn't declared in module.nix for that service. Left unchecked
    # these break the build at Nix eval time with an opaque "option
    # does not exist" error. The most common cause is a service
    # losing an option upstream (e.g. `mediawiki.secrets` removed)
    # while an existing JSON file still carries the now-orphan key.
    for service in sorted(synced_config['services'].keys()):
        if service not in module_schema:
            continue  # Already handled by the obsolete-services pass.
        svc_cfg = synced_config['services'][service]
        if not isinstance(svc_cfg, dict):
            continue
        declared = module_schema[service]
        stale = [k for k in svc_cfg.keys() if k not in declared]
        for key in sorted(stale):
            value = svc_cfg.pop(key)
            changes.append(
                f"~ Dropped stale key: services.{service}.{key} "
                f"(value was {json.dumps(value)})"
            )

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
