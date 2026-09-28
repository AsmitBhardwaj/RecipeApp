"""The suite-wide OpenAI guard (tests/__init__.py) is really installed."""
from __future__ import annotations

import unittest

import tests
from app import config
from app.pipeline import llm


class NoOpenAIGuardTests(unittest.TestCase):
    def test_api_key_is_blank(self) -> None:
        self.assertFalse(config.OPENAI_API_KEY)

    def test_unmocked_client_raises_and_is_recorded(self) -> None:
        before = len(tests.UNMOCKED_OPENAI_CALLS)
        try:
            with self.assertRaises(tests.UnmockedOpenAICall):
                llm._client()
            # It is a BaseException, so `except Exception` in app code can't swallow it.
            self.assertFalse(issubclass(tests.UnmockedOpenAICall, Exception))
        finally:
            del tests.UNMOCKED_OPENAI_CALLS[before:]  # don't trip the atexit failure


if __name__ == "__main__":
    unittest.main()
