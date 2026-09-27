"""Regression test for the "stranded processing row" bug.

`process_job` runs inside a FastAPI `BackgroundTasks` call in production — if
anything inside the pipeline raises an exception that isn't one of the known,
already-`_fail`-handled error types (FetchError / LLMError / UrlError), the
job would previously never reach a terminal status. That leaves the client's
"Extracting recipe…" processing card polling (and showing) forever, since it
only clears on `complete`/`failed`.

This drives `process_job` with everything up through image resolution stubbed
out, but has image resolution itself raise a bare, unclassified exception —
exactly the "an un-wrapped network error from image resolution" case the fix's
docstring calls out — and asserts the job still lands in `failed` with a
specific, non-crashing error code, rather than propagating the exception (which
in production would leave the row in `processing`).
"""
from __future__ import annotations

import unittest
from unittest import mock

from app.models import Confidence, Job, LLMRecipe
from app.pipeline import orchestrator
from app.pipeline.fetch import VideoMetadata
from app.pipeline.urls import ResolvedUrl

VIDEO_ID = "instagram:DVBmx5kAsa2"


def _job() -> Job:
    return Job(
        job_id="job-crash",
        user_id="user-1",
        url="https://www.instagram.com/reel/DVBmx5kAsa2/",
        created_at="2026-07-28T00:00:00+00:00",
    )


class TerminalStatusGuaranteeTest(unittest.TestCase):
    def test_unexpected_exception_still_marks_job_failed(self):
        resolved = ResolvedUrl(
            url="https://www.instagram.com/reel/DVBmx5kAsa2/",
            platform="instagram",
            video_id="DVBmx5kAsa2",
            canonical_video_id=VIDEO_ID,
        )
        meta = VideoMetadata(
            caption="Ingredients\n• Ground beef\n• 2 cups mozzarella",
            thumbnail_url=None,
            video_id="DVBmx5kAsa2",
            title="Taquitos",
        )
        extracted = LLMRecipe(
            title="Taquitos",
            ingredients=[],
            instructions=[],
            confidence=Confidence(
                overall=0.9,
                ingredients_complete=True,
                instructions_complete=True,
                missing_fields=[],
            ),
        )

        with mock.patch.object(orchestrator.urls, "resolve", return_value=resolved), \
             mock.patch.object(orchestrator.fetch, "fetch_instagram_metadata", return_value=meta), \
             mock.patch.object(orchestrator.signal, "has_recipe_signal", return_value=True), \
             mock.patch.object(orchestrator.llm, "extract_recipe", return_value=extracted), \
             mock.patch.object(orchestrator.db, "get_recipe_by_video_id", return_value=None), \
             mock.patch.object(orchestrator.db, "save_job"), \
             mock.patch.object(
                 orchestrator.images, "resolve_image",
                 side_effect=RuntimeError("unclassified image-resolution network error"),
             ):
            # Must not raise — the whole point of the guarantee.
            job = orchestrator.process_job(_job())

        self.assertEqual(job.status, "failed")
        self.assertEqual(job.error_code, "unknown_error")
        self.assertTrue(job.error)
