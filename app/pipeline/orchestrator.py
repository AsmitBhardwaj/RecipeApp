"""Wires the whole pipeline into one synchronous flow (CLAUDE.md §3 / §5).

    URL -> canonical id -> CACHE CHECK -> fetch -> signal check ->
      (extract | dish-id -> generic) -> validate -> image -> save.

Runs synchronously for now: POST a URL, get a finished recipe back in one
request/response cycle. Background queue/workers are a later optimization.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from .. import config, db
from ..models import Confidence, DishIdentification, Job, LLMRecipe, Recipe, UserRecipe
from . import fetch, images, llm, signal, urls


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _with_generated_instructions(
    extracted: LLMRecipe, generated: LLMRecipe
) -> LLMRecipe:
    """Merge for the "real ingredients, generated method" case.

    Keeps the caption's real ingredients/title/times and swaps in the generated
    instructions. The `Confidence` object carries the mixed nature (ingredients
    stay complete since they're real; overall is capped to signal a generic
    reference method; "instructions" is no longer a missing field).
    """
    old = extracted.confidence
    conf = Confidence(
        overall=min(old.overall, 0.5),
        ingredients_complete=old.ingredients_complete,
        instructions_complete=bool(generated.instructions),
        missing_fields=[f for f in old.missing_fields if f != "instructions"],
    )
    return extracted.model_copy(
        update={"instructions": generated.instructions, "confidence": conf}
    )


def _fail(job: Job, code: str, message: str) -> Job:
    job.status = "failed"
    job.error_code = code
    job.error = message
    db.save_job(job)
    return job


def _finalize(job: Job, recipe: Recipe) -> Job:
    db.save_recipe(recipe)
    db.save_user_recipe(
        UserRecipe(
            user_id=job.user_id,
            recipe_id=recipe.recipe_id,
            saved_at=_now(),
        )
    )
    job.recipe_id = recipe.recipe_id
    job.status = "complete"
    db.save_job(job)
    return job


def create_job(url: str, user_id: str) -> Job:
    """Create and persist a fresh `queued` Job, returning it immediately.

    Split out from `process_job` so the API can hand back a job_id in well under
    a second and run the (slow) extraction afterwards via BackgroundTasks. This
    does NO network work — it only writes the queued row.
    """
    job = Job(
        job_id=str(uuid.uuid4()),
        user_id=user_id,
        url=url,
        created_at=_now(),
    )
    db.save_job(job)  # status defaults to "queued"
    return job


def process_job(job: Job) -> Job:
    """Run the full extraction for an already-created (queued) Job.

    Single source of truth for the extraction pipeline — called synchronously
    in tests and via BackgroundTasks in production. Expects `job` to already be
    persisted (see `create_job`).
    """
    # 1. Normalize/expand URL + extract canonical video id (the cache key).
    try:
        resolved = urls.resolve(job.url)
    except urls.UrlError as exc:
        return _fail(job, "invalid_url", str(exc))

    job.canonical_video_id = resolved.canonical_video_id
    job.platform = resolved.platform  # type: ignore[assignment]
    job.status = "processing"
    db.save_job(job)

    # 2. CACHE CHECK — hard requirement. Never re-extract/re-call the LLM for a
    #    video we've already processed (CLAUDE.md §7).
    cached = db.get_recipe_by_video_id(resolved.canonical_video_id)
    if cached is not None:
        return _finalize(job, cached)

    # 3. Fetch caption / metadata / thumbnail. Instagram uses the embed-endpoint
    #    scrape; everything else (TikTok) goes through yt-dlp.
    try:
        if resolved.platform == "instagram":
            meta = fetch.fetch_instagram_metadata(resolved.url)
        else:
            meta = fetch.fetch_metadata(resolved.url)
    except fetch.FetchError as exc:
        return _fail(job, exc.code, exc.message)

    fallback_title = meta.title or "Untitled recipe"

    # 4. Signal check → extract vs dish-ID fallback.
    try:
        if signal.has_recipe_signal(meta.caption):
            llm_recipe = llm.extract_recipe(meta.caption)
            source_type = "caption"
            # Gap fix (CLAUDE.md §5): the strict extraction prompt is correctly
            # forbidden from inventing steps, so an ingredients-only caption
            # comes back with real ingredients but ZERO instructions. Rather
            # than ship a stepless recipe, generate a method for those exact
            # ingredients and flag the whole recipe as generated — the same
            # treatment as the no-signal fallback. Scoped strictly to the
            # empty-instructions case; captions with partial steps are untouched.
            if llm_recipe.ingredients and not llm_recipe.instructions:
                dish = DishIdentification(dish_name=llm_recipe.title)
                generated = llm.generate_generic_recipe(
                    dish, known_ingredients=llm_recipe.ingredients
                )
                llm_recipe = _with_generated_instructions(llm_recipe, generated)
                source_type = "generated"
        else:
            dish = llm.identify_dish(meta.caption)
            if not dish.dish_name:
                # Can't even name the dish — surface "couldn't read this one".
                return _fail(
                    job,
                    "could_not_identify_dish",
                    "caption lacked recipe signal and the dish could not be identified",
                )
            llm_recipe = llm.generate_generic_recipe(dish)
            source_type = "generated"
    except llm.LLMError as exc:
        return _fail(job, exc.code, exc.message)

    # 5. Resolve image (thumbnail -> stock -> none).
    title = llm_recipe.title or fallback_title
    image_url, image_source = images.resolve_image(meta.thumbnail_url, title)

    # 6. Assemble the full, cacheable Recipe.
    recipe = Recipe(
        recipe_id=str(uuid.uuid4()),
        canonical_video_id=resolved.canonical_video_id,
        title=title,
        servings=llm_recipe.servings,
        prep_time_minutes=llm_recipe.prep_time_minutes,
        cook_time_minutes=llm_recipe.cook_time_minutes,
        total_time_minutes=llm_recipe.total_time_minutes,
        ingredients=llm_recipe.ingredients,
        instructions=llm_recipe.instructions,
        confidence=llm_recipe.confidence,
        source_type=source_type,  # type: ignore[arg-type]
        image_url=image_url,
        image_source=image_source,  # type: ignore[arg-type]
    )

    return _finalize(job, recipe)
