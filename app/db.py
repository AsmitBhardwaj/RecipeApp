"""Tiny SQLite storage layer. Single file, no external service.

Recipes are cached by `canonical_video_id` (UNIQUE) — this is the idempotency
key that stops a viral video from triggering redundant LLM/scrape work
(CLAUDE.md §7). Jobs and recipes are stored as JSON blobs with the lookup keys
promoted to real columns.
"""
from __future__ import annotations

import json
import os
import sqlite3
from contextlib import contextmanager
from typing import Iterator, Optional

from . import config
from .models import Job, Recipe, UserRecipe


def _connect() -> sqlite3.Connection:
    # WAL lets the polling reads (GET /v1/jobs/{id}) run concurrently with the
    # background writer instead of hitting "database is locked" under the async
    # job model; busy_timeout adds a grace window for the brief moments a writer
    # actually holds the lock. Both are safe to set on every connection.
    conn = sqlite3.connect(config.DB_PATH, timeout=5.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    return conn


@contextmanager
def _tx() -> Iterator[sqlite3.Connection]:
    """Open a connection, wrap the body in a transaction (commit on success,
    rollback on error), and ALWAYS close it.

    The bare `with sqlite3.connect(...) as conn:` form manages the transaction
    but never closes the connection — a leak that the new high-frequency polling
    path would make painful.
    """
    conn = _connect()
    try:
        with conn:
            yield conn
    finally:
        conn.close()


def init_db() -> None:
    # DB_PATH may point at a mounted volume (e.g. /data/recipes.db on Railway);
    # make sure its parent directory exists before SQLite tries to open the file.
    db_dir = os.path.dirname(config.DB_PATH)
    if db_dir:
        os.makedirs(db_dir, exist_ok=True)
    with _tx() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS jobs (
                job_id TEXT PRIMARY KEY,
                data   TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS recipes (
                recipe_id          TEXT PRIMARY KEY,
                canonical_video_id TEXT UNIQUE NOT NULL,
                data               TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_recipes_video_id
                ON recipes (canonical_video_id);

            CREATE TABLE IF NOT EXISTS user_recipes (
                user_id     TEXT NOT NULL,
                recipe_id   TEXT NOT NULL,
                custom_name TEXT,
                sort_key    TEXT,
                saved_at    TEXT NOT NULL,
                PRIMARY KEY (user_id, recipe_id)
            );

            -- Persistent fixed-window rate-limit counters (app/ratelimit.py).
            -- One row per (identity+scope+window-size, window-start); survives
            -- restarts/redeploys, unlike the old in-memory limiter.
            CREATE TABLE IF NOT EXISTS rate_limits (
                bucket_key   TEXT    NOT NULL,
                window_start INTEGER NOT NULL,
                count        INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (bucket_key, window_start)
            );

            -- User feedback (POST /feedback), shown on the /admin/feedback page.
            -- At least one of rating/message is enforced at the API level.
            CREATE TABLE IF NOT EXISTS feedback (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                rating        INTEGER,
                message       TEXT,
                contact_email TEXT,
                app_version   TEXT,
                platform      TEXT,
                created_at    TEXT NOT NULL
            );

            -- Admin page lists newest-first; index keeps that ordering cheap.
            CREATE INDEX IF NOT EXISTS idx_feedback_created_at
                ON feedback (created_at DESC);
            """
        )


# --------------------------------------------------------------------------- #
# Jobs
# --------------------------------------------------------------------------- #


def save_job(job: Job) -> None:
    with _tx() as conn:
        conn.execute(
            "INSERT INTO jobs (job_id, data) VALUES (?, ?) "
            "ON CONFLICT(job_id) DO UPDATE SET data = excluded.data",
            (job.job_id, job.model_dump_json()),
        )


def get_job(job_id: str) -> Optional[Job]:
    with _tx() as conn:
        row = conn.execute(
            "SELECT data FROM jobs WHERE job_id = ?", (job_id,)
        ).fetchone()
    return Job.model_validate_json(row["data"]) if row else None


# --------------------------------------------------------------------------- #
# Recipes (cache)
# --------------------------------------------------------------------------- #


def save_recipe(recipe: Recipe) -> None:
    with _tx() as conn:
        conn.execute(
            "INSERT INTO recipes (recipe_id, canonical_video_id, data) "
            "VALUES (?, ?, ?) "
            "ON CONFLICT(recipe_id) DO UPDATE SET data = excluded.data",
            (recipe.recipe_id, recipe.canonical_video_id, recipe.model_dump_json()),
        )


def get_recipe_by_video_id(canonical_video_id: str) -> Optional[Recipe]:
    with _tx() as conn:
        row = conn.execute(
            "SELECT data FROM recipes WHERE canonical_video_id = ?",
            (canonical_video_id,),
        ).fetchone()
    return Recipe.model_validate_json(row["data"]) if row else None


def get_recipe(recipe_id: str) -> Optional[Recipe]:
    with _tx() as conn:
        row = conn.execute(
            "SELECT data FROM recipes WHERE recipe_id = ?", (recipe_id,)
        ).fetchone()
    return Recipe.model_validate_json(row["data"]) if row else None


# --------------------------------------------------------------------------- #
# User <-> recipe join
# --------------------------------------------------------------------------- #


def save_user_recipe(link: UserRecipe) -> None:
    with _tx() as conn:
        conn.execute(
            "INSERT INTO user_recipes "
            "(user_id, recipe_id, custom_name, sort_key, saved_at) "
            "VALUES (?, ?, ?, ?, ?) "
            "ON CONFLICT(user_id, recipe_id) DO NOTHING",
            (link.user_id, link.recipe_id, link.custom_name, link.sort_key, link.saved_at),
        )


# --------------------------------------------------------------------------- #
# Rate-limit counters
# --------------------------------------------------------------------------- #


def rate_limit_incr(bucket_key: str, window_start: int) -> int:
    """Atomically bump the counter for (bucket_key, window_start) and return the
    new value. A single UPSERT ... RETURNING keeps the read-modify-write inside
    one statement, so concurrent workers can't lose increments."""
    with _tx() as conn:
        row = conn.execute(
            "INSERT INTO rate_limits (bucket_key, window_start, count) "
            "VALUES (?, ?, 1) "
            "ON CONFLICT(bucket_key, window_start) DO UPDATE SET count = count + 1 "
            "RETURNING count",
            (bucket_key, window_start),
        ).fetchone()
    return int(row["count"])


def rate_limit_cleanup(older_than: int) -> None:
    """Delete counter rows whose window ended before `older_than` (epoch secs).
    Only the current window is ever read, so anything older is dead weight."""
    with _tx() as conn:
        conn.execute("DELETE FROM rate_limits WHERE window_start < ?", (older_than,))


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
    with _tx() as conn:
        cur = conn.execute(
            "INSERT INTO feedback "
            "(rating, message, contact_email, app_version, platform, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (rating, message, contact_email, app_version, platform, created_at),
        )
        return int(cur.lastrowid)


def get_all_feedback() -> list[sqlite3.Row]:
    """Every feedback row, newest first (for the admin page)."""
    with _tx() as conn:
        rows = conn.execute(
            "SELECT id, rating, message, contact_email, app_version, platform, "
            "created_at FROM feedback ORDER BY created_at DESC, id DESC"
        ).fetchall()
    return list(rows)
