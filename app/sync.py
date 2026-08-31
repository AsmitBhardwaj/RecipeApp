"""Stage 2a — the account-scoped sync API.

Three authenticated endpoints back the client's mirror + outbox model:

  POST /v1/sync/push   apply a batch of local mutations (last-writer-wins)
  GET  /v1/sync/pull   fetch everything changed since a cursor
  POST /v1/recipes/batch   hydrate full recipe bodies for a set of ids

The server is the source of truth and arbitrates convergence by `updated_at`
(client wall-clock ms); it never interprets a record's `payload` (opaque JSON
owned by the client). Recipe *content* is not duplicated into sync — the library
collection carries only membership/personalization, and a new device fetches the
bodies it doesn't have from the shared cache via /v1/recipes/batch.
"""
from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field, field_validator

from . import db
from .auth.router import current_user
from .auth.service import User
from .models import Recipe

router = APIRouter(prefix="/v1", tags=["sync"])

# Bounds — authed, but still cap batch size and payload to keep a single request
# from writing unbounded data.
_MAX_CHANGES = 500
_MAX_PAYLOAD_BYTES = 64 * 1024
_MAX_PULL_LIMIT = 500
_MAX_BATCH_IDS = 500


class Change(BaseModel):
    collection: str
    item_id: str = Field(min_length=1, max_length=256)
    updated_at: int = Field(ge=0)  # client wall-clock, epoch milliseconds
    deleted: bool = False
    payload: Optional[str] = None  # opaque client JSON; absent/None for deletes

    @field_validator("collection")
    @classmethod
    def _known_collection(cls, v: str) -> str:
        if v not in db.SYNC_COLLECTIONS:
            raise ValueError(f"unknown collection: {v}")
        return v

    @field_validator("payload")
    @classmethod
    def _payload_size(cls, v: Optional[str]) -> Optional[str]:
        if v is not None and len(v.encode("utf-8")) > _MAX_PAYLOAD_BYTES:
            raise ValueError("payload too large")
        return v


class PushRequest(BaseModel):
    changes: list[Change] = Field(default_factory=list, max_length=_MAX_CHANGES)


class ServerChange(BaseModel):
    collection: str
    item_id: str
    seq: int
    updated_at: int
    deleted: bool
    payload: Optional[str] = None


class PushResponse(BaseModel):
    applied: list[str]
    conflicts: list[ServerChange]  # server-wins records the client should adopt
    cursor: int


class PullResponse(BaseModel):
    changes: list[ServerChange]
    cursor: int
    has_more: bool


class BatchRequest(BaseModel):
    ids: list[str] = Field(default_factory=list, max_length=_MAX_BATCH_IDS)


class BatchResponse(BaseModel):
    recipes: list[Recipe]


@router.post("/sync/push", response_model=PushResponse)
def sync_push(req: PushRequest, user: User = Depends(current_user)) -> PushResponse:
    result = db.sync_push(user.id, [c.model_dump() for c in req.changes])
    return PushResponse(
        applied=result["applied"],
        conflicts=[ServerChange(**c) for c in result["conflicts"]],
        cursor=result["cursor"],
    )


@router.get("/sync/pull", response_model=PullResponse)
def sync_pull(
    cursor: int = Query(0, ge=0),
    limit: int = Query(_MAX_PULL_LIMIT, ge=1, le=_MAX_PULL_LIMIT),
    user: User = Depends(current_user),
) -> PullResponse:
    result = db.sync_pull(user.id, cursor, limit)
    return PullResponse(
        changes=[ServerChange(**c) for c in result["changes"]],
        cursor=result["cursor"],
        has_more=result["has_more"],
    )


@router.post("/recipes/batch", response_model=BatchResponse)
def recipes_batch(req: BatchRequest, user: User = Depends(current_user)) -> BatchResponse:
    # De-dupe while preserving order; membership already proven by the pulled
    # library, so this only reads from the shared recipe cache.
    seen: set[str] = set()
    ids = [i for i in req.ids if not (i in seen or seen.add(i))]
    return BatchResponse(recipes=db.recipes_by_ids(ids))
