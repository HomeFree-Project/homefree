"""
Configuration service for storing installation settings
"""

from typing import Dict, Any, Optional


class ConfigService:
    """Service for managing installation configuration"""

    # In-memory storage for installation configuration
    _config: Dict[str, Any] = {
        'hostname': 'homefree',
        'timezone': 'America/Los_Angeles',
        'locale': 'en_US.UTF-8',
        'keymap': 'us',
        'vconsole': 'us',
        'username': 'admin',
        'fullname': 'HomeFree Admin',
        'password': '',
        'partitioning': None,
        'development_mode': False,
    }

    @staticmethod
    def set_hostname(hostname: str):
        """Set system hostname"""
        ConfigService._config['hostname'] = hostname

    @staticmethod
    def set_timezone(timezone: str):
        """Set system timezone"""
        ConfigService._config['timezone'] = timezone

    @staticmethod
    def set_locale(locale: str):
        """Set system locale"""
        ConfigService._config['locale'] = locale

    @staticmethod
    def set_keyboard(layout: str, vconsole: str):
        """Set keyboard layout"""
        ConfigService._config['keymap'] = layout
        ConfigService._config['vconsole'] = vconsole

    @staticmethod
    def set_user(username: str, fullname: str, password: str):
        """Set user account information"""
        ConfigService._config['username'] = username
        ConfigService._config['fullname'] = fullname
        ConfigService._config['password'] = password

    @staticmethod
    def set_partitioning(config: str):
        """Set partitioning configuration"""
        # Parse config string (JSON or other format)
        import json
        try:
            ConfigService._config['partitioning'] = json.loads(config)
        except:
            ConfigService._config['partitioning'] = {'raw': config}

    @staticmethod
    def get_config() -> Dict[str, Any]:
        """Get current configuration"""
        return ConfigService._config.copy()

    @staticmethod
    def get(key: str, default: Any = None) -> Any:
        """Get a specific config value"""
        return ConfigService._config.get(key, default)

    @staticmethod
    def set_development_mode(enabled: bool):
        """Enable or disable development mode"""
        ConfigService._config['development_mode'] = enabled

    @staticmethod
    def is_development_mode() -> bool:
        """Check if development mode is enabled"""
        return ConfigService._config.get('development_mode', False)
