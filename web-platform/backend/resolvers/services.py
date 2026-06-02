"""
Services information resolvers
"""

import json
import os
import subprocess
import logging
from pathlib import Path
from typing import List, Dict, Any, Optional, Set, Tuple

from models import ServiceStatus

logger = logging.getLogger(__name__)

CONFIG_JSON_PATH = "/run/homefree/admin/config.json"
HOMEFREE_CONFIG_PATH = "/etc/nixos/homefree-config.json"
ALL_SERVICES_JSON_PATH = "/run/homefree/admin/all-services.json"
SERVICE_METADATA_JSON_PATH = "/run/homefree/admin/service-metadata.json"
SERVICE_OPTIONS_SCHEMA_PATH = "/run/homefree/admin/service-options-schema.json"

## SSO sentinels — kept in sync with simple_main.py. When zitadel-
## provision finishes its first successful run it touches the global
## sentinel; per-service .provisioned files mark which apps have a
## minted OIDC client (only meaningful for native_oidc services —
## caddy_gated / basic_auth piggyback on the global one).
SSO_SECRETS_DIR = "/var/lib/homefree-secrets"
SSO_GLOBAL_SENTINEL = f"{SSO_SECRETS_DIR}/.sso-provisioned"
SSO_KIND_NATIVE = "native_oidc"
SSO_KIND_CADDY = "caddy_gated"
SSO_KIND_BRIDGE = "basic_auth"


def _resolve_sso(
    service_config: Dict[str, Any],
    global_provisioned: bool,
) -> Tuple[str, str, bool, bool]:
    """Pull (kind, notes, provisioned, applicable) out of a service-config entry.

    kind / notes / applicable come from the Nix-emitted `sso` block.
    `applicable` (only meaningful when kind == "none") distinguishes a
    deliberate "SSO not applicable" posture from a pending integration.
    `provisioned` mirrors the same readiness logic the SSO endpoint uses:
      - native_oidc → per-service .provisioned sentinel in its secrets dir
      - caddy_gated / basic_auth → global sentinel (oauth2-proxy is up)
      - anything else → False (n/a)
    """
    sso = service_config.get("sso") or {}
    kind = sso.get("kind") or "none"
    notes = sso.get("notes") or ""
    # Defaults true (Nix option default) — only false when the service
    # explicitly opts out of SSO as not applicable.
    applicable = sso.get("applicable", True)
    if kind == SSO_KIND_NATIVE:
        label = service_config.get("label", "")
        secrets_dir_name = sso.get("secrets-dir") or label
        provisioned = os.path.exists(
            f"{SSO_SECRETS_DIR}/{secrets_dir_name}/.provisioned"
        )
    elif kind in (SSO_KIND_CADDY, SSO_KIND_BRIDGE):
        provisioned = global_provisioned
    else:
        provisioned = False
    return kind, notes, provisioned, applicable


def _bg_base(name: str) -> Tuple[Optional[str], Optional[str]]:
    """If `name` ends in -blue/-green return (base, colour), else (None, None).

    The -blue/-green suffix is the blue/green unit-naming contract — see
    lib/blue-green.nix (unitPrefix / unitName). Both a plain systemd
    colour (`<name>-<colour>`) and a podman one (`podman-<name>-<colour>`)
    end in the same suffix, so suffix matching covers both."""
    for colour in ("blue", "green"):
        suffix = "-" + colour
        if name.endswith(suffix):
            return name[: -len(suffix)], colour
    return None, None


