"""Sign in with Apple authorization-code exchange and account revocation.

Secrets and credentials are never logged. Stored refresh tokens are encrypted
with a dedicated deployment secret and are kept only for Apple's revocation API.
"""
from __future__ import annotations

import base64
import hashlib
import time
from dataclasses import dataclass

import jwt
import requests
from cryptography.fernet import Fernet, InvalidToken

from .. import config, db

_TOKEN_URL = "https://appleid.apple.com/auth/token"
_REVOKE_URL = "https://appleid.apple.com/auth/revoke"
_TIMEOUT = 10


class AppleRevocationError(RuntimeError):
    def __init__(self, safe_code: str):
        super().__init__(safe_code)
        self.safe_code = safe_code


@dataclass(frozen=True)
class RevocationAttempt:
    succeeded: bool
    safe_error_code: str | None = None


def _client_id() -> str:
    if not config.APPLE_CLIENT_IDS:
        raise AppleRevocationError("configuration_missing")
    return config.APPLE_CLIENT_IDS[0]


def _client_secret() -> str:
    if not config.APPLE_TEAM_ID or not config.APPLE_KEY_ID or not config.APPLE_PRIVATE_KEY:
        raise AppleRevocationError("configuration_missing")
    now = int(time.time())
    try:
        return jwt.encode(
            {
                "iss": config.APPLE_TEAM_ID,
                "iat": now,
                "exp": now + 300,
                "aud": "https://appleid.apple.com",
                "sub": _client_id(),
            },
            config.APPLE_PRIVATE_KEY,
            algorithm="ES256",
            headers={"kid": config.APPLE_KEY_ID},
        )
    except Exception as exc:  # key parse/signing failure; never include details
        raise AppleRevocationError("client_secret_failed") from exc


def _fernet() -> Fernet:
    secret = config.APPLE_REVOCATION_ENCRYPTION_KEY
    if not secret or len(secret) < 32:
        raise AppleRevocationError("encryption_configuration_missing")
    key = base64.urlsafe_b64encode(hashlib.sha256(secret.encode("utf-8")).digest())
    return Fernet(key)


def encrypt_refresh_token(refresh_token: str) -> str:
    return _fernet().encrypt(refresh_token.encode("utf-8")).decode("ascii")


def decrypt_refresh_token(encrypted: str) -> str:
    try:
        return _fernet().decrypt(encrypted.encode("ascii")).decode("utf-8")
    except (InvalidToken, ValueError, UnicodeError) as exc:
        raise AppleRevocationError("credential_decryption_failed") from exc


def exchange_authorization_code(authorization_code: str) -> str:
    """Exchange Apple's one-time code and return its revocation refresh token."""
    try:
        response = requests.post(
            _TOKEN_URL,
            data={
                "client_id": _client_id(),
                "client_secret": _client_secret(),
                "code": authorization_code,
                "grant_type": "authorization_code",
            },
            timeout=_TIMEOUT,
        )
    except requests.RequestException as exc:
        raise AppleRevocationError("token_exchange_unavailable") from exc
    if response.status_code != 200:
        raise AppleRevocationError("token_exchange_rejected")
    try:
        refresh_token = response.json().get("refresh_token")
    except ValueError as exc:
        raise AppleRevocationError("token_exchange_invalid_response") from exc
    if not isinstance(refresh_token, str) or not refresh_token:
        raise AppleRevocationError("token_exchange_missing_credential")
    return refresh_token


def store_for_user(user_id: str, refresh_token: str) -> None:
    db.store_apple_revocation_credential(user_id, encrypt_refresh_token(refresh_token))


def revoke_encrypted(encrypted: str) -> RevocationAttempt:
    try:
        token = decrypt_refresh_token(encrypted)
        response = requests.post(
            _REVOKE_URL,
            data={
                "client_id": _client_id(),
                "client_secret": _client_secret(),
                "token": token,
                "token_type_hint": "refresh_token",
            },
            timeout=_TIMEOUT,
        )
        if response.status_code == 200:
            return RevocationAttempt(True)
        return RevocationAttempt(False, "revocation_rejected")
    except AppleRevocationError as exc:
        return RevocationAttempt(False, exc.safe_code)
    except requests.RequestException:
        return RevocationAttempt(False, "revocation_unavailable")


def retry_pending(limit: int = 5) -> tuple[int, int]:
    """Retry a bounded batch. Returns (completed, remaining/failed in batch)."""
    completed = failed = 0
    for task in db.list_apple_revocation_tasks(limit):
        result = revoke_encrypted(task["encrypted_refresh_token"])
        if result.succeeded:
            db.complete_apple_revocation_task(task["id"])
            completed += 1
        else:
            db.fail_apple_revocation_task(task["id"], result.safe_error_code or "temporary_failure")
            failed += 1
    return completed, failed
