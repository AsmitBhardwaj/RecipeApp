"""FastAPI app: POST /v1/jobs and GET /v1/jobs/{job_id}.

Synchronous MVP — POST runs the whole pipeline and returns the finished recipe
in one request/response cycle (no background worker yet).
"""
from __future__ import annotations

import hmac
import html
import logging
from datetime import datetime, timezone
from typing import Optional

from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from pydantic import BaseModel, field_validator, model_validator

from . import (
    appstore,
    burstlimit,
    config,
    db,
    entitlements,
    importlimit,
    ratelimit,
    spendcap,
    spendsignal,
)
from .auth.router import current_user, optional_current_user, router as auth_router
from .auth import apple_revocation
from .auth.service import User
from .entitlements_router import router as entitlements_router
from .models import Job, Recipe
from .mealplan import router as mealplan_router
from .pantry import router as pantry_router
from .pipeline import orchestrator
from .sync import router as sync_router

app = FastAPI(title="Recipe Extraction API", version="0.1.0")

# Auth endpoints (/auth/*) and the account-scoped sync API (/v1/sync/*,
# /v1/recipes/batch). Both still behind the app-key gate below.
app.include_router(auth_router)
app.include_router(sync_router)
# Pantry suggestions (/v1/pantry/suggestions) — account-scoped, same app-key gate.
app.include_router(pantry_router)
# Plan on a Budget (/v1/meal-plan/budget) — Pro-gated LLM generation.
app.include_router(mealplan_router)
# Server-verified Pro entitlement (/v1/entitlements/*, /v1/appstore/notifications).
app.include_router(entitlements_router)


@app.on_event("startup")
def _startup() -> None:
    db.init_db()
    try:
        completed, pending = apple_revocation.retry_pending()
        if completed or pending:
            logging.getLogger("uvicorn.error").info(
                "Apple revocation retry batch: completed=%s pending=%s", completed, pending
            )
    except Exception:  # retry work must never prevent the API from starting
        logging.getLogger("uvicorn.error").exception(
            "Apple revocation retry batch failed without exposing credentials"
        )
    appstore_key_loaded = appstore.private_key_loaded_ok()
    logging.getLogger("uvicorn.error").log(
        logging.INFO if appstore_key_loaded else logging.ERROR,
        "App Store private key loaded OK: %s",
        appstore_key_loaded,
    )
    if config.JWT_SECRET_IS_DEV_FALLBACK:
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
    # Exempt paths that legitimately can't send X-App-Key:
    #   * `/` and `/health` — monitoring probes (an uptime checker won't send it).
    #   * `/admin/*` — a browser page, guarded by its own Basic Auth.
    #   * `/v1/appstore/notifications` — Apple POSTs these server-to-server and
    #     never sends our app key; the Apple SIGNATURE is the authentication
    #     (verified in the handler). Without this, every App Store notification
    #     would be rejected 401 and the entitlement would silently never update.
    _app_key_exempt = path in ("/", "/health", "/v1/appstore/notifications")
    if config.APP_KEY and not _app_key_exempt and not path.startswith("/admin"):
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


def _enforce_import_limit(account: Optional[User]) -> None:
    """Reject with 402 + a distinct machine error_code when a free account is at
    its monthly import cap. Pro, grandfathered, and anonymous callers pass.

    Pro is the server-verified entitlement (app/entitlements.py) — no client
    header is trusted."""
    is_pro = entitlements.is_pro_user(account.id) if account else False
    try:
        importlimit.check_allowed(account, is_pro)
    except importlimit.ImportLimitExceeded as exc:
        raise HTTPException(
            status_code=402,
            detail={
                "error_code": exc.code,
                "message": "You've reached this month's free import limit. Upgrade to Platter Pro for unlimited imports.",
                "limit": exc.limit,
            },
        )


def _enforce_import_burst_limit(account: Optional[User]) -> None:
    """Reject with 429 + the distinct `rate_limit_exceeded` code when an account is
    over its per-hour/per-day import burst cap (app/burstlimit.py).

    Applies to PRO accounts too — Pro removes the monthly cap, not this ceiling —
    so the client must NOT show the paywall for this (the code differs from the
    import cap's `free_limit_reached`). Anonymous imports have no account to key
    on; they remain bounded by the per-user/IP limiter above."""
    if account is None:
        return
    try:
        burstlimit.check_import(account.id)
    except burstlimit.BurstLimitExceeded as exc:
        raise HTTPException(
            status_code=429,
            detail={
                "error_code": exc.code,
                "message": "You're importing too quickly. Please try again a bit later.",
                "limit": exc.limit,
                "window": exc.window_label,
            },
        )


