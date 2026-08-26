"""Storage layer — SQLAlchemy Core over SQLite (local/dev) or Postgres (Railway).

The connection target is chosen at runtime (see `_database_url`):
  * `config.DATABASE_URL` set  → Postgres (Railway), normalized to the psycopg
    driver. This is production once Stage 1 ships.
  * otherwise                  → a local SQLite file at `config.DB_PATH`, so
    local dev and the unittest suite need no Postgres.

Recipes are still cached by `canonical_video_id` (UNIQUE) — the idempotency key
that stops a viral video from triggering redundant LLM/scrape work (CLAUDE.md
§7). Jobs and recipes are stored as JSON blobs with the lookup keys promoted to
real columns; the auth tables (users / auth_identities / refresh_tokens) are new
in Stage 1.

Public function names/behavior are unchanged from the old sqlite3 layer so
`main.py`, `orchestrator.py`, and `ratelimit.py` did not have to change. Upserts
use the dialect-specific `insert(...).on_conflict_*` helper, which has the same
API on both the sqlite and postgresql dialects.
"""
from __future__ import annotations

from typing import Optional

from sqlalchemy import (
    BigInteger,
    Boolean,
    Column,
    Integer,
    MetaData,
    String,
    Table,
    Text,
    create_engine,
    delete,
    select,
)
from sqlalchemy.dialects.postgresql import insert as _pg_insert
from sqlalchemy.dialects.sqlite import insert as _sqlite_insert
from sqlalchemy.engine import Engine

from . import config
from .models import Job, Recipe, UserRecipe

# --------------------------------------------------------------------------- #
# Schema
# --------------------------------------------------------------------------- #

metadata = MetaData()

jobs = Table(
    "jobs",
    metadata,
    Column("job_id", String, primary_key=True),
    Column("data", Text, nullable=False),
)

recipes = Table(
    "recipes",
    metadata,
    Column("recipe_id", String, primary_key=True),
    Column("canonical_video_id", String, nullable=False, unique=True, index=True),
    Column("data", Text, nullable=False),
)

user_recipes = Table(
    "user_recipes",
    metadata,
    Column("user_id", String, primary_key=True),
    Column("recipe_id", String, primary_key=True),
    Column("custom_name", Text),
    Column("sort_key", Text),
    Column("saved_at", Text, nullable=False),
)

rate_limits = Table(
    "rate_limits",
    metadata,
    Column("bucket_key", String, primary_key=True),
    Column("window_start", BigInteger, primary_key=True),
    Column("count", Integer, nullable=False, default=0),
)

feedback = Table(
    "feedback",
    metadata,
    Column("id", Integer, primary_key=True, autoincrement=True),
    Column("rating", Integer),
    Column("message", Text),
    Column("contact_email", Text),
    Column("app_version", Text),
    Column("platform", Text),
    Column("created_at", Text, nullable=False, index=True),
)

# --- Auth (Stage 1) -------------------------------------------------------- #

# One row per account. `email` is the human identifier (nullable: an Apple user
# on a private relay who hides their email still gets an account, keyed only by
# their provider identity). `password_hash` is set only for email/password
# accounts. `full_name` captures Apple's one-time name (Stage 3).
users = Table(
    "users",
    metadata,
    Column("id", String, primary_key=True),
    Column("email", String, unique=True),
    Column("email_verified", Boolean, nullable=False, default=False),
    Column("password_hash", Text),
    Column("full_name", Text),
    Column("created_at", Text, nullable=False),
    Column("updated_at", Text, nullable=False),
)

# Links a verified provider identity (Apple/Google `sub`) to a user, so the same
# person signing in with the same provider always lands on the same account.
auth_identities = Table(
    "auth_identities",
    metadata,
    Column("provider", String, primary_key=True),   # "apple" | "google"
    Column("subject", String, primary_key=True),     # provider's stable `sub`
    Column("user_id", String, nullable=False, index=True),
    Column("email", String),
    Column("created_at", Text, nullable=False),
)

# Server record of issued refresh-token ids (jti) so they can be rotated on use
# and revoked on sign-out / account deletion. The token itself is a signed JWT;
# only its id is stored.
refresh_tokens = Table(
    "refresh_tokens",
    metadata,
    Column("jti", String, primary_key=True),
    Column("user_id", String, nullable=False, index=True),
    Column("issued_at", Text, nullable=False),
    Column("expires_at", Text, nullable=False),
    Column("revoked", Boolean, nullable=False, default=False),
)

# --------------------------------------------------------------------------- #
# Engine
# --------------------------------------------------------------------------- #

_engine: Optional[Engine] = None


def _normalize_url(url: str) -> str:
    """Point SQLAlchemy at the psycopg (v3) driver for Postgres. Railway hands
    out `postgres://` / `postgresql://`; SQLAlchemy needs the explicit driver."""
    if url.startswith("postgres://"):
        return "postgresql+psycopg://" + url[len("postgres://"):]
    if url.startswith("postgresql://"):
        return "postgresql+psycopg://" + url[len("postgresql://"):]
    return url


def _database_url() -> str:
    if config.DATABASE_URL:
        return _normalize_url(config.DATABASE_URL)
    return f"sqlite:///{config.DB_PATH}"


def _build_engine() -> Engine:
    url = _database_url()
    # future=True keeps 2.0-style semantics; pool_pre_ping avoids handing out a
    # Postgres connection the server has already dropped (idle recycling on
    # Railway). SQLite ignores the pool args harmlessly.
    return create_engine(url, future=True, pool_pre_ping=not url.startswith("sqlite"))


