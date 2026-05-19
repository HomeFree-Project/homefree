#!/usr/bin/env python3
"""
Sync homefree-config.json with the HomeFree service schema.

This script keeps the JSON config in sync with the schema by adding
newly-introduced services and dropping option subkeys that no longer
exist, while preserving all user values. It NEVER removes a whole
service — a `services.<name>` key may belong to a custom-flake app
this script cannot see, and the Nix layer already tolerates orphaned
keys (see `homefree-configuration.nix`).

Service schema discovery
------------------------
A service's `homefree.services.<name>` option may be declared in two
places, and BOTH are scanned:

  1. The top-level `module.nix` `services = { ... }` block — used only
     for the handful of services with no app directory (admin,
     landing-page, oauth2-proxy).

  2. Each app's own `apps/<name>/default.nix` (or
     `services/<name>/default.nix`) — since the `apps/`/`services/`
     auto-discovery refactor, every user-facing service declares
     `options.homefree.services.<name>` in its own directory.

Scanning ONLY `module.nix` (as this script originally did) made the
sync think every app-directory service was "obsolete" and strip it
from the config — a destructive bug. Discovery must mirror what
`configuration.nix`'s `discoverModules` does: every non-`_`-prefixed
directory under `apps/` and `services/` is a real service.
"""

import json
import os
import sys
import re
from typing import Any, Dict, Set, List, Tuple


