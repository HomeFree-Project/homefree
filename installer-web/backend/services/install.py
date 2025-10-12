"""
Installation service - handles the actual NixOS installation process
Ported from Calamares nixos module
"""

import os
import subprocess
import threading
import logging
import psutil
from pathlib import Path
from typing import Dict, Any, Optional

from services.config import ConfigService
from services.network import NetworkService
from utils.privileged import run_privileged, popen_privileged, write_file_privileged, mkdir_privileged

logger = logging.getLogger(__name__)


class InstallationService:
    """Service for managing the NixOS installation process"""

    _status: Dict[str, Any] = {
        'step': 'Not started',
        'progress': 0.0,
        'message': '',
        'completed': False,
        'error': None,
    }

    _install_thread: Optional[threading.Thread] = None
    _running = False

    # Templates for configuration files
    FLAKE_TEMPLATE = """{
  description = "HomeFree NixOS Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    homefree-base.url = "git+https://git.homefree.host/homefree/homefree.git?ref=build-image";
  };

  outputs = { self, nixpkgs, homefree-base, ... }@inputs:
  let
    system = "x86_64-linux";
  in {
    nixosConfigurations = {
      @@hostname@@ = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          homefree-base.nixosModules.homefree
          ./configuration.nix
          ./homefree-configuration.nix
        ];
        specialArgs = {
          inherit system;
          homefree-inputs = homefree-base.inputs;
        };
      };
    };
  };
}
"""

    HOMEFREE_CONFIG_TEMPLATE = """{ ... }:
{
  homefree = {
    system = {
      # System identity
      hostName = "@@hostname@@";
      timeZone = "@@timezone@@";
      defaultLocale = "@@locale@@";
      keyMap = "@@vconsole@@";

      # Admin user
      adminUsername = "@@username@@";
      adminDescription = "@@fullname@@";
    };

    network = {
@@router_config@@
    };

    ## @TODO: Rename? e.g. user-services; optional-services? web-services?  There are other services besides these.
    services = {
      adguard = {
        enable = true;
      };
    };
  };

  # Set admin user password
  users.users.@@username@@ = {
    hashedPassword = "@@hashed_password@@";
  };
}
"""

    CONFIGURATION_TEMPLATE = """# Local system configuration overrides for HomeFree
# Most system configuration is managed by HomeFree (see homefree-configuration.nix)
# This file is for system-specific settings only.
#
# To rebuild: sudo nixos-rebuild switch --flake /etc/nixos#@@hostname@@-system
# See: https://git.homefree.host/homefree/homefree

{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./homefree-configuration.nix
  ];

@@bootloader@@

  # NixOS Release Version
  system.stateVersion = "@@nixosversion@@";
}
"""

    @staticmethod
    def initialize():
        """Initialize the installation service"""
        logger.info("Installation service initialized")

    @staticmethod
    def start() -> bool:
        """Start the installation process in a background thread"""
        if InstallationService._running:
            logger.warning("Installation already in progress")
            return False

        InstallationService._running = True
        InstallationService._status = {
            'step': 'Starting installation...',
            'progress': 0.0,
            'message': 'Preparing to install HomeFree',
            'completed': False,
            'error': None,
        }

        # Start installation in background thread
        InstallationService._install_thread = threading.Thread(
            target=InstallationService._run_installation,
            daemon=True
        )
        InstallationService._install_thread.start()

        return True

    @staticmethod
    def get_status() -> Dict[str, Any]:
        """Get current installation status"""
        return InstallationService._status.copy()

    @staticmethod
    def _update_status(step: str, progress: float, message: str):
        """Update installation status"""
        InstallationService._status.update({
            'step': step,
            'progress': progress,
            'message': message,
        })
        logger.info(f"[{progress:.0f}%] {step}: {message}")

    @staticmethod
    def _set_error(error: str):
        """Set installation error"""
        InstallationService._status['error'] = error
        InstallationService._status['completed'] = False
        InstallationService._running = False
        logger.error(f"Installation error: {error}")

    @staticmethod
    def _set_completed():
        """Mark installation as completed"""
        InstallationService._status['completed'] = True
        InstallationService._status['progress'] = 100.0
        InstallationService._running = False
        logger.info("Installation completed successfully")

    @staticmethod
    def _get_partition_path(disk: str, partition_number: int) -> str:
        """Get correct partition device path for the given disk and partition number

        Args:
            disk: Device path (e.g., /dev/sda, /dev/nvme0n1, /dev/vda)
            partition_number: Partition number (1, 2, 3, etc.)

        Returns:
            Complete partition path (e.g., /dev/sda1, /dev/nvme0n1p1, /dev/vda1)
        """
        # NVMe devices use 'p' notation: /dev/nvme0n1p1
        if 'nvme' in disk:
            return f"{disk}p{partition_number}"
        # Standard SATA/SCSI/virtio devices: /dev/sda1, /dev/vda1, etc.
        else:
            return f"{disk}{partition_number}"

    @staticmethod
    def _run_installation():
        """Run the installation process"""
        try:
            root_mount_point = "/mnt"

            # Step 1: Partition and format disks
            InstallationService._update_status(
                "Partitioning disks",
                5.0,
                "Creating partitions and filesystems"
            )
            InstallationService._partition_disks(root_mount_point)

            # Step 2: Generate hardware configuration
            InstallationService._update_status(
                "Generating hardware configuration",
                15.0,
                "Detecting hardware and generating configuration"
            )
            InstallationService._generate_hardware_config(root_mount_point)

            # Step 3: Generate NixOS configuration
            InstallationService._update_status(
                "Generating HomeFree configuration",
                25.0,
                "Creating flake.nix and configuration files"
            )
            InstallationService._generate_configs(root_mount_point)

            # Step 4: Initialize git repository
            InstallationService._update_status(
                "Initializing git repository",
                30.0,
                "Setting up git for flake management"
            )
            InstallationService._init_git(root_mount_point)

            # Step 5: Run nixos-install
            InstallationService._update_status(
                "Installing HomeFree",
                35.0,
                "Building and installing packages...  (this may take 15-30 minutes)"
            )
            InstallationService._nixos_install(root_mount_point)

            # Step 6: Post-install configuration
            InstallationService._update_status(
                "Finishing installation",
                95.0,
                "Finalizing system configuration"
            )
            InstallationService._post_install(root_mount_point)

            # Complete
            InstallationService._update_status(
                "Installation complete",
                100.0,
                "HomeFree has been successfully installed!"
            )
            InstallationService._set_completed()

        except Exception as e:
            logger.exception("Installation failed")
            InstallationService._set_error(str(e))

    @staticmethod
    def _partition_disks(root_mount_point: str):
        """Partition and format disks with btrfs"""
        config = ConfigService.get_config()
        partitioning = config.get('partitioning')

        if not partitioning or not partitioning.get('disk'):
            raise Exception("No disk selected for installation")

        disk = partitioning.get('disk')
        use_swap = partitioning.get('use_swap', True)
        use_encryption = partitioning.get('use_encryption', False)

        if use_encryption:
            raise Exception("LUKS encryption not yet implemented")

        logger.info(f"Partitioning disk {disk} with btrfs")

        # Detect firmware type
        fw_type = "efi" if Path("/sys/firmware/efi").exists() else "bios"

        try:
            # Unmount any existing partitions on the disk
            run_privileged(
                f"umount {disk}* 2>/dev/null || true",
                shell=True,
                check=False
            )

            # Wipe filesystem signatures
            run_privileged(
                ["wipefs", "-a", disk],
                check=True,
                capture_output=True
            )

            # Create GPT partition table
            run_privileged(
                ["parted", "-s", disk, "mklabel", "gpt"],
                check=True,
                capture_output=True
            )

            if fw_type == "efi":
                # UEFI: Create EFI partition (512MB) and root partition
                run_privileged(
                    ["parted", "-s", disk, "mkpart", "ESP", "fat32", "1MiB", "513MiB"],
                    check=True
                )
                run_privileged(
                    ["parted", "-s", disk, "set", "1", "esp", "on"],
                    check=True
                )

                if use_swap:
                    # Create swap partition (RAM size)
                    mem_total = psutil.virtual_memory().total
                    swap_size_mb = int(mem_total / (1024 * 1024))
                    swap_end = 513 + swap_size_mb

                    run_privileged(
                        ["parted", "-s", disk, "mkpart", "swap", "linux-swap", "513MiB", f"{swap_end}MiB"],
                        check=True
                    )

                    # Root partition starts after swap
                    run_privileged(
                        ["parted", "-s", disk, "mkpart", "root", "btrfs", f"{swap_end}MiB", "100%"],
                        check=True
                    )

                    efi_part = InstallationService._get_partition_path(disk, 1)
                    swap_part = InstallationService._get_partition_path(disk, 2)
                    root_part = InstallationService._get_partition_path(disk, 3)
                else:
                    # Root partition takes rest of disk
                    run_privileged(
                        ["parted", "-s", disk, "mkpart", "root", "btrfs", "513MiB", "100%"],
                        check=True
                    )

                    efi_part = InstallationService._get_partition_path(disk, 1)
                    swap_part = None
                    root_part = InstallationService._get_partition_path(disk, 2)

                # Format EFI partition
                run_privileged(
                    ["mkfs.vfat", "-F32", "-n", "EFI", efi_part],
                    check=True
                )
            else:
                # BIOS: Just create root partition
                if use_swap:
                    mem_total = psutil.virtual_memory().total
                    swap_size_mb = int(mem_total / (1024 * 1024))
                    swap_end = 1 + swap_size_mb

                    run_privileged(
                        ["parted", "-s", disk, "mkpart", "swap", "linux-swap", "1MiB", f"{swap_end}MiB"],
                        check=True
                    )
                    run_privileged(
                        ["parted", "-s", disk, "mkpart", "root", "btrfs", f"{swap_end}MiB", "100%"],
                        check=True
                    )

                    swap_part = InstallationService._get_partition_path(disk, 1)
                    root_part = InstallationService._get_partition_path(disk, 2)
                else:
                    run_privileged(
                        ["parted", "-s", disk, "mkpart", "root", "btrfs", "1MiB", "100%"],
                        check=True
                    )

                    swap_part = None
                    root_part = InstallationService._get_partition_path(disk, 1)

                efi_part = None

            # Format swap if enabled
            if swap_part:
                run_privileged(
                    ["mkswap", "-L", "swap", swap_part],
                    check=True
                )
                run_privileged(
                    ["swapon", swap_part],
                    check=True
                )

            # Format root partition with btrfs
            run_privileged(
                ["mkfs.btrfs", "-f", "-L", "nixos", root_part],
                check=True
            )

            # Mount root partition
            run_privileged(
                ["mount", root_part, root_mount_point],
                check=True
            )

            # Create btrfs subvolumes for better snapshot management
            run_privileged(
                ["btrfs", "subvolume", "create", f"{root_mount_point}/@"],
                check=True
            )
            run_privileged(
                ["btrfs", "subvolume", "create", f"{root_mount_point}/@home"],
                check=True
            )
            run_privileged(
                ["btrfs", "subvolume", "create", f"{root_mount_point}/@nix"],
                check=True
            )

            # Unmount and remount with subvolumes
            run_privileged(
                ["umount", root_mount_point],
                check=True
            )

            # Mount root subvolume
            run_privileged(
                ["mount", "-o", "subvol=@,compress=zstd,noatime", root_part, root_mount_point],
                check=True
            )

            # Create mount points
            mkdir_privileged(f"{root_mount_point}/home")
            mkdir_privileged(f"{root_mount_point}/nix")

            # Mount home subvolume
            run_privileged(
                ["mount", "-o", "subvol=@home,compress=zstd,noatime", root_part, f"{root_mount_point}/home"],
                check=True
            )

            # Mount nix subvolume
            run_privileged(
                ["mount", "-o", "subvol=@nix,compress=zstd,noatime", root_part, f"{root_mount_point}/nix"],
                check=True
            )

            # Mount EFI partition if UEFI
            if efi_part:
                mkdir_privileged(f"{root_mount_point}/boot")
                run_privileged(
                    ["mount", efi_part, f"{root_mount_point}/boot"],
                    check=True
                )

            logger.info(f"Successfully partitioned and mounted {disk}")

        except subprocess.CalledProcessError as e:
            raise Exception(f"Failed to partition disk: {e}")

    @staticmethod
    def _generate_hardware_config(root_mount_point: str):
        """Generate hardware-configuration.nix"""
        try:
            run_privileged(
                ["nixos-generate-config", "--root", root_mount_point],
                check=True,
                capture_output=True
            )
        except subprocess.CalledProcessError as e:
            raise Exception(f"Failed to generate hardware config: {e.stderr.decode()}")

    @staticmethod
    def _generate_configs(root_mount_point: str):
        """Generate flake.nix, homefree-configuration.nix, and configuration.nix"""
        config = ConfigService.get_config()
        nixos_dir = Path(root_mount_point) / "etc/nixos"
        mkdir_privileged(str(nixos_dir))

        # Get NixOS version
        try:
            version = subprocess.check_output(["nixos-version"]).decode().strip()
            version = '.'.join(version.split('.')[:2])[:5]
        except:
            version = "24.05"

        # Detect firmware type
        fw_type = "efi" if Path("/sys/firmware/efi").exists() else "bios"

        # Generate bootloader config
        if fw_type == "efi":
            bootloader = """  # Bootloader (UEFI)
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
"""
        else:
            bootloader = """  # Bootloader (BIOS)
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";  # TODO: Auto-detect boot device
  boot.loader.grub.useOSProber = true;
"""

        # Get network interfaces
        wan_interface = NetworkService.get_wan_interface() or ''
        lan_interface = NetworkService.get_lan_interface() or ''

        # Generate router config only if both interfaces are configured
        if wan_interface and lan_interface:
            router_config = f"""      # Network interfaces
      wan-interface = "{wan_interface}";
      lan-interface = "{lan_interface}";

      # Enable router functionality
      router.enable = true;
"""
        else:
            router_config = """      # Router mode disabled - insufficient network interfaces
      router.enable = false;
"""

        # Generate hashed password using mkpasswd
        password = config.get('password', '')
        if password:
            try:
                # Use mkpasswd to generate SHA-512 hashed password
                result = subprocess.run(
                    ['mkpasswd', '-m', 'sha-512', password],
                    capture_output=True,
                    text=True,
                    check=True
                )
                hashed_password = result.stdout.strip()
                logger.info("Generated hashed password for user")
            except subprocess.CalledProcessError as e:
                logger.error(f"Failed to hash password: {e}")
                hashed_password = ""
        else:
            hashed_password = ""

        # Template variables
        variables = {
            'hostname': config.get('hostname', 'homefree'),
            'timezone': config.get('timezone', 'America/Los_Angeles'),
            'locale': config.get('locale', 'en_US.UTF-8'),
            'vconsole': config.get('vconsole', 'us'),
            'username': config.get('username', 'admin'),
            'fullname': config.get('fullname', 'HomeFree Admin'),
            'wan_interface': wan_interface,
            'lan_interface': lan_interface,
            'nixosversion': version,
            'bootloader': bootloader,
            'router_config': router_config,
            'hashed_password': hashed_password,
        }

        # Generate flake.nix
        flake_content = InstallationService.FLAKE_TEMPLATE
        for key, value in variables.items():
            flake_content = flake_content.replace(f"@@{key}@@", str(value))

        write_file_privileged(str(nixos_dir / "flake.nix"), flake_content)

        # Generate homefree-configuration.nix
        homefree_config = InstallationService.HOMEFREE_CONFIG_TEMPLATE
        for key, value in variables.items():
            homefree_config = homefree_config.replace(f"@@{key}@@", str(value))

        write_file_privileged(str(nixos_dir / "homefree-configuration.nix"), homefree_config)

        # Generate configuration.nix
        configuration = InstallationService.CONFIGURATION_TEMPLATE
        for key, value in variables.items():
            configuration = configuration.replace(f"@@{key}@@", str(value))

        write_file_privileged(str(nixos_dir / "configuration.nix"), configuration)

        logger.info(f"Generated configuration files in {nixos_dir}")

    @staticmethod
    def _init_git(root_mount_point: str):
        """Initialize git repository for flake"""
        nixos_dir = Path(root_mount_point) / "etc/nixos"

        try:
            # Git operations on /mnt need privilege escalation
            run_privileged(["git", "init", str(nixos_dir)], check=True)
            run_privileged(["git", "-C", str(nixos_dir), "add", "."], check=True)
            run_privileged(
                ["git", "-C", str(nixos_dir), "config", "user.email", "installer@homefree.local"],
                check=True
            )
            run_privileged(
                ["git", "-C", str(nixos_dir), "config", "user.name", "HomeFree Installer"],
                check=True
            )
            run_privileged(
                ["git", "-C", str(nixos_dir), "commit", "-m", "Initial configuration"],
                check=True
            )
            logger.info("Initialized git repository")
        except subprocess.CalledProcessError as e:
            raise Exception(f"Failed to initialize git: {e}")

    @staticmethod
    def _nixos_install(root_mount_point: str):
        """Run nixos-install"""
        import os

        config = ConfigService.get_config()
        hostname = config.get('hostname', 'homefree')

        try:
            # nixos-install automatically prepends 'nixosConfigurations.' so just pass the hostname
            flake_ref = f"{root_mount_point}/etc/nixos#{hostname}"
            logger.info(f"Installing NixOS with flake reference: {flake_ref}")

            # Log the generated flake.nix content for debugging
            # Note: We can't read the file directly from /mnt as nixos user,
            # but we can use cat via pkexec or just skip this debug step
            try:
                flake_path = Path(root_mount_point) / "etc/nixos/flake.nix"
                # Use privileged read via cat
                result = run_privileged(
                    ["cat", str(flake_path)],
                    capture_output=True,
                    text=True,
                    check=True
                )
                logger.info(f"Flake content:\n{result.stdout}")
            except Exception as e:
                logger.warning(f"Could not read flake.nix: {e}")

            # DEBUG: Test what the flake reference resolves to
            import subprocess as sp
            try:
                test_cmd = [
                    "nix", "--extra-experimental-features", "nix-command flakes",
                    "flake", "show", flake_ref, "--json"
                ]
                test_result = sp.run(test_cmd, capture_output=True, text=True, timeout=30)
                logger.info(f"DEBUG flake show output: {test_result.stdout[:500]}")
                logger.info(f"DEBUG flake show stderr: {test_result.stderr[:500]}")
            except Exception as e:
                logger.warning(f"DEBUG flake show failed: {e}")

            # Build nixos-install command with --show-trace for better error messages
            cmd = [
                "nixos-install",
                "--debug",  # Enable bash set -x for detailed debugging
                "--flake", flake_ref,
                "--no-root-passwd",
                "--root", root_mount_point,
                "--show-trace"  # Add detailed error tracing
            ]

            # Log the exact command being run
            logger.info(f"Running command: {' '.join(cmd)}")
            logger.info(f"Inheriting environment from systemd service (preserves PATH with Nix tools)")

            # Run nixos-install inheriting the systemd service environment
            # This preserves the PATH that includes all necessary Nix commands
            process = popen_privileged(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                universal_newlines=True
            )

            # Stream output and update progress
            progress = 35.0
            output_lines = []
            for line in process.stdout:
                output_lines.append(line)
                line_stripped = line.strip()
                logger.info(f"nixos-install: {line_stripped}")

                # Update progress based on different types of output
                updated = False

                # Evaluating/preparing (early phase)
                if any(keyword in line.lower() for keyword in ["evaluating", "preparing"]):
                    progress = min(progress + 0.1, 50.0)
                    InstallationService._update_status(
                        "Preparing installation",
                        progress,
                        line_stripped[:100]
                    )
                    updated = True

                # Nix operations (copying, downloading, fetching, building) - treat all equally
                elif any(keyword in line.lower() for keyword in ["copying", "downloading", "fetching", "building"]):
                    progress = min(progress + 0.2, 85.0)

                    # Determine the action and extract details
                    if "building" in line.lower():
                        step_name = "Building packages"
                        # Try to extract package name
                        if "'" in line:
                            parts = line.split("'")
                            if len(parts) >= 2:
                                pkg_name = parts[1].split("/")[-1] if "/" in parts[1] else parts[1]
                                message = f"Building {pkg_name}"
                            else:
                                message = line_stripped[:100]
                        else:
                            message = line_stripped[:100]
                    elif "copying" in line.lower():
                        step_name = "Installing HomeFree"
                        message = line_stripped[:100]
                    elif "downloading" in line.lower() or "fetching" in line.lower():
                        step_name = "Downloading packages"
                        message = line_stripped[:100]
                    else:
                        step_name = "Installing HomeFree"
                        message = line_stripped[:100]

                    InstallationService._update_status(
                        step_name,
                        progress,
                        message
                    )
                    updated = True

                # Installing/setting up packages
                elif "installing" in line.lower() or "setting up" in line.lower():
                    progress = min(progress + 0.2, 90.0)
                    InstallationService._update_status(
                        "Installing packages",
                        progress,
                        line_stripped[:100]
                    )
                    updated = True

                # Activating system
                elif "activating" in line.lower() or "systemd" in line.lower():
                    progress = min(progress + 0.3, 92.0)
                    InstallationService._update_status(
                        "Activating system",
                        progress,
                        line_stripped[:100]
                    )
                    updated = True

            process.wait()

            # Log full output if failed for debugging
            if process.returncode != 0:
                logger.error(f"nixos-install failed with exit code {process.returncode}")
                logger.error(f"Full output:\n{''.join(output_lines[-100:])}")  # Last 100 lines
                raise Exception(f"nixos-install failed with code {process.returncode}")

            logger.info("nixos-install completed successfully")

        except Exception as e:
            raise Exception(f"Failed to install HomeFree: {e}")

    @staticmethod
    def _post_install(root_mount_point: str):
        """Post-installation tasks"""
        config = ConfigService.get_config()
        username = config.get('username', 'admin')
        password = config.get('password', '')

        # Set password using chpasswd in the installed system
        # This matches the standard NixOS installer behavior
        if password:
            try:
                logger.info(f"Setting password for user {username} using chpasswd")

                # Use nixos-enter with a shell command to pipe password to chpasswd
                # Format: username:password
                passwd_input = f"{username}:{password}\n"

                # Run chpasswd in the chroot environment
                process = popen_privileged(
                    ["nixos-enter", "--root", root_mount_point, "--", "chpasswd"],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True
                )
                stdout, stderr = process.communicate(input=passwd_input)

                if process.returncode != 0:
                    logger.error(f"chpasswd failed: {stderr}")
                    logger.warning("Password may not be set correctly - hashedPassword in config should work")
                else:
                    logger.info(f"Successfully set password for user {username} via chpasswd")

            except Exception as e:
                logger.warning(f"Failed to set password via chpasswd: {e}")
                logger.info("Falling back to hashedPassword in configuration file")

        logger.info(f"Post-install complete for user {username}")
