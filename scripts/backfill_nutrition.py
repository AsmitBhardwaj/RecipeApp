"""One-time backfill of `nutrition` onto recipes cached before nutrition shipped.

New recipes get nutrition inside the main extraction call (no extra round-trip).
This script only fills the gap for recipes already in the cache: it walks the
`recipes` table, and for every recipe whose `nutrition` is still null it makes a
single nutrition-only LLM call (llm.estimate_nutrition) and writes the result
back into the SAME cached recipe row — so it's computed once per recipe and
shared across every user who saved that video, never per user.

Runs against whatever DB app.db is configured for: local SQLite by default, or
Railway Postgres when DATABASE_URL is set (same resolution as the app).

Usage:
    # dry run first — counts what WOULD be backfilled, makes no LLM calls, writes
    # nothing:
    python -m scripts.backfill_nutrition --dry-run

    # real run (needs OPENAI_API_KEY; against prod also set DATABASE_URL):
    OPENAI_API_KEY=sk-... \\
    DATABASE_URL=postgresql://user:pass@host:5432/railway \\
    python -m scripts.backfill_nutrition

Options:
    --dry-run      Report how many recipes lack nutrition; do not call the LLM or
                   write anything.
    --limit N      Process at most N recipes this run (default: all). Handy for a
                   small trial batch before committing to the whole cache.

Idempotent: a recipe that already has nutrition is skipped, so re-running only
picks up the ones still missing it (e.g. after transient LLM failures). NOTE:
recipes where the model legitimately returns null (too few usable quantities to
estimate) stay null and WILL be re-attempted on a later run — that's cheap at
this cache size and avoids a schema change just to record "tried, gave up".
"""
from __future__ import annotations

import argparse
import sys
import time

from sqlalchemy import select

from app import db  # noqa: E402  (imports metadata + Table definitions)
from app.models import Recipe
from app.pipeline import llm

# Gentle pacing between LLM calls so a large backfill doesn't burst the API.
_SLEEP_SECONDS = 0.2


def _iter_recipes():
    """Yield every cached Recipe (decoded), newest storage order irrelevant."""
    engine = db.get_engine()
    with engine.begin() as conn:
        rows = conn.execute(select(db.recipes.c.data)).fetchall()
    for (data,) in rows:
        yield Recipe.model_validate_json(data)


def main() -> int:
    parser = argparse.ArgumentParser(description="Backfill recipe nutrition.")
    parser.add_argument("--dry-run", action="store_true", help="count only; no LLM, no writes")
    parser.add_argument("--limit", type=int, default=None, help="max recipes to process")
    args = parser.parse_args()

    db.init_db()

    all_recipes = list(_iter_recipes())
    missing = [r for r in all_recipes if r.nutrition is None]
    print(f"cache: {len(all_recipes)} recipes, {len(missing)} missing nutrition")

    if args.dry_run:
        print("dry run — no LLM calls, nothing written.")
        return 0

    if not missing:
        print("nothing to backfill.")
        return 0

    targets = missing[: args.limit] if args.limit is not None else missing
    filled = skipped_null = failed = 0

    for i, recipe in enumerate(targets, start=1):
        label = f"[{i}/{len(targets)}] {recipe.title!r} ({recipe.canonical_video_id})"
        try:
            nutrition = llm.estimate_nutrition(
                title=recipe.title,
                ingredients=recipe.ingredients,
                servings=recipe.servings,
            )
        except llm.LLMError as exc:
            failed += 1
            print(f"  FAIL {label}: {exc.code}: {exc.message}", file=sys.stderr)
            continue

        if nutrition is None:
            skipped_null += 1
            print(f"  null {label}: not enough usable quantities — left null")
            time.sleep(_SLEEP_SECONDS)
            continue

        # Write the estimate back into the SAME cached row (shared across users).
        updated = recipe.model_copy(update={"nutrition": nutrition})
        db.save_recipe(updated)
        filled += 1
        print(f"  ok   {label}: {nutrition.basis}/{nutrition.source} {nutrition.calories} kcal")
        time.sleep(_SLEEP_SECONDS)

    print(f"\ndone: {filled} filled, {skipped_null} left null, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
