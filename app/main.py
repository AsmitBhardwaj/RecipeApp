"""FastAPI app: POST /v1/jobs and GET /v1/jobs/{job_id}.

Synchronous MVP — POST runs the whole pipeline and returns the finished recipe
in one request/response cycle (no background worker yet).
"""
from __future__ import annotations

import hmac
from typing import Optional

from fastapi import BackgroundTasks, FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from . import config, db, ratelimit
from .models import Job, Recipe
from .pipeline import orchestrator

app = FastAPI(title="Recipe Extraction API", version="0.1.0")


@app.on_event("startup")
def _startup() -> None:
    db.init_db()


# --------------------------------------------------------------------------- #
# App-key gate — a static shared secret the iOS app sends on every request. This
# is the first thing checked, before any routing/processing. It is abuse
# deterrence, not auth (the key ships inside the app binary; see config.APP_KEY).
# `/` is exempt so Railway's healthcheck (and humans) can still reach it. If no
# APP_KEY is configured server-side the gate is disabled (fail-open) for local
# dev / tests.
# --------------------------------------------------------------------------- #
@app.middleware("http")
async def _require_app_key(request: Request, call_next):
    if config.APP_KEY and request.url.path != "/":
        presented = request.headers.get("X-App-Key", "")
        # Constant-time compare to avoid leaking the key via response timing.
        if not hmac.compare_digest(presented, config.APP_KEY):
            return JSONResponse(
                status_code=401, content={"detail": "invalid or missing app key"}
            )
    return await call_next(request)


# --------------------------------------------------------------------------- #
# Per-request identity for rate limiting.
# --------------------------------------------------------------------------- #
def _resolve_user_id(request: Request) -> str:
    """The client-supplied anonymous UUID (spoofable — abuse signal only). Fall
    back to the stub when absent or implausibly large."""
    raw = (request.headers.get("X-User-Id") or "").strip()
    if raw and len(raw) <= 200:
        return raw
    return config.DEFAULT_USER_ID


def _client_ip(request: Request) -> str:
    """Real client IP. Behind the Railway proxy the true address is the first
    hop of X-Forwarded-For; `request.client` would just be the proxy."""
    forwarded = request.headers.get("X-Forwarded-For")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


# --------------------------------------------------------------------------- #
# Request / response shapes
# --------------------------------------------------------------------------- #


class JobRequest(BaseModel):
    url: str


class JobResponse(BaseModel):
    job: Job
    recipe: Optional[Recipe] = None


def _with_recipe(job: Job) -> JobResponse:
    recipe = db.get_recipe(job.recipe_id) if job.recipe_id else None
    return JobResponse(job=job, recipe=recipe)


# --------------------------------------------------------------------------- #
# Endpoints
# --------------------------------------------------------------------------- #


@app.get("/")
def health() -> dict:
    return {"status": "ok", "model": config.OPENAI_MODEL}


@app.post("/v1/jobs", response_model=JobResponse)
def submit_job(
    req: JobRequest, background_tasks: BackgroundTasks, request: Request
) -> JobResponse:
    # Rate-limit only the expensive submit path — GET polling (every ~1.5s) must
    # not burn the extraction budget. Both the per-user-id and per-IP dimensions
    # are enforced (see app/ratelimit.py).
    user_id = _resolve_user_id(request)
    try:
        ratelimit.check(user_id, _client_ip(request))
    except ratelimit.RateLimitExceeded as exc:
        raise HTTPException(status_code=429, detail=str(exc))

    # Persist a queued job and return its id immediately — the extension can't
    # hold the request open while we scrape + call the LLM. The actual work runs
    # after the response is sent (CLAUDE.md §3: submit-and-close).
    job = orchestrator.create_job(req.url, user_id)
    background_tasks.add_task(orchestrator.process_job, job)
    return _with_recipe(job)  # recipe is None while status == "queued"


@app.get("/v1/jobs/{job_id}", response_model=JobResponse)
def get_job(job_id: str) -> JobResponse:
    job = db.get_job(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="job not found")
    return _with_recipe(job)
