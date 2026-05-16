"""
Secrets Manager Service

Handles encryption and management of secrets using sops-nix with SSH keys.
Uses system SSH host key and user SSH public key for encryption.
"""

import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Dict, List, Optional, Tuple
import yaml


# File paths
CONFIG_FILE = Path("/etc/nixos/homefree-config.json")
SECRETS_DIR = Path("/etc/nixos/secrets")
SECRETS_FILE = SECRETS_DIR / "secrets.yaml"
SOPS_CONFIG_FILE = Path("/etc/nixos/.sops.yaml")
SYSTEM_SSH_HOST_KEY_DIR = Path("/etc/ssh")
SYSTEM_SSH_PRIVATE_KEY = SYSTEM_SSH_HOST_KEY_DIR / "ssh_host_ed25519_key"


class SecretsManager:
    """Manages secrets encryption and storage using sops"""

    @staticmethod
    def get_system_ssh_public_key() -> Optional[str]:
        """
        Get the system SSH host public key (ed25519)

        Returns:
            SSH public key string or None if not found
        """
        key_path = SYSTEM_SSH_HOST_KEY_DIR / "ssh_host_ed25519_key.pub"

        if not key_path.exists():
            return None

        try:
            with open(key_path, 'r') as f:
                return f.read().strip()
        except Exception as e:
            print(f"Error reading system SSH public key: {e}")
            return None

    @staticmethod
    def get_user_ssh_public_key() -> Optional[str]:
        """
        Get the user SSH public key from homefree config
        Uses the first authorized key

        Returns:
            User SSH public key or None if not configured
        """
        if not CONFIG_FILE.exists():
            return None

        try:
            with open(CONFIG_FILE, 'r') as f:
                config = json.load(f)

            authorized_keys = config.get('system', {}).get('authorizedKeys', [])
            # Use the first authorized key for secrets encryption
            return authorized_keys[0] if authorized_keys else None
        except Exception as e:
            print(f"Error reading user SSH public key from config: {e}")
            return None

    @staticmethod
    def validate_ssh_public_key(key: str) -> Tuple[bool, Optional[str]]:
        """
        Validate SSH public key format

        Args:
            key: SSH public key string

        Returns:
            Tuple of (is_valid, error_message)
        """
        if not key or not key.strip():
            return False, "Key cannot be empty"

        key = key.strip()
        parts = key.split()

        if len(parts) < 2:
            return False, "Invalid SSH key format"

        key_type = parts[0]
        if key_type not in ['ssh-rsa', 'ssh-ed25519', 'ssh-dss', 'ecdsa-sha2-nistp256',
                            'ecdsa-sha2-nistp384', 'ecdsa-sha2-nistp521']:
            return False, f"Unsupported key type: {key_type}"

        return True, None

    @staticmethod
    def ensure_secrets_dir():
        """Ensure secrets directory exists with proper permissions"""
        SECRETS_DIR.mkdir(parents=True, exist_ok=True)
        os.chmod(SECRETS_DIR, 0o700)

    @staticmethod
    def ssh_to_age(ssh_public_key: str) -> Optional[str]:
        """
        Convert SSH public key to age public key format

        Args:
            ssh_public_key: SSH public key string

        Returns:
            age public key string or None on error
        """
        try:
            result = subprocess.run(
                ['ssh-to-age'],
                input=ssh_public_key,
                capture_output=True,
                text=True,
                check=True
            )
            return result.stdout.strip()
        except Exception as e:
            print(f"Error converting SSH key to age: {e}")
            return None

    @staticmethod
    def ssh_private_to_age(ssh_private_key_path: Path) -> Optional[str]:
        """
        Convert SSH private key to age private key format

        Args:
            ssh_private_key_path: Path to SSH private key file

        Returns:
            age private key string or None on error
        """
        try:
            with open(ssh_private_key_path, 'r') as f:
                result = subprocess.run(
                    ['ssh-to-age', '-private-key'],
                    input=f.read(),
                    capture_output=True,
                    text=True,
                    check=True
                )
            return result.stdout.strip()
        except Exception as e:
            print(f"Error converting SSH private key to age: {e}")
            return None

    @staticmethod
    def create_sops_config(system_key: str, user_key: Optional[str] = None):
        """
        Create or update .sops.yaml configuration file

        Args:
            system_key: System SSH host public key
            user_key: Optional user SSH public key
        """
        # Convert SSH keys to age format
        age_keys = []

        system_age_key = SecretsManager.ssh_to_age(system_key)
        if system_age_key:
            age_keys.append(system_age_key)

        if user_key:
            user_age_key = SecretsManager.ssh_to_age(user_key)
            if user_age_key:
                age_keys.append(user_age_key)

        if not age_keys:
            raise Exception("Failed to convert any SSH keys to age format")

        sops_config = {
            'creation_rules': [
                {
                    'path_regex': r'.*/secrets/.*\.yaml$',
                    'age': ','.join(age_keys)
                }
            ]
        }

        with open(SOPS_CONFIG_FILE, 'w') as f:
            yaml.dump(sops_config, f, default_flow_style=False)

        os.chmod(SOPS_CONFIG_FILE, 0o600)

    @staticmethod
    def get_secrets_status(service_label: Optional[str] = None) -> Dict[str, Dict[str, bool]]:
        """
        Get status of which secrets exist for services

        Args:
            service_label: Optional service label to filter. If None, return all services.

        Returns:
            Dict mapping service labels to dict of secret keys and their existence status
            Example: {"vaultwarden": {"adminToken": True, "smtpPassword": False}}
        """
        if not SECRETS_FILE.exists():
            return {}

        try:
            # Read encrypted secrets file with sops
            # Convert SSH private key to age format for decryption
            age_private_key = SecretsManager.ssh_private_to_age(SYSTEM_SSH_PRIVATE_KEY)
            if not age_private_key:
                print("Failed to convert system SSH private key to age format")
                return {}

            env = os.environ.copy()
            env['SOPS_AGE_KEY'] = age_private_key

            result = subprocess.run(
                ['sops', '--config', str(SOPS_CONFIG_FILE), '--decrypt', str(SECRETS_FILE)],
                capture_output=True,
                text=True,
                check=True,
                env=env
            )

            secrets_data = yaml.safe_load(result.stdout) or {}

            # Convert flat structure to nested
            status = {}
            for key, value in secrets_data.items():
                if '/' in key:
                    service, secret_key = key.split('/', 1)
                    if service_label and service != service_label:
                        continue
                    if service not in status:
                        status[service] = {}
                    status[service][secret_key] = value is not None and value != ""

            return status if not service_label else status.get(service_label, {})

        except subprocess.CalledProcessError as e:
            print(f"Error decrypting secrets file: {e.stderr}")
            return {}
        except Exception as e:
            print(f"Error reading secrets status: {e}")
            return {}

    @staticmethod
    def set_secret(service_label: str, secret_key: str, secret_value: str) -> Tuple[bool, Optional[str]]:
        """
        Set a secret value for a service

        Args:
            service_label: Service identifier (e.g., "vaultwarden")
            secret_key: Secret key name (e.g., "adminToken")
            secret_value: The secret value to store

        Returns:
            Tuple of (success, error_message)
        """
        # Validate keys exist
        system_key = SecretsManager.get_system_ssh_public_key()
        if not system_key:
            return False, "System SSH host key not found"

        user_key = SecretsManager.get_user_ssh_public_key()
        if not user_key:
            return False, "No SSH authorized keys configured. Please add an SSH key in System settings to manage secrets."

        # Convert SSH keys to age format
        system_age_key = SecretsManager.ssh_to_age(system_key)
        if not system_age_key:
            return False, "Failed to convert system SSH key to age format"

        age_recipients = [system_age_key]

        # Try to convert user key, but don't fail if it's not ed25519
        user_age_key = SecretsManager.ssh_to_age(user_key)
        if user_age_key:
            age_recipients.append(user_age_key)
        else:
            print(f"Warning: User SSH key is not ed25519, skipping. Only ed25519 keys are supported for secrets encryption.")

        age_recipients_str = ','.join(age_recipients)

        # Ensure infrastructure exists
        SecretsManager.ensure_secrets_dir()
        SecretsManager.create_sops_config(system_key, user_key)

        # Key format for sops: service/secretKey
        sops_key = f"{service_label}/{secret_key}"

        try:
            # Initialize secrets file if it doesn't exist
            if not SECRETS_FILE.exists():
                with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False) as tmp:
                    yaml.dump({}, tmp)
                    tmp_path = tmp.name

                # Encrypt empty file with sops using age recipients directly
                subprocess.run(
                    ['sops', '--age', age_recipients_str, '--encrypt', '--input-type', 'yaml', '--output-type', 'yaml',
                     '--output', str(SECRETS_FILE), tmp_path],
                    check=True,
                    capture_output=True
                )

                os.unlink(tmp_path)

            # Use sops to set the value
            # Convert SSH private key to age format and set SOPS_AGE_KEY for decryption
            age_private_key = SecretsManager.ssh_private_to_age(SYSTEM_SSH_PRIVATE_KEY)
            if not age_private_key:
                return False, "Failed to convert system SSH private key to age format"

            env = os.environ.copy()
            env['SOPS_AGE_KEY'] = age_private_key

            subprocess.run(
                ['sops', '--age', age_recipients_str, '--set', f'["{sops_key}"] "{secret_value}"', str(SECRETS_FILE)],
                check=True,
                capture_output=True,
                text=True,
                env=env
            )

            return True, None

        except subprocess.CalledProcessError as e:
            error_msg = e.stderr if e.stderr else str(e)
            return False, f"Failed to encrypt secret: {error_msg}"
        except Exception as e:
            return False, f"Error setting secret: {str(e)}"

    @staticmethod
    def delete_secret(service_label: str, secret_key: str) -> Tuple[bool, Optional[str]]:
        """
        Delete a secret value

        Args:
            service_label: Service identifier
            secret_key: Secret key name

        Returns:
            Tuple of (success, error_message)
        """
        if not SECRETS_FILE.exists():
            return True, None  # Already doesn't exist

        # Get keys for decryption
        system_key = SecretsManager.get_system_ssh_public_key()
        if not system_key:
            return False, "System SSH host key not found"

        user_key = SecretsManager.get_user_ssh_public_key()
        if not user_key:
            return False, "No SSH authorized keys configured"

        # Convert SSH keys to age format
        system_age_key = SecretsManager.ssh_to_age(system_key)
        if not system_age_key:
            return False, "Failed to convert system SSH key to age format"

        age_recipients = [system_age_key]

        # Try to convert user key, but don't fail if it's not ed25519
        user_age_key = SecretsManager.ssh_to_age(user_key)
        if user_age_key:
            age_recipients.append(user_age_key)
        else:
            print(f"Warning: User SSH key is not ed25519, skipping. Only ed25519 keys are supported for secrets encryption.")

        age_recipients_str = ','.join(age_recipients)

        sops_key = f"{service_label}/{secret_key}"

        try:
            # Use sops to delete the key
            # Convert SSH private key to age format for decryption
            age_private_key = SecretsManager.ssh_private_to_age(SYSTEM_SSH_PRIVATE_KEY)
            if not age_private_key:
                return False, "Failed to convert system SSH private key to age format"

            env = os.environ.copy()
            env['SOPS_AGE_KEY'] = age_private_key

            subprocess.run(
                ['sops', '--age', age_recipients_str, '--set', f'["{sops_key}"] null', str(SECRETS_FILE)],
                check=True,
                capture_output=True,
                text=True,
                env=env
            )

            return True, None

        except subprocess.CalledProcessError as e:
            error_msg = e.stderr if e.stderr else str(e)
            return False, f"Failed to delete secret: {error_msg}"
        except Exception as e:
            return False, f"Error deleting secret: {str(e)}"

    @staticmethod
    def get_schema() -> Dict[str, Dict[str, Dict]]:
        """
        Get secrets schema from generated JSON file

        Returns:
            Dict mapping service labels to their secret schemas
        """
        schema_file = Path("/run/homefree/admin/service-secrets-schema.json")

        if not schema_file.exists():
            return {}

        try:
            with open(schema_file, 'r') as f:
                return json.load(f)
        except Exception as e:
            print(f"Error loading secrets schema: {e}")
            return {}

    @staticmethod
    def get_instance_labels_for_service(service_name: str) -> List[str]:
        """
        Get instance labels for services that support multiple instances.

        For instance-based services (like Minecraft), returns a list of labels
        formatted as "{service}_{subdomain}" for each instance.
        For regular services, returns a list with just the service name.

        Args:
            service_name: Service name (e.g., "minecraft")

        Returns:
            List of instance labels (e.g., ["minecraft_minecraft-cisco", "minecraft_survival"])
            or just [service_name] for non-instance services
        """
        if not CONFIG_FILE.exists():
            return [service_name]

        try:
            config = json.loads(CONFIG_FILE.read_text())
            service_config = config.get('services', {}).get(service_name, {})

            # Check if service has instances
            instances = service_config.get('instances', [])
            if instances and isinstance(instances, list):
                # Return label for each instance: {service}_{subdomain}
                labels = []
                for instance in instances:
                    subdomain = instance.get('subdomain', service_name)
                    labels.append(f"{service_name}_{subdomain}")
                return labels
            else:
                # Not an instance-based service, just return service name
                return [service_name]

        except Exception as e:
            print(f"Error getting instance labels for {service_name}: {e}")
            return [service_name]

    @staticmethod
    def get_secret_file_path(service_label: str, secret_key: str) -> Path:
        """
        Get the file path where a secret should be stored.

        Secrets are written to /var/lib/homefree-secrets/ and managed by the backend.
        Format: /var/lib/homefree-secrets/{service}/{secret-key}

        Directory permissions: 0700 (root only)
        File permissions: 0600 (root only)

        Args:
            service_label: Service identifier (e.g., "minecraft")
            secret_key: Secret key name (e.g., "curseforge-api-key")

        Returns:
            Path object for the secret file
        """
        base_dir = Path("/var/lib/homefree-secrets")
        return base_dir / service_label / secret_key

    @staticmethod
    def extract_and_write_secret(service_name: str, instance_label: str, secret_key: str) -> Tuple[bool, Optional[str]]:
        """
        Extract a secret from SOPS and write it to an individual file

        Args:
            service_name: Service name for SOPS key lookup (e.g., "minecraft")
            instance_label: Instance label for file path (e.g., "minecraft_minecraft-cisco")
            secret_key: Secret key name

        Returns:
            Tuple of (success, error_message)
        """
        if not SECRETS_FILE.exists():
            return False, "Secrets file does not exist"

        try:
            # Convert SSH private key to age format for decryption
            age_private_key = SecretsManager.ssh_private_to_age(SYSTEM_SSH_PRIVATE_KEY)
            if not age_private_key:
                return False, "Failed to convert system SSH private key to age format"

            env = os.environ.copy()
            env['SOPS_AGE_KEY'] = age_private_key

            # Decrypt secrets file
            result = subprocess.run(
                ['sops', '--config', str(SOPS_CONFIG_FILE), '--decrypt', str(SECRETS_FILE)],
                capture_output=True,
                text=True,
                check=True,
                env=env
            )

            secrets_data = yaml.safe_load(result.stdout) or {}

            # Get the secret value using service name (not instance label)
            # For instance-based services, secrets are stored per service, not per instance
            sops_key = f"{service_name}/{secret_key}"
            secret_value = secrets_data.get(sops_key)

            if secret_value is None or secret_value == "":
                # Secret not set, don't create file
                return True, None

            # Get target file path using instance label
            file_path = SecretsManager.get_secret_file_path(instance_label, secret_key)

            # Create parent directory if needed. Only set the default
            # mode (0700) on initial creation; if the directory already
            # exists, the Nix module that owns the service has already
            # set the right mode (e.g. headscale's prepare-secrets unit
            # makes it 0750 root:headscale so headplane can read).
            # Unconditionally chmod-ing here would clobber that and
            # break the service on the next rebuild.
            dir_path = file_path.parent
            existed = dir_path.is_dir()
            dir_path.mkdir(parents=True, exist_ok=True)
            if not existed:
                os.chmod(dir_path, 0o700)

            # Write secret to temporary file first (atomic write)
            with tempfile.NamedTemporaryFile(mode='w', dir=file_path.parent, delete=False) as tmp:
                tmp.write(secret_value)
                tmp_path = tmp.name

            # Set proper permissions before renaming
            os.chmod(tmp_path, 0o600)

            # Atomic rename
            os.rename(tmp_path, file_path)

            return True, None

        except subprocess.CalledProcessError as e:
            return False, f"Failed to decrypt secrets: {e.stderr}"
        except Exception as e:
            return False, f"Error writing secret file: {str(e)}"

    @staticmethod
    def write_secret_files() -> Tuple[bool, Optional[str]]:
        """
        Extract all secrets from SOPS and write them to individual files.
        Creates files at /var/lib/homefree-secrets/{service}/{secret-key}

        Returns:
            Tuple of (success, error_message)
        """
        if not SECRETS_FILE.exists():
            # No secrets file means no secrets to write
            return True, None

        try:
            # Convert SSH private key to age format for decryption
            age_private_key = SecretsManager.ssh_private_to_age(SYSTEM_SSH_PRIVATE_KEY)
            if not age_private_key:
                return False, "Failed to convert system SSH private key to age format"

            env = os.environ.copy()
            env['SOPS_AGE_KEY'] = age_private_key

            # Decrypt secrets file
            result = subprocess.run(
                ['sops', '--config', str(SOPS_CONFIG_FILE), '--decrypt', str(SECRETS_FILE)],
                capture_output=True,
                text=True,
                check=True,
                env=env
            )

            secrets_data = yaml.safe_load(result.stdout) or {}

            # Write each secret to its own file
            for sops_key, secret_value in secrets_data.items():
                if '/' not in sops_key:
                    continue  # Skip malformed keys

                if secret_value is None or secret_value == "":
                    continue  # Skip empty secrets

                service_name, secret_key = sops_key.split('/', 1)

                # Get all instance labels for this service
                # For instance-based services (like minecraft), this returns multiple labels
                # For regular services, this returns just [service_name]
                instance_labels = SecretsManager.get_instance_labels_for_service(service_name)

                # Write this secret to each instance
                for instance_label in instance_labels:
                    # Pass service_name for SOPS lookup, instance_label for file path
                    success, error = SecretsManager.extract_and_write_secret(service_name, instance_label, secret_key)
                    if not success:
                        print(f"Warning: Failed to write secret {instance_label}/{secret_key}: {error}")

            return True, None

        except subprocess.CalledProcessError as e:
            return False, f"Failed to decrypt secrets: {e.stderr}"
        except Exception as e:
            return False, f"Error writing secret files: {str(e)}"
