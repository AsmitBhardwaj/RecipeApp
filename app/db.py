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
    Float,
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

from . import config, ingredient_matching
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

# Successful-import ledger for the free-tier monthly limit (app/importlimit.py).
# One row per successfully-completed import, keyed by `job_id` as the PRIMARY KEY
# so recording is idempotent: a paste-text retry finalizes the SAME job_id, and
# `on_conflict_do_nothing` means it is never counted twice. Failed / site_blocked
# jobs never reach `_finalize`, so they are never recorded. `year_month` is the
# UTC calendar-month bucket ("YYYY-MM") the count query filters on.
import_events = Table(
    "import_events",
    metadata,
    Column("job_id", String, primary_key=True),
    Column("account_id", String, nullable=False),
    Column("year_month", String, nullable=False),
    Column("created_at", Text, nullable=False),
    Index("ix_import_events_account_month", "account_id", "year_month"),
)

# Device-level account-creation abuse signal (app/devicesignal.py). One row per
# account, recording the device (the client's persistent `X-User-Id`) it was
# created from and whether that device had ALREADY created another account within
# a trailing window. `flagged` is ADVISORY — surfaced for manual review, never
# auto-enforced (shared devices / reinstalls make false positives expected).
# `device_id` is nullable: an account created without a usable header is recorded
# unflagged and never correlates with others (a null device is not "the same
# device" as another null). Kept as its own table (not a column on `users`) so it
# is created cleanly by `create_all` without a Postgres migration.
account_device_signals = Table(
    "account_device_signals",
    metadata,
    Column("account_id", String, primary_key=True),
    Column("device_id", String),
    Column("created_at", Text, nullable=False),
    Column("flagged", Boolean, nullable=False, default=False),
    Column("related_account_id", String),  # the prior same-device account, when flagged
    Index("ix_account_device_signals_device", "device_id", "created_at"),
)