def _enforce_spend_cap(account: User) -> None:
    """Reject with 429 + the distinct `spend_cap_reached` code when an account is
    at/over its HARD trailing-30-day estimated-spend cap (app/spendcap.py). Applies
    to Pro and free alike (cost is cost); sits above the count-based burst caps as a
    dollar backstop. Like the burst caps, the code differs from the paywall's 402
    so the client shows a "try later" message, not an upgrade prompt."""
    try:
        spendcap.check(account.id)
    except spendcap.SpendCapExceeded as exc:
        raise HTTPException(
            status_code=429,
            detail={
                "error_code": exc.code,
                "message": "You've hit your recent usage limit. It frees up as your usage from the past 30 days ages off.",
                "limit": exc.limit,
                "window": exc.window_label,
            },
        )


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


class ImportUsageResponse(BaseModel):
    limit: int
    used: int
    remaining: int
    resets_at: str
    is_limited: bool


def _strip_pro_fields(recipe: Optional[Recipe], is_pro: bool) -> Optional[Recipe]:
    """Nutrition (calories/macros) is a Pro feature. It rides on the shared recipe
    payload, so strip it server-side for non-Pro accounts — a modified client can't
    reveal it. Pro accounts get the full recipe."""
    if recipe is None or is_pro or recipe.nutrition is None:
        return recipe
    return recipe.model_copy(update={"nutrition": None})


def _with_recipe(job: Job, is_pro: bool) -> JobResponse:
    recipe = db.get_recipe(job.recipe_id) if job.recipe_id else None
    return JobResponse(job=job, recipe=_strip_pro_fields(recipe, is_pro))


# --------------------------------------------------------------------------- #
# Endpoints
# --------------------------------------------------------------------------- #


@app.get("/v1/import-usage", response_model=ImportUsageResponse)
def get_import_usage(account: User = Depends(current_user)) -> ImportUsageResponse:
    """Return the server-authoritative monthly allowance for the signed-in user."""
    now = datetime.now(timezone.utc)
    used = db.count_imports_in_month(account.id, importlimit.month_key(now))
    limit = config.FREE_IMPORT_LIMIT
    reset = (
        datetime(now.year + 1, 1, 1, tzinfo=timezone.utc)
        if now.month == 12
        else datetime(now.year, now.month + 1, 1, tzinfo=timezone.utc)
    )
    return ImportUsageResponse(
        limit=limit,
        used=used,
        remaining=max(0, limit - used),
        resets_at=reset.isoformat(),
        is_limited=not importlimit.is_grandfathered(account.created_at),
    )


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
        # Log the real error server-side, but do NOT return it: a DB exception
        # string can carry the connection DSN (host/user), and /health is publicly
        # reachable (exempt from the app-key gate) for uptime probes.
        logging.getLogger("uvicorn.error").error("readiness check failed: %s", exc)
        return JSONResponse(
            status_code=503,
            content={"status": "unhealthy", "database": "error"},
        )
    return JSONResponse(
        status_code=200,
        content={"status": "ok", "model": config.OPENAI_MODEL, **db_status},
    )


@app.post("/v1/jobs", response_model=JobResponse)
def submit_job(
    req: JobRequest,
    background_tasks: BackgroundTasks,
    request: Request,
    account: User = Depends(current_user),
) -> JobResponse:
    # Auth is REQUIRED here (current_user → 401 on a missing/invalid token) so no
    # OpenAI call is ever made for an unauthenticated caller. Identity is the
    # verified account (JWT `sub`); the spoofable X-User-Id is no longer trusted
    # or read on this route.

    # Rate-limit only the expensive submit path — GET polling (every ~1.5s) must
    # not burn the extraction budget. Keyed on the verified account id and the
    # client IP (see app/ratelimit.py).
    try:
        ratelimit.check(account.id, _client_ip(request))
    except ratelimit.RateLimitExceeded as exc:
        raise HTTPException(status_code=429, detail=str(exc))

    # Free-tier monthly import cap (Pro is unlimited). Checked BEFORE any job is
    # created so a capped user does no extraction work; returns 402 + a distinct
    # error_code the client maps to the paywall.
    _enforce_import_limit(account)

    # Per-account burst/daily import ceiling — bounds cost even for Pro accounts
    # (429 + rate_limit_exceeded, NOT the paywall). Kept after the monthly cap so
    # a free user at their monthly limit still gets the paywall, not this.
    _enforce_import_burst_limit(account)

    # Hard per-account 30-day dollar cap — the enforcing backstop above the count
    # caps (429 + spend_cap_reached). Blocks once trailing-30-day estimated spend
    # is over the cap, regardless of Pro status.
    _enforce_spend_cap(account)

    # Persist a queued job and return its id immediately — the extension can't
    # hold the request open while we scrape + call the LLM. The actual work runs
    # after the response is sent (CLAUDE.md §3: submit-and-close). The verified
    # account id is stamped on the job so the eventual success is counted against
    # the right account, across devices.
    job = orchestrator.create_job(req.url, account.id, account_id=account.id)
    background_tasks.add_task(orchestrator.process_job, job)
    # recipe is None while status == "queued"; is_pro only affects a finished recipe.
    return _with_recipe(job, entitlements.is_pro_user(account.id))