def _collapse_blue_green(unit_states):
    """Collapse each blue/green unit pair into ONE synthetic UnitState so a
    deliberately-dormant standby colour does not read as 'degraded'.

    A blue/green service runs as two units on two ports — only one colour
    serves traffic at a time, the other sits intentionally `inactive`
    (see docs/agent-notes/blue-green-deployment.md). A flat aggregate
    would always see "some up, some not" and report degraded forever.

    Returns the list to aggregate over: standalone units (unchanged) plus
    one synthetic verdict per detected pair — healthy if >=1 colour is
    running, starting if a colour is activating and none up, failed/down
    if neither colour can run (a real outage, NOT masked). Also tags the
    REAL UnitState objects with .bg_role ('active'/'standby') in the
    unambiguous one-colour-running case, so the UI can render the dormant
    colour as non-error."""
    from models import UnitState

    by_name = {u.name: u for u in unit_states}

    bg_pairs = []          # (base, blue_unit, green_unit)
    paired_names: Set[str] = set()
    for u in unit_states:
        base, _ = _bg_base(u.name)
        if base is None or u.name in paired_names:
            continue
        blue_name, green_name = base + "-blue", base + "-green"
        # A real pair requires BOTH colours present. A lone -blue with no
        # -green sibling is NOT a pair — it falls through as a standalone.
        if blue_name in by_name and green_name in by_name:
            bg_pairs.append((base, by_name[blue_name], by_name[green_name]))
            paired_names.add(blue_name)
            paired_names.add(green_name)

    def _is_running(u):
        return u.active_state == "active" and u.sub_state == "running"

    def _is_starting(u):
        return u.active_state in ("activating", "reloading") or u.sub_state == "start"

    def _is_failed(u):
        return u.active_state == "failed"

    pair_verdicts = []
    for base, blue, green in bg_pairs:
        pair = (blue, green)
        running = [u for u in pair if _is_running(u)]

        # Verdict precedence: running > starting > failed > inactive.
        if running:
            # >=1 colour serving -> healthy. Steady state (one running,
            # one inactive) AND flip-in-progress (both running) both
            # land here.
            verdict = UnitState(name=base, active_state="active", sub_state="running")
        elif any(_is_starting(u) for u in pair):
            # a colour mid-start, none up yet -> "starting"
            verdict = UnitState(name=base, active_state="activating", sub_state="start")
        elif any(_is_failed(u) for u in pair):
            # neither colour can run, >=1 failed -> real outage, NOT masked
            verdict = UnitState(name=base, active_state="failed", sub_state="failed")
        else:
            # neither running, neither starting, none failed -> both dead
            verdict = UnitState(name=base, active_state="inactive", sub_state="dead")
        pair_verdicts.append(verdict)

        # Tag the real units for the UI — ONLY in the unambiguous
        # one-running case, the only case where an inactive colour is
        # *expected*. both-running (mid-flip): neither is dormant ->
        # leave None. neither-running: a down colour SHOULD look down ->
        # leave None.
        if len(running) == 1:
            running[0].bg_role = "active"
            other = green if running[0] is blue else blue
            other.bg_role = "standby"

    standalone = [u for u in unit_states if u.name not in paired_names]
    return standalone + pair_verdicts


