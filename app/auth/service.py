"""Account persistence and the sign-in / upsert logic.

The recipe pipeline still uses `app/db.py`'s function API; this module owns the
new auth tables (users / auth_identities / refresh_tokens) and talks to the same
engine directly via SQLAlchemy Core.

Account model:
  * Email/password accounts have a `password_hash`.
  * Apple/Google accounts have a row in `auth_identities` keyed by (provider,
    subject). The first sign-in creates the user; later ones resolve to it.
  * Cross-method linking: a verified provider email that matches an existing
    account attaches to it, so "signed up with email, later used Google" is one
    account — never a silent duplicate.
"""
from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional

from sqlalchemy import select, update

from .. import db
from ..db import auth_identities, refresh_tokens, users
from . import security
from .providers import VerifiedIdentity


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _normalize_email(email: Optional[str]) -> Optional[str]:
    return email.strip().lower() if email else None


@dataclass(frozen=True)
class User:
    id: str
    email: Optional[str]
    email_verified: bool
    full_name: Optional[str]
    has_password: bool


class EmailInUse(Exception):
    """Registration attempted with an email that already has an account."""


def _row_to_user(row) -> User:
    return User(
        id=row["id"],
        email=row["email"],
        email_verified=bool(row["email_verified"]),
        full_name=row["full_name"],
        has_password=bool(row["password_hash"]),
    )


# --------------------------------------------------------------------------- #
# Lookups
# --------------------------------------------------------------------------- #


def get_user_by_id(user_id: str) -> Optional[User]:
    with db.get_engine().begin() as conn:
        row = conn.execute(select(users).where(users.c.id == user_id)).mappings().fetchone()
    return _row_to_user(row) if row else None


def get_user_by_email(email: str) -> Optional[User]:
    norm = _normalize_email(email)
    if not norm:
        return None
    with db.get_engine().begin() as conn:
        row = conn.execute(select(users).where(users.c.email == norm)).mappings().fetchone()
    return _row_to_user(row) if row else None


# --------------------------------------------------------------------------- #
# Email / password
# --------------------------------------------------------------------------- #


def create_email_user(email: str, password: str, full_name: Optional[str]) -> User:
    norm = _normalize_email(email)
    if get_user_by_email(norm):
        raise EmailInUse(norm)
    now = _now_iso()
    user_id = uuid.uuid4().hex
    with db.get_engine().begin() as conn:
        conn.execute(
            users.insert().values(
                id=user_id,
                email=norm,
                email_verified=False,  # Stage 1: not yet verified (see report)
                password_hash=security.hash_password(password),
                full_name=(full_name or None),
                created_at=now,
                updated_at=now,
            )
        )
    return User(id=user_id, email=norm, email_verified=False, full_name=full_name or None, has_password=True)


def authenticate_email(email: str, password: str) -> Optional[User]:
    """Return the user on correct credentials, else None. Transparently upgrades
    the stored hash if argon2 parameters have changed."""
    norm = _normalize_email(email)
    with db.get_engine().begin() as conn:
        row = conn.execute(select(users).where(users.c.email == norm)).mappings().fetchone()
        if row is None or not security.verify_password(password, row["password_hash"]):
            return None
        if security.needs_rehash(row["password_hash"]):
            conn.execute(
                update(users)
                .where(users.c.id == row["id"])
                .values(password_hash=security.hash_password(password), updated_at=_now_iso())
            )
    return _row_to_user(row)


# --------------------------------------------------------------------------- #
# Apple / Google
# --------------------------------------------------------------------------- #