def _get_engine() -> Engine:
    global _engine
    if _engine is None:
        _engine = _build_engine()
    return _engine


def get_engine() -> Engine:
    """Public accessor for the shared engine (used by the auth store)."""
    return _get_engine()


def _insert(table: Table):
    """Dialect-appropriate INSERT builder exposing `.on_conflict_*`."""
    return _pg_insert(table) if _get_engine().dialect.name == "postgresql" else _sqlite_insert(table)


def init_db() -> None:
    """Create the engine (rebuilding it so tests that swap `config.DB_PATH` /
    `DATABASE_URL` between runs pick up the change) and ensure the schema."""
    global _engine
    if _engine is not None:
        _engine.dispose()
    _engine = _build_engine()
    metadata.create_all(_engine)


# --------------------------------------------------------------------------- #
# Jobs
# --------------------------------------------------------------------------- #


def save_job(job: Job) -> None:
    stmt = _insert(jobs).values(job_id=job.job_id, data=job.model_dump_json())
    stmt = stmt.on_conflict_do_update(index_elements=["job_id"], set_={"data": stmt.excluded.data})
    with _get_engine().begin() as conn:
        conn.execute(stmt)


def get_job(job_id: str) -> Optional[Job]:
    with _get_engine().begin() as conn:
        row = conn.execute(select(jobs.c.data).where(jobs.c.job_id == job_id)).fetchone()
    return Job.model_validate_json(row[0]) if row else None


# --------------------------------------------------------------------------- #
# Recipes (cache)
# --------------------------------------------------------------------------- #


def save_recipe(recipe: Recipe) -> None:
    stmt = _insert(recipes).values(
        recipe_id=recipe.recipe_id,
        canonical_video_id=recipe.canonical_video_id,
        data=recipe.model_dump_json(),
    )
    stmt = stmt.on_conflict_do_update(index_elements=["recipe_id"], set_={"data": stmt.excluded.data})
    with _get_engine().begin() as conn:
        conn.execute(stmt)


def get_recipe_by_video_id(canonical_video_id: str) -> Optional[Recipe]:
    with _get_engine().begin() as conn:
        row = conn.execute(
            select(recipes.c.data).where(recipes.c.canonical_video_id == canonical_video_id)
        ).fetchone()
    return Recipe.model_validate_json(row[0]) if row else None


def get_recipe(recipe_id: str) -> Optional[Recipe]:
    with _get_engine().begin() as conn:
        row = conn.execute(select(recipes.c.data).where(recipes.c.recipe_id == recipe_id)).fetchone()
    return Recipe.model_validate_json(row[0]) if row else None


# --------------------------------------------------------------------------- #
# User <-> recipe join
# --------------------------------------------------------------------------- #


def save_user_recipe(link: UserRecipe) -> None:
    stmt = _insert(user_recipes).values(
        user_id=link.user_id,
        recipe_id=link.recipe_id,
        custom_name=link.custom_name,
        sort_key=link.sort_key,
        saved_at=link.saved_at,
    )
    stmt = stmt.on_conflict_do_nothing(index_elements=["user_id", "recipe_id"])
    with _get_engine().begin() as conn:
        conn.execute(stmt)


# --------------------------------------------------------------------------- #
# Rate-limit counters
# --------------------------------------------------------------------------- #


def rate_limit_incr(bucket_key: str, window_start: int) -> int:
    """Atomically bump the counter for (bucket_key, window_start) and return the
    new value. A single UPSERT ... RETURNING keeps the read-modify-write inside
    one statement, so concurrent workers can't lose increments."""
    stmt = _insert(rate_limits).values(bucket_key=bucket_key, window_start=window_start, count=1)
    stmt = stmt.on_conflict_do_update(
        index_elements=["bucket_key", "window_start"],
        set_={"count": rate_limits.c.count + 1},
    ).returning(rate_limits.c.count)
    with _get_engine().begin() as conn:
        return int(conn.execute(stmt).scalar_one())


def rate_limit_cleanup(older_than: int) -> None:
    """Delete counter rows whose window ended before `older_than` (epoch secs)."""
    with _get_engine().begin() as conn:
        conn.execute(delete(rate_limits).where(rate_limits.c.window_start < older_than))


# --------------------------------------------------------------------------- #
# Feedback
# --------------------------------------------------------------------------- #


def save_feedback(
    *,
    rating: Optional[int],
    message: Optional[str],
    contact_email: Optional[str],
    app_version: Optional[str],
    platform: Optional[str],
    created_at: str,
) -> int:
    """Insert one feedback row; returns its new id."""
    stmt = feedback.insert().values(
        rating=rating,
        message=message,
        contact_email=contact_email,
        app_version=app_version,
        platform=platform,
        created_at=created_at,
    )
    with _get_engine().begin() as conn:
        result = conn.execute(stmt)
        return int(result.inserted_primary_key[0])


def get_all_feedback() -> list:
    """Every feedback row, newest first (for the admin page). Returns RowMapping
    objects, which support `row["rating"]`-style access like the old sqlite3.Row."""
    with _get_engine().begin() as conn:
        rows = conn.execute(
            select(feedback).order_by(feedback.c.created_at.desc(), feedback.c.id.desc())
        ).mappings().all()
    return list(rows)
