"""
Secrets API Resolvers

Handles API endpoints for secrets management using sops-nix
"""

import logging
from typing import Dict, Optional
from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel

from services.secrets_manager import SecretsManager

logger = logging.getLogger(__name__)

# Create router
router = APIRouter(prefix="/api/secrets", tags=["secrets"])


# Request/Response Models
class SecretSetRequest(BaseModel):
    """Request model for setting a secret"""
    value: str


class SecretResponse(BaseModel):
    """Response model for secret operations"""
    success: bool
    message: Optional[str] = None


class SecretsStatusResponse(BaseModel):
    """Response model for secrets status"""
    secrets: Dict[str, Dict[str, bool]]


class SecretsSchemaResponse(BaseModel):
    """Response model for secrets schema"""
    schema: Dict[str, Dict[str, Dict]]


class KeyStatusResponse(BaseModel):
    """Response model for key status"""
    exists: bool
    key: Optional[str] = None


# Endpoints

@router.get("/schema", response_model=SecretsSchemaResponse)
async def get_secrets_schema():
    """
    Get the secrets schema for all services

    Returns schema showing which secrets each service requires
    """
    try:
        schema = SecretsManager.get_schema()
        return SecretsSchemaResponse(schema=schema)
    except Exception as e:
        logger.error(f"Error getting secrets schema: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to get secrets schema: {str(e)}"
        )


@router.get("/status", response_model=SecretsStatusResponse)
async def get_secrets_status(service: Optional[str] = None):
    """
    Get status of which secrets exist

    Args:
        service: Optional service label to filter results

    Returns status showing which secrets are set (exists) vs not set
    """
    try:
        secrets_status = SecretsManager.get_secrets_status(service)
        return SecretsStatusResponse(secrets=secrets_status)
    except Exception as e:
        logger.error(f"Error getting secrets status: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to get secrets status: {str(e)}"
        )


@router.get("/keys/system", response_model=KeyStatusResponse)
async def get_system_key():
    """
    Get system SSH host public key

    Returns the system's SSH host key used for secrets decryption
    """
    try:
        key = SecretsManager.get_system_ssh_public_key()
        return KeyStatusResponse(
            exists=key is not None,
            key=key
        )
    except Exception as e:
        logger.error(f"Error getting system key: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to get system key: {str(e)}"
        )


@router.get("/keys/user", response_model=KeyStatusResponse)
async def get_user_key():
    """
    Get user SSH public key status

    Returns whether a user key is configured and the key value
    """
    try:
        key = SecretsManager.get_user_ssh_public_key()
        return KeyStatusResponse(
            exists=key is not None,
            key=key
        )
    except Exception as e:
        logger.error(f"Error getting user key: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to get user key: {str(e)}"
        )


@router.post("/{service_label}/{secret_key}", response_model=SecretResponse)
async def set_secret(service_label: str, secret_key: str, request: SecretSetRequest):
    """
    Create or update a secret value

    Args:
        service_label: Service identifier (e.g., "vaultwarden")
        secret_key: Secret key name (e.g., "adminToken")
        request: Request body containing the secret value

    Returns success status and any error message
    """
    try:
        success, error = SecretsManager.set_secret(
            service_label,
            secret_key,
            request.value
        )

        if not success:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=error or "Failed to set secret"
            )

        # Write secret files immediately after setting
        # This ensures secrets are available to services right away
        write_success, write_error = SecretsManager.write_secret_files()
        if not write_success:
            logger.warning(f"Secret set in SOPS but failed to write files: {write_error}")

        return SecretResponse(
            success=True,
            message="Secret set successfully"
        )

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error setting secret: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to set secret: {str(e)}"
        )


@router.delete("/{service_label}/{secret_key}", response_model=SecretResponse)
async def delete_secret(service_label: str, secret_key: str):
    """
    Delete a secret value

    Args:
        service_label: Service identifier
        secret_key: Secret key name

    Returns success status and any error message
    """
    try:
        success, error = SecretsManager.delete_secret(service_label, secret_key)

        if not success:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=error or "Failed to delete secret"
            )

        return SecretResponse(
            success=True,
            message="Secret deleted successfully"
        )

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error deleting secret: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to delete secret: {str(e)}"
        )
