"""Test-suite-wide safety rails. Importing the `tests` package (unittest and pytest
both do, before any test module) installs them.

1. NO REAL OPENAI CALLS. The API key is blanked and `llm._client` is replaced with a
   guard that raises. A test that means to exercise the LLM layer must stub it
   (`mock.patch.object(llm, "_client", ...)` or patch a higher-level function); a
   test that forgets fails loudly instead of quietly spending money. The guard
   raises a BaseException (so no `except Exception` in app code can swallow it),
   records the call, and an atexit hook fails the whole run if any call was ever
   made — even one raised inside a background thread.

2. OPTIONAL POSTGRES. With TEST_DATABASE_URL set, `db.init_db()` builds its engine
   against that database (schema dropped and recreated each time) instead of a
   per-test SQLite file, so the same suite runs on the production dialect:

       TEST_DATABASE_URL=postgresql://user:pw@localhost:5432/test python -m pytest tests
"""
from __future__ import annotations

import atexit
import os

# Set (to empty) rather than pop: load_dotenv() never overrides an existing
# variable, so this keeps the developer's real key out of config.
os.environ["OPENAI_API_KEY"] = ""
os.environ.setdefault("APP_KEY", "")

from app import config, db  # noqa: E402  (must follow the env setup above)
from app.pipeline import llm  # noqa: E402

config.OPENAI_API_KEY = None

UNMOCKED_OPENAI_CALLS: list[str] = []


class UnmockedOpenAICall(BaseException):
    """A test reached the real OpenAI client without stubbing it."""


def _forbidden_client():
    UNMOCKED_OPENAI_CALLS.append("llm._client()")
    raise UnmockedOpenAICall(
        "A test tried to create a real OpenAI client. Stub llm._client (or the "
        "function under test) — tests must never call OpenAI."
    )


llm._client = _forbidden_client


@atexit.register
def _fail_run_if_openai_was_reached() -> None:
    if UNMOCKED_OPENAI_CALLS:
        print(f"\nFATAL: test run reached OpenAI unmocked {len(UNMOCKED_OPENAI_CALLS)} time(s).")
        os._exit(1)


_TEST_PG_URL = os.getenv("TEST_DATABASE_URL")
if _TEST_PG_URL:
    from sqlalchemy import create_engine

    def _build_test_pg_engine():
        engine = create_engine(db._normalize_url(_TEST_PG_URL), future=True, pool_pre_ping=True)
        db.metadata.drop_all(engine)
        return engine

    db._build_engine = _build_test_pg_engine
