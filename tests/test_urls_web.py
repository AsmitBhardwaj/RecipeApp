"""Generic-web URL resolution + normalization (app/pipeline/urls.py).

The blog tier turns any non-IG/TikTok URL into a `web` ResolvedUrl whose
canonical id is the NORMALIZED url — so the same recipe shared with different
tracking params or a trailing slash maps to one cache entry. Also guards that
the existing IG/TikTok resolution is unchanged.

Blog hosts aren't shortlink hosts, so resolve() does no network here.

    python3 -m unittest tests.test_urls_web
"""
from __future__ import annotations

import unittest

from app.pipeline import urls


class NormalizeTests(unittest.TestCase):
    def test_strips_tracking_and_trailing_slash(self):
        got = urls._normalize_web_url(
            "https://Cooking.Example.com/recipes/123-foo/?utm_source=ig&fbclid=abc&page=2"
        )
        self.assertEqual(got, "https://cooking.example.com/recipes/123-foo?page=2")

    def test_drops_default_port_and_fragment(self):
        got = urls._normalize_web_url("https://example.com:443/foo/#jump-to-recipe")
        self.assertEqual(got, "https://example.com/foo")

    def test_keeps_nondefault_port(self):
        got = urls._normalize_web_url("http://example.com:8080/foo")
        self.assertEqual(got, "http://example.com:8080/foo")

    def test_bare_host_becomes_root_path(self):
        self.assertEqual(urls._normalize_web_url("https://example.com"), "https://example.com/")


class ResolveWebTests(unittest.TestCase):
    def test_blog_url_resolves_to_web_platform(self):
        r = urls.resolve("https://cooking.example.com/recipes/123-foo/")
        self.assertEqual(r.platform, "web")
        self.assertEqual(r.video_id, "")
        self.assertEqual(r.canonical_video_id, "web:https://cooking.example.com/recipes/123-foo")
        self.assertEqual(r.url, "https://cooking.example.com/recipes/123-foo")

    def test_bare_domain_gets_https_scheme(self):
        r = urls.resolve("cooking.example.com/recipes/x")
        self.assertEqual(r.platform, "web")
        self.assertTrue(r.canonical_video_id.startswith("web:https://cooking.example.com/recipes/x"))

    def test_same_recipe_diff_tracking_shares_cache_key(self):
        a = urls.resolve("https://example.com/r/pie?utm_medium=x")
        b = urls.resolve("https://example.com/r/pie/")
        self.assertEqual(a.canonical_video_id, b.canonical_video_id)

    def test_empty_url_still_rejected(self):
        with self.assertRaises(urls.UrlError):
            urls.resolve("   ")


class ResolveVideoRegressionTests(unittest.TestCase):
    def test_tiktok_unchanged(self):
        r = urls.resolve("https://www.tiktok.com/@user/video/1234567890123456789")
        self.assertEqual(r.platform, "tiktok")
        self.assertEqual(r.canonical_video_id, "tiktok:1234567890123456789")

    def test_instagram_unchanged(self):
        r = urls.resolve("https://www.instagram.com/reel/DVBmx5kAsa2/")
        self.assertEqual(r.platform, "instagram")
        self.assertEqual(r.canonical_video_id, "instagram:DVBmx5kAsa2")


if __name__ == "__main__":
    unittest.main()
