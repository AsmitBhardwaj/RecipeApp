"""Request-gating layer: persistent rate limiting (app/ratelimit.py) and the
static app-key middleware (app/main.py).

Rate-limit tests drive `ratelimit.check` directly against a throwaway SQLite
file; app-key tests go through the FastAPI middleware with a stubbed
orchestrator so no real pipeline/LLM runs.

    python3 -m unittest tests.test_ratelimit_appkey
"""
from __future__ import annotations

import os
import tempfile
import unittest
from datetime import datetime, timezone

from fastapi.testclient import TestClient

from app import config, db, ratelimit
from app.models import Job


def _fresh_db() -> str:
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    return path


class RateLimitCoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self._orig_db = config.DB_PATH
        self._path = _fresh_db()
        config.DB_PATH = self._path
        db.init_db()

        # Snapshot + set predictable limits. ratelimit._rules() reads config
        # fresh on every call, so plain attribute assignment is enough.
        self._orig = {
            k: getattr(config, k)
            for k in (
                "RATE_LIMIT_USER_PER_MIN",
                "RATE_LIMIT_USER_PER_HOUR",
                "RATE_LIMIT_IP_PER_MIN",
                "RATE_LIMIT_IP_PER_HOUR",
            )
        }
        config.RATE_LIMIT_USER_PER_MIN = 3
        config.RATE_LIMIT_USER_PER_HOUR = 1000
        config.RATE_LIMIT_IP_PER_MIN = 1000
        config.RATE_LIMIT_IP_PER_HOUR = 1000

    def tearDown(self) -> None:
        config.DB_PATH = self._orig_db
        for k, v in self._orig.items():
            setattr(config, k, v)
        os.unlink(self._path)

    def _allowed(self, calls: int, user: str = "u", ip: str = "1.1.1.1") -> int:
        n = 0
        for _ in range(calls):
            try:
                ratelimit.check(user, ip)
                n += 1
            except ratelimit.RateLimitExceeded:
                break
        return n

    def test_per_user_minute_limit(self) -> None:
        # limit is 3 → exactly 3 allowed, 4th trips.
        self.assertEqual(self._allowed(10), 3)

    def test_users_have_independent_buckets(self) -> None:
        self.assertEqual(self._allowed(3, user="A"), 3)
        self.assertEqual(self._allowed(3, user="B"), 3)  # unaffected by A

    def test_per_ip_catches_user_id_rotation(self) -> None:
        # Attacker rotates X-User-Id (so per-user never trips) but shares an IP.
        config.RATE_LIMIT_USER_PER_MIN = 1000
        config.RATE_LIMIT_IP_PER_MIN = 2
        n = 0
        for i in range(5):
            try:
                ratelimit.check(f"rot-{i}", "9.9.9.9")
                n += 1
            except ratelimit.RateLimitExceeded:
                break
        self.assertEqual(n, 2)

    def test_counters_persist_across_connections(self) -> None:
        # Each check opens/closes its own connection; exhausting then re-checking
        # must stay blocked (the whole point of moving off in-memory state).
        self._allowed(10)
        with self.assertRaises(ratelimit.RateLimitExceeded):
            ratelimit.check("u", "1.1.1.1")

    def test_exceeded_carries_dimension_and_limit(self) -> None:
        self._allowed(3)
        with self.assertRaises(ratelimit.RateLimitExceeded) as ctx:
            ratelimit.check("u", "1.1.1.1")
        self.assertEqual(ctx.exception.dimension, "u")
        self.assertEqual(ctx.exception.limit, 3)


class AppKeyGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self._orig_db = config.DB_PATH
        self._orig_key = config.APP_KEY
        self._path = _fresh_db()
        config.DB_PATH = self._path
        db.init_db()  # create tables now; don't depend on the startup event
        config.APP_KEY = "top-secret"

        # Keep rate limits out of the way for app-key-focused assertions.
        self._orig_limits = {
            k: getattr(config, k)
            for k in (
                "RATE_LIMIT_USER_PER_MIN",
                "RATE_LIMIT_USER_PER_HOUR",
                "RATE_LIMIT_IP_PER_MIN",
                "RATE_LIMIT_IP_PER_HOUR",
            )
        }
        for k in self._orig_limits:
            setattr(config, k, 100000)

        import app.main as main

        self.main = main
        main.orchestrator.create_job = lambda url, uid: Job(
            job_id="j1",
            user_id=uid,
            url=url,
            canonical_video_id="v1",
            platform="instagram",
            status="queued",
            created_at=datetime.now(timezone.utc).isoformat(),
        )
        main.orchestrator.process_job = lambda job: None
        self.client = TestClient(main.app)

    def tearDown(self) -> None:
        config.DB_PATH = self._orig_db
        config.APP_KEY = self._orig_key
        for k, v in self._orig_limits.items():
            setattr(config, k, v)
        os.unlink(self._path)

    def test_health_is_exempt(self) -> None:
        self.assertEqual(self.client.get("/").status_code, 200)

    def test_missing_key_rejected(self) -> None:
        r = self.client.post("/v1/jobs", json={"url": "http://x"})
        self.assertEqual(r.status_code, 401)

    def test_wrong_key_rejected(self) -> None:
        r = self.client.post(
            "/v1/jobs", json={"url": "http://x"}, headers={"X-App-Key": "nope"}
        )
        self.assertEqual(r.status_code, 401)

    def test_correct_key_passes(self) -> None:
        r = self.client.post(
            "/v1/jobs",
            json={"url": "http://x"},
            headers={"X-App-Key": "top-secret", "X-User-Id": "user-A"},
        )
        self.assertEqual(r.status_code, 200)

    def test_gate_disabled_when_no_key_configured(self) -> None:
        config.APP_KEY = None  # fail-open for local dev
        r = self.client.post("/v1/jobs", json={"url": "http://x"})
        self.assertEqual(r.status_code, 200)

    def test_rate_limit_maps_to_429(self) -> None:
        config.RATE_LIMIT_USER_PER_MIN = 2
        h = {"X-App-Key": "top-secret", "X-User-Id": "burst"}
        codes = [
            self.client.post("/v1/jobs", json={"url": "http://x"}, headers=h).status_code
            for _ in range(3)
        ]
        self.assertEqual(codes, [200, 200, 429])


if __name__ == "__main__":
    unittest.main()
