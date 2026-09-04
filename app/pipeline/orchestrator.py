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
from . import fetch, images, jsonld, llm, netguard, signal, urls, web


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

    # 2b. Generic web / blog tier — its own fetch + JSON-LD/article flow. Kept
    #     entirely separate from the IG/TikTok video path below.
    if resolved.platform == "web":
        return _process_web(job, resolved)

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


def process_pasted_text(job: Job, text: str) -> Job:
    """Retry a failed job with user-pasted recipe text instead of a fetch.

    The remedy for the `site_blocked` state (a publisher's bot protection stopped
    us from fetching the page — see app/pipeline/web.py) and its caption analog
    (`caption_not_found`): the user copies the recipe text themselves and we run
    it straight through extraction, skipping the network entirely.

    Retry-IN-PLACE: this reuses the SAME job (its already-resolved
    `canonical_video_id` and `platform`), flips it from `failed` back through
    `processing` to `complete`/`failed`, and caches the recipe under the existing
    canonical id — so one user pasting a blocked URL populates the shared cache
    for everyone who submits it later (the same compounding-cache behavior the
    normal pipeline relies on, CLAUDE.md §7).

    Extraction path is chosen by the job's `platform`: a blocked BLOG (platform
    "web", or unknown) is article-shaped → `extract_recipe_from_article`; a
    blocked/failed Instagram/TikTok CAPTION is caption-shaped → `extract_recipe`.
    The two prompts differ (ARTICLE vs CAPTION framing), so we route rather than
    force one to cover both.
    """
    is_caption = job.platform in ("instagram", "tiktok")

    job.status = "processing"
    job.extraction_method = "pasted_text"
    # Defensive: a job that failed before URL resolution would have no canonical
    # id, but the recipes cache key is NOT NULL — synthesize a stable one.
    if not job.canonical_video_id:
        job.canonical_video_id = f"paste:{job.url}"
    db.save_job(job)

    # If the same URL was pasted (or otherwise cached) since this job failed,
    # reuse the cached recipe rather than re-calling the LLM (and sidestep the
    # UNIQUE(canonical_video_id) constraint a fresh insert would hit).
    cached = db.get_recipe_by_video_id(job.canonical_video_id)
    if cached is not None:
        return _finalize(job, cached)

    try:
        if is_caption:
            llm_recipe = llm.extract_recipe(text)
        else:
            llm_recipe = llm.extract_recipe_from_article(text)
    except llm.LLMError as exc:
        return _fail(job, exc.code, exc.message)

    if not llm_recipe.ingredients and not llm_recipe.instructions:
        return _fail(job, "no_recipe_found", "We couldn't find a recipe in that text.")

    source_type = "caption" if is_caption else "article"

    # Same gap fix as the fetch paths (CLAUDE.md §5): real ingredients but zero
    # steps → generate a method for those exact ingredients, flag it generated.
    if llm_recipe.ingredients and not llm_recipe.instructions:
        try:
            dish = DishIdentification(dish_name=llm_recipe.title)
            generated = llm.generate_generic_recipe(dish, known_ingredients=llm_recipe.ingredients)
        except llm.LLMError as exc:
            return _fail(job, exc.code, exc.message)
        llm_recipe = _with_generated_instructions(llm_recipe, generated)
        source_type = "generated"

    title = llm_recipe.title or "Untitled recipe"
    # No page/thumbnail to draw from on a paste — resolve to a stock image.
    if is_caption:
        image_url, image_source = images.resolve_image(None, title)
    else:
        image_url, image_source = images.resolve_web_image(None, title)

    recipe = Recipe(
        recipe_id=str(uuid.uuid4()),
        canonical_video_id=job.canonical_video_id,
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


def _process_web(job: Job, resolved: urls.ResolvedUrl) -> Job:
    """Generic-web extraction: SSRF-guarded fetch → JSON-LD (structured) → else
    article text + LLM (article). Reuses image resolution and _finalize as-is.
    """
    # SSRF-guarded fetch (the guard runs inside web.safe_get, per hop).
    try:
        html, _final_url = web.safe_get(resolved.url)
    except netguard.BlockedURLError as exc:
        return _fail(job, exc.code, exc.message)
    except web.WebFetchError as exc:
        return _fail(job, exc.code, exc.message)

    # Tier 1: complete schema.org Recipe JSON-LD → ground truth, no LLM.
    parsed = jsonld.parse_recipe_jsonld(html)
    if parsed is not None:
        llm_recipe = parsed.recipe
        source_type = "structured"
        image_candidate = parsed.image_url
    else:
        # Tier 2: no (complete) JSON-LD → extract from readability article text.
        text = web.extract_article_text(html)
        if not text.strip():
            return _fail(job, "no_recipe_found", "We couldn't find a recipe on this page.")
        try:
            llm_recipe = llm.extract_recipe_from_article(text)
        except llm.LLMError as exc:
            return _fail(job, exc.code, exc.message)
        if not llm_recipe.ingredients and not llm_recipe.instructions:
            return _fail(job, "no_recipe_found", "We couldn't find a recipe on this page.")

        source_type = "article"
        image_candidate = web.og_image(html)

        # Same gap fix as the caption path: real ingredients but zero steps →
        # generate a method for those ingredients and flag the recipe generated.
        if llm_recipe.ingredients and not llm_recipe.instructions:
            try:
                dish = DishIdentification(dish_name=llm_recipe.title)
                generated = llm.generate_generic_recipe(
                    dish, known_ingredients=llm_recipe.ingredients
                )
            except llm.LLMError as exc:
                return _fail(job, exc.code, exc.message)
            llm_recipe = _with_generated_instructions(llm_recipe, generated)
            source_type = "generated"

    title = llm_recipe.title or "Untitled recipe"
    image_url, image_source = images.resolve_web_image(image_candidate, title)

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
