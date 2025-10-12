"""
Configuration resolvers for timezone, keyboard, user, etc.
"""

from typing import List, Optional
from models import (
    TimezoneRegion, KeyboardLayout, InstallSummary,
    PartitioningConfig, MutationResult
)
from services.config import ConfigService
from services.network import NetworkService


class ConfigResolver:
    @staticmethod
    def get_timezones() -> List[TimezoneRegion]:
        """Get available timezones grouped by region"""
        # Return common timezones organized by region
        return [
            TimezoneRegion(
                region="Americas",
                zones=[
                    "America/New_York", "America/Chicago", "America/Denver",
                    "America/Los_Angeles", "America/Anchorage", "America/Toronto",
                    "America/Mexico_City", "America/Sao_Paulo"
                ]
            ),
            TimezoneRegion(
                region="Europe",
                zones=[
                    "Europe/London", "Europe/Paris", "Europe/Berlin",
                    "Europe/Rome", "Europe/Madrid", "Europe/Moscow"
                ]
            ),
            TimezoneRegion(
                region="Asia",
                zones=[
                    "Asia/Dubai", "Asia/Kolkata", "Asia/Singapore",
                    "Asia/Tokyo", "Asia/Shanghai", "Asia/Seoul"
                ]
            ),
            TimezoneRegion(
                region="Pacific",
                zones=[
                    "Australia/Sydney", "Australia/Melbourne", "Pacific/Auckland"
                ]
            ),
        ]

    @staticmethod
    def get_keyboard_layouts() -> List[KeyboardLayout]:
        """Get available keyboard layouts"""
        return [
            KeyboardLayout(name="us", description="English (US)"),
            KeyboardLayout(name="uk", description="English (UK)"),
            KeyboardLayout(name="de", description="German"),
            KeyboardLayout(name="fr", description="French"),
            KeyboardLayout(name="es", description="Spanish"),
            KeyboardLayout(name="it", description="Italian"),
            KeyboardLayout(name="pt", description="Portuguese"),
            KeyboardLayout(name="ru", description="Russian"),
            KeyboardLayout(name="jp", description="Japanese"),
            KeyboardLayout(name="dvorak", description="Dvorak"),
            KeyboardLayout(name="colemak", description="Colemak"),
        ]

    @staticmethod
    def set_location(timezone: str, locale: str) -> MutationResult:
        """Set timezone and locale"""
        try:
            ConfigService.set_timezone(timezone)
            ConfigService.set_locale(locale)
            return MutationResult(
                success=True,
                message=f"Location set: timezone={timezone}, locale={locale}"
            )
        except Exception as e:
            return MutationResult(
                success=False,
                message=f"Failed to set location: {str(e)}"
            )

    @staticmethod
    def set_keyboard(layout: str, vconsole: str) -> MutationResult:
        """Set keyboard layout"""
        try:
            ConfigService.set_keyboard(layout, vconsole)
            return MutationResult(
                success=True,
                message=f"Keyboard set: layout={layout}, vconsole={vconsole}"
            )
        except Exception as e:
            return MutationResult(
                success=False,
                message=f"Failed to set keyboard: {str(e)}"
            )

    @staticmethod
    def set_user(username: str, fullname: str, password: str) -> MutationResult:
        """Set user account information"""
        try:
            # Validate username
            if not username or len(username) < 3:
                return MutationResult(
                    success=False,
                    message="Username must be at least 3 characters"
                )

            # Validate password
            if not password or len(password) < 8:
                return MutationResult(
                    success=False,
                    message="Password must be at least 8 characters"
                )

            ConfigService.set_user(username, fullname, password)
            return MutationResult(
                success=True,
                message=f"User configured: {username}"
            )
        except Exception as e:
            return MutationResult(
                success=False,
                message=f"Failed to set user: {str(e)}"
            )

    @staticmethod
    def set_hostname(hostname: str) -> MutationResult:
        """Set system hostname"""
        try:
            ConfigService.set_hostname(hostname)
            return MutationResult(
                success=True,
                message=f"Hostname set: {hostname}"
            )
        except Exception as e:
            return MutationResult(
                success=False,
                message=f"Failed to set hostname: {str(e)}"
            )

    @staticmethod
    def set_partitioning(config: str) -> MutationResult:
        """Set partitioning configuration"""
        try:
            ConfigService.set_partitioning(config)
            return MutationResult(
                success=True,
                message="Partitioning configured"
            )
        except Exception as e:
            return MutationResult(
                success=False,
                message=f"Failed to set partitioning: {str(e)}"
            )

    @staticmethod
    def set_development_mode(enabled: bool) -> MutationResult:
        """Enable or disable development mode"""
        try:
            ConfigService.set_development_mode(enabled)
            status = "enabled" if enabled else "disabled"
            return MutationResult(
                success=True,
                message=f"Development mode {status}"
            )
        except Exception as e:
            return MutationResult(
                success=False,
                message=f"Failed to set development mode: {str(e)}"
            )

    @staticmethod
    def get_install_summary() -> InstallSummary:
        """Get installation configuration summary"""
        config = ConfigService.get_config()

        partitioning = None
        if config.get('partitioning'):
            part_config = config['partitioning']
            partitioning = PartitioningConfig(
                device=part_config.get('disk', part_config.get('device', '')),  # Frontend sends 'disk', fallback to 'device'
                mode=part_config.get('mode', 'auto'),
                encryption=part_config.get('use_encryption', part_config.get('encryption', False)),  # Frontend sends 'use_encryption'
                swap=part_config.get('use_swap', part_config.get('swap', True)),  # Frontend sends 'use_swap'
            )

        return InstallSummary(
            hostname=config.get('hostname', 'homefree'),
            timezone=config.get('timezone', 'America/Los_Angeles'),
            locale=config.get('locale', 'en_US.UTF-8'),
            keymap=config.get('keymap', 'us'),
            username=config.get('username', 'admin'),
            fullname=config.get('fullname', 'HomeFree Admin'),
            wan_interface=NetworkService.get_wan_interface() or '',
            lan_interface=NetworkService.get_lan_interface() or '',
            partitioning=partitioning,
        )
