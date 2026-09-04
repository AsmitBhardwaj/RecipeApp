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
    Index,
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

# --- Sync (Stage 2) -------------------------------------------------------- #

# One generic table for every synced collection (meal plan, grocery checks,
# grocery manual items, cookbooks, memberships, library entries). The client
# owns each `payload` shape; the server treats it as opaque JSON and only
# arbitrates convergence:
#   * `updated_at` — client wall-clock ms; the last-writer-wins comparison key.
#   * `deleted`    — tombstone (a delete is just an update with a newer ts).
#   * `seq`        — a per-user monotonic version the server assigns on every
#                    write, so a device can pull "everything since cursor N".
sync_items = Table(
    "sync_items",
    metadata,
    Column("user_id", String, primary_key=True),
    Column("collection", String, primary_key=True),
    Column("item_id", String, primary_key=True),
    Column("seq", BigInteger, nullable=False),
    Column("updated_at", BigInteger, nullable=False),
    Column("deleted", Boolean, nullable=False, default=False),
    Column("payload", Text),
    Index("idx_sync_user_seq", "user_id", "seq"),
)

# Per-user monotonic counter that allocates `seq` values (kept separate so
# allocation is a single atomic UPSERT, not a MAX() scan racing under load).
sync_state = Table(
    "sync_state",
    metadata,
    Column("user_id", String, primary_key=True),
    Column("seq", BigInteger, nullable=False, default=0),
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


def health_check() -> dict:
    """Liveness probe for the configured database: run `SELECT 1` against the
    real engine and report the dialect. Raises if the DB is unreachable so the
    caller (the /health endpoint) can fail loudly — the whole point is that a DB
    outage shows up in monitoring instead of every job silently failing while
    `GET /` still says "ok". Also surfaces which backend is actually live
    (postgresql vs sqlite), so a misconfigured DATABASE_URL is visible."""
    from sqlalchemy import text

    engine = _get_engine()
    with engine.connect() as conn:
        conn.execute(text("SELECT 1"))
    return {"database": "ok", "dialect": engine.dialect.name}


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


# --------------------------------------------------------------------------- #
# Sync (Stage 2) — generic per-user, last-writer-wins record store
# --------------------------------------------------------------------------- #

# The collections the client is allowed to sync. Kept as an allowlist so a
# compromised/buggy client can't spray arbitrary collection names into the table.
SYNC_COLLECTIONS = frozenset(
    {"library", "meal_plan", "grocery_check", "grocery_manual", "cookbook", "cookbook_membership"}
)


def _allocate_seq(conn, user_id: str, n: int) -> int:
    """Atomically reserve `n` consecutive seq values for a user and return the
    FIRST one. The single UPSERT + RETURNING makes concurrent pushes safe: each
    gets a disjoint block."""
    stmt = _insert(sync_state).values(user_id=user_id, seq=n)
    stmt = stmt.on_conflict_do_update(
        index_elements=["user_id"], set_={"seq": sync_state.c.seq + n}
    ).returning(sync_state.c.seq)
    new_max = int(conn.execute(stmt).scalar_one())
    return new_max - n + 1


def sync_user_cursor(user_id: str) -> int:
    """The user's current max seq (0 if they have no synced data yet)."""
    with _get_engine().begin() as conn:
        row = conn.execute(select(sync_state.c.seq).where(sync_state.c.user_id == user_id)).fetchone()
    return int(row[0]) if row else 0


def sync_push(user_id: str, changes: list[dict]) -> dict:
    """Apply a batch of client mutations under last-writer-wins.

    Each change is {collection, item_id, updated_at, deleted, payload}. A change
    is accepted only if it is newer (strictly greater `updated_at`) than what the
    server holds — otherwise the SERVER's record wins and is returned as a
    conflict so the client can reconcile its mirror. Returns
    {applied: [...ids], conflicts: [server rows], cursor: <user max seq>}.
    """
    applied: list[str] = []
    conflicts: list[dict] = []

    with _get_engine().begin() as conn:
        # Resolve winners against current server state (per-item read keeps this
        # portable and correct; batches are modest).
        winners: list[dict] = []
        for ch in changes:
            existing = conn.execute(
                select(sync_items.c.updated_at).where(
                    sync_items.c.user_id == user_id,
                    sync_items.c.collection == ch["collection"],
                    sync_items.c.item_id == ch["item_id"],
                )
            ).fetchone()
            if existing is None or ch["updated_at"] > int(existing[0]):
                winners.append(ch)
            else:
                row = conn.execute(
                    select(sync_items).where(
                        sync_items.c.user_id == user_id,
                        sync_items.c.collection == ch["collection"],
                        sync_items.c.item_id == ch["item_id"],
                    )
                ).mappings().fetchone()
                conflicts.append(_sync_row_to_change(row))

        if winners:
            base = _allocate_seq(conn, user_id, len(winners))
            for offset, ch in enumerate(winners):
                stmt = _insert(sync_items).values(
                    user_id=user_id,
                    collection=ch["collection"],
                    item_id=ch["item_id"],
                    seq=base + offset,
                    updated_at=ch["updated_at"],
                    deleted=bool(ch.get("deleted", False)),
                    payload=ch.get("payload"),
                )
                stmt = stmt.on_conflict_do_update(
                    index_elements=["user_id", "collection", "item_id"],
                    set_={
                        "seq": stmt.excluded.seq,
                        "updated_at": stmt.excluded.updated_at,
                        "deleted": stmt.excluded.deleted,
                        "payload": stmt.excluded.payload,
                    },
                )
                conn.execute(stmt)
                applied.append(ch["item_id"])

        cursor_row = conn.execute(
            select(sync_state.c.seq).where(sync_state.c.user_id == user_id)
        ).fetchone()
        cursor = int(cursor_row[0]) if cursor_row else 0

    return {"applied": applied, "conflicts": conflicts, "cursor": cursor}


def sync_pull(user_id: str, cursor: int, limit: int) -> dict:
    """Everything changed for a user since `cursor`, ordered by seq. Returns
    {changes: [...], cursor: <new cursor>, has_more: bool}."""
    with _get_engine().begin() as conn:
        rows = conn.execute(
            select(sync_items)
            .where(sync_items.c.user_id == user_id, sync_items.c.seq > cursor)
            .order_by(sync_items.c.seq.asc())
            .limit(limit + 1)
        ).mappings().all()

    has_more = len(rows) > limit
    rows = rows[:limit]
    changes = [_sync_row_to_change(r) for r in rows]
    new_cursor = changes[-1]["seq"] if changes else cursor
    return {"changes": changes, "cursor": new_cursor, "has_more": has_more}


def _sync_row_to_change(row) -> dict:
    return {
        "collection": row["collection"],
        "item_id": row["item_id"],
        "seq": int(row["seq"]),
        "updated_at": int(row["updated_at"]),
        "deleted": bool(row["deleted"]),
        "payload": row["payload"],
    }


def delete_user_sync_data(user_id: str) -> None:
    """Hard-delete all of a user's synced rows + their seq counter (Stage 5)."""
    with _get_engine().begin() as conn:
        conn.execute(delete(sync_items).where(sync_items.c.user_id == user_id))
        conn.execute(delete(sync_state).where(sync_state.c.user_id == user_id))


def delete_account(user_id: str) -> None:
    """Hard-delete a user and everything scoped to them, in one transaction
    (Stage 5, in-app account deletion). Removes synced records + seq counter, the
    per-user recipe join rows, all refresh tokens, provider identities, and the
    account row itself. The shared recipe CACHE (keyed by canonical video id) is
    intentionally left intact — it's not personal data and other users rely on it.
    """
    with _get_engine().begin() as conn:
        conn.execute(delete(sync_items).where(sync_items.c.user_id == user_id))
        conn.execute(delete(sync_state).where(sync_state.c.user_id == user_id))
        conn.execute(delete(user_recipes).where(user_recipes.c.user_id == user_id))
        conn.execute(delete(refresh_tokens).where(refresh_tokens.c.user_id == user_id))
        conn.execute(delete(auth_identities).where(auth_identities.c.user_id == user_id))
        conn.execute(delete(users).where(users.c.id == user_id))


def recipes_by_ids(ids: list[str]) -> list[Recipe]:
    """Full recipe content for a set of ids, from the shared cache. Lets a new
    device hydrate the recipe bodies for the library entries it just pulled."""
    if not ids:
        return []
    with _get_engine().begin() as conn:
        rows = conn.execute(select(recipes.c.data).where(recipes.c.recipe_id.in_(ids))).fetchall()
    return [Recipe.model_validate_json(r[0]) for r in rows]