def extract_service_schema_from_module(module_file: str) -> Dict[str, Dict[str, Any]]:
    """
    Walk module.nix's `services = { ... }` block and return a mapping
    of every declared top-level service to a metadata dict:

        {
          'subkeys':        Set[str],   # declared subkeys (enable, public, ...)
          'enable_default': bool,       # default value of `enable` option
        }

    Used for:
      1. Knowing which services exist (the dict's keys) — replaces
         the old `extract_service_names_from_module`.
      2. Knowing which subkeys are valid per service so we can drop
         stale ones from JSON. Without this, an orphan key in JSON
         like `mediawiki.secrets = {}` makes the build fail at Nix
         eval time with an opaque "option does not exist" error.
      3. Seeding new services into JSON with the right enable default
         (so e.g. zitadel comes out enabled when missing from JSON).

    The parser is intentionally textual and conservative — it only
    detects subkeys declared via `<name> = lib.mkOption { ... }` or
    `<name> = { ... }` (the latter for nested groupings like
    `secrets = { ... }`). Submodule-internal options (per-instance
    attrs inside a `listOf submodule {...}`) are not walked because
    Nix's submodule type enforces those at eval time on its own.
    """
    schema: Dict[str, Dict[str, Any]] = {}
    try:
        with open(module_file, 'r') as f:
            lines = f.readlines()

        in_services = False
        brace_depth = 0
        current_svc = None  # Name of the service whose body we're inside.

        def _read_enable_default(start: int) -> bool:
            """Scan forward from `enable = lib.mkOption {` for a
            `default = true|false;` line. Returns False if not found
            (safe fallback — the most common default)."""
            for j in range(start, min(start + 15, len(lines))):
                md = re.match(r'^\s*default\s*=\s*(true|false)\s*;', lines[j])
                if md:
                    return md.group(1) == 'true'
                if '};' in lines[j]:
                    break
            return False

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
                    # Look ahead to confirm this has an `enable` mkOption.
                    enable_line = None
                    for j in range(i + 1, min(i + 5, len(lines))):
                        if 'enable' in lines[j] and 'lib.mkOption' in lines[j]:
                            enable_line = j
                            break
                    if enable_line is not None:
                        current_svc = name
                        schema.setdefault(current_svc, {
                            'subkeys': set(),
                            'enable_default': _read_enable_default(enable_line + 1),
                        })
                    else:
                        current_svc = None
                    continue

            # Subkey inside a service body: depth 2 → either opens a
            # mkOption (depth 3) or a nested attrset.
            if current_svc and depth_before == 2:
                m = re.match(r'^\s*([\w-]+)\s*=\s*(?:lib\.mkOption|\{)', line)
                if m:
                    schema[current_svc]['subkeys'].add(m.group(1))

            # Close of current service body returns to depth 1.
            if current_svc and brace_depth == 1:
                current_svc = None

        return schema
    except Exception as e:
        print(f"Warning: Could not parse module.nix schema: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        return {}


def _read_enable_default(lines: List[str], start: int) -> bool:
    """Scan forward from an `enable = lib.mkOption {` line for a
    `default = true|false;`. Returns False if not found (the common
    default — most services ship disabled)."""
    for j in range(start, min(start + 15, len(lines))):
        md = re.match(r'^\s*default\s*=\s*(true|false)\s*;', lines[j])
        if md:
            return md.group(1) == 'true'
        if '};' in lines[j]:
            break
    return False


def _parse_options_attrset(lines: List[str], open_idx: int) -> Dict[str, Any]:
    """
    Parse an attrset of `mkOption`s — the body bound to
    `homefree.services.<name>` (typically the `userOptions` let-binding
    in an app's default.nix).

    `open_idx` is the line index whose text contains the attrset's
    opening `{`. Walks to the matching `}` and returns:

        { 'subkeys': Set[str], 'enable_default': bool }

    Subkeys are detected at the attrset's top level via
    `<name> = lib.mkOption { ... }` or `<name> = { ... }` (nested
    groupings like `secrets = { ... }`). Same conservative textual
    style as the module.nix parser.
    """
    subkeys: Set[str] = set()
    enable_default = False
    depth = 0
    started = False
    for i in range(open_idx, len(lines)):
        line = lines[i]
        depth_before = depth
        depth += line.count('{') - line.count('}')
        if not started:
            if depth > 0:
                started = True
            continue
        # Top level of the attrset is depth 1 (depth_before == 1).
        if depth_before == 1:
            m = re.match(r'^\s*([\w-]+)\s*=\s*(?:lib\.mkOption|\{)', line)
            if m:
                key = m.group(1)
                subkeys.add(key)
                if key == 'enable' and 'lib.mkOption' in line:
                    enable_default = _read_enable_default(lines, i + 1)
        if depth <= 0:
            break
    return {'subkeys': subkeys, 'enable_default': enable_default}


def _extract_schema_from_app_file(app_file: str) -> Dict[str, Dict[str, Any]]:
    """
    Parse one `apps/<name>/default.nix` (or `services/<name>/...`) for
    its `options.homefree.services.<name>` declaration and return the
    {name: metadata} schema entry (usually a single entry, but a file
    may declare more than one).

    Handles the two declaration shapes seen in the repo:
      - `options.homefree.services.<name> = userOptions;`
        where `userOptions` is a `let`-bound attrset above.
      - `options.homefree.services.<name> = { ... };` inline.
    """
    schema: Dict[str, Dict[str, Any]] = {}
    try:
        with open(app_file, 'r') as f:
            lines = f.readlines()
    except OSError:
        return schema

    for i, line in enumerate(lines):
        m = re.match(
            r'^\s*options\.homefree\.services\.([\w-]+)\s*=\s*(.+)$',
            line,
        )
        if not m:
            continue
        name = m.group(1)
        rhs = m.group(2).strip()
        if rhs.startswith('{'):
            # Inline attrset on this line.
            schema[name] = _parse_options_attrset(lines, i)
        else:
            # RHS is an identifier (e.g. `userOptions;` or
            # `userOptions // { ... };`). Find that let-binding.
            ident_m = re.match(r'([\w-]+)', rhs)
            if not ident_m:
                continue
            ident = ident_m.group(1)
            bind_idx = None
            for j, bl in enumerate(lines):
                if re.match(rf'^\s*{re.escape(ident)}\s*=\s*\{{', bl):
                    bind_idx = j
                    break
            if bind_idx is not None:
                schema[name] = _parse_options_attrset(lines, bind_idx)
            else:
                # Binding not found textually — still register the
                # service (with no subkeys) so it is recognised; the
                # stale-subkey sweep simply skips a service with an
                # empty subkey set.
                schema[name] = {'subkeys': set(), 'enable_default': False}
    return schema


def extract_service_schema(module_file: str) -> Dict[str, Dict[str, Any]]:
    """
    Aggregate the full service schema from BOTH sources:
      1. the top-level module.nix `services = { ... }` block, and
      2. every `apps/<name>/default.nix` and `services/<name>/default.nix`
         that declares `options.homefree.services.<name>`.

    A config-service is precisely a thing that declares
    `homefree.services.<name>` — that declaration is what maps to a
    `services.<name>` key in homefree-config.json. Directories that
    don't declare it are pure infrastructure modules (caddy, unbound,
    mysql, ...) — they have no config-service key and must NOT be
    discovered, or the sync would wrongly inject them into the JSON.

    Disabled modules (`_`-prefixed directories) are skipped, mirroring
    configuration.nix's discovery.
    """
    repo_root = os.path.dirname(os.path.abspath(module_file))

    # (1) module.nix services block (admin, landing-page, oauth2-proxy).
    schema: Dict[str, Dict[str, Any]] = dict(
        extract_service_schema_from_module(module_file)
    )

    # (2) every app/service directory that declares a config service.
    for sub in ('apps', 'services'):
        base = os.path.join(repo_root, sub)
        if not os.path.isdir(base):
            continue
        for entry in sorted(os.listdir(base)):
            if entry.startswith('_'):
                continue  # disabled module — excluded from the build
            app_file = os.path.join(base, entry, 'default.nix')
            if not os.path.isfile(app_file):
                continue
            for name, meta in _extract_schema_from_app_file(app_file).items():
                schema[name] = meta

    return schema


def extract_service_names_from_module(module_file: str) -> List[str]:
    """Compatibility wrapper. Returns a sorted list of service names."""
    return sorted(extract_service_schema(module_file).keys())


def sync_config(module_file: str, current_config: Dict) -> Tuple[Dict, List[str]]:
    """
    Sync current config with the HomeFree service schema.
    Returns (synced_config, changes).

    This focuses on the practical sync issues:
    1. Add schema services missing from the JSON (with correct defaults)
    2. Drop option subkeys no longer declared for a known service
    3. Preserve all user-configured values
    4. NEVER remove a whole service — see the note below; custom-flake
       services and orphaned keys are kept and merely reported
    """
    changes = []
    synced_config = json.loads(json.dumps(current_config))  # Deep copy

    # Pull the full service schema from module.nix AND every app/service
    # directory. Names drive the service-level add/remove sweep;
    # per-service subkey sets drive the stale-option-key drop.
    module_schema = extract_service_schema(module_file)

    if not module_schema:
        changes.append("! Warning: Could not extract services from schema, skipping service sync")
        return synced_config, changes

    module_services_set = set(module_schema.keys())

    # Ensure services section exists
    if 'services' not in synced_config:
        synced_config['services'] = {}
        changes.append("+ Added: services section")

    current_services = set(synced_config['services'].keys())

    # NOTE — this sync deliberately NEVER removes a whole service.
    #
    # A `services.<name>` key in the config can come from a CUSTOM
    # FLAKE (registered under `developers.flakes`) — an app declared in
    # a flake OUTSIDE this repo. This script only scans the in-repo
    # apps/ and services/ trees, so it cannot see custom-flake services
    # and must not treat their config keys as "obsolete". A previous
    # version of this script removed every service it didn't recognise
    # and silently wiped users' configs.
    #
    # Removal is also unnecessary: `homefree-configuration.nix` filters
    # `services.<name>` keys to ones that resolve to a declared option
    # at eval time, so a genuinely orphaned key (app deleted, flake
    # removed) is tolerated by the build — it does not need pruning
    # here. The settings stay inert in the JSON and come back if the
    # app/flake is re-added.
    #
    # Unrecognised services are merely reported, for visibility.
    unrecognised = sorted(current_services - module_services_set)
    if unrecognised:
        changes.append(
            "i Unrecognised services kept as-is (custom-flake apps or "
            f"orphaned keys; not removed): {', '.join(unrecognised)}"
        )

    # Find new services (in the in-repo schema but not in JSON)
    new_services = module_services_set - current_services

    # Add new services with defaults pulled from each app's `enable`
    # mkOption `default = ...`. The default varies per service (e.g.
    # zitadel defaults on, frigate defaults off); without this lookup
    # every fresh-add would land disabled.
    for service in sorted(new_services):
        enable_default = module_schema[service]['enable_default']
        synced_config['services'][service] = {
            'enable': enable_default,
            'public': False
        }
        changes.append(
            f"+ Added new service: {service} "
            f"(enable={str(enable_default).lower()}, public=false)"
        )

    # Drop stale subkeys: JSON has a key under `services.<name>` that
    # isn't declared for that service. Left unchecked these break the
    # build at Nix eval time with an opaque "option does not exist"
    # error. The most common cause is a service losing an option
    # upstream (e.g. `mediawiki.secrets` removed) while an existing
    # JSON file still carries the now-orphan key.
    #
    # This only runs for services we HAVE a schema for. A custom-flake
    # service (no in-repo schema) is skipped entirely — we can't tell a
    # valid subkey from a stale one without the flake's option set, and
    # guessing would corrupt a working config.
    for service in sorted(synced_config['services'].keys()):
        if service not in module_schema:
            continue  # custom-flake / unrecognised — leave it untouched.
        svc_cfg = synced_config['services'][service]
        if not isinstance(svc_cfg, dict):
            continue
        declared = module_schema[service]['subkeys']
        # An empty subkey set means the app's option block could not be
        # text-parsed (not that the service has zero options). Skip the
        # sweep — dropping "stale" keys against an empty schema would
        # delete EVERY key and corrupt a working service config.
        if not declared:
            continue
        stale = [k for k in svc_cfg.keys() if k not in declared]
        for key in sorted(stale):
            value = svc_cfg.pop(key)
            changes.append(
                f"~ Dropped stale key: services.{service}.{key} "
                f"(value was {json.dumps(value)})"
            )

    # One-time key renames for non-services sections. Each entry maps an
    # old key path to its new name; the value is preserved verbatim. This
    # is necessary because the generic "ensure required keys exist" pass
    # below would otherwise leave the old key in place AND seed a fresh
    # default for the new key — losing the user's value AND tripping the
    # Nix-side check for unknown options once the old key is removed
    # from the schema.
    section_renames: Dict[str, Dict[str, str]] = {
        'network': {
            # Renamed to disambiguate from AdGuard Home's blocklist. The
            # flag only controls Unbound's bundled Steven Black hosts
            # include, which is independent of (and usually redundant
            # with) AdGuard.
            'enable-adblock': 'enable-unbound-adblock',
        },
    }
    for section, renames in section_renames.items():
        if section not in synced_config or not isinstance(synced_config[section], dict):
            continue
        for old_key, new_key in renames.items():
            if old_key in synced_config[section] and new_key not in synced_config[section]:
                synced_config[section][new_key] = synced_config[section].pop(old_key)
                changes.append(
                    f"~ Renamed {section}.{old_key} -> {section}.{new_key}"
                )
            elif old_key in synced_config[section]:
                # Both present — new_key wins, drop the legacy one.
                value = synced_config[section].pop(old_key)
                changes.append(
                    f"- Dropped legacy {section}.{old_key} "
                    f"(value was {json.dumps(value)}; {new_key} already set)"
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
            'enable-unbound-adblock': False,
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
