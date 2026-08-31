"""Central config. Loads secrets from a local .env file (gitignored)."""
from __future__ import annotations

import os

from dotenv import load_dotenv

load_dotenv()

OPENAI_API_KEY: str | None = os.getenv("OPENAI_API_KEY")
PEXELS_API_KEY: str | None = os.getenv("PEXELS_API_KEY")

# "mini" tier, not the flagship — this reformat-caption-into-JSON task does not
# need a frontier model, and cost matters (see CLAUDE.md §7). Set OPENAI_MODEL
# to "gpt-5.4-nano" to go cheaper still.
OPENAI_MODEL: str = os.getenv("OPENAI_MODEL", "gpt-5.4-mini")

DB_PATH: str = os.getenv("DB_PATH", "recipes.db")

# When set (Railway Postgres), this is the source of truth for the DB connection
# and DB_PATH is ignored. Railway hands out a `postgresql://…` URL; app/db.py
# normalizes it to the psycopg (v3) driver. When unset, the app falls back to a
# local SQLite file at DB_PATH — so local dev and the test-suite need no Postgres.
DATABASE_URL: str | None = os.getenv("DATABASE_URL")

# --------------------------------------------------------------------------- #
# Auth (Stage 1). Real user accounts: our own JWTs, plus server-side
# verification of Apple/Google identity tokens.
# --------------------------------------------------------------------------- #

# HS256 signing secret for the access/refresh JWTs WE issue. MUST be set to a
# strong random value in Railway; if it leaks or changes, all sessions are
# invalidated. Unset → a fixed dev-only secret so local dev / tests run without
# config (NEVER relied on in production — the app logs a warning at startup).
JWT_SECRET: str = os.getenv("JWT_SECRET", "dev-insecure-jwt-secret-change-me")

# Whether a real JWT_SECRET was provided. main.py warns when running on the dev
# fallback so a misconfigured production deploy is loud, not silent.
JWT_SECRET_IS_DEV_FALLBACK: bool = os.getenv("JWT_SECRET") is None

ACCESS_TOKEN_TTL_MINUTES: int = int(os.getenv("ACCESS_TOKEN_TTL_MINUTES", "30"))
REFRESH_TOKEN_TTL_DAYS: int = int(os.getenv("REFRESH_TOKEN_TTL_DAYS", "60"))
JWT_ISSUER: str = os.getenv("JWT_ISSUER", "recipeapp")


def _csv(env: str) -> list[str]:
    """Parse a comma-separated env var into a stripped, non-empty list."""
    return [v.strip() for v in (os.getenv(env) or "").split(",") if v.strip()]


# Allowed audiences when verifying provider identity tokens. Apple's native
# Sign in with Apple sets `aud` to the app's bundle id; Google sets it to the
# OAuth client id used on the device. Both accept multiple values (e.g. an
# extra Services ID, or iOS + web client ids). A provider login is rejected if
# these are unset — we never verify a token against an empty audience allowlist.
APPLE_CLIENT_IDS: list[str] = _csv("APPLE_CLIENT_IDS")
GOOGLE_CLIENT_IDS: list[str] = _csv("GOOGLE_CLIENT_IDS")

# Apple Sign in requires calling a token-revocation endpoint on account deletion
# (Stage 5). These identify our app to Apple for that call; unused until Stage 5.
APPLE_TEAM_ID: str | None = os.getenv("APPLE_TEAM_ID")
APPLE_KEY_ID: str | None = os.getenv("APPLE_KEY_ID")
APPLE_PRIVATE_KEY: str | None = os.getenv("APPLE_PRIVATE_KEY")

# Brute-force bounds on the email/password login endpoint (per-IP and per-email,
# per 15-minute window). Separate from the extraction rate limits.
LOGIN_ATTEMPTS_PER_WINDOW: int = int(os.getenv("LOGIN_ATTEMPTS_PER_WINDOW", "10"))
LOGIN_WINDOW_SECONDS: int = int(os.getenv("LOGIN_WINDOW_SECONDS", "900"))

# No real auth yet. Requests carry a client-supplied `X-User-Id` (an anonymous
# UUID the iOS app persists) which we now honor for rate limiting — but it is
# spoofable and is NOT identity verification (see app/ratelimit.py). This stub
# is only the fallback when the header is absent/unusable.
DEFAULT_USER_ID: str = "00000000-0000-0000-0000-000000000001"

# Static shared "app key" — a secret embedded in the iOS app and checked on
# EVERY request before any processing (401 if missing/wrong). This is abuse
# deterrence for a public beta endpoint, NOT real auth: a key shipped inside an
# app binary is extractable by anyone who unpacks the IPA. It stops casual
# scripted hits on the open endpoint; rotate via this env var + an app update
# if it leaks. Set locally in .env and in the Railway dashboard — NEVER commit a
# real value (this repo is public). If unset here, the gate is disabled
# (fail-open) so local dev / tests work without the header.
APP_KEY: str | None = os.getenv("APP_KEY")

# Password for the /admin/feedback page (HTTP Basic Auth, username "admin").
# Set in Railway's env vars (and locally in .env). If unset, the admin page is
# disabled (503) rather than exposing feedback. NEVER commit a real value.
ADMIN_PASSWORD: str | None = os.getenv("ADMIN_PASSWORD")

# Persistent (SQLite) rate limits — two identity dimensions x two windows.
# Generous for a real TestFlight beta user, tight enough to bound cost abuse
# (~$0.002-0.005 per extraction; caching by video id makes repeats ~free).
# Per user-id: a human using the Share Sheet does a few/min at most.
RATE_LIMIT_USER_PER_MIN: int = int(os.getenv("RATE_LIMIT_USER_PER_MIN", "8"))
RATE_LIMIT_USER_PER_HOUR: int = int(os.getenv("RATE_LIMIT_USER_PER_HOUR", "40"))
# Per IP: higher, to absorb NAT/households sharing one IP, while capping a
# single attacker who rotates X-User-Id (defense in depth).
RATE_LIMIT_IP_PER_MIN: int = int(os.getenv("RATE_LIMIT_IP_PER_MIN", "15"))
RATE_LIMIT_IP_PER_HOUR: int = int(os.getenv("RATE_LIMIT_IP_PER_HOUR", "100"))
