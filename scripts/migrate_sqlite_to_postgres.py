"""One-shot copy of existing SQLite data into Railway Postgres.

Stage 1 moves the DB from SQLite to Postgres. The only pre-existing data worth
carrying over is the recipe cache and jobs/feedback — the auth tables are new
and empty, and rate-limit counters are transient (they regenerate within a
minute), so both are skipped.

Usage:
    # point at the OLD sqlite file and the NEW postgres url, then run once
    SRC_SQLITE=recipes.db \\
    DATABASE_URL=postgresql://user:pass@host:5432/railway \\
    python -m scripts.migrate_sqlite_to_postgres

Idempotent: rows that already exist in Postgres (by primary key) are left
untouched, so re-running is safe.
"""
from __future__ import annotations

import os
import sys

from sqlalchemy import create_engine, select
from sqlalchemy.dialects.postgresql import insert as pg_insert

from app import db  # noqa: E402  (imports metadata + Table definitions)

# Tables to copy, in FK-safe order. rate_limits (transient) and the auth tables
# (new/empty) are intentionally omitted.
_TABLES = [db.recipes, db.jobs, db.user_recipes, db.feedback]


def main() -> int:
    src_path = os.getenv("SRC_SQLITE", "recipes.db")
    dst_url = os.getenv("DATABASE_URL")
    if not dst_url:
        print("ERROR: set DATABASE_URL to the target Postgres url.", file=sys.stderr)
        return 2
    if not os.path.exists(src_path):
        print(f"ERROR: source sqlite file not found: {src_path}", file=sys.stderr)
        return 2

    src = create_engine(f"sqlite:///{src_path}", future=True)
    dst = create_engine(db._normalize_url(dst_url), future=True)

    # Ensure the full schema (including auth tables) exists on the target.
    db.metadata.create_all(dst)

    total = 0
    with src.begin() as s, dst.begin() as d:
        for table in _TABLES:
            rows = [dict(r) for r in s.execute(select(table)).mappings().all()]
            if not rows:
                print(f"{table.name}: 0 rows")
                continue
            stmt = pg_insert(table).on_conflict_do_nothing()
            d.execute(stmt, rows)
            total += len(rows)
            print(f"{table.name}: copied {len(rows)} rows")

    print(f"done — {total} rows migrated into Postgres.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
