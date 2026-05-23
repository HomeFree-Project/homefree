"""
Config writer service - updates NixOS configuration files
"""

from pathlib import Path
from typing import Dict, Any, List, Optional, Tuple
import logging
import shutil
import json
import os
import stat
import tempfile
from datetime import datetime
from services.secrets_manager import SecretsManager

logger = logging.getLogger(__name__)


class ConfigWriter:
    """Service for writing NixOS configuration files"""

    CONFIG_FILE = Path("/etc/nixos/homefree-config.json")
    BACKUP_DIR = Path("/var/lib/homefree-admin/config-backups")

    @staticmethod
    def write_config(config: Dict[str, Any]) -> bool:
        """
        Write configuration changes to homefree-config.json

        Args:
            config: Configuration dictionary with new values

        Returns:
            True if successful, False otherwise
        """
        if not ConfigWriter.CONFIG_FILE.exists():
            logger.error(f"Config file not found: {ConfigWriter.CONFIG_FILE}")
            return False

        try:
            # Backup current config
            ConfigWriter._backup_config()

            # Read current config
            current_config = json.loads(ConfigWriter.CONFIG_FILE.read_text())

            # Update each section (deep merge)
            if 'system' in config:
                current_config['system'].update(config['system'])

            if 'network' in config:
                current_config['network'].update(config['network'])

            if 'dns' in config:
                current_config['dns'].update(config['dns'])

            if 'services' in config:
                # Special services that shouldn't be saved to config (no user-configurable options)
                # admin-api is for monitoring only and has no config options
                special_services = {'admin-api'}

                # Load service options schema to identify multi-instance services
                schema_file = Path("/run/homefree/admin/service-options-schema.json")
                options_schema = {}
                if schema_file.exists():
                    with open(schema_file, 'r') as f:
                        options_schema = json.load(f)

                # Merge services - add new ones, update existing ones
                # Filter out special services that aren't configurable
                for service_name, service_config in config['services'].items():
                    if service_name in special_services:
                        continue  # Skip special services

                    # Check if this is a multi-instance service entry (format: parent_subdomain)
                    if '_' in service_name:
                        parts = service_name.split('_', 1)
                        parent_service = parts[0]
                        instance_subdomain = parts[1]

                        # Check if parent service has instances option
                        if parent_service in options_schema:
                            parent_options = options_schema[parent_service]
                            if 'instances' in parent_options and parent_options['instances'].get('type', '').startswith('listOf'):
                                # This is a multi-instance service - update the instances array
                                if parent_service not in current_config['services']:
                                    current_config['services'][parent_service] = {}
                                if 'instances' not in current_config['services'][parent_service]:
                                    current_config['services'][parent_service]['instances'] = []

                                # Find the instance in the array by subdomain
                                instances = current_config['services'][parent_service]['instances']
                                instance_index = next((i for i, inst in enumerate(instances) if inst.get('subdomain') == instance_subdomain), -1)

                                if instance_index >= 0:
                                    # Update existing instance
                                    instances[instance_index].update(service_config)
                                else:
                                    # New instance - add to array
                                    instances.append({
                                        'subdomain': instance_subdomain,
                                        **service_config
                                    })
                                continue  # Skip normal service update

                    # Regular single-instance service
                    if service_name not in current_config['services']:
                        current_config['services'][service_name] = {}
                    current_config['services'][service_name].update(service_config)

            if 'backups' in config:
                current_config['backups'].update(config['backups'])

            # External Proxies (`service-config`), whole-domain transparent
            # proxies (`proxied-domains`), and network/local mounts
            # (`mounts`) are edited as whole arrays by the admin UI. Unlike
            # `developers` below they have no competing on-disk writer, and
            # the frontend always sends the full array (sourced from the
            # fresh on-disk config when unedited), so a whole-array replace
            # is correct and cannot resurrect deleted rows. Without this,
            # deletions and edits on those pages are silently dropped — the
            # row reappears (or the change vanishes) after a page reload.
            if 'service-config' in config:
                current_config['service-config'] = config['service-config']

            if 'proxied-domains' in config:
                current_config['proxied-domains'] = config['proxied-domains']

            if 'mounts' in config:
                current_config['mounts'] = config['mounts']

            # Storage pools (Storage admin module). Same whole-array-replace
            # rationale as `mounts` above: the frontend sends the full pools
            # list and the pool-create job writes the full list, so a replace
            # is correct and cannot resurrect a forgotten pool.
            if 'storage' in config:
                current_config['storage'] = config['storage']

            # Snapshots (System / per-volume snapshot toggle). The Storage
            # admin module emits the WHOLE snapshots object (spreading the
            # current one) so a partial replace is correct here too. Without
            # this branch, the snapshots key in the payload was silently
            # dropped — making the System Snapshots checkbox a no-op on
            # disk and flickering the "Configuration changed" notice
            # (success → checkConfigDirty re-fetched a clean disk → false).
            if 'snapshots' in config:
                current_config['snapshots'] = config['snapshots']

            # NOTE: the `developers` section (registered custom flakes) is
            # deliberately NOT written here. It is owned exclusively by
            # DevelopersService, which writes it via its own endpoints and
            # keeps /etc/nixos/flake.nix + custom-flakes.nix in sync with
            # it. The generic /api/config/save and /api/config/apply paths
            # POST the frontend's whole pendingConfig blob — which carries
            # a `developers` snapshot taken at page load. If we wrote that
            # here, a flake removed via the Developers page would be
            # resurrected by the next Apply (stale snapshot clobbers the
            # fresh on-disk list). `current_config` is read fresh from
            # disk above, so simply not touching `developers` preserves
            # whatever DevelopersService last wrote.

            # Write SOPS-managed secrets from plaintext values to SOPS
            success, error = ConfigWriter._write_sops_managed_secrets(current_config)
            if not success:
                logger.warning(f"Failed to write secrets to SOPS: {error}")
                # Continue anyway - secrets might not be configured yet

            # Extract secrets from SOPS to files and inject paths
            success, error = ConfigWriter._inject_secret_paths(current_config)
            if not success:
                logger.warning(f"Failed to write secret files: {error}")
                # Continue anyway - secrets might not be configured yet

            # Write updated config with pretty formatting, ATOMICALLY. The
            # admin UI now polls /api/config/current while this runs; a plain
            # write_text() truncates-then-writes, so a concurrent reader could
            # observe an empty/partial file and report a bogus parse error (and
            # a crash mid-write would corrupt the source-of-truth config).
            ConfigWriter._atomic_write(
                json.dumps(current_config, indent=2, sort_keys=False) + '\n'
            )
            logger.info("Configuration file updated successfully")
            return True

        except Exception as e:
            logger.error(f"Error writing config file: {e}")
            return False

    @staticmethod
    def _atomic_write(text: str):
        """
        Write CONFIG_FILE atomically: write a sibling temp file, fsync it, then
        os.replace() (an atomic rename on the same filesystem). A concurrent
        reader therefore always sees either the old or the new complete file,
        never a torn half-write. The new file's mode is matched to the old
        one's so permissions don't silently change.
        """
        target = ConfigWriter.CONFIG_FILE
        mode = None
        if target.exists():
            mode = stat.S_IMODE(os.stat(target).st_mode)

        fd, tmp = tempfile.mkstemp(
            dir=str(target.parent), prefix=".homefree-config.", suffix=".tmp"
        )
        try:
            with os.fdopen(fd, "w") as f:
                f.write(text)
                f.flush()
                os.fsync(f.fileno())
            if mode is not None:
                os.chmod(tmp, mode)
            os.replace(tmp, target)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    @staticmethod
    def _backup_config():
        """Create a timestamped backup of the current config"""
        try:
            ConfigWriter.BACKUP_DIR.mkdir(parents=True, exist_ok=True)
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            backup_file = ConfigWriter.BACKUP_DIR / f"homefree-config.{timestamp}.json"
            shutil.copy2(ConfigWriter.CONFIG_FILE, backup_file)
            logger.info(f"Config backed up to: {backup_file}")
        except Exception as e:
            logger.warning(f"Failed to backup config: {e}")

    @staticmethod
    def _write_sops_managed_secrets(config: Dict[str, Any]) -> Tuple[bool, Optional[str]]:
        """
        Write SOPS-managed secrets from config to encrypted SOPS storage.

        For secrets marked as sops-managed in the schema, this function:
        1. Detects plaintext secret values in the config
        2. Writes them to encrypted SOPS storage
        3. Leaves path-based secrets untouched (user-managed)

        Args:
            config: The configuration dictionary containing secret values

        Returns:
            Tuple of (success, error_message)
        """
        try:
            logger.info("_write_sops_managed_secrets() called")
            # Load service options schema to identify SOPS-managed secrets
            schema_file = Path("/run/homefree/admin/service-options-schema.json")
            if not schema_file.exists():
                logger.warning("Service options schema not found, skipping SOPS secret writing")
                return True, None

            with open(schema_file, 'r') as f:
                options_schema = json.load(f)

            if 'services' not in config:
                logger.info("No services in config, returning")
                return True, None

            logger.info(f"Processing {len(config['services'])} services for SOPS secrets")

            # Process each service's secrets
            for service_label, service_config in config['services'].items():
                if 'secrets' not in service_config:
                    continue

                # Check if this service has SOPS-managed secrets in the schema
                if service_label not in options_schema:
                    continue

                service_options = options_schema[service_label]
                if 'secrets' not in service_options:
                    continue

                secrets_option = service_options['secrets']

                # Only process if this is a SOPS-managed secrets field
                if not secrets_option.get('sops-managed', False):
                    continue

                # Get the secret field definitions
                secret_fields = secrets_option.get('submodule-fields', [])
                sops_managed_keys = {field['path'] for field in secret_fields if field.get('sops-managed', False)}

                # Write each SOPS-managed secret to SOPS
                for secret_key, secret_value in service_config['secrets'].items():
                    if secret_key not in sops_managed_keys:
                        continue

                    # Skip if it's already a path (starts with /)
                    if isinstance(secret_value, str) and secret_value.startswith('/'):
                        continue

                    # Skip if empty or null
                    if not secret_value:
                        continue

                    # This is a plaintext value that needs to be written to SOPS
                    logger.info(f"Writing SOPS-managed secret: {service_label}/{secret_key}")
                    success, error = SecretsManager.set_secret(service_label, secret_key, secret_value)
                    if not success:
                        logger.error(f"Failed to write secret {service_label}/{secret_key} to SOPS: {error}")
                        return False, f"Failed to write secret {service_label}/{secret_key}: {error}"

                    # Write the secret to disk file
                    write_success, write_error = SecretsManager.write_secret_files()
                    if not write_success:
                        logger.warning(f"Failed to extract secret to file: {write_error}")

                    # Replace plaintext value with file path in config
                    secret_path = str(SecretsManager.get_secret_file_path(service_label, secret_key))
                    service_config['secrets'][secret_key] = secret_path
                    logger.info(f"Replaced plaintext with path: {secret_path}")

            return True, None

        except Exception as e:
            logger.error(f"Error writing SOPS-managed secrets: {e}")
            return False, str(e)

    @staticmethod
    def _inject_secret_paths(config: Dict[str, Any]) -> Tuple[bool, Optional[str]]:
        """
        Write secrets from SOPS to individual files and inject file paths into config.

        This extracts secrets from encrypted SOPS storage and writes them to
        /var/lib/homefree-secrets/{service}/{secret-key}, then auto-populates
        the config with these paths so services can find the secret files.

        All directories and files are created with root-only permissions (0700/0600).

        Args:
            config: The configuration dictionary to inject paths into

        Returns:
            Tuple of (success, error_message)
        """
        try:
            # Write all secrets from SOPS to individual files
            success, error = SecretsManager.write_secret_files()
            if not success:
                return False, error

            # Get secrets schema to know what secrets each service needs
            secrets_schema = SecretsManager.get_schema()

            # Get secrets status to know which secrets are actually set
            secrets_status = SecretsManager.get_secrets_status()

            # Inject secret paths into config for each service
            if 'services' in config:
                for service_label, service_config in config['services'].items():
                    # Check if this service has secrets defined
                    if service_label not in secrets_schema:
                        continue

                    # Ensure secrets section exists in config
                    if 'secrets' not in service_config:
                        service_config['secrets'] = {}

                    # Get this service's secrets
                    service_secrets = secrets_schema.get(service_label, {})
                    service_status = secrets_status.get(service_label, {})

                    # Inject path for each secret that is actually set
                    for secret_key in service_secrets.keys():
                        # Only inject path if the secret is actually set (not empty)
                        if service_status.get(secret_key, False):
                            secret_path = str(SecretsManager.get_secret_file_path(service_label, secret_key))
                            service_config['secrets'][secret_key] = secret_path
                            logger.debug(f"Injected secret path for {service_label}/{secret_key}: {secret_path}")

            return True, None

        except Exception as e:
            logger.error(f"Error injecting secret paths: {e}")
            return False, str(e)
