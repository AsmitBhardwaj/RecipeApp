"""App Store Connect private-key normalization and startup diagnostics."""
from __future__ import annotations

import unittest
from unittest import mock

from app import config


class AppStorePrivateKeyConfigTests(unittest.TestCase):
    def test_normalizes_body_only_input(self):
        self.assertEqual(
            config._normalize_appstore_private_key("  abc123\nxyz789  "),
            "-----BEGIN PRIVATE KEY-----\nabc123xyz789\n-----END PRIVATE KEY-----\n",
        )

    def test_normalizes_escaped_newlines(self):
        escaped = (
            "-----BEGIN PRIVATE KEY-----\\nabc123\\nxyz789\\n"
            "-----END PRIVATE KEY-----"
        )
        self.assertEqual(
            config._normalize_appstore_private_key(escaped),
            "-----BEGIN PRIVATE KEY-----\nabc123\nxyz789\n-----END PRIVATE KEY-----\n",
        )

    def test_normalizes_full_pem_input(self):
        pem = "-----BEGIN PRIVATE KEY-----\nabc123\n-----END PRIVATE KEY-----\n"
        self.assertEqual(config._normalize_appstore_private_key(pem), pem)

    @mock.patch("app.main.db.init_db")
    @mock.patch("app.main.appstore.private_key_loaded_ok", return_value=True)
    def test_startup_logs_success_without_key_material(self, _loaded, _init_db):
        from app import main

        with mock.patch.object(config, "JWT_SECRET_IS_DEV_FALLBACK", False):
            with self.assertLogs("uvicorn.error", level="INFO") as captured:
                main._startup()

        self.assertEqual(
            captured.output,
            ["INFO:uvicorn.error:App Store private key loaded OK: True"],
        )


if __name__ == "__main__":
    unittest.main()
