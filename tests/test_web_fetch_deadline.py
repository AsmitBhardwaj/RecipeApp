"""Tests for app/pipeline/web.py's total fetch deadline and no-retry behavior
on blocked/timed-out responses.

Context: a gimmesomeoven.com import sat showing "Extracting recipe..." for
several minutes with no per-request timeout ever firing server-side — nothing
here previously bounded the WHOLE fetch (connect + read + every redirect hop
combined), only each individual request. These tests lock in the fix:
`safe_get` now fails fast (paste-eligible `fetch_timeout`, not a bare
`fetch_failed` or an unclassified exception) once `_TOTAL_DEADLINE` elapses,
whether that's before a hop even starts, during a hop's own timeout, or
mid-stream on a body that trickles bytes just under the per-request timeout
("tarpitting" — a known anti-bot technique).

Every test mocks `netguard.assert_fetchable` (no-op) and
`requests.Session.get` so nothing here touches the real network or DNS.

    python3 -m unittest tests.test_web_fetch_deadline
"""
from __future__ import annotations

import time
import unittest
from unittest import mock

import requests

from app.pipeline import web


class SafeGetDeadlineTests(unittest.TestCase):

    def test_deadline_already_expired_fails_fast_without_a_request(self):
        """If the budget is already gone before the first hop, don't even try —
        confirms the check runs BEFORE `session.get`, not just around it."""
        with mock.patch.object(web.netguard, "assert_fetchable"), \
             mock.patch.object(web, "_TOTAL_DEADLINE", -1.0), \
             mock.patch.object(web.requests.Session, "get") as get_mock:
            with self.assertRaises(web.WebFetchError) as ctx:
                web.safe_get("https://slow.example.test/recipe")

        self.assertEqual(ctx.exception.code, "fetch_timeout")
        get_mock.assert_not_called()

    def test_hop_timeout_raises_fetch_timeout_not_fetch_failed(self):
        """A per-request timeout (ReadTimeout is-a Timeout) must classify as
        the distinct, paste-eligible `fetch_timeout` — not the generic
        `fetch_failed` bucket, and never an unclassified exception that would
        reach `process_job`'s crash-guard as `unknown_error`."""
        with mock.patch.object(web.netguard, "assert_fetchable"), \
             mock.patch.object(
                 web.requests.Session, "get",
                 side_effect=requests.exceptions.ReadTimeout("read timed out"),
             ):
            with self.assertRaises(web.WebFetchError) as ctx:
                web.safe_get("https://slow.example.test/recipe")

        self.assertEqual(ctx.exception.code, "fetch_timeout")

    def test_blocked_status_fails_immediately_with_no_retry(self):
        """A block response (403 etc.) still classifies as `site_blocked`, and
        exactly one request is made — no retry against the same origin."""
        resp = mock.Mock(spec=requests.Response)
        resp.is_redirect = False
        resp.status_code = 403
        resp.headers = {}

        with mock.patch.object(web.netguard, "assert_fetchable"), \
             mock.patch.object(web.requests.Session, "get", return_value=resp) as get_mock:
            with self.assertRaises(web.WebFetchError) as ctx:
                web.safe_get("https://blocked.example.test/recipe")

        self.assertEqual(ctx.exception.code, "site_blocked")
        get_mock.assert_called_once()

    def test_successful_html_response_still_returns_normally(self):
        """Regression guard: a normal, fast, allowed response is unaffected by
        the deadline plumbing."""
        resp = mock.Mock(spec=requests.Response)
        resp.is_redirect = False
        resp.status_code = 200
        resp.headers = {"Content-Type": "text/html; charset=utf-8"}
        resp.encoding = "utf-8"
        resp.iter_content = lambda chunk_size: iter([b"<html><body>Recipe</body></html>"])
        resp.raise_for_status = mock.Mock()

        with mock.patch.object(web.netguard, "assert_fetchable"), \
             mock.patch.object(web.requests.Session, "get", return_value=resp):
            html, final_url = web.safe_get("https://ok.example.test/recipe")

        self.assertIn("Recipe", html)
        self.assertEqual(final_url, "https://ok.example.test/recipe")


class ReadCappedDeadlineTests(unittest.TestCase):
    """`_read_capped` is where a body that trickles bytes just under the
    per-request socket timeout ("tarpitting") gets caught — the per-request
    timeout alone only bounds the gap BETWEEN reads, not the total time spent
    reading."""

    def test_stops_when_deadline_passes_mid_stream(self):
        class SlowResponse:
            def __init__(self):
                self.encoding = "utf-8"
                self.closed = False

            def iter_content(self, chunk_size):
                yield b"first-chunk-arrives-in-time"
                time.sleep(0.05)
                yield b"-second-chunk-arrives-late"

            def close(self):
                self.closed = True

        resp = SlowResponse()
        deadline = time.monotonic() + 0.02  # expires between the two chunks

        with self.assertRaises(web.WebFetchError) as ctx:
            web._read_capped(resp, deadline=deadline)

        self.assertEqual(ctx.exception.code, "fetch_timeout")
        self.assertTrue(resp.closed, "the response must still be closed on a timeout")


if __name__ == "__main__":
    unittest.main()
