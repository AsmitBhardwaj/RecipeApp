from __future__ import annotations

import unittest
from unittest import mock

import requests

from app import config
from app.auth import apple_revocation


class AppleRevocationTests(unittest.TestCase):
    def setUp(self):
        self.original_secret = config.APPLE_REVOCATION_ENCRYPTION_KEY
        self.original_clients = config.APPLE_CLIENT_IDS
        config.APPLE_REVOCATION_ENCRYPTION_KEY = "test-only-random-secret-that-is-long-enough"
        config.APPLE_CLIENT_IDS = ["com.example.app"]

    def tearDown(self):
        config.APPLE_REVOCATION_ENCRYPTION_KEY = self.original_secret
        config.APPLE_CLIENT_IDS = self.original_clients

    def test_stored_credential_is_encrypted_and_round_trips(self):
        encrypted = apple_revocation.encrypt_refresh_token("private-refresh-token")
        self.assertNotIn("private-refresh-token", encrypted)
        self.assertEqual(apple_revocation.decrypt_refresh_token(encrypted), "private-refresh-token")

    @mock.patch("app.auth.apple_revocation._client_secret", return_value="signed-client-secret")
    @mock.patch("app.auth.apple_revocation.requests.post")
    def test_authorization_code_exchange_returns_refresh_credential(self, post, _secret):
        post.return_value.status_code = 200
        post.return_value.json.return_value = {"refresh_token": "apple-refresh"}
        self.assertEqual(
            apple_revocation.exchange_authorization_code("one-time-code"),
            "apple-refresh",
        )
        body = post.call_args.kwargs["data"]
        self.assertEqual(body["grant_type"], "authorization_code")
        self.assertEqual(body["client_id"], "com.example.app")

    @mock.patch("app.auth.apple_revocation._client_secret", return_value="signed-client-secret")
    @mock.patch("app.auth.apple_revocation.requests.post")
    def test_revoke_posts_decrypted_token(self, post, _secret):
        post.return_value.status_code = 200
        encrypted = apple_revocation.encrypt_refresh_token("apple-refresh")
        result = apple_revocation.revoke_encrypted(encrypted)
        self.assertTrue(result.succeeded)
        self.assertEqual(post.call_args.kwargs["data"]["token_type_hint"], "refresh_token")
        self.assertEqual(post.call_args.kwargs["data"]["token"], "apple-refresh")

    @mock.patch("app.auth.apple_revocation.requests.post", side_effect=requests.Timeout())
    def test_temporary_revoke_failure_is_safe_and_retryable(self, _post):
        encrypted = apple_revocation.encrypt_refresh_token("apple-refresh")
        with mock.patch("app.auth.apple_revocation._client_secret", return_value="secret"):
            result = apple_revocation.revoke_encrypted(encrypted)
        self.assertFalse(result.succeeded)
        self.assertEqual(result.safe_error_code, "revocation_unavailable")


if __name__ == "__main__":
    unittest.main()
