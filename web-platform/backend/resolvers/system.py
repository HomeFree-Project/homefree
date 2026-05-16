"""
System information resolvers
"""

import psutil
import subprocess
import logging
from pathlib import Path
from typing import List

from models import SystemInfo, DiskInfo, SystemCapabilities, MutationResult
from utils.privileged import run_privileged

logger = logging.getLogger(__name__)


class SystemResolver:
    # Firmware/TPM capabilities are immutable per boot; probed once and
    # cached so GET /api/system doesn't hit the filesystem every call.
    _capabilities_cache: SystemCapabilities = None

    @staticmethod
    def get_system_info() -> SystemInfo:
        """Get system information including hostname, CPU, memory, and disks"""

        # Get hostname
        try:
            hostname = subprocess.check_output(['hostname']).decode().strip()
        except:
            hostname = 'nixos'

        # Get CPU info
        try:
            with open('/proc/cpuinfo', 'r') as f:
                for line in f:
                    if line.strip().startswith('model name'):
                        cpu_info = line.split(':')[1].strip()
                        break
                else:
                    cpu_info = 'Unknown CPU'
        except:
            cpu_info = 'Unknown CPU'

        # Get memory total
        memory_total = psutil.virtual_memory().total

        # Get disks
        disks = SystemResolver._get_disks()

        # Probe hardware capabilities for the partitioning UI
        capabilities = SystemResolver._get_capabilities()

        return SystemInfo(
            hostname=hostname,
            cpu_info=cpu_info,
            memory_total=memory_total,
            disks=disks,
            capabilities=capabilities
        )

    @staticmethod
    def _get_capabilities() -> SystemCapabilities:
        """Probe firmware/TPM capabilities (cached after first call).

        - UEFI: presence of /sys/firmware/efi (same check the installer
          uses to pick a bootloader).
        - TPM2: a TPM2 resource-manager device node. /dev/tpmrm0 is the
          in-kernel RM device; /dev/tpm0 is the raw device. Either is
          enough for systemd-cryptenroll --tpm2-device=auto to work.
        """
        if SystemResolver._capabilities_cache is not None:
            return SystemResolver._capabilities_cache

        uefi = Path("/sys/firmware/efi").exists()

        tpm2_available = False
        try:
            tpm2_available = (
                Path("/dev/tpmrm0").exists() or Path("/dev/tpm0").exists()
            )
            # A TPM1.2 device also exposes /dev/tpm0; confirm version 2
            # via sysfs when the class entry is present.
            if tpm2_available:
                ver = Path("/sys/class/tpm/tpm0/tpm_version_major")
                if ver.exists():
                    tpm2_available = ver.read_text().strip() == "2"
        except Exception as e:
            logger.warning(f"TPM probe failed, assuming no TPM2: {e}")
            tpm2_available = False

        logger.info(
            f"Capabilities probed: uefi={uefi} tpm2={tpm2_available}"
        )
        SystemResolver._capabilities_cache = SystemCapabilities(
            uefi=uefi, tpm2_available=tpm2_available
        )
        return SystemResolver._capabilities_cache

    @staticmethod
    def _get_disks() -> List[DiskInfo]:
        """Get list of available disks"""
        disks = []

        try:
            # Use lsblk to get disk information
            result = subprocess.run(
                ['lsblk', '-d', '-n', '-o', 'NAME,SIZE,MODEL,TYPE', '-e', '7,11'],
                capture_output=True,
                text=True
            )

            for line in result.stdout.strip().split('\n'):
                if not line:
                    continue

                try:
                    # Split without limit since MODEL can contain spaces
                    parts = line.split()
                    if len(parts) >= 3 and parts[-1] == 'disk':
                        name = '/dev/' + parts[0]
                        size_str = parts[1]
                        # lsblk format: NAME SIZE MODEL TYPE
                        # MODEL can have spaces, TYPE is always the last token
                        # If we have exactly 3 parts: NAME SIZE TYPE (no model)
                        # If we have 4+ parts: NAME SIZE MODEL... TYPE
                        if len(parts) == 3:
                            model = 'Unknown'
                        else:
                            # Join all parts between SIZE and TYPE as the model
                            model = ' '.join(parts[2:-1])

                        # Convert size to bytes
                        size_bytes = SystemResolver._parse_size(size_str)

                        # Skip disks that are removable (USB sticks, etc.)
                        removable = SystemResolver._is_removable(parts[0])
                        if removable:
                            logger.info(f"Skipping removable disk: {name}")
                            continue

                        disks.append(DiskInfo(
                            name=name,
                            size=size_bytes,
                            model=model,
                            removable=removable
                        ))
                except Exception as e:
                    logger.error(f"Error processing disk line '{line}': {e}")
                    continue

        except Exception as e:
            logger.error(f"Error getting disks: {e}")

        # Sort disks by name for consistent ordering in UI
        disks.sort(key=lambda d: d.name)

        return disks

    @staticmethod
    def _parse_size(size_str: str) -> int:
        """Convert size string (e.g., '240G') to bytes"""
        units = {'K': 1024, 'M': 1024**2, 'G': 1024**3, 'T': 1024**4, 'B': 1}

        size_str = size_str.strip()
        if size_str[-1] in units:
            return int(float(size_str[:-1]) * units[size_str[-1]])
        return int(size_str)

    @staticmethod
    def _is_removable(device: str) -> bool:
        """Check if a device is removable"""
        removable_path = Path(f'/sys/block/{device}/removable')
        if removable_path.exists():
            try:
                return removable_path.read_text().strip() == '1'
            except:
                pass
        return False

    @staticmethod
    def is_virtualized() -> bool:
        """Check if the system is running in a virtual machine (QEMU/KVM)"""
        try:
            # Use systemd-detect-virt to check for virtualization
            result = subprocess.run(
                ['systemd-detect-virt'],
                capture_output=True,
                text=True
            )

            # systemd-detect-virt returns 0 if virtualized, non-zero if not
            if result.returncode == 0:
                virt_type = result.stdout.strip()
                logger.info(f"Virtualization detected: {virt_type}")
                # Check specifically for QEMU/KVM
                return virt_type in ['qemu', 'kvm']

            logger.info("No virtualization detected")
            return False
        except FileNotFoundError:
            logger.warning("systemd-detect-virt not found, checking DMI")
            # Fallback: check DMI product name
            try:
                product_name_path = Path('/sys/class/dmi/id/product_name')
                if product_name_path.exists():
                    product_name = product_name_path.read_text().strip()
                    is_qemu = any(keyword in product_name.lower() for keyword in ['qemu', 'kvm', 'standard pc'])
                    logger.info(f"DMI product name: {product_name}, QEMU/KVM: {is_qemu}")
                    return is_qemu
            except Exception as e:
                logger.warning(f"Failed to read DMI info: {e}")

            return False
        except Exception as e:
            logger.error(f"Error detecting virtualization: {e}")
            return False

    @staticmethod
    def reboot() -> MutationResult:
        """Reboot the system"""
        try:
            logger.info("Rebooting system...")
            # Use systemctl reboot with privilege escalation
            run_privileged(["systemctl", "reboot"], check=True)
            return MutationResult(
                success=True,
                message="System is rebooting..."
            )
        except Exception as e:
            logger.error(f"Failed to reboot: {e}")
            return MutationResult(
                success=False,
                message=f"Failed to reboot: {str(e)}"
            )
