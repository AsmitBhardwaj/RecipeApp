"""Stage 2a sync-API tests: push/pull convergence, last-writer-wins conflicts,
tombstones, the delta cursor, auth gating, and recipe hydration."""
from __future__ import annotations

import os
import tempfile
import unittest

from fastapi.testclient import TestClient

from app import config, db
from app.main import app
from app.models import Recipe, Servings


def _recipe(rid: str, vid: str, title: str) -> Recipe:
    return Recipe(
        recipe_id=rid,
        canonical_video_id=vid,
        title=title,
        servings=Servings(),
        source_type="caption",
    )


class SyncTests(unittest.TestCase):
    def setUp(self):
        self._orig_db = config.DB_PATH
        fd, self._path = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        config.DB_PATH = self._path
        db.init_db()
        self.client = TestClient(app)
        self.auth = self._register("sync@user.com")

    def tearDown(self):
        config.DB_PATH = self._orig_db
        try:
            os.remove(self._path)
        except OSError:
            pass

    def _register(self, email: str) -> dict:
        r = self.client.post("/auth/register", json={"email": email, "password": "supersecret1"})
        self.assertEqual(r.status_code, 200, r.text)
        return {"Authorization": f"Bearer {r.json()['access_token']}"}

    def _push(self, changes, headers=None):
        return self.client.post("/v1/sync/push", json={"changes": changes}, headers=headers or self.auth)

    def _pull(self, cursor=0, headers=None):
        return self.client.get(f"/v1/sync/pull?cursor={cursor}", headers=headers or self.auth)

    # ---- auth gating ------------------------------------------------------ #

    def test_endpoints_require_auth(self):
        self.assertEqual(self.client.post("/v1/sync/push", json={"changes": []}).status_code, 401)
        self.assertEqual(self.client.get("/v1/sync/pull").status_code, 401)
        self.assertEqual(self.client.post("/v1/recipes/batch", json={"ids": []}).status_code, 401)

    def test_unknown_collection_rejected(self):
        r = self._push([{"collection": "nope", "item_id": "1", "updated_at": 1, "payload": "{}"}])
        self.assertEqual(r.status_code, 422)

    # ---- basic push / pull ------------------------------------------------ #

    def test_push_then_pull_roundtrips(self):
        changes = [
            {"collection": "meal_plan", "item_id": "m1", "updated_at": 100, "payload": '{"dayKey":"2026-08-27"}'},
            {"collection": "cookbook", "item_id": "c1", "updated_at": 100, "payload": '{"name":"Weeknight"}'},
        ]
        push = self._push(changes)
        self.assertEqual(push.status_code, 200, push.text)
        self.assertEqual(set(push.json()["applied"]), {"m1", "c1"})

        pull = self._pull(0).json()
        self.assertEqual(len(pull["changes"]), 2)
        self.assertGreater(pull["cursor"], 0)
        # Pulling again from the new cursor yields nothing.
        self.assertEqual(len(self._pull(pull["cursor"]).json()["changes"]), 0)

    def test_delta_pull_only_returns_new_changes(self):
        self._push([{"collection": "meal_plan", "item_id": "m1", "updated_at": 1, "payload": "{}"}])
        c1 = self._pull(0).json()["cursor"]
        self._push([{"collection": "meal_plan", "item_id": "m2", "updated_at": 2, "payload": "{}"}])
        delta = self._pull(c1).json()
        self.assertEqual([c["item_id"] for c in delta["changes"]], ["m2"])

    # ---- last-writer-wins ------------------------------------------------- #

    def test_newer_update_wins(self):
        self._push([{"collection": "cookbook", "item_id": "c1", "updated_at": 100, "payload": '{"name":"A"}'}])
        r = self._push([{"collection": "cookbook", "item_id": "c1", "updated_at": 200, "payload": '{"name":"B"}'}])
        self.assertEqual(r.json()["applied"], ["c1"])
        latest = self._pull(0).json()["changes"][-1]
        self.assertIn('"name":"B"', latest["payload"])

    def test_stale_update_is_rejected_as_conflict(self):
        self._push([{"collection": "cookbook", "item_id": "c1", "updated_at": 200, "payload": '{"name":"new"}'}])
        # A device pushing an OLDER edit loses; server returns its winning record.
        r = self._push([{"collection": "cookbook", "item_id": "c1", "updated_at": 150, "payload": '{"name":"old"}'}]).json()
        self.assertEqual(r["applied"], [])
        self.assertEqual(len(r["conflicts"]), 1)
        self.assertIn('"name":"new"', r["conflicts"][0]["payload"])

    def test_tombstone_syncs_as_delete(self):
        self._push([{"collection": "grocery_manual", "item_id": "g1", "updated_at": 1, "payload": '{"name":"milk"}'}])
        self._push([{"collection": "grocery_manual", "item_id": "g1", "updated_at": 2, "deleted": True}])
        latest = self._pull(0).json()["changes"][-1]
        self.assertTrue(latest["deleted"])

    # ---- isolation between users ------------------------------------------ #

    def test_users_are_isolated(self):
        self._push([{"collection": "cookbook", "item_id": "c1", "updated_at": 1, "payload": "{}"}])
        other = self._register("other@user.com")
        self.assertEqual(len(self._pull(0, headers=other).json()["changes"]), 0)

    # ---- recipe hydration ------------------------------------------------- #

    def test_recipes_batch_returns_cached_bodies(self):
        db.save_recipe(_recipe("r1", "v1", "Tacos"))
        db.save_recipe(_recipe("r2", "v2", "Pho"))
        r = self.client.post("/v1/recipes/batch", json={"ids": ["r1", "r2", "missing"]}, headers=self.auth)
        self.assertEqual(r.status_code, 200, r.text)
        titles = sorted(x["title"] for x in r.json()["recipes"])
        self.assertEqual(titles, ["Pho", "Tacos"])


if __name__ == "__main__":
    unittest.main()