# Internal-only LLM cost ledger (app/llm_cost.py). One row per LLM API call tied
# to a recipe import, budget-plan generation, or pantry suggestion. Purely for
# post-launch unit-economics review — never read on any user-facing path. Raw
# token counts are stored alongside the estimated cost so spend can be recomputed
# if published rates change. `account_id` is nullable (an unauthenticated import
# has no account); such rows group under a NULL bucket in the admin sum.
llm_cost_events = Table(
    "llm_cost_events",
    metadata,
    Column("id", Integer, primary_key=True, autoincrement=True),
    Column("account_id", String),  # nullable — anonymous import has no account
    Column("call_type", String, nullable=False),  # import | budget_plan | pantry_suggestion
    Column("model", String, nullable=False),
    Column("prompt_tokens", Integer, nullable=False, default=0),
    Column("cached_tokens", Integer, nullable=False, default=0),
    Column("completion_tokens", Integer, nullable=False, default=0),
    # Nullable: NULL means "no known rate for this model", distinct from $0.
    Column("estimated_cost_usd", Float),
    Column("created_at", Text, nullable=False),
    Index("ix_llm_cost_events_account_created", "account_id", "created_at"),
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
# Import ledger (free-tier monthly limit — app/importlimit.py)
# --------------------------------------------------------------------------- #


def record_import_event(account_id: str, job_id: str, year_month: str, created_at: str) -> None:
    """Record ONE successful import against an account's monthly count. Idempotent
    per `job_id` (PRIMARY KEY + do-nothing on conflict) so a paste-text retry of
    the same job — or any re-finalize — is never counted twice."""
    stmt = _insert(import_events).values(
        job_id=job_id, account_id=account_id, year_month=year_month, created_at=created_at
    ).on_conflict_do_nothing(index_elements=["job_id"])
    with _get_engine().begin() as conn:
        conn.execute(stmt)


def count_imports_in_month(account_id: str, year_month: str) -> int:
    """How many successful imports this account has recorded in the given UTC
    calendar month ("YYYY-MM")."""
    from sqlalchemy import func

    stmt = (
        select(func.count())
        .select_from(import_events)
        .where(import_events.c.account_id == account_id)
        .where(import_events.c.year_month == year_month)
    )
    with _get_engine().begin() as conn:
        return int(conn.execute(stmt).scalar_one())


# --------------------------------------------------------------------------- #
# LLM cost ledger (internal unit economics — app/llm_cost.py)
# --------------------------------------------------------------------------- #


def record_llm_cost_event(
    *,
    account_id: Optional[str],
    call_type: str,
    model: str,
    prompt_tokens: int,
    cached_tokens: int,
    completion_tokens: int,
    estimated_cost_usd: Optional[float],
    created_at: str,
) -> None:
    """Append one LLM cost event. Fire-and-forget append (no upsert): each LLM
    API call is its own row, so a multi-call import produces several rows."""
    stmt = llm_cost_events.insert().values(
        account_id=account_id,
        call_type=call_type,
        model=model,
        prompt_tokens=prompt_tokens,
        cached_tokens=cached_tokens,
        completion_tokens=completion_tokens,
        estimated_cost_usd=estimated_cost_usd,
        created_at=created_at,
    )
    with _get_engine().begin() as conn:
        conn.execute(stmt)


def sum_llm_cost_by_account(
    since_iso: Optional[str] = None, until_iso: Optional[str] = None
) -> list[dict]:
    """Internal admin query: total estimated LLM spend per account over an
    optional [since, until) window (ISO-8601 UTC strings; timestamps are stored as
    `+00:00` isoformat so string comparison is chronological). Returns one dict
    per account, highest spend first, each with the summed cost, call count, and
    token totals. A NULL `account_id` (unauthenticated imports) is its own row."""
    from sqlalchemy import func

    cost = func.coalesce(func.sum(llm_cost_events.c.estimated_cost_usd), 0.0)
    stmt = select(
        llm_cost_events.c.account_id,
        cost.label("estimated_cost_usd"),
        func.count().label("calls"),
        func.coalesce(func.sum(llm_cost_events.c.prompt_tokens), 0).label("prompt_tokens"),
        func.coalesce(func.sum(llm_cost_events.c.cached_tokens), 0).label("cached_tokens"),
        func.coalesce(func.sum(llm_cost_events.c.completion_tokens), 0).label("completion_tokens"),
    )
    if since_iso is not None:
        stmt = stmt.where(llm_cost_events.c.created_at >= since_iso)
    if until_iso is not None:
        stmt = stmt.where(llm_cost_events.c.created_at < until_iso)
    stmt = stmt.group_by(llm_cost_events.c.account_id).order_by(cost.desc())
    with _get_engine().begin() as conn:
        rows = conn.execute(stmt).mappings().all()
    return [dict(r) for r in rows]


def accounts_over_spend(since_iso: str, threshold_usd: float) -> list[dict]:
    """Accounts whose estimated LLM spend since `since_iso` exceeds
    `threshold_usd` (the soft spend circuit breaker — app/spendsignal.py). Highest
    spend first. Excludes the NULL (unauthenticated) bucket: only real accounts
    can be flagged for review. Uses HAVING so the DB does the filtering."""
    from sqlalchemy import func

    cost = func.coalesce(func.sum(llm_cost_events.c.estimated_cost_usd), 0.0)
    stmt = (
        select(
            llm_cost_events.c.account_id,
            cost.label("estimated_cost_usd"),
            func.count().label("calls"),
        )
        .where(llm_cost_events.c.created_at >= since_iso)
        .where(llm_cost_events.c.account_id.isnot(None))
        .group_by(llm_cost_events.c.account_id)
        .having(cost > threshold_usd)
        .order_by(cost.desc())
    )
    with _get_engine().begin() as conn:
        rows = conn.execute(stmt).mappings().all()
    return [dict(r) for r in rows]


def account_spend_since(account_id: str, since_iso: str) -> float:
    """Total estimated LLM spend (USD) for ONE account since `since_iso`
    (ISO-8601 UTC). Powers the hard per-account 30-day spend cap (app/spendcap.py),
    so it must be cheap — served by the (account_id, created_at) index. Rows with a
    NULL cost (a model with no configured pricing) contribute 0."""
    from sqlalchemy import func

    cost = func.coalesce(func.sum(llm_cost_events.c.estimated_cost_usd), 0.0)
    stmt = (
        select(cost)
        .where(llm_cost_events.c.account_id == account_id)
        .where(llm_cost_events.c.created_at >= since_iso)
    )
    with _get_engine().begin() as conn:
        return float(conn.execute(stmt).scalar() or 0.0)


# --------------------------------------------------------------------------- #
# Device-level account-creation signal (app/devicesignal.py)
# --------------------------------------------------------------------------- #


def record_account_device_signal(
    account_id: str,
    device_id: Optional[str],
    created_at: str,
    flagged: bool,
    related_account_id: Optional[str],
) -> None:
    """Record the device an account was created from. Idempotent per account_id
    (do-nothing on conflict) so a re-run of the creation path never double-writes
    or flips an already-recorded flag."""
    stmt = _insert(account_device_signals).values(
        account_id=account_id,
        device_id=device_id,
        created_at=created_at,
        flagged=flagged,
        related_account_id=related_account_id,
    ).on_conflict_do_nothing(index_elements=["account_id"])
    with _get_engine().begin() as conn:
        conn.execute(stmt)


def recent_accounts_for_device(
    device_id: str, since_iso: str, exclude_account_id: Optional[str] = None
) -> list[str]:
    """Account ids created from `device_id` at/after `since_iso` (ISO-8601 UTC),
    newest first. Timestamps are all `+00:00` isoformat, so the string `>=`
    compares chronologically. Used to decide whether a new account should be
    flagged as a repeat device."""
    stmt = select(account_device_signals.c.account_id).where(
        account_device_signals.c.device_id == device_id,
        account_device_signals.c.created_at >= since_iso,
    )
    if exclude_account_id is not None:
        stmt = stmt.where(account_device_signals.c.account_id != exclude_account_id)
    stmt = stmt.order_by(account_device_signals.c.created_at.desc())
    with _get_engine().begin() as conn:
        return [r[0] for r in conn.execute(stmt).fetchall()]


def get_account_device_signal(account_id: str) -> Optional[dict]:
    """The device signal recorded for one account (or None), for manual triage."""
    with _get_engine().begin() as conn:
        row = conn.execute(
            select(account_device_signals).where(
                account_device_signals.c.account_id == account_id
            )
        ).mappings().fetchone()
    return dict(row) if row else None


def list_flagged_accounts() -> list[dict]:
    """Every flagged account-creation signal, newest first (manual-review queue)."""
    with _get_engine().begin() as conn:
        rows = conn.execute(
            select(account_device_signals)
            .where(account_device_signals.c.flagged.is_(True))
            .order_by(account_device_signals.c.created_at.desc())
        ).mappings().all()
    return [dict(r) for r in rows]


# --------------------------------------------------------------------------- #
# Recipes (cache)
# --------------------------------------------------------------------------- #


def save_recipe(recipe: Recipe) -> None:
    # Normalize ingredient names at the write chokepoint so EVERY recipe landing
    # in the cache carries `normalized_name` for pantry matching, regardless of
    # source path (caption, article, JSON-LD/structured, generated, paste, or a
    # backfill re-save). Idempotent — see ingredient_matching.normalize_ingredients.
    if recipe.ingredients:
        recipe = recipe.model_copy(
            update={"ingredients": ingredient_matching.normalize_ingredients(recipe.ingredients)}
        )
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


def all_recipes() -> list[Recipe]:
    """Every cached recipe. Backs the pantry-suggestion cache-search (option A —
    full scan; PANTRY_SCOPE.md §3a). Isolated here so a later inverted-index
    swap-in touches only this function, not its callers. Track its latency:
    it grows with the cache."""
    with _get_engine().begin() as conn:
        rows = conn.execute(select(recipes.c.data)).fetchall()
    return [Recipe.model_validate_json(r[0]) for r in rows]


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
    {"library", "meal_plan", "grocery_check", "grocery_manual", "cookbook", "cookbook_membership",
     "pantry_items"}
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


def pantry_item_names(user_id: str) -> list[str]:
    """The user's current pantry item names, read from the generic sync store
    (`pantry_items` collection). Tombstoned (deleted) rows are skipped; the
    payload is the client's opaque `PantryItem` JSON, from which we read only
    `name`. Used by the pantry-suggestion endpoint so the client need not re-send
    its pantry on every request. A malformed/paylod-less row is skipped, not
    fatal — one bad record must not sink the whole suggestion request."""
    import json

    with _get_engine().begin() as conn:
        rows = conn.execute(
            select(sync_items.c.payload).where(
                sync_items.c.user_id == user_id,
                sync_items.c.collection == "pantry_items",
                sync_items.c.deleted.is_(False),
            )
        ).fetchall()
    names: list[str] = []
    for (payload,) in rows:
        if not payload:
            continue
        try:
            name = json.loads(payload).get("name")
        except (ValueError, AttributeError):
            continue
        if isinstance(name, str) and name.strip():
            names.append(name)
    return names


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
