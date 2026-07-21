"""Caption / metadata / thumbnail fetch (CLAUDE.md §5).

Kept in its own module (not inline in the API layer) so it can later be
extracted into the isolated, frequently-updated yt-dlp microservice the spec
calls for. Failures (private/deleted/unsupported) are turned into a typed
`FetchError` with a coarse machine code rather than crashing the request.

TikTok goes through yt-dlp (`fetch_metadata`). Instagram goes through a direct
embed-endpoint scrape (`fetch_instagram_metadata`) — yt-dlp's IG path is
login-gated in practice, whereas the `/embed/captioned/` endpoint serves the
caption without auth.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional
import json
import re
import requests

import yt_dlp


class FetchError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass
class VideoMetadata:
    caption: str
    thumbnail_url: Optional[str]
    video_id: Optional[str]
    title: Optional[str]


def _classify(message: str) -> str:
    m = message.lower()
    if "private" in m:
        return "private_video"
    if any(w in m for w in ("not exist", "deleted", "unavailable", "removed", "404")):
        return "video_unavailable"
    if "login" in m or "sign in" in m or "cookies" in m:
        return "login_required"
    if "unsupported url" in m:
        return "unsupported_url"
    return "fetch_failed"


def fetch_metadata(url: str) -> VideoMetadata:
    opts = {
        "quiet": True,
        "no_warnings": True,
        "skip_download": True,
        "noplaylist": True,
    }
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=False)
    except yt_dlp.utils.DownloadError as exc:
        msg = str(exc)
        raise FetchError(_classify(msg), msg) from exc
    except Exception as exc:  # noqa: BLE001 - anything else yt-dlp throws
        raise FetchError("fetch_failed", str(exc)) from exc

    if info is None:
        raise FetchError("fetch_failed", "yt-dlp returned no metadata")

    # Caption text lives in the video description for IG/TikTok.
    caption = info.get("description") or info.get("title") or ""
    return VideoMetadata(
        caption=caption,
        thumbnail_url=info.get("thumbnail"),
        video_id=info.get("id"),
        title=info.get("title"),
    )


# --------------------------------------------------------------------------- #
# Instagram caption fetch (CLAUDE.md §5).
#
# Matches fetch_metadata's contract exactly:
#   - returns VideoMetadata
#   - raises FetchError(code, message) on failure, never lets exceptions leak
#
# thumbnail_url is always None (see TODO.md — Reel thumbnails are frequently
# not food-related, so we skip scraping og:image and let resolve_image()
# fall through to the stock-photo path).
# --------------------------------------------------------------------------- #

_IG_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"

_IG_SHORTCODE_RE = re.compile(r"instagram\.com/(?:reel|reels|p|tv)/([A-Za-z0-9_-]+)")
_CONTEXTJSON_KEY_RE = re.compile(r'contextJSON["\']?\s*[:=]\s*"')


def _ig_find_matching_close_quote(s: str, start: int) -> int:
    """Find the closing quote NOT preceded by an odd number of backslashes,
    so escaped quotes (\\") inside the JSON string don't end the scan early."""
    i = start
    while i < len(s):
        if s[i] == '"':
            backslashes = 0
            j = i - 1
            while j >= 0 and s[j] == "\\":
                backslashes += 1
                j -= 1
            if backslashes % 2 == 0:
                return i
        i += 1
    raise ValueError("Could not find closing quote for contextJSON value.")


def _ig_recursive_find_caption(node):
    if isinstance(node, dict):
        cap = node.get("edge_media_to_caption")
        if isinstance(cap, dict):
            edges = cap.get("edges")
            if edges:
                try:
                    return edges[0]["node"]["text"]
                except (KeyError, IndexError, TypeError):
                    pass
        for v in node.values():
            found = _ig_recursive_find_caption(v)
            if found:
                return found
    elif isinstance(node, list):
        for item in node:
            found = _ig_recursive_find_caption(item)
            if found:
                return found
    return None


def _ig_extract_caption_from_html(html: str):
    """Primary strategy: locate contextJSON, un-escape, walk to caption text."""
    m = _CONTEXTJSON_KEY_RE.search(html)
    if not m:
        return None

    start = m.end()
    end = _ig_find_matching_close_quote(html, start)
    raw = html[start:end]  # still JSON-escaped, e.g. \" and \/

    unescaped = json.loads('"' + raw + '"')
    data = json.loads(unescaped)

    try:
        edges = data["gql_data"]["shortcode_media"]["edge_media_to_caption"]["edges"]
        if edges:
            return edges[0]["node"]["text"]
    except (KeyError, IndexError, TypeError):
        pass

    return _ig_recursive_find_caption(data)


def _ig_extract_caption_fallbacks(html: str):
    """Rare fallbacks — never fired in the 30-URL validation run, kept for safety."""
    m = re.search(r'class="[^"]*Caption[^"]*"[^>]*>(.*?)</div>', html, re.DOTALL)
    if m:
        text = re.sub(r"<[^>]+>", "", m.group(1)).strip()
        if text:
            return text
    m = re.search(r'<meta[^>]+property="og:description"[^>]+content="([^"]*)"', html)
    if m:
        return m.group(1).strip()
    return None


def fetch_instagram_metadata(url: str) -> VideoMetadata:
    """
    Fetch an Instagram Reel's caption via the validated contextJSON strategy
    (29/30 success on real reels, two independent networks, no proxy needed).

    IMPORTANT: the User-Agent header must be set — Instagram serves a thin
    response with the same HTTP 200 to a bare python-requests UA.
    """
    m = _IG_SHORTCODE_RE.search(url)
    if not m:
        raise FetchError("fetch_failed", f"Could not extract Instagram shortcode from URL: {url}")
    shortcode = m.group(1)

    embed_url = f"https://www.instagram.com/reel/{shortcode}/embed/captioned/"

    try:
        session = requests.Session()
        session.headers.update({"User-Agent": _IG_UA})  # the critical fix
        resp = session.get(embed_url, timeout=15)
        resp.raise_for_status()
        html = resp.text
    except requests.RequestException as exc:
        raise FetchError("fetch_failed", str(exc)) from exc

    try:
        caption = _ig_extract_caption_from_html(html)
        if caption is None:
            caption = _ig_extract_caption_fallbacks(html)
    except Exception as exc:  # noqa: BLE001 - malformed contextJSON, etc.
        raise FetchError("fetch_failed", f"Failed to parse Instagram response: {exc}") from exc

    if caption is None:
        # ~3% of real reels hit this (e.g. audio-only / caption-less reels).
        # This is where the "paste the caption?" UI fallback should eventually
        # catch the user — not built yet, so for now it's a typed failure.
        raise FetchError(
            "caption_not_found",
            "Could not extract a caption for this reel (it may not have one).",
        )

    return VideoMetadata(
        caption=caption,
        thumbnail_url=None,  # intentionally skipped — see TODO.md
        video_id=shortcode,
        title=None,
    )
