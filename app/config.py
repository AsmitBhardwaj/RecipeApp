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
