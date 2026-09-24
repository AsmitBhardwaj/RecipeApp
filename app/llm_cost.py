"""Per-account LLM cost accounting (internal unit-economics only).

This is observability, NOT a correctness or billing boundary: it records an
*estimated* dollar cost for each LLM API call, attributed to the account and the
call category that triggered it (recipe import / budget-plan / pantry
suggestion). Nothing user-facing reads this — it exists so we can sum estimated
spend per account after launch (see `db.sum_llm_cost_by_account` and the
`/admin/llm-costs` endpoint).

Design (kept deliberately low-overhead and non-invasive):

* A `contextvars.ContextVar` holds the current (account_id, call_type) for the
  duration of a logical operation. Callers wrap their LLM-invoking region in
  `with llm_cost.track(account_id, "import"): ...`.
* `pipeline/llm._raw_call` — the single chokepoint every LLM request funnels
  through, including the corrective retry — calls `record_usage(...)` after each
  API response. When no `track(...)` context is active (e.g. the nutrition
  backfill script, or a unit test calling `llm` directly), recording is a no-op,
  so this adds nothing to those paths and can never change their behavior.
* Recording is wrapped in try/except and only ever emits a log warning on
  failure: a cost-logging problem must NEVER fail a real extraction.

Token counts are stored ALONGSIDE the estimated cost (not just the dollar
figure) so spend can be recomputed later if published rates change or if a rate
here turns out to be wrong — the raw usage is the durable record.
"""
from __future__ import annotations

import json
import logging
import os
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Iterator, Optional

_log = logging.getLogger("app.llm_cost")

# --------------------------------------------------------------------------- #
# Pricing
#
# USD per 1,000,000 tokens as (input, cached_input, output).
#
# SOURCED, NOT GUESSED — these are the published standard (non-batch, non-fast)
# rates for the models this app actually configures (see config.OPENAI_MODEL,
# default "gpt-5.4-mini"; "gpt-5.4-nano" is the documented cheaper alternative):
#   * gpt-5.4-mini : $0.75 in / $0.075 cached / $4.50 out  (per 1M)
#   * gpt-5.4-nano : $0.20 in / $0.02  cached / $1.25 out  (per 1M)
# per OpenAI's "Introducing GPT-5.4 mini and nano" announcement.
#
# NOTE / caveat surfaced to the operator: OpenAI's live pricing *table* has at
# times listed mini at DOUBLE this ($1.50 in / $9.00 out) — that appears to be
# the "fast" tier, while the app uses the standard synchronous API. If your own
# cost numbers come in ~2× these, that tier split is the likely reason. Override
# any rate without a code change via the LLM_PRICING_OVERRIDES env var, a JSON
# map of model -> [input, cached_input, output] per 1M tokens, e.g.:
#   LLM_PRICING_OVERRIDES='{"gpt-5.4-mini":[1.50,0.15,9.00]}'
# --------------------------------------------------------------------------- #

_DEFAULT_PRICING: dict[str, tuple[float, float, float]] = {
    "gpt-5.4-mini": (0.75, 0.075, 4.50),
    "gpt-5.4-nano": (0.20, 0.02, 1.25),
}


def _load_pricing() -> dict[str, tuple[float, float, float]]:
    pricing = dict(_DEFAULT_PRICING)
    raw = os.getenv("LLM_PRICING_OVERRIDES")
    if raw:
        try:
            for model, rates in json.loads(raw).items():
                pricing[model] = (float(rates[0]), float(rates[1]), float(rates[2]))
        except (ValueError, TypeError, IndexError, KeyError) as exc:
            _log.warning("ignoring malformed LLM_PRICING_OVERRIDES: %s", exc)
    return pricing


_PRICING = _load_pricing()


def estimate_cost_usd(
    model: str, prompt_tokens: int, cached_tokens: int, completion_tokens: int
) -> Optional[float]:
    """Estimated USD cost for one call, or None if the model has no known rate.

    Cached (prompt-cache-hit) input tokens are billed at the cheaper cached rate;
    the rest of the prompt tokens at the full input rate. Returns None (rather
    than 0.0) for an unpriced model so callers/queries can distinguish "free" from
    "we don't have a rate for this" — the token counts are still recorded."""
    rate = _PRICING.get(model)
    if rate is None:
        return None
    input_rate, cached_rate, output_rate = rate
    non_cached = max(prompt_tokens - cached_tokens, 0)
    return (
        non_cached / 1_000_000 * input_rate
        + cached_tokens / 1_000_000 * cached_rate
        + completion_tokens / 1_000_000 * output_rate
    )


# --------------------------------------------------------------------------- #
# Active-context tracking
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class _Ctx:
    account_id: Optional[str]
    call_type: str


_current: ContextVar[Optional[_Ctx]] = ContextVar("llm_cost_ctx", default=None)

# The call categories the operator asked to track. Kept as an allowlist so a
# typo in a `track(...)` call is caught loudly rather than silently logged under
# a bogus category.
CALL_TYPES = frozenset({"import", "budget_plan", "pantry_suggestion"})


@contextmanager
def track(account_id: Optional[str], call_type: str) -> Iterator[None]:
    """Attribute every LLM call made inside this block to `account_id` /
    `call_type`. Nestable and re-entrant (the inner context wins, then the outer
    is restored). `account_id` may be None for an unauthenticated import."""
    if call_type not in CALL_TYPES:
        raise ValueError(f"unknown llm_cost call_type: {call_type!r}")
    token = _current.set(_Ctx(account_id=account_id, call_type=call_type))
    try:
        yield
    finally:
        _current.reset(token)


def record_usage(model: str, usage) -> None:
    """Record one LLM call's token usage + estimated cost against the active
    `track(...)` context. No-op when no context is active or `usage` is missing.

    Never raises: cost accounting must not be able to break an extraction. Called
    from the LLM chokepoint after each API response (including the retry)."""
    ctx = _current.get()
    if ctx is None or usage is None:
        return
    try:
        prompt_tokens = int(getattr(usage, "prompt_tokens", 0) or 0)
        completion_tokens = int(getattr(usage, "completion_tokens", 0) or 0)
        details = getattr(usage, "prompt_tokens_details", None)
        cached_tokens = int(getattr(details, "cached_tokens", 0) or 0) if details else 0

        cost = estimate_cost_usd(model, prompt_tokens, cached_tokens, completion_tokens)
        if cost is None:
            _log.warning("no pricing for model %r — recording usage with null cost", model)

        # Imported here (not at module load) to avoid any import-order coupling
        # with the storage layer.
        from . import db

        db.record_llm_cost_event(
            account_id=ctx.account_id,
            call_type=ctx.call_type,
            model=model,
            prompt_tokens=prompt_tokens,
            cached_tokens=cached_tokens,
            completion_tokens=completion_tokens,
            estimated_cost_usd=cost,
            created_at=datetime.now(timezone.utc).isoformat(),
        )
    except Exception as exc:  # noqa: BLE001 — accounting must never break a call
        _log.warning("failed to record LLM cost event: %s", exc)
