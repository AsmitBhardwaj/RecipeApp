"""FastAPI app: POST /v1/jobs and GET /v1/jobs/{job_id}.

Synchronous MVP — POST runs the whole pipeline and returns the finished recipe
in one request/response cycle (no background worker yet).
"""
from __future__ import annotations

import hmac
import html
from datetime import datetime, timezone
from typing import Optional

from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from pydantic import BaseModel, field_validator, model_validator

from . import config, db, ratelimit
from .auth.router import router as auth_router
from .models import Job, Recipe
from .pipeline import orchestrator
from .sync import router as sync_router

app = FastAPI(title="Recipe Extraction API", version="0.1.0")

# Auth endpoints (/auth/*) and the account-scoped sync API (/v1/sync/*,
# /v1/recipes/batch). Both still behind the app-key gate below.
app.include_router(auth_router)
app.include_router(sync_router)


@app.on_event("startup")
def _startup() -> None:
    db.init_db()
    if config.JWT_SECRET_IS_DEV_FALLBACK:
        import logging

        logging.getLogger("uvicorn.error").warning(
            "JWT_SECRET is unset — using the INSECURE dev fallback. Set JWT_SECRET "
            "in the environment before serving real users."
        )


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
    # `/` (healthcheck) and `/admin/*` (browser page, guarded by its own Basic
    # Auth instead — a browser can't send X-App-Key) are exempt.
    path = request.url.path
    # `/` and `/health` (monitoring probes) and `/admin/*` (its own Basic Auth)
    # are exempt — an uptime checker won't send X-App-Key.
    if config.APP_KEY and path not in ("/", "/health") and not path.startswith("/admin"):
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
    # Lightweight LIVENESS check — no DB touch. This is Railway's healthcheck
    # path (railway.json), so it must stay cheap and must NOT fail on a DB
    # outage: coupling the platform healthcheck to the DB would make Railway
    # kill/restart the container in a crash loop during a DB blip. Readiness
    # (including the DB) lives at /health below.
    return {"status": "ok", "model": config.OPENAI_MODEL}


@app.get("/health")
def health_ready() -> JSONResponse:
    # READINESS check for external monitoring: actually exercises the configured
    # database (SELECT 1) and reports which backend is live. Returns 503 if the
    # DB is unreachable so an outage fails LOUDLY — the gap that let the original
    # incident hide behind a green `GET /` while every job silently failed.
    try:
        db_status = db.health_check()
    except Exception as exc:  # noqa: BLE001 - any DB failure => not ready
        return JSONResponse(
            status_code=503,
            content={"status": "unhealthy", "database": "error", "detail": str(exc)},
        )
    return JSONResponse(
        status_code=200,
        content={"status": "ok", "model": config.OPENAI_MODEL, **db_status},
    )


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


# --------------------------------------------------------------------------- #
# Feedback
# --------------------------------------------------------------------------- #


class FeedbackRequest(BaseModel):
    rating: Optional[int] = None
    message: Optional[str] = None
    contact_email: Optional[str] = None
    app_version: Optional[str] = None
    platform: Optional[str] = None

    @field_validator("message", "contact_email", "app_version", "platform")
    @classmethod
    def _blank_to_none(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return None
        v = v.strip()
        return v or None

    @field_validator("rating")
    @classmethod
    def _rating_range(cls, v: Optional[int]) -> Optional[int]:
        if v is not None and not (1 <= v <= 5):
            raise ValueError("rating must be between 1 and 5")
        return v

    @model_validator(mode="after")
    def _require_rating_or_message(self) -> "FeedbackRequest":
        if self.rating is None and not self.message:
            raise ValueError("provide a rating or a message")
        return self


@app.post("/feedback")
def submit_feedback(req: FeedbackRequest, request: Request) -> dict:
    # Same abuse-prevention as the job endpoint: APP_KEY (middleware) + the
    # persistent per-user/per-IP rate limiter.
    user_id = _resolve_user_id(request)
    try:
        ratelimit.check(user_id, _client_ip(request))
    except ratelimit.RateLimitExceeded as exc:
        raise HTTPException(status_code=429, detail=str(exc))

    feedback_id = db.save_feedback(
        rating=req.rating,
        message=req.message,
        contact_email=req.contact_email,
        app_version=req.app_version,
        platform=req.platform,
        created_at=datetime.now(timezone.utc).isoformat(),
    )
    return {"status": "ok", "id": feedback_id}


# --------------------------------------------------------------------------- #
# Admin page (HTTP Basic Auth; exempt from the app-key gate above)
# --------------------------------------------------------------------------- #

_basic = HTTPBasic()


def _require_admin(credentials: HTTPBasicCredentials = Depends(_basic)) -> None:
    if not config.ADMIN_PASSWORD:
        # Never expose feedback without a configured password.
        raise HTTPException(status_code=503, detail="admin page not configured")
    ok_user = hmac.compare_digest(credentials.username, "admin")
    ok_pass = hmac.compare_digest(credentials.password, config.ADMIN_PASSWORD)
    if not (ok_user and ok_pass):
        raise HTTPException(
            status_code=401,
            detail="unauthorized",
            headers={"WWW-Authenticate": "Basic"},
        )


@app.get("/admin/feedback", response_class=HTMLResponse)
def admin_feedback(_: None = Depends(_require_admin)) -> str:
    rows = db.get_all_feedback()

    def esc(value) -> str:
        return html.escape(str(value)) if value not in (None, "") else "—"

    def stars(rating) -> str:
        if rating is None:
            return "—"
        r = max(0, min(5, int(rating)))
        return "★" * r + "☆" * (5 - r)

    body_rows = "".join(
        "<tr>"
        f"<td class='when'>{esc(row['created_at'])}</td>"
        f"<td class='rating'>{stars(row['rating'])}</td>"
        f"<td class='msg'>{esc(row['message'])}</td>"
        f"<td>{esc(row['contact_email'])}</td>"
        f"<td>{esc(row['app_version'])}</td>"
        f"<td>{esc(row['platform'])}</td>"
        "</tr>"
        for row in rows
    )
    if not body_rows:
        body_rows = "<tr><td colspan='6' class='empty'>No feedback yet.</td></tr>"

    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Feedback ({len(rows)})</title>
<style>
  body {{ font-family: -apple-system, system-ui, sans-serif; margin: 24px; color: #2b2320; }}
  h1 {{ font-size: 20px; }}
  table {{ border-collapse: collapse; width: 100%; font-size: 14px; }}
  th, td {{ text-align: left; padding: 8px 10px; border-bottom: 1px solid #e5ddcf; vertical-align: top; }}
  th {{ background: #f4f1e8; }}
  td.when {{ white-space: nowrap; color: #7a6f63; font-variant-numeric: tabular-nums; }}
  td.rating {{ white-space: nowrap; color: #8a5a2b; letter-spacing: 1px; }}
  td.msg {{ max-width: 520px; white-space: pre-wrap; }}
  td.empty {{ text-align: center; color: #7a6f63; padding: 24px; }}
</style></head>
<body>
  <h1>Feedback — {len(rows)} total</h1>
  <table>
    <thead><tr><th>When (UTC)</th><th>Rating</th><th>Message</th><th>Email</th><th>Version</th><th>Platform</th></tr></thead>
    <tbody>{body_rows}</tbody>
  </table>
</body></html>"""
