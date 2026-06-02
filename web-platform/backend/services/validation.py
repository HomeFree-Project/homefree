"""
Validation service - validates configuration before applying
"""

import re
import ipaddress
from typing import Dict, Any, List, Tuple
import logging

logger = logging.getLogger(__name__)


class ValidationService:
    """Service for validating configuration changes"""

    @staticmethod
    def validate_config(config: Dict[str, Any]) -> Tuple[bool, List[str]]:
        """
        Validate entire configuration.

        Args:
            config: Configuration dictionary to validate

        Returns:
            Tuple of (is_valid, list_of_errors)
        """
        errors = []

        # Validate each section
        if 'system' in config:
            errors.extend(ValidationService._validate_system(config['system']))

        if 'network' in config:
            errors.extend(ValidationService._validate_network(config['network']))

        if 'dns' in config:
            errors.extend(ValidationService._validate_dns(config['dns']))

        if 'services' in config:
            errors.extend(ValidationService._validate_services(config['services']))

        if 'backups' in config:
            errors.extend(ValidationService._validate_backups(config['backups']))

        if 'storage' in config:
            errors.extend(ValidationService._validate_storage(
                config['storage'], config.get('mounts')))

        return len(errors) == 0, errors

    @staticmethod
    def _validate_system(system_config: Dict[str, Any]) -> List[str]:
        """Validate system configuration"""
        errors = []

        # Validate hostname
        if 'hostName' in system_config:
            hostname = system_config['hostName']
            if not hostname:
                errors.append("Hostname cannot be empty")
            elif not re.match(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$', hostname, re.IGNORECASE):
                errors.append(f"Invalid hostname: {hostname}. Must be alphanumeric with optional hyphens")

        # Validate domain
        if 'domain' in system_config:
            domain = system_config['domain']
            if domain and not re.match(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$', domain, re.IGNORECASE):
                errors.append(f"Invalid domain: {domain}")

        # Validate timezone
        if 'timeZone' in system_config:
            timezone = system_config['timeZone']
            if not timezone:
                errors.append("Timezone cannot be empty")

        # Validate locale
        if 'defaultLocale' in system_config:
            locale = system_config['defaultLocale']
            if locale and not re.match(r'^[a-z]{2}_[A-Z]{2}\.[A-Z0-9-]+$', locale):
                errors.append(f"Invalid locale format: {locale}. Expected format: en_US.UTF-8")

        # Validate username
        if 'adminUsername' in system_config:
            username = system_config['adminUsername']
            if not username:
                errors.append("Admin username cannot be empty")
            elif not re.match(r'^[a-z_]([a-z0-9_-]{0,31}|[a-z0-9_-]{0,30}\$)$', username):
                errors.append(f"Invalid username: {username}. Must start with letter or underscore")

        return errors

    @staticmethod
    def _validate_network(network_config: Dict[str, Any]) -> List[str]:
        """Validate network configuration"""
        errors = []

        # Validate interfaces
        if 'wan-interface' in network_config:
            if not network_config['wan-interface']:
                errors.append("WAN interface cannot be empty")

        if 'lan-interface' in network_config:
            if not network_config['lan-interface']:
                errors.append("LAN interface cannot be empty")

        # Check for same interface
        if ('wan-interface' in network_config and 'lan-interface' in network_config):
            if network_config['wan-interface'] == network_config['lan-interface']:
                errors.append("WAN and LAN interfaces must be different")

        # Validate IP addresses
        if 'lan-address' in network_config:
            try:
                ipaddress.ip_address(network_config['lan-address'])
            except ValueError:
                errors.append(f"Invalid LAN address: {network_config['lan-address']}")

        # Validate subnet
        if 'lan-subnet' in network_config:
            try:
                network = ipaddress.ip_network(network_config['lan-subnet'])
            except ValueError:
                errors.append(f"Invalid LAN subnet: {network_config['lan-subnet']}")

        # Validate DHCP range
        if 'dhcp-range-start' in network_config and 'dhcp-range-end' in network_config:
            try:
                start_ip = ipaddress.ip_address(network_config['dhcp-range-start'])
                end_ip = ipaddress.ip_address(network_config['dhcp-range-end'])

                if start_ip >= end_ip:
                    errors.append("DHCP range start must be less than end")

                # Validate range is within subnet
                if 'lan-subnet' in network_config:
                    subnet = ipaddress.ip_network(network_config['lan-subnet'])
                    if start_ip not in subnet or end_ip not in subnet:
                        errors.append("DHCP range must be within LAN subnet")

            except ValueError as e:
                errors.append(f"Invalid DHCP range: {e}")

        # Validate guest networks (VLANs) — must run BEFORE static-ips so
        # static-ips can cross-reference the validated guest-network list
        # and pick the right per-network subnet for the in-subnet check.
        guest_networks = network_config.get('guest-networks', []) or []
        if guest_networks:
            errors.extend(ValidationService._validate_guest_networks(
                guest_networks,
                network_config.get('lan-subnet')
            ))

        # Validate static IPs
        if 'static-ips' in network_config:
            errors.extend(ValidationService._validate_static_ips(
                network_config['static-ips'],
                network_config.get('lan-subnet'),
                guest_networks,
            ))

        # Validate bitrates
        for field in ['wan-bitrate-mbps-down', 'wan-bitrate-mbps-up']:
            if field in network_config and network_config[field] is not None:
                if not isinstance(network_config[field], int) or network_config[field] <= 0:
                    errors.append(f"{field} must be a positive integer")

        return errors

    @staticmethod
    def _validate_guest_networks(guest_networks: List[Dict[str, Any]],
                                 lan_subnet: str = None) -> List[str]:
        """Validate guest-network (VLAN) configurations."""
        errors = []
        seen_ids = set()
        seen_vlan_ids = set()
        seen_names = set()
        parsed_subnets = []
        lan_net = None
        if lan_subnet:
            try:
                lan_net = ipaddress.ip_network(lan_subnet)
            except ValueError:
                pass

        for idx, gn in enumerate(guest_networks):
            prefix = f"Guest network #{idx + 1}"

            gn_id = gn.get('id', '')
            if not gn_id:
                errors.append(f"{prefix}: id required")
            elif not re.match(r'^[a-z0-9]([a-z0-9-]{0,13}[a-z0-9])?$', gn_id):
                # Kernel ifname limit is 15 chars; constrain slug accordingly.
                errors.append(f"{prefix}: invalid id '{gn_id}' "
                              f"(lowercase letters/digits/hyphens, max 15 chars)")
            elif gn_id in seen_ids:
                errors.append(f"{prefix}: duplicate id '{gn_id}'")
            else:
                seen_ids.add(gn_id)

            name = gn.get('name', '')
            if not name:
                errors.append(f"{prefix}: name required")
            elif name in seen_names:
                errors.append(f"{prefix}: duplicate name '{name}'")
            else:
                seen_names.add(name)

            vlan_id = gn.get('vlan-id')
            if not isinstance(vlan_id, int) or vlan_id < 1 or vlan_id > 4094:
                errors.append(f"{prefix}: vlan-id must be an integer 1-4094")
            elif vlan_id in seen_vlan_ids:
                errors.append(f"{prefix}: duplicate vlan-id {vlan_id}")
            else:
                seen_vlan_ids.add(vlan_id)

            subnet_str = gn.get('subnet', '')
            this_net = None
            try:
                this_net = ipaddress.ip_network(subnet_str, strict=True)
            except (ValueError, TypeError):
                errors.append(f"{prefix}: invalid subnet '{subnet_str}'")

            # Subnet must not overlap main LAN or any earlier guest subnet.
            if this_net is not None:
                if lan_net is not None and this_net.overlaps(lan_net):
                    errors.append(f"{prefix}: subnet {subnet_str} overlaps "
                                  f"main LAN {lan_subnet}")
                for other_id, other_net in parsed_subnets:
                    if this_net.overlaps(other_net):
                        errors.append(f"{prefix}: subnet {subnet_str} overlaps "
                                      f"guest network '{other_id}' ({other_net})")
                parsed_subnets.append((gn_id or f"#{idx + 1}", this_net))

            # Gateway must lie inside the subnet.
            gateway = gn.get('gateway', '')
            if this_net is not None and gateway:
                try:
                    gw_ip = ipaddress.ip_address(gateway)
                    if gw_ip not in this_net:
                        errors.append(f"{prefix}: gateway {gateway} is not in "
                                      f"subnet {subnet_str}")
                except ValueError:
                    errors.append(f"{prefix}: invalid gateway '{gateway}'")
            elif not gateway:
                errors.append(f"{prefix}: gateway required")

            # DHCP range must lie inside the subnet, start < end.
            start = gn.get('dhcp-range-start', '')
            end = gn.get('dhcp-range-end', '')
            try:
                start_ip = ipaddress.ip_address(start) if start else None
                end_ip = ipaddress.ip_address(end) if end else None
                if start_ip is None or end_ip is None:
                    errors.append(f"{prefix}: dhcp-range-start and "
                                  f"dhcp-range-end required")
                else:
                    if start_ip >= end_ip:
                        errors.append(f"{prefix}: dhcp-range-start must be "
                                      f"less than dhcp-range-end")
                    if this_net is not None and (
                            start_ip not in this_net or end_ip not in this_net):
                        errors.append(f"{prefix}: DHCP range must be inside "
                                      f"subnet {subnet_str}")
            except ValueError as e:
                errors.append(f"{prefix}: invalid DHCP range: {e}")

        return errors

    @staticmethod
    def _validate_static_ips(static_ips: List[Dict[str, Any]],
                             lan_subnet: str = None,
                             guest_networks: List[Dict[str, Any]] = None) -> List[str]:
        """Validate static IP configurations.

        Each static-ip may carry a `network` field pointing at a
        guest-network id; when set, the IP must lie in that network's
        subnet rather than the main LAN subnet.
        """
        errors = []
        seen_macs = set()
        seen_ips = set()
        seen_hostnames = set()

        subnet = None
        if lan_subnet:
            try:
                subnet = ipaddress.ip_network(lan_subnet)
            except ValueError:
                pass

        # Index guest-network subnets by id for cross-reference. Skip
        # entries with no/empty id — _validate_guest_networks already
        # flags those as errors.
        gn_subnets: Dict[str, Any] = {}
        for gn in (guest_networks or []):
            gn_id = gn.get('id')
            if not gn_id:
                continue
            try:
                gn_subnets[gn_id] = ipaddress.ip_network(gn.get('subnet', ''))
            except (ValueError, TypeError):
                pass

        for idx, ip_config in enumerate(static_ips):
            prefix = f"Static IP #{idx + 1}"

            # Validate MAC address
            mac = ip_config.get('mac-address', '')
            if not mac:
                errors.append(f"{prefix}: MAC address required")
            elif not re.match(r'^([0-9a-f]{2}:){5}[0-9a-f]{2}$', mac, re.IGNORECASE):
                errors.append(f"{prefix}: Invalid MAC address format: {mac}")
            elif mac.lower() in seen_macs:
                errors.append(f"{prefix}: Duplicate MAC address: {mac}")
            else:
                seen_macs.add(mac.lower())

            # Validate hostname
            hostname = ip_config.get('hostname', '')
            if not hostname:
                errors.append(f"{prefix}: Hostname required")
            elif not re.match(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$', hostname, re.IGNORECASE):
                errors.append(f"{prefix}: Invalid hostname: {hostname}")
            elif hostname.lower() in seen_hostnames:
                errors.append(f"{prefix}: Duplicate hostname: {hostname}")
            else:
                seen_hostnames.add(hostname.lower())

            # Resolve target subnet — guest-network if assigned, else main LAN.
            network_id = ip_config.get('network')
            if network_id:
                if network_id not in gn_subnets:
                    errors.append(f"{prefix}: references unknown guest network "
                                  f"'{network_id}'")
                    target_subnet = None
                    target_subnet_label = None
                else:
                    target_subnet = gn_subnets[network_id]
                    target_subnet_label = f"guest network '{network_id}' " \
                                          f"({target_subnet})"
            else:
                target_subnet = subnet
                target_subnet_label = f"LAN subnet {lan_subnet}" if subnet else None

            # Validate IP address
            ip = ip_config.get('ip', '')
            if not ip:
                errors.append(f"{prefix}: IP address required")
            else:
                try:
                    ip_addr = ipaddress.ip_address(ip)

                    # Check for duplicates
                    if ip in seen_ips:
                        errors.append(f"{prefix}: Duplicate IP address: {ip}")
                    else:
                        seen_ips.add(ip)

                    # Check if in the right subnet (main LAN or assigned guest)
                    if target_subnet and ip_addr not in target_subnet:
                        errors.append(f"{prefix}: IP {ip} is not in "
                                      f"{target_subnet_label}")

                except ValueError:
                    errors.append(f"{prefix}: Invalid IP address: {ip}")

        return errors

    @staticmethod
    def _validate_dns(dns_config: Dict[str, Any]) -> List[str]:
        """Validate DNS configuration"""
        errors = []

        if 'overrides' in dns_config:
            for idx, override in enumerate(dns_config['overrides']):
                prefix = f"DNS Override #{idx + 1}"

                # Validate hostname
                if not override.get('hostname'):
                    errors.append(f"{prefix}: Hostname required")

                # Validate domain
                if not override.get('domain'):
                    errors.append(f"{prefix}: Domain required")

                # Validate IP
                ip = override.get('ip', '')
                if not ip:
                    errors.append(f"{prefix}: IP address required")
                else:
                    try:
                        ipaddress.ip_address(ip)
                    except ValueError:
                        errors.append(f"{prefix}: Invalid IP address: {ip}")

        return errors

    @staticmethod
    def _validate_services(services_config: Dict[str, Dict[str, Any]]) -> List[str]:
        """Validate services configuration"""
        errors = []

        # Basic validation - ensure enable/public are boolean
        for service_name, service_settings in services_config.items():
            if 'enable' in service_settings:
                if not isinstance(service_settings['enable'], bool):
                    errors.append(f"Service {service_name}: enable must be boolean")

            if 'public' in service_settings:
                if not isinstance(service_settings['public'], bool):
                    errors.append(f"Service {service_name}: public must be boolean")

        return errors

    @staticmethod
    def _validate_backups(backups_config: Dict[str, Any]) -> List[str]:
        """Validate backups configuration"""
        errors = []

        # Only validate if backups are enabled
        if not backups_config.get('enable', False):
            return errors

        # Validate backup path when backups are enabled
        if 'to-path' in backups_config:
            path = backups_config['to-path']
            if not path:
                errors.append("Backup path cannot be empty when backups are enabled")
            elif not path.startswith('/'):
                errors.append(f"Backup path must be absolute: {path}")
        else:
            errors.append("Backup path is required when backups are enabled")

        # Validate Backblaze config
        if backups_config.get('backblaze-enable'):
            if not backups_config.get('backblaze-bucket'):
                errors.append("Backblaze bucket required when Backblaze backups are enabled")

        return errors

    @staticmethod
    def _validate_storage(storage_config: Dict[str, Any],
                          mounts_config: List[Dict[str, Any]] = None) -> List[str]:
        """Validate the storage.pools section. Pools are created by the admin
        backend, but a hand-edited or stale homefree-config.json could carry a
        malformed pool — catch it before it reaches a rebuild (mounting a bogus
        pool, or two pools fighting for one mount point)."""
        errors = []
        pools = storage_config.get('pools') or []
        valid_profiles = {'single': 1, 'raid0': 2, 'raid1': 2, 'raid10': 4,
                          'raid5': 3, 'raid6': 4}

        seen_names = set()
        seen_mounts = set()
        network_mounts = {m.get('mount-point') for m in (mounts_config or [])}

        for p in pools:
            name = p.get('name')
            mountpoint = p.get('mountpoint')
            profile = p.get('profile')
            members = p.get('members') or []

            if not name:
                errors.append("Storage volume name cannot be empty")
            elif name in seen_names:
                errors.append(f"Duplicate storage volume name: {name}")
            seen_names.add(name)

            if not mountpoint or not str(mountpoint).startswith('/'):
                errors.append(f"Storage volume '{name}': mount point must be an absolute path")
            else:
                if mountpoint in seen_mounts:
                    errors.append(f"Duplicate storage volume mount point: {mountpoint}")
                if mountpoint in network_mounts:
                    errors.append(f"Storage volume '{name}': mount point {mountpoint} "
                                  f"collides with a network mount")
                seen_mounts.add(mountpoint)

            need = valid_profiles.get(profile)
            if need is None:
                errors.append(f"Storage volume '{name}': unsupported profile '{profile}'")
            elif profile == 'single' and len(members) != 1:
                errors.append(f"Storage volume '{name}': a single volume uses exactly one drive")
            elif len(members) < need:
                errors.append(f"Storage volume '{name}': {profile} needs at least {need} drives")
            elif profile == 'raid10' and len(members) % 2:
                errors.append(f"Storage volume '{name}': raid10 needs an even number of drives")

            for m in members:
                if not m or '/' in m:
                    errors.append(f"Storage volume '{name}': members must be bare "
                                  f"/dev/disk/by-id names (no '/')")
                    break

            if not p.get('fs-uuid'):
                errors.append(f"Storage volume '{name}': missing fs-uuid")

            if p.get('encrypted'):
                mappers = p.get('luks-mappers') or []
                is_parity = profile in ('raid5', 'raid6')
                # btrfs-native = per-disk LUKS (one mapper per member); parity =
                # LUKS-on-md (one mapper for the assembled array).
                expected = 1 if is_parity else len(members)
                if len(mappers) != expected:
                    errors.append(
                        f"Storage volume '{name}': encrypted {profile} expects "
                        f"{expected} luks-mapper "
                        f"{'entry' if expected == 1 else 'entries'}, "
                        f"got {len(mappers)}")
                seen_mappers = set()
                for m in mappers:
                    mn = m.get('mapper') if isinstance(m, dict) else None
                    by_id = m.get('by-id') if isinstance(m, dict) else None
                    luks_uuid = m.get('luks-uuid') if isinstance(m, dict) else None
                    if not (mn and by_id and luks_uuid):
                        errors.append(
                            f"Storage volume '{name}': luks-mapper entry missing "
                            f"mapper / by-id / luks-uuid")
                        continue
                    if '/' in mn:
                        errors.append(
                            f"Storage volume '{name}': luks mapper name "
                            f"'{mn}' must not contain '/'")
                    if mn in seen_mappers:
                        errors.append(
                            f"Storage volume '{name}': duplicate luks mapper "
                            f"name '{mn}'")
                    seen_mappers.add(mn)

        # NFS shares (Phase 2a): host/subnet-trust exports.
        import ipaddress
        seen_share_names = set()
        for sh in (storage_config.get('shares') or []):
            sname = sh.get('name')
            spath = sh.get('path')
            if not sname:
                errors.append("NFS share name cannot be empty")
            elif sname in seen_share_names:
                errors.append(f"Duplicate NFS share name: {sname}")
            seen_share_names.add(sname)
            if not spath or not str(spath).startswith('/'):
                errors.append(f"NFS share '{sname}': path must be an absolute path")
            for tok in (sh.get('allowed') or '').replace(',', ' ').split():
                try:
                    ipaddress.ip_network(tok, strict=False)
                except ValueError:
                    errors.append(f"NFS share '{sname}': '{tok}' is not a valid IP or CIDR")

        return errors

    @staticmethod
    def check_network_change_warning(old_config: Dict[str, Any], new_config: Dict[str, Any]) -> List[str]:
        """
        Check if network changes could cause connectivity loss.

        Returns:
            List of warning messages
        """
        warnings = []

        # Check for interface changes
        if old_config.get('wan-interface') != new_config.get('wan-interface'):
            warnings.append(
                "⚠️ WARNING: Changing WAN interface may cause loss of internet connectivity. "
                "Ensure you have console access to the system."
            )

        if old_config.get('lan-interface') != new_config.get('lan-interface'):
            warnings.append(
                "⚠️ WARNING: Changing LAN interface may cause loss of local network connectivity. "
                "Ensure you have console access to the system."
            )

        # Check for LAN address changes
        if old_config.get('lan-address') != new_config.get('lan-address'):
            warnings.append(
                "⚠️ WARNING: Changing LAN address will disconnect current admin session. "
                "You will need to reconnect at the new address."
            )

        # Check for subnet changes
        if old_config.get('lan-subnet') != new_config.get('lan-subnet'):
            warnings.append(
                "⚠️ WARNING: Changing LAN subnet will affect all connected devices. "
                "They will need to obtain new IP addresses."
            )

        return warnings
