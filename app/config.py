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

# --------------------------------------------------------------------------- #
# Free-tier import limit (Platter Pro's "Unlimited imports" — CLAUDE.md §2).
#
# A signed-in FREE account may create at most FREE_IMPORT_LIMIT *successful*
# imports per calendar month (UTC). Pro accounts are never limited (see
# app/importlimit.py). Enforcement is per account and server-side, so it holds
# across devices and the Share Extension. Only accounts identified by a valid
# JWT are limited; unauthenticated/anonymous imports fall back to the existing
# per-user/IP rate limiter only (documented gap — see importlimit.py).
#
# GRANDFATHERING: accounts whose `created_at` is strictly BEFORE
# FREE_LIMIT_EFFECTIVE_DATE are exempt forever, so shipping this never
# retroactively limits an existing user. Both values below are PLACEHOLDERS —
# set them (here or via env) once the per-user monthly-import distribution has
# been reviewed. With the effective date left in the far future, EVERY current
# account is grandfathered, i.e. the limit is effectively OFF until you set a
# real date. Recommended: pick FREE_IMPORT_LIMIT at/above the ~95th percentile
# of real monthly imports, and set FREE_LIMIT_EFFECTIVE_DATE to the ship date so
# only accounts created after launch are ever limited.
FREE_IMPORT_LIMIT: int = int(os.getenv("FREE_IMPORT_LIMIT", "30"))  # PLACEHOLDER
FREE_LIMIT_EFFECTIVE_DATE: str = os.getenv(
    "FREE_LIMIT_EFFECTIVE_DATE", "2099-01-01T00:00:00+00:00"
)  # PLACEHOLDER — far-future = limit disabled / everyone grandfathered

# --------------------------------------------------------------------------- #
# Burst / daily caps on the LLM-backed endpoints (app/burstlimit.py).
#
# These sit ON TOP of the generic per-user/IP limiter (ratelimit.py) and the
# free-tier monthly import cap (importlimit.py). They are enforced PER ACCOUNT
# and bound cost even for accounts the monthly cap never touches: unlike the
# monthly cap, PRO accounts ARE subject to these — Pro removes the monthly cap,
# not the burst ceiling. Over-limit returns HTTP 429 with error_code
# "rate_limit_exceeded" (distinct from the paywall's 402 "free_limit_reached",
# so the client shows "slow down" rather than an upgrade prompt).
#
# Imports (/v1/jobs + the paste-fallback path) get both a per-hour burst cap and
# a per-day cap; budget-plan and pantry generation each get their own per-day cap
# in an independent bucket namespace (one endpoint's usage never consumes
# another's allowance). Windows are fixed and UTC-aligned, so the daily counter
# resets at UTC midnight.
BURST_IMPORT_PER_HOUR: int = int(os.getenv("BURST_IMPORT_PER_HOUR", "30"))
BURST_IMPORT_PER_DAY: int = int(os.getenv("BURST_IMPORT_PER_DAY", "100"))
BURST_BUDGET_PLAN_PER_DAY: int = int(os.getenv("BURST_BUDGET_PLAN_PER_DAY", "10"))
BURST_PANTRY_PER_DAY: int = int(os.getenv("BURST_PANTRY_PER_DAY", "20"))

# Device-level account-creation signal (app/devicesignal.py). A new account
# created from a device (the client's persistent `X-User-Id`) that ALREADY
# created another account within this trailing window is FLAGGED for manual
# review — advisory only, never an automatic block (shared devices / reinstalls
# make false positives expected).
DEVICE_MULTI_ACCOUNT_WINDOW_DAYS: int = int(os.getenv("DEVICE_MULTI_ACCOUNT_WINDOW_DAYS", "30"))

# --------------------------------------------------------------------------- #
# Plan on a Budget (docs/budget-meal-planning.md).
#
# The minimum weekly budget scales with household size: a household of N cannot
# plan below `N × MIN_BUDGET_PER_PERSON`, rounded to the nearest $5 (see
# app/budget.py). Enforced server-side in the budget-plan endpoint AND mirrored
# client-side (RecipeKit BudgetMath) so the stepper never shows a sub-minimum
# value. PLACEHOLDER value — tune once real basket costs are sanity-checked.
MIN_BUDGET_PER_PERSON: int = int(os.getenv("MIN_BUDGET_PER_PERSON", "25"))  # PLACEHOLDER

# How many recipes one budget-plan generation fans out to. Guards LLM cost — one
# structured-output call returns this many recipes (not N separate calls).
BUDGET_PLAN_RECIPE_COUNT: int = int(os.getenv("BUDGET_PLAN_RECIPE_COUNT", "7"))
