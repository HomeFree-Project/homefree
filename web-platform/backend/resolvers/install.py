"""
Installation process resolver
"""

from models import InstallProgress, MutationResult
from services.install import InstallationService


class InstallResolver:
    @staticmethod
    def start_installation() -> MutationResult:
        """Start the installation process"""
        try:
            success = InstallationService.start()
            if success:
                return MutationResult(
                    success=True,
                    message="Installation started"
                )
            else:
                return MutationResult(
                    success=False,
                    message="Installation already in progress or failed to start"
                )
        except Exception as e:
            return MutationResult(
                success=False,
                message=f"Failed to start installation: {str(e)}"
            )

    @staticmethod
    def get_progress() -> InstallProgress:
        """Get current installation progress"""
        status = InstallationService.get_status()

        return InstallProgress(
            step=status.get('step', 'Initializing...'),
            progress=status.get('progress', 0.0),
            message=status.get('message', ''),
            completed=status.get('completed', False),
            error=status.get('error'),
            recovery_passphrase=status.get('recovery_passphrase'),
            error_detail=status.get('error_detail'),
        )