@app.get("/v1/jobs/{job_id}", response_model=JobResponse)
def get_job(job_id: str, account: Optional[User] = Depends(optional_current_user)) -> JobResponse:
    # Optional auth: this is the poll route (also hit anonymously), so a missing
    # token degrades to "not Pro" (nutrition stripped) rather than 401. A valid
    # token lets a Pro account receive the full recipe (with nutrition).
    job = db.get_job(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="job not found")
    return _with_recipe(job, entitlements.is_pro_user(account.id) if account else False)


class PasteRequest(BaseModel):
    text: str


@app.post("/v1/jobs/{job_id}/paste", response_model=JobResponse)
def paste_job_text(
    job_id: str,
    req: PasteRequest,
    request: Request,
    account: User = Depends(current_user),
) -> JobResponse:
    """Retry a failed job with user-pasted recipe text (the remedy for the
    `site_blocked` state and its caption analog — see
    orchestrator.process_pasted_text). Auth is REQUIRED (current_user → 401 on a
    missing/invalid token, before any LLM work); same app-key gate (middleware)
    and per-account/per-IP rate limit as the submit path.

    Runs synchronously and returns the finished recipe (or a failed job): unlike
    the fire-and-forget submit path, the caller (the paste screen) is actively
    waiting on the result.
    """
    try:
        ratelimit.check(account.id, _client_ip(request))
    except ratelimit.RateLimitExceeded as exc:
        raise HTTPException(status_code=429, detail=str(exc))

    # A paste is itself an import attempt (it can turn a failed job into a saved
    # recipe), so it is subject to the same free-tier cap AND the same per-account
    # burst/daily import ceiling, both checked before any work.
    _enforce_import_limit(account)
    _enforce_import_burst_limit(account)
    _enforce_spend_cap(account)

    text = req.text.strip()
    if len(text) < 10:
        raise HTTPException(status_code=400, detail="pasted text is too short to extract a recipe")

    job = db.get_job(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="job not found")

    # Attribute the import to the signed-in account so its success is counted
    # under the right account (the original job may have been created before this
    # field existed).
    job.account_id = account.id

    job = orchestrator.process_pasted_text(job, text)
    return _with_recipe(job, entitlements.is_pro_user(account.id))


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
def submit_feedback(
    req: FeedbackRequest,
    request: Request,
    account: Optional[User] = Depends(optional_current_user),
) -> dict:
    # Same abuse-prevention as the job endpoint: APP_KEY (middleware) + the
    # persistent per-user/per-IP rate limiter.
    user_id = _resolve_user_id(request)
    try:
        ratelimit.check(user_id, _client_ip(request))
    except ratelimit.RateLimitExceeded as exc:
        raise HTTPException(status_code=429, detail=str(exc))

    feedback_id = db.save_feedback(
        account_id=account.id if account else None,
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


@app.get("/admin/flagged-accounts")
def admin_flagged_accounts(_: None = Depends(_require_admin)) -> dict:
    """Manual-review queue for BOTH advisory signals — nothing here is
    auto-restricted; this is the surface for deciding by hand what to do:
      * device — accounts created on a device that already made another account
        (app/devicesignal.py).
      * spend  — accounts whose trailing-window estimated LLM spend is over the
        soft circuit-breaker threshold (app/spendsignal.py)."""
    device_rows = db.list_flagged_accounts()
    spend_rows = spendsignal.flagged_accounts()
    return {
        # Existing device-signal shape, kept unchanged for backward compatibility.
        "count": len(device_rows),
        "flagged": device_rows,
        # Soft spend circuit breaker (advisory, not auto-blocked).
        "spend_count": len(spend_rows),
        "spend_flagged": spend_rows,
        "spend_threshold_usd": config.SPEND_FLAG_THRESHOLD_USD,
        "spend_window_days": config.SPEND_FLAG_WINDOW_DAYS,
    }


@app.get("/admin/llm-costs")
def admin_llm_costs(
    since: Optional[str] = None,
    until: Optional[str] = None,
    _: None = Depends(_require_admin),
) -> dict:
    """Internal unit-economics view: estimated LLM spend per account (app/llm_cost.py).

    Not user-facing — Basic-Auth admin only, same gate as the other /admin pages.
    `since`/`until` are optional ISO-8601 UTC bounds ([since, until)); omit both
    for all-time. A NULL account row is unauthenticated imports. Costs are
    ESTIMATES from token usage × configured per-token rates (see llm_cost pricing
    notes), for sanity-checking cost assumptions, not billing."""
    rows = db.sum_llm_cost_by_account(since_iso=since, until_iso=until)
    total = round(sum(float(r["estimated_cost_usd"] or 0.0) for r in rows), 6)
    return {
        "since": since,
        "until": until,
        "model": config.OPENAI_MODEL,
        "total_estimated_cost_usd": total,
        "account_count": len(rows),
        "accounts": rows,
    }


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
