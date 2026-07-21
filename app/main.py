"""FastAPI app: POST /v1/jobs and GET /v1/jobs/{job_id}.

Synchronous MVP — POST runs the whole pipeline and returns the finished recipe
in one request/response cycle (no background worker yet).
"""
from __future__ import annotations

import time
from collections import defaultdict, deque
from typing import Deque, Dict, Optional

from fastapi import BackgroundTasks, FastAPI, HTTPException
from pydantic import BaseModel

from . import config, db
from .models import Job, Recipe
from .pipeline import orchestrator

app = FastAPI(title="Recipe Extraction API", version="0.1.0")


@app.on_event("startup")
def _startup() -> None:
    db.init_db()


# --------------------------------------------------------------------------- #
# In-memory per-user rate limiter (CLAUDE.md §7). Generous — only stops
# scripted abuse. Resets on restart; fine for single-process MVP.
# --------------------------------------------------------------------------- #
_hits: Dict[str, Deque[float]] = defaultdict(deque)


def _rate_limited(user_id: str) -> bool:
    now = time.monotonic()
    window = _hits[user_id]
    while window and now - window[0] > 60:
        window.popleft()
    if len(window) >= config.RATE_LIMIT_PER_MINUTE:
        return True
    window.append(now)
    return False


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
def submit_job(req: JobRequest, background_tasks: BackgroundTasks) -> JobResponse:
    user_id = config.DEFAULT_USER_ID  # auth stubbed — single default user

    if _rate_limited(user_id):
        raise HTTPException(
            status_code=429,
            detail=f"rate limit exceeded ({config.RATE_LIMIT_PER_MINUTE}/min)",
        )

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
