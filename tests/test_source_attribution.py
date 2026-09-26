from __future__ import annotations

import os
import sqlite3
import tempfile
import unittest
from unittest import mock

from sqlalchemy import select

from app import config, db
from app.models import Confidence, Ingredient, Instruction, Job, LLMRecipe, Recipe
from app.pipeline import jsonld, orchestrator
from app.pipeline.fetch import VideoMetadata
from app.pipeline.urls import ResolvedUrl


def _content() -> LLMRecipe:
    return LLMRecipe(
        title="Soup",
        ingredients=[Ingredient(name="tomato")],
        instructions=[Instruction(step_number=1, text="Cook.")],
        confidence=Confidence(overall=0.9),
    )


def _job(url: str = "https://example.com/source") -> Job:
    return Job(job_id="j1", user_id="device", url=url, created_at="2026-09-25T00:00:00+00:00")


class AttributionPipelineTests(unittest.TestCase):
    def _common(self):
        return mock.patch.multiple(
            orchestrator.db,
            save_job=mock.DEFAULT,
            save_recipe=mock.DEFAULT,
            save_user_recipe=mock.DEFAULT,
        )

    def test_social_imports_capture_platform_url_and_creator(self):
        cases = (
            ("instagram", "https://www.instagram.com/reel/abc/", "abc", "chef_ig"),
            ("tiktok", "https://www.tiktok.com/@chef/video/123", "123", "chef_tt"),
        )
        for platform, url, video_id, creator in cases:
            with self.subTest(platform=platform):
                resolved = ResolvedUrl(url, platform, video_id, f"{platform}:{video_id}")
                metadata = VideoMetadata("1 cup tomato\n1. Cook", None, video_id, "Soup", creator)
                fetch_name = "fetch_instagram_metadata" if platform == "instagram" else "fetch_metadata"
                with mock.patch.object(orchestrator.urls, "resolve", return_value=resolved), \
                     mock.patch.object(orchestrator.db, "get_recipe_by_video_id", return_value=None), \
                     mock.patch.object(orchestrator.fetch, fetch_name, return_value=metadata), \
                     mock.patch.object(orchestrator.signal, "has_recipe_signal", return_value=True), \
                     mock.patch.object(orchestrator.llm, "extract_recipe", return_value=_content()), \
                     mock.patch.object(orchestrator.images, "resolve_image", return_value=(None, "none")), \
                     mock.patch.object(orchestrator.importlimit, "record_success"), \
                     self._common() as stores:
                    orchestrator._process_job(_job(url))
                recipe = stores["save_recipe"].call_args.args[0]
                self.assertEqual(recipe.source_url, url)
                self.assertEqual(recipe.source_platform, platform)
                self.assertEqual(recipe.source_creator, creator)

    def test_missing_optional_creator_is_preserved_as_none(self):
        resolved = ResolvedUrl("https://www.instagram.com/reel/abc/", "instagram", "abc", "instagram:abc")
        metadata = VideoMetadata("1 cup tomato\n1. Cook", None, "abc", "Soup", None)
        with mock.patch.object(orchestrator.urls, "resolve", return_value=resolved), \
             mock.patch.object(orchestrator.db, "get_recipe_by_video_id", return_value=None), \
             mock.patch.object(orchestrator.fetch, "fetch_instagram_metadata", return_value=metadata), \
             mock.patch.object(orchestrator.signal, "has_recipe_signal", return_value=True), \
             mock.patch.object(orchestrator.llm, "extract_recipe", return_value=_content()), \
             mock.patch.object(orchestrator.images, "resolve_image", return_value=(None, "none")), \
             mock.patch.object(orchestrator.importlimit, "record_success"), \
             self._common() as stores:
            orchestrator._process_job(_job(resolved.url))
        self.assertIsNone(stores["save_recipe"].call_args.args[0].source_creator)

    def test_web_import_uses_final_url_and_explicit_author(self):
        resolved = ResolvedUrl("https://example.com/old", "web", "", "web:https://example.com/old")
        html = '<meta name="author" content="Ada Cook"><html></html>'
        parsed = jsonld.ParsedRecipe(recipe=_content(), image_url=None)
        with mock.patch.object(orchestrator.urls, "resolve", return_value=resolved), \
             mock.patch.object(orchestrator.db, "get_recipe_by_video_id", return_value=None), \
             mock.patch.object(orchestrator.web, "safe_get", return_value=(html, "https://example.com/recipe")), \
             mock.patch.object(orchestrator.jsonld, "parse_recipe_jsonld", return_value=parsed), \
             mock.patch.object(orchestrator.images, "resolve_web_image", return_value=(None, "none")), \
             mock.patch.object(orchestrator.importlimit, "record_success"), \
             self._common() as stores:
            orchestrator._process_job(_job(resolved.url))
        recipe = stores["save_recipe"].call_args.args[0]
        self.assertEqual(recipe.source_url, "https://example.com/recipe")
        self.assertEqual(recipe.source_platform, "web")
        self.assertEqual(recipe.source_creator, "Ada Cook")

    def test_cache_hit_preserves_attribution_without_refetch(self):
        resolved = ResolvedUrl("https://www.instagram.com/reel/abc/", "instagram", "abc", "instagram:abc")
        cached = Recipe(
            recipe_id="r1", canonical_video_id="instagram:abc", title="Soup",
            source_type="caption", source_url=resolved.url, source_platform="instagram",
            source_creator="chef",
        )
        with mock.patch.object(orchestrator.urls, "resolve", return_value=resolved), \
             mock.patch.object(orchestrator.db, "get_recipe_by_video_id", return_value=cached), \
             mock.patch.object(orchestrator.fetch, "fetch_instagram_metadata") as fetch_call, \
             mock.patch.object(orchestrator.importlimit, "record_success"), \
             self._common() as stores:
            orchestrator._process_job(_job(resolved.url))
        fetch_call.assert_not_called()
        self.assertEqual(stores["save_recipe"].call_args.args[0].source_creator, "chef")