def upsert_provider_user(identity: VerifiedIdentity, full_name: Optional[str]) -> User:
    """Resolve a verified provider identity to an account, creating or linking as
    needed, and return the user."""
    now = _now_iso()
    email = _normalize_email(identity.email)

    with db.get_engine().begin() as conn:
        link = conn.execute(
            select(auth_identities).where(
                auth_identities.c.provider == identity.provider,
                auth_identities.c.subject == identity.subject,
            )
        ).mappings().fetchone()

        # Known identity → its user. Backfill a one-time full name / email.
        if link is not None:
            row = conn.execute(select(users).where(users.c.id == link["user_id"])).mappings().fetchone()
            _backfill(conn, row, full_name=full_name, email=email, email_verified=identity.email_verified, now=now)
            row = conn.execute(select(users).where(users.c.id == link["user_id"])).mappings().fetchone()
            return _row_to_user(row)

        # New identity. Link to an existing account with the same VERIFIED email,
        # otherwise create a fresh user.
        user_row = None
        if email and identity.email_verified:
            user_row = conn.execute(select(users).where(users.c.email == email)).mappings().fetchone()

        if user_row is None:
            user_id = uuid.uuid4().hex
            conn.execute(
                users.insert().values(
                    id=user_id,
                    email=email,
                    email_verified=identity.email_verified,
                    password_hash=None,
                    full_name=(full_name or None),
                    created_at=now,
                    updated_at=now,
                )
            )
        else:
            user_id = user_row["id"]
            _backfill(conn, user_row, full_name=full_name, email=email, email_verified=identity.email_verified, now=now)

        conn.execute(
            auth_identities.insert().values(
                provider=identity.provider,
                subject=identity.subject,
                user_id=user_id,
                email=email,
                created_at=now,
            )
        )
        row = conn.execute(select(users).where(users.c.id == user_id)).mappings().fetchone()
        return _row_to_user(row)


def _backfill(conn, row, *, full_name: Optional[str], email: Optional[str], email_verified: bool, now: str) -> None:
    """Fill in a missing full name (Apple returns it only once) or a missing
    verified email on an existing account. Never overwrites present values."""
    if row is None:
        return
    values = {}
    if full_name and not row["full_name"]:
        values["full_name"] = full_name
    if email and not row["email"]:
        values["email"] = email
        values["email_verified"] = email_verified
    if values:
        values["updated_at"] = now
        conn.execute(update(users).where(users.c.id == row["id"]).values(**values))


# --------------------------------------------------------------------------- #
# Full name (Stage 3 — Apple's one-time name, set only if absent)
# --------------------------------------------------------------------------- #


def set_full_name_if_absent(user_id: str, full_name: Optional[str]) -> None:
    if not full_name:
        return
    with db.get_engine().begin() as conn:
        row = conn.execute(select(users).where(users.c.id == user_id)).mappings().fetchone()
        if row is not None and not row["full_name"]:
            conn.execute(
                update(users).where(users.c.id == user_id).values(full_name=full_name, updated_at=_now_iso())
            )


# --------------------------------------------------------------------------- #
# Refresh-token lifecycle
# --------------------------------------------------------------------------- #


def record_refresh_token(jti: str, user_id: str, expires_at: datetime) -> None:
    with db.get_engine().begin() as conn:
        conn.execute(
            refresh_tokens.insert().values(
                jti=jti,
                user_id=user_id,
                issued_at=_now_iso(),
                expires_at=expires_at.isoformat(),
                revoked=False,
            )
        )


def refresh_token_active(jti: str, user_id: str) -> bool:
    with db.get_engine().begin() as conn:
        row = conn.execute(
            select(refresh_tokens).where(refresh_tokens.c.jti == jti)
        ).mappings().fetchone()
    return bool(row) and row["user_id"] == user_id and not row["revoked"]


def revoke_refresh_token(jti: str) -> None:
    with db.get_engine().begin() as conn:
        conn.execute(update(refresh_tokens).where(refresh_tokens.c.jti == jti).values(revoked=True))


def revoke_all_refresh_tokens(user_id: str) -> None:
    with db.get_engine().begin() as conn:
        conn.execute(
            update(refresh_tokens).where(refresh_tokens.c.user_id == user_id).values(revoked=True)
        )
