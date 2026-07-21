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

# No real auth yet — every request is attributed to this stubbed user.
DEFAULT_USER_ID: str = "00000000-0000-0000-0000-000000000001"

# Generous per-user limit — should never affect a real user, only scripted
# abuse of the free/unlimited extraction tier (CLAUDE.md §7).
RATE_LIMIT_PER_MINUTE: int = int(os.getenv("RATE_LIMIT_PER_MINUTE", "30"))
