"""
Configuration resolvers for timezone, keyboard, user, etc.
"""

import re
from typing import List, Optional
from zoneinfo import available_timezones
from models import (
    TimezoneRegion, KeyboardLayout, InstallSummary,
    PartitioningConfig, MutationResult
)
from services.config import ConfigService
from services.network import NetworkService

# Region prefixes we don't want to show in the picker — these are
# alias/legacy trees that duplicate the canonical Continent/City names.
_TZ_SKIP_PREFIXES = (
    "SystemV/", "US/", "Canada/", "Brazil/", "Chile/", "Mexico/",
    "Etc/GMT+",  # confusing sign convention; keep just "Etc/UTC" and a few canonicals
)


PASSWORD_MIN_LENGTH = 8
PASSWORD_MAX_LENGTH = 128
_PASSWORD_CONTROL_CHAR_RE = re.compile(r'[\x00-\x1F\x7F]')


def validate_password(password: str) -> Optional[str]:
    """Return an error message if the password isn't acceptable, or None
    if it is. Combines the Linux-side rules (no control chars, length
    bounds — the installer hands the password to mkpasswd / chpasswd
    which would corrupt or truncate on control chars) with Zitadel's
    default complexity policy (upper + lower + number + symbol).

    Kept in sync with the frontend validator in
    web-platform/frontend/src/shared/password-policy.js.
    """
    if not password:
        return "Password is required"
    if _PASSWORD_CONTROL_CHAR_RE.search(password):
        return (
            "Password contains a control character (newline, tab, etc.) "
            "that cannot be used as a Linux password"
        )
    if len(password) > PASSWORD_MAX_LENGTH:
        return f"Password must be at most {PASSWORD_MAX_LENGTH} characters"
    if len(password) < PASSWORD_MIN_LENGTH:
        return f"Password must be at least {PASSWORD_MIN_LENGTH} characters"

    missing = []
    if not re.search(r'[A-Z]', password):
        missing.append("an uppercase letter")
    if not re.search(r'[a-z]', password):
        missing.append("a lowercase letter")
    if not re.search(r'[0-9]', password):
        missing.append("a number")
    if not re.search(r'[^A-Za-z0-9]', password):
        missing.append("a symbol")
    if missing:
        return "Password must include " + ", ".join(missing)

    return None


class ConfigResolver:
    @staticmethod
    def get_timezones() -> List[TimezoneRegion]:
        """All IANA timezones from the system tzdata, grouped by the
        first segment (Continent or special bucket like Etc, Pacific).
        Sourced via zoneinfo.available_timezones() so we don't maintain
        a list by hand and we stay in sync with system tzdata updates.
        """
        regions: dict[str, list[str]] = {}
        for tz in sorted(available_timezones()):
            if tz.startswith(_TZ_SKIP_PREFIXES):
                continue
            region = tz.split("/", 1)[0] if "/" in tz else "Other"
            regions.setdefault(region, []).append(tz)
        return [
            TimezoneRegion(region=r, zones=z)
            for r, z in sorted(regions.items())
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
    def set_user(username: str, fullname: str, email: str, password: str) -> MutationResult:
        """Set user account information"""
        try:
            # Validate username
            if not username or len(username) < 3:
                return MutationResult(
                    success=False,
                    message="Username must be at least 3 characters"
                )

            # Validate email (basic format check)
            if email and '@' not in email:
                return MutationResult(
                    success=False,
                    message="Invalid email format"
                )

            # Validate password
            password_error = validate_password(password)
            if password_error:
                return MutationResult(
                    success=False,
                    message=password_error
                )

            ConfigService.set_user(username, fullname, email, password)
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
    def set_domain(domain: str) -> MutationResult:
        """Set domain for HomeFree instance"""
        try:
            ConfigService.set_domain(domain)
            return MutationResult(
                success=True,
                message=f"Domain set: {domain}"
            )
        except Exception as e:
            return MutationResult(
                success=False,
                message=f"Failed to set domain: {str(e)}"
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
