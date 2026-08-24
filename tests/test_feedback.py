"""Feedback endpoint (POST /feedback) and the admin page (GET /admin/feedback).

Validation: at least one of rating/message is required; rating (if present) must
be 1-5. The admin page is Basic-Auth protected and exempt from the app-key gate.

    python3 -m unittest tests.test_feedback
"""
from __future__ import annotations

import base64
import os
import tempfile
import unittest

from fastapi.testclient import TestClient

from app import config, db


def _fresh_db() -> str:
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    return path


def _basic(user: str, password: str) -> dict:
    token = base64.b64encode(f"{user}:{password}".encode()).decode()
    return {"Authorization": f"Basic {token}"}


class FeedbackTests(unittest.TestCase):
    def setUp(self) -> None:
        self._orig_db = config.DB_PATH
        self._orig_key = config.APP_KEY
        self._orig_admin = config.ADMIN_PASSWORD
        self._path = _fresh_db()
        config.DB_PATH = self._path
        db.init_db()

        # Focus on validation/auth: no app key, generous limits.
        config.APP_KEY = None
        config.ADMIN_PASSWORD = "admin-pw"
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
        self.client = TestClient(main.app)

    def tearDown(self) -> None:
        config.DB_PATH = self._orig_db
        config.APP_KEY = self._orig_key
        config.ADMIN_PASSWORD = self._orig_admin
        for k, v in self._orig_limits.items():
            setattr(config, k, v)
        os.unlink(self._path)

    # --- validation ---------------------------------------------------------

    def test_rejects_empty_rating_and_message(self) -> None:
        r = self.client.post("/feedback", json={"contact_email": "a@b.com"})
        self.assertEqual(r.status_code, 422)
        self.assertEqual(db.get_all_feedback(), [])

    def test_rejects_when_both_explicitly_null(self) -> None:
        r = self.client.post("/feedback", json={"rating": None, "message": "   "})
        self.assertEqual(r.status_code, 422)

    def test_accepts_rating_only(self) -> None:
        r = self.client.post("/feedback", json={"rating": 5})
        self.assertEqual(r.status_code, 200)
        rows = db.get_all_feedback()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["rating"], 5)
        self.assertIsNone(rows[0]["message"])

    def test_accepts_message_only(self) -> None:
        r = self.client.post("/feedback", json={"message": "Love the app!"})
        self.assertEqual(r.status_code, 200)
        rows = db.get_all_feedback()
        self.assertEqual(len(rows), 1)
        self.assertIsNone(rows[0]["rating"])
        self.assertEqual(rows[0]["message"], "Love the app!")

    def test_accepts_both_with_optional_email(self) -> None:
        r = self.client.post(
            "/feedback",
            json={"rating": 4, "message": "Nice", "contact_email": "me@x.com",
                  "app_version": "1.0", "platform": "ios"},
        )
        self.assertEqual(r.status_code, 200)
        row = db.get_all_feedback()[0]
        self.assertEqual((row["rating"], row["message"], row["contact_email"]),
                         (4, "Nice", "me@x.com"))

    def test_rejects_out_of_range_rating(self) -> None:
        self.assertEqual(self.client.post("/feedback", json={"rating": 0}).status_code, 422)
        self.assertEqual(self.client.post("/feedback", json={"rating": 9}).status_code, 422)

    # --- admin page ---------------------------------------------------------

    def test_admin_requires_auth(self) -> None:
        self.assertEqual(self.client.get("/admin/feedback").status_code, 401)
        self.assertEqual(
            self.client.get("/admin/feedback", headers=_basic("admin", "wrong")).status_code,
            401,
        )

    def test_admin_shows_feedback_newest_first(self) -> None:
        self.client.post("/feedback", json={"message": "first"})
        self.client.post("/feedback", json={"message": "second"})
        r = self.client.get("/admin/feedback", headers=_basic("admin", "admin-pw"))
        self.assertEqual(r.status_code, 200)
        self.assertIn("first", r.text)
        self.assertIn("second", r.text)
        # newest-first: "second" appears before "first" in the HTML.
        self.assertLess(r.text.index("second"), r.text.index("first"))

    def test_admin_disabled_when_password_unset(self) -> None:
        config.ADMIN_PASSWORD = None
        r = self.client.get("/admin/feedback", headers=_basic("admin", "anything"))
        self.assertEqual(r.status_code, 503)

    def test_admin_exempt_from_app_key_but_feedback_is_not(self) -> None:
        config.APP_KEY = "secret"
        # Admin page: no X-App-Key, just Basic Auth → allowed.
        self.assertEqual(
            self.client.get("/admin/feedback", headers=_basic("admin", "admin-pw")).status_code,
            200,
        )
        # POST /feedback still requires the app key.
        self.assertEqual(self.client.post("/feedback", json={"rating": 5}).status_code, 401)
        self.assertEqual(
            self.client.post("/feedback", json={"rating": 5}, headers={"X-App-Key": "secret"}).status_code,
            200,
        )


if __name__ == "__main__":
    unittest.main()
