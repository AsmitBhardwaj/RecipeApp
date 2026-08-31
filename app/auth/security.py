"""Password hashing and the access/refresh JWTs we issue.

These are OUR tokens (HS256, signed with `config.JWT_SECRET`) — distinct from the
Apple/Google identity tokens we *verify* in providers.py. An access token is a
short-lived bearer proving "this request is user X"; a refresh token is a
long-lived, single-use credential (tracked by `jti` in the refresh_tokens table)
that mints new access tokens without re-login.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone
from typing import Optional

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError, VerificationError, InvalidHashError

from .. import config

_ALGO = "HS256"
_hasher = PasswordHasher()


# --------------------------------------------------------------------------- #
# Passwords
# --------------------------------------------------------------------------- #


def hash_password(password: str) -> str:
    return _hasher.hash(password)


def verify_password(password: str, password_hash: Optional[str]) -> bool:
    """Constant-ish-time verify. False (never raises) for a bad password or a
    user with no password set (a social-only account)."""
    if not password_hash:
        return False
    try:
        return _hasher.verify(password_hash, password)
    except (VerifyMismatchError, VerificationError, InvalidHashError):
        return False


def needs_rehash(password_hash: str) -> bool:
    """True if the stored hash uses outdated argon2 parameters and should be
    re-hashed on the next successful login."""
    try:
        return _hasher.check_needs_rehash(password_hash)
    except Exception:
        return False


# --------------------------------------------------------------------------- #
# JWTs we issue
# --------------------------------------------------------------------------- #


def _now() -> datetime:
    return datetime.now(timezone.utc)


def create_access_token(user_id: str) -> tuple[str, int]:
    """Return (token, expires_in_seconds)."""
    ttl = timedelta(minutes=config.ACCESS_TOKEN_TTL_MINUTES)
    now = _now()
    payload = {
        "sub": user_id,
        "type": "access",
        "iss": config.JWT_ISSUER,
        "iat": int(now.timestamp()),
        "exp": int((now + ttl).timestamp()),
    }
    return jwt.encode(payload, config.JWT_SECRET, algorithm=_ALGO), int(ttl.total_seconds())


def create_refresh_token(user_id: str) -> tuple[str, str, datetime]:
    """Return (token, jti, expires_at). The caller records `jti` so the token can
    be rotated on use and revoked."""
    ttl = timedelta(days=config.REFRESH_TOKEN_TTL_DAYS)
    now = _now()
    expires_at = now + ttl
    jti = uuid.uuid4().hex
    payload = {
        "sub": user_id,
        "type": "refresh",
        "jti": jti,
        "iss": config.JWT_ISSUER,
        "iat": int(now.timestamp()),
        "exp": int(expires_at.timestamp()),
    }
    return jwt.encode(payload, config.JWT_SECRET, algorithm=_ALGO), jti, expires_at


class TokenError(Exception):
    """Raised when a token we issued is missing, malformed, expired, or the
    wrong type."""


def decode_token(token: str, *, expected_type: str) -> dict:
    """Verify signature/exp/issuer and that the token is of `expected_type`
    ("access" or "refresh"). Returns the claims or raises TokenError."""
    try:
        claims = jwt.decode(
            token,
            config.JWT_SECRET,
            algorithms=[_ALGO],
            issuer=config.JWT_ISSUER,
            options={"require": ["exp", "iat", "sub"]},
        )
    except jwt.PyJWTError as exc:
        raise TokenError(str(exc)) from exc
    if claims.get("type") != expected_type:
        raise TokenError(f"expected a {expected_type} token")
    return claims