class AttributionPersistenceTests(unittest.TestCase):
    def setUp(self):
        self.original = config.DB_PATH
        fd, self.path = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        config.DB_PATH = self.path
        db.init_db()

    def tearDown(self):
        config.DB_PATH = self.original
        if db._engine is not None:
            db._engine.dispose()
        try:
            os.remove(self.path)
        except OSError:
            pass

    def test_serialization_and_persistence_round_trip(self):
        recipe = Recipe(
            recipe_id="r1", canonical_video_id="web:https://example.com/r", title="Soup",
            source_type="structured", source_url="https://example.com/r",
            source_platform="web", source_creator="Ada Cook",
        )
        db.save_recipe(recipe)
        loaded = db.get_recipe("r1")
        self.assertEqual(loaded.source_url, recipe.source_url)
        self.assertEqual(loaded.source_platform, "web")
        self.assertEqual(loaded.source_creator, "Ada Cook")
        self.assertIn('"source_url":"https://example.com/r"', recipe.model_dump_json())


class AttributionMigrationTests(unittest.TestCase):
    def test_legacy_rows_backfill_from_completed_job_without_inventing_creator(self):
        original = config.DB_PATH
        fd, path = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        connection = sqlite3.connect(path)
        connection.executescript("""
            CREATE TABLE jobs (job_id VARCHAR PRIMARY KEY, data TEXT NOT NULL);
            CREATE TABLE recipes (recipe_id VARCHAR PRIMARY KEY, canonical_video_id VARCHAR NOT NULL UNIQUE, data TEXT NOT NULL);
            CREATE TABLE user_recipes (user_id VARCHAR NOT NULL, recipe_id VARCHAR NOT NULL, custom_name TEXT, sort_key TEXT, saved_at TEXT NOT NULL, PRIMARY KEY (user_id, recipe_id));
            CREATE TABLE feedback (id INTEGER PRIMARY KEY AUTOINCREMENT, rating INTEGER, message TEXT, contact_email TEXT, app_version TEXT, platform TEXT, created_at TEXT NOT NULL);
        """)
        connection.execute(
            "INSERT INTO jobs VALUES (?, ?)",
            ("j", '{"job_id":"j","user_id":"device","account_id":"account","url":"https://example.com/recipe","canonical_video_id":"web:https://example.com/recipe","platform":"web","status":"complete","created_at":"now","recipe_id":"r"}'),
        )
        connection.execute(
            "INSERT INTO recipes VALUES (?, ?, ?)",
            ("r", "web:https://example.com/recipe", '{"recipe_id":"r","canonical_video_id":"web:https://example.com/recipe","title":"Soup","source_type":"structured"}'),
        )
        connection.execute(
            "INSERT INTO user_recipes VALUES (?, ?, ?, ?, ?)",
            ("device", "r", None, "", "now"),
        )
        connection.commit()
        connection.close()

        try:
            config.DB_PATH = path
            db.init_db()
            recipe = db.get_recipe("r")
            self.assertEqual(recipe.source_url, "https://example.com/recipe")
            self.assertEqual(recipe.source_platform, "web")
            self.assertIsNone(recipe.source_creator)
            with db.get_engine().begin() as conn:
                self.assertEqual(
                    conn.execute(select(db.user_recipes.c.account_id)).scalar_one(),
                    "account",
                )
                self.assertEqual(conn.execute(select(db.jobs.c.account_id)).scalar_one(), "account")
        finally:
            config.DB_PATH = original
            if db._engine is not None:
                db._engine.dispose()
            try:
                os.remove(path)
            except OSError:
                pass


if __name__ == "__main__":
    unittest.main()
