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


def _normalize_pem(raw: str | None) -> str | None:
    if raw is None:
        return None
    value = raw.strip().replace("\\r\\n", "\n").replace("\\n", "\n")
    return f"{value}\n" if value else None


APPLE_PRIVATE_KEY: str | None = _normalize_pem(os.getenv("APPLE_PRIVATE_KEY"))
# Dedicated server-side secret used to encrypt Apple's revocation credential at
# rest. Use a random value of at least 32 characters; it is never sent to Apple
# or to the client. Deliberately not derived from JWT_SECRET so either secret can
# be rotated independently.
APPLE_REVOCATION_ENCRYPTION_KEY: str | None = os.getenv(
    "APPLE_REVOCATION_ENCRYPTION_KEY"
)

# --------------------------------------------------------------------------- #
# App Store server-verified Pro entitlement (app/appstore.py, app/entitlements.py)
# --------------------------------------------------------------------------- #
# The ONLY source of truth for Pro is a StoreKit 2 signed transaction the client
# posts to /v1/entitlements/verify, verified here against Apple. There is no
# client-trusted header any more.
#
# Signature verification (chain to the Apple root) is OFFLINE and needs only the
# public Apple root certs bundled in app/appstore_certs/. The three secrets below
# are the App Store Server API key, used to look up subscription STATUS (renewal
# info) so we learn the billing-grace expiry a bare transaction doesn't carry.
# All three come from App Store Connect → Users & Access → Integrations →
# In-App Purchase keys. Set them in Railway (and locally in .env); NEVER commit
# real values (this repo is public). The code fails CLOSED: if these are unset,
# /v1/entitlements/verify returns 503 and no account is ever upgraded.
APPSTORE_ISSUER_ID: str | None = os.getenv("APPSTORE_ISSUER_ID")
APPSTORE_KEY_ID: str | None = os.getenv("APPSTORE_KEY_ID")


def _normalize_appstore_private_key(raw: str | None) -> str | None:
    """Return a canonical PKCS#8 PEM for an App Store Connect ``.p8`` key.

    Railway variables are commonly pasted either as the base64 body alone or
    with newlines escaped as the two characters ``\\n``.  Apple's SDK expects
    PEM armor and real newlines, so normalize both forms at the config boundary.
    """
    if raw is None:
        return None

    value = raw.strip().replace("\\r\\n", "\n").replace("\\n", "\n")
    begin = "-----BEGIN PRIVATE KEY-----"
    end = "-----END PRIVATE KEY-----"

    if value.startswith(begin) and end in value:
        return f"{value}\n"

    body = value.replace(begin, "").replace(end, "")
    body = "".join(body.split())
    if not body:
        return None
    return f"{begin}\n{body}\n{end}\n"


# Full .p8 PEM contents (multi-line, "-----BEGIN PRIVATE KEY----- ..."), stored
# in an env var exactly like APPLE_PRIVATE_KEY above.
APPSTORE_PRIVATE_KEY: str | None = _normalize_appstore_private_key(
    os.getenv("APPSTORE_PRIVATE_KEY")
)
# The app's bundle id and numeric App Store id. The bundle id is checked against
# every verified transaction; the Apple id is required by Apple's library to
# verify PRODUCTION transactions.
APPSTORE_BUNDLE_ID: str = os.getenv("APPSTORE_BUNDLE_ID", "com.recipeapp.RecipeApp2")
_appstore_app_apple_id_raw = os.getenv("APPSTORE_APP_APPLE_ID")
APPSTORE_APP_APPLE_ID: int | None = (
    int(_appstore_app_apple_id_raw) if (_appstore_app_apple_id_raw or "").strip().isdigit() else None
)
# Default environment ONLY as a hint/fallback. Verification does not rely on it:
# we verify against Production first and fall back to Sandbox, then store the
# environment Apple actually reports per entitlement (App Review / TestFlight
# send Sandbox transactions to this production server).
APPSTORE_ENVIRONMENT: str = os.getenv("APPSTORE_ENVIRONMENT", "Production")
# The only product ids that grant Pro. A transaction for anything else is rejected.
APPSTORE_PRODUCT_IDS: frozenset[str] = frozenset(
    {
        "com.recipeapp.RecipeApp2.pro.monthly",
        "com.recipeapp.RecipeApp2.pro.yearly",
    }
)


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
# FREE_LIMIT_EFFECTIVE_DATE remains configurable for deployments that need to
# grandfather accounts created before a particular launch date. The default is
# deliberately in the past so the five-import free plan applies to every account.
FREE_IMPORT_LIMIT: int = int(os.getenv("FREE_IMPORT_LIMIT", "5"))
FREE_LIMIT_EFFECTIVE_DATE: str = os.getenv(
    "FREE_LIMIT_EFFECTIVE_DATE", "1970-01-01T00:00:00+00:00"
)

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
# Soft spend circuit breaker (app/spendsignal.py).
#
# An advisory backstop ON TOP of the per-call rate/burst caps: if an account's
# trailing-SPEND_FLAG_WINDOW_DAYS estimated LLM spend (summed from
# llm_cost_events) exceeds SPEND_FLAG_THRESHOLD_USD, the account is FLAGGED for
# manual review in the admin panel — never auto-blocked, exactly like the
# device-multi-account signal (app/devicesignal.py). Visibility only, so a real
# power user is never silently cut off.
#
# THRESHOLD_USD is a PLACEHOLDER, tune against the real per-account cost
# distribution post-launch. Rationale for the default: net revenue is ~$24.65/yr
# per Pro user, so a single 30-day window costing ~4× that whole year's revenue
# ($100) is well past any plausible real usage. Sanity note: the existing burst
# caps (imports 100/day, budget 10/day, pantry 20/day) already bound one account
# to roughly $40/month of estimated spend (≈$80 at the doubled "fast" price
# tier), so this breaker sits ABOVE that ceiling — it fires only when something
# is genuinely off (a cap removed/misconfigured, costs far higher than modeled,
# or scripted abuse), not on a heavy-but-legitimate user.
SPEND_FLAG_WINDOW_DAYS: int = int(os.getenv("SPEND_FLAG_WINDOW_DAYS", "30"))
SPEND_FLAG_THRESHOLD_USD: float = float(os.getenv("SPEND_FLAG_THRESHOLD_USD", "100"))  # PLACEHOLDER

# --------------------------------------------------------------------------- #
# HARD per-account spend cap (app/spendcap.py) — an ENFORCING backstop, not the
# advisory flag above. Once an account's estimated LLM spend over the TRAILING 30
# DAYS (summed from llm_cost_events) is at/over this many dollars, the LLM-backed
# endpoints reject further calls with HTTP 429 (a rolling window, so it eases as
# old spend ages out — no fixed reset instant).
#
# This sits ABOVE the count-based burst caps (imports 100/day, budget 10/day,
# pantry 20/day), so it only trips when per-call cost is far higher than modeled,
# a count cap is misconfigured, or costs run away — a real user on the count caps
# never reaches it. PLACEHOLDER dollar value; tune against the real per-account
# 30-day cost distribution post-launch. Set to 0 (or negative) to DISABLE the
# hard cap and fall back to the count caps + the advisory flag only.
PER_ACCOUNT_30D_SPEND_CAP_USD: float = float(
    os.getenv("PER_ACCOUNT_30D_SPEND_CAP_USD", "5.00")
)  # PLACEHOLDER

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
