"""One-time backfill of `ingredients[].normalized_name` on recipes cached before
ingredient normalization shipped.

New recipes get `normalized_name` populated automatically at write time
(app/db.save_recipe → ingredient_matching.normalize_ingredients). This script
only fills the gap for the recipes already in the cache: it walks the `recipes`
table and, for every recipe that has at least one ingredient still missing a
`normalized_name`, recomputes normalized names for that recipe and writes it back
into the SAME cached row — so normalization is done once per recipe and shared
across every user who saved that video, never per user.

No LLM calls and no network — normalization is pure local string work, so this
is cheap and safe to re-run.

Runs against whatever DB app.db is configured for: local SQLite by default, or
Railway Postgres when DATABASE_URL is set (same resolution as the app).

Usage:
    # dry run first — reports what WOULD change (old name -> normalized), writes
    # nothing:
    python -m scripts.backfill_ingredient_normalization --dry-run

    # real run (against prod also set DATABASE_URL):
    DATABASE_URL=postgresql://user:pass@host:5432/railway \\
    python -m scripts.backfill_ingredient_normalization

Options:
    --dry-run      Show which recipes/ingredients would be normalized; write
                   nothing.
    --limit N      Process at most N recipes this run (default: all).

Idempotent: recipes whose ingredients already all have a `normalized_name` are
skipped, so re-running only touches the ones still missing it. NOTE: because
save_recipe recomputes normalization on every write, a plain re-save would also
normalize — this script exists to do that deliberately and report exactly what
changed before it touches production data.
"""
from __future__ import annotations

import argparse

from sqlalchemy import select

from app import db  # noqa: E402  (imports metadata + Table definitions)
from app.ingredient_matching import normalize_ingredient_name, normalize_ingredients
from app.models import Recipe


def _iter_recipes():
    """Yield every cached Recipe (decoded)."""
    engine = db.get_engine()
    with engine.begin() as conn:
        rows = conn.execute(select(db.recipes.c.data)).fetchall()
    for (data,) in rows:
        yield Recipe.model_validate_json(data)


def _needs_backfill(recipe: Recipe) -> bool:
    """A recipe needs work if any ingredient lacks a normalized_name."""
    return any(ing.normalized_name is None for ing in recipe.ingredients)


def main() -> int:
    parser = argparse.ArgumentParser(description="Backfill ingredient normalized_name.")
    parser.add_argument("--dry-run", action="store_true", help="report only; write nothing")
    parser.add_argument("--limit", type=int, default=None, help="max recipes to process")
    args = parser.parse_args()

    db.init_db()

    all_recipes = list(_iter_recipes())
    missing = [r for r in all_recipes if _needs_backfill(r)]
    print(f"cache: {len(all_recipes)} recipes, {len(missing)} missing normalized_name")

    if not missing:
        print("nothing to backfill.")
        return 0

    targets = missing[: args.limit] if args.limit is not None else missing

    if args.dry_run:
        print("dry run — nothing written. Would normalize:")
        for i, recipe in enumerate(targets, start=1):
            print(f"[{i}/{len(targets)}] {recipe.title!r} ({recipe.canonical_video_id})")
            for ing in recipe.ingredients:
                norm = normalize_ingredient_name(ing.name)
                print(f"    {ing.name!r} -> {norm!r}")
        return 0

    written = 0
    for i, recipe in enumerate(targets, start=1):
        updated = recipe.model_copy(
            update={"ingredients": normalize_ingredients(recipe.ingredients)}
        )
        db.save_recipe(updated)
        written += 1
        print(f"[{i}/{len(targets)}] ok {recipe.title!r} ({recipe.canonical_video_id})")

    print(f"\ndone: {written} recipes normalized")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
