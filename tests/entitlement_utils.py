"""Test helpers for seeding server-verified Pro entitlements.

Endpoint tests grant Pro by writing a stored entitlement row directly (the same
row `verify_and_store` would produce), instead of the old spoofable
`X-Pro-Entitled` header. Verification against Apple is exercised separately in
test_entitlements.py with a fake verifier.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Optional

from app import db


def grant_pro(
    user_id: str,
    *,
    days: Optional[int] = 30,
    grace_days: Optional[int] = None,
    product_id: str = "com.recipeapp.RecipeApp2.pro.monthly",
    original_transaction_id: Optional[str] = None,
    environment: str = "Sandbox",
) -> None:
    """Seed a stored entitlement for an account. `days` sets pro_expires_at (None =
    already expired/absent); `grace_days` sets grace_expires_at when given."""
    now = datetime.now(timezone.utc)
    db.upsert_entitlement(
        user_id=user_id,
        product_id=product_id,
        original_transaction_id=original_transaction_id or f"otid-{user_id}",
        pro_expires_at=(now + timedelta(days=days)).isoformat() if days is not None else None,
        grace_expires_at=(now + timedelta(days=grace_days)).isoformat() if grace_days is not None else None,
        environment=environment,
        last_verified_at=now.isoformat(),
        updated_at=now.isoformat(),
    )


def revoke_pro(user_id: str) -> None:
    db.delete_entitlement(user_id)