class ServicesResolver:
    @staticmethod
    def get_services() -> List[ServiceStatus]:
        """Get list of all services with their runtime status and configuration"""

        # Read configurations
        all_services = ServicesResolver._read_all_services()
        homefree_config = ServicesResolver._read_homefree_config()
        services_config_map = ServicesResolver._read_service_config_map()

        # External-proxy entries (homefree.service-config in the LIVE on-disk
        # config) keyed by label. These hold the user's enable/public for
        # External Proxies. The catalog (services_config_map) is the DEPLOYED
        # render and only updates on rebuild, so for external services we read
        # enable/public from here — otherwise a pending toggle reverts on
        # reload because the catalog still shows the last-built value.
        disk_service_config = {
            e.get("label"): e
            for e in (homefree_config.get("service-config") or [])
            if isinstance(e, dict) and e.get("label")
        }

        # Global SSO bootstrap sentinel — checked once per request and
        # shared across every caddy_gated / basic_auth service.
        global_sso_provisioned = os.path.exists(SSO_GLOBAL_SENTINEL)

        # Cross-module overrides on `enable`. services/alerts/default.nix
        # uses `lib.mkForce` to flip homefree.services.ntfy.enable=true
        # whenever both alerts.enable AND alerts.channels.ntfy.enable are
        # true in homefree-config.json — the JSON-derived `enable` value
        # below would otherwise read False (the user never toggled the
        # ntfy row, alerts owns it). Surface that to the UI so the row
        # reports the effective state and can lock the toggle against
        # accidental writes that would lose to mkForce on rebuild anyway.
        alerts_cfg = homefree_config.get("alerts") or {}
        ntfy_forced_by_alerts = bool(alerts_cfg.get("enable")) and bool(
            (alerts_cfg.get("channels") or {}).get("ntfy", {}).get("enable")
        )

        services_status = []
        processed_labels = set()

        # First, process all services from the generated list
        for service_label in all_services:
            service_settings = homefree_config.get("services", {}).get(service_label, {})
            enabled = service_settings.get("enable", False)
            public = service_settings.get("public", False)

            enable_managed_by = None
            if service_label == "ntfy" and ntfy_forced_by_alerts:
                enabled = True
                enable_managed_by = "alerts"

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
                active_state, sub_state, unit_states = ServicesResolver._get_systemd_status(systemd_service_names)
            else:
                active_state, sub_state, unit_states = "inactive", "dead", []

            sso_kind, sso_notes, sso_provisioned, sso_applicable = _resolve_sso(
                service_config, global_sso_provisioned
            )

            admin_show = service_config.get("admin", {}).get("show", True)

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
                parent=parent,
                unit_states=unit_states,
                sso_kind=sso_kind,
                sso_notes=sso_notes,
                sso_provisioned=sso_provisioned,
                sso_applicable=sso_applicable,
                admin_show=admin_show,
                enable_managed_by=enable_managed_by,
            )

            services_status.append(service_status)
            processed_labels.add(service_label)

        # Now process any additional services from service-config that aren't in the main list
        # (like admin, landing-page, etc.)
        for service_label, service_config_data in services_config_map.items():
            if service_label in processed_labels:
                continue

            service_config = service_config_data.get("service-config", {})

            # Extract service info first to get parent
            name = service_config.get("name", service_label.replace("-", " ").title())
            project_name = service_config.get("project-name", name)
            systemd_service_names = service_config.get("systemd-service-names", [])
            parent = service_config.get("parent", None)
            url = service_config_data.get("url", None)

            # An External Proxies vhost: a top-level catalog entry (no parent)
            # with no systemd units. Its enable/public live in the
            # service-config entry, so the UI routes its toggles there.
            is_external = parent is None and not systemd_service_names

            # Determine enabled state based on whether this is a child instance or special service
            if parent:
                # This is a child instance - need to check its enable state from parent's instances array
                parent_settings = homefree_config.get("services", {}).get(parent, {})
                instances = parent_settings.get("instances", [])

                # Extract subdomain from label (format: parent_subdomain)
                subdomain = service_label.split('_', 1)[1] if '_' in service_label else None

                # Find matching instance by subdomain
                instance = next((inst for inst in instances if inst.get("subdomain") == subdomain), None)

                if instance:
                    enabled = instance.get("enable", True)
                    public = instance.get("public", False)
                else:
                    enabled = True  # Default to enabled if instance not found
                    public = False
            else:
                # External-proxy / special catalog entries. enable + public are
                # the single source of truth in the service-config entry — NOT
                # services.<label>. Prefer the LIVE on-disk entry so a pending
                # toggle shows immediately; fall back to the deployed catalog's
                # reverse-proxy (covers special services like admin/landing,
                # which aren't in the user's service-config[]).
                disk_entry = disk_service_config.get(service_label, {})
                rp = service_config.get("reverse-proxy", {})
                enabled = disk_entry.get("enable", rp.get("enable", True))
                public = disk_entry.get("public", rp.get("public", False))

            # Get runtime status from systemd
            if systemd_service_names:
                active_state, sub_state, unit_states = ServicesResolver._get_systemd_status(systemd_service_names)
            else:
                active_state, sub_state, unit_states = "unknown", "unknown", []

            sso_kind, sso_notes, sso_provisioned, sso_applicable = _resolve_sso(
                service_config, global_sso_provisioned
            )

            admin_show = service_config.get("admin", {}).get("show", True)

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
                parent=parent,
                unit_states=unit_states,
                sso_kind=sso_kind,
                sso_notes=sso_notes,
                sso_provisioned=sso_provisioned,
                sso_applicable=sso_applicable,
                external=is_external,
                admin_show=admin_show,
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

        # Sort: failed/degraded first (RED - most important), then running, then starting, then disabled
        def sort_key(service):
            is_failed = (
                service.active_state == "failed" or
                service.sub_state == "failed" or
                (service.active_state == "active" and service.sub_state == "degraded")
            )
            is_running = service.active_state == "active" and service.sub_state == "running"
            is_transitioning = (
                service.active_state in ("activating", "reloading", "deactivating") or
                service.sub_state in ("start", "stop", "reloading", "auto-restart")
            )
            is_disabled = not service.enabled or (service.active_state == "inactive" and service.sub_state == "dead")

            # Priority: 0 = failed/degraded (RED - top), 1 = running, 2 = transitioning/starting, 3 = disabled/stopped, 4 = other
            if is_failed:
                priority = 0
            elif is_running:
                priority = 1
            elif is_transitioning:
                priority = 2
            elif is_disabled:
                priority = 3
            else:
                priority = 4

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
    def _get_systemd_status(service_names: List[str]):
        """
        Query each systemd unit's state and return:
          (aggregate_active_state, aggregate_sub_state, unit_states)

        unit_states is a list of {"name", "active_state", "sub_state",
        "bg_role"} — one entry per *real* unit, so the UI can flag
        specific stragglers when the aggregate is "degraded".

        Before aggregating, blue/green colour pairs are collapsed by
        _collapse_blue_green: a `<base>-blue` / `<base>-green` pair is
        one logical unit (healthy if either colour is up), so the
        always-inactive standby colour doesn't peg the row at "degraded".
        The returned unit_states still lists every real unit.

        Aggregate semantics (the part that drives the colored dot —
        computed over the collapsed list):
        - All units active+running  -> ("active", "running")     -> green "Running"
        - Some active, some not     -> ("active", "degraded")    -> yellow "Degraded"
        - All units failed          -> ("failed", "failed")      -> red "Failed"
        - All units inactive/dead   -> ("inactive", "dead")      -> grey "Stopped"
        - Anything still starting   -> ("activating", "start")   -> orange "Starting"
        - Mix of failed + inactive  -> ("failed", "failed")      -> red "Failed"

        The "degraded" sentinel sub_state is what the frontend uses to
        decide between a hard-fail red dot and a partial yellow dot.
        """
        if not service_names:
            return "unknown", "unknown", []

        unit_states = []
        for service_name in service_names:
            active_state = "unknown"
            sub_state = "unknown"
            try:
                result = subprocess.run(
                    ['systemctl', 'show', service_name,
                     '--property=ActiveState,SubState,LoadState'],
                    capture_output=True,
                    text=True,
                    timeout=5,
                )

                if result.returncode == 0:
                    load_state = "loaded"
                    for line in result.stdout.strip().split('\n'):
                        if line.startswith('ActiveState='):
                            active_state = line.split('=', 1)[1].lower()
                        elif line.startswith('SubState='):
                            sub_state = line.split('=', 1)[1].lower()
                        elif line.startswith('LoadState='):
                            load_state = line.split('=', 1)[1].lower()
                    # Treat a missing/not-found unit as inactive so it
                    # contributes to "degraded" rather than masking the
                    # reason. ("not-found" + active_state == "inactive"
                    # is what systemctl reports for unknown units.)
                    if load_state == "not-found":
                        active_state = "inactive"
                        sub_state = "dead"
                else:
                    logger.warning(f"Failed to get status for {service_name}: {result.stderr}")
            except subprocess.TimeoutExpired:
                logger.error(f"Timeout querying systemd for {service_name}")
            except Exception as e:
                logger.error(f"Error getting status for {service_name}: {e}")

            from models import UnitState
            unit_states.append(UnitState(
                name=service_name,
                active_state=active_state,
                sub_state=sub_state,
            ))

        # Compute aggregate. Collapse blue/green colour pairs first: a
        # pair is one logical unit (healthy if either colour is up), so
        # the always-inactive standby colour doesn't drag the row into a
        # permanent "degraded". Standalone units pass through unchanged.
        agg_input = _collapse_blue_green(unit_states)

        running = [u for u in agg_input if u.active_state == "active" and u.sub_state == "running"]
        failed = [u for u in agg_input if u.active_state == "failed"]
        starting = [u for u in agg_input if u.active_state in ("activating", "reloading") or u.sub_state == "start"]
        # "Not running" = anything that isn't healthy: inactive, failed, unknown, etc.
        not_running = [u for u in agg_input if u not in running]

        total = len(agg_input)
        if not_running == []:
            agg_active, agg_sub = "active", "running"
        elif starting and len(running) + len(starting) == total:
            agg_active, agg_sub = "activating", "start"
        elif failed and len(failed) == total:
            agg_active, agg_sub = "failed", "failed"
        elif len(running) == 0 and not starting:
            # Nothing running at all — call it stopped (or failed if any
            # failed). Failed wins because it's actionable.
            if failed:
                agg_active, agg_sub = "failed", "failed"
            else:
                agg_active, agg_sub = "inactive", "dead"
        else:
            # The interesting case: at least one healthy, at least one not.
            # This is "degraded" — service is partially up.
            agg_active, agg_sub = "active", "degraded"

        return agg_active, agg_sub, unit_states

    @staticmethod
    def get_units_for_label(label: str) -> Optional[List[str]]:
        """Return the list of systemd unit names that back a given service
        label, or None if the label isn't in the catalog. Used by the
        action endpoint as an allowlist: only labels that appear in
        all-services.json (or service-config) can be controlled, and
        only their declared units."""
        all_services = ServicesResolver._read_all_services()
        services_config_map = ServicesResolver._read_service_config_map()
        if label not in all_services and label not in services_config_map:
            return None
        service_config = services_config_map.get(label, {}).get("service-config", {})
        return service_config.get("systemd-service-names", []) or []

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
