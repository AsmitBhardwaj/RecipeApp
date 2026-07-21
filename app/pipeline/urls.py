"""URL normalization + canonical video-ID extraction (CLAUDE.md §5).

The canonical video ID is the cache/idempotency key, so we must derive it
*before* any extraction work. Short links (vm.tiktok.com, etc.) are expanded
by following redirects.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from urllib.parse import urlparse

import requests

_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
)

# Hosts whose links are shortened/redirected and must be expanded first.
_SHORTLINK_HOSTS = {
    "vm.tiktok.com",
    "vt.tiktok.com",
    "instagr.am",
}


class UrlError(ValueError):
    """Raised when a URL can't be understood or a video ID can't be found."""


@dataclass
class ResolvedUrl:
    url: str  # expanded, normalized URL
    platform: str  # "instagram" | "tiktok"
    video_id: str  # platform-native id/shortcode
    canonical_video_id: str  # "<platform>:<video_id>" — the cache key


def _expand(url: str) -> str:
    """Follow redirects for known short-link hosts."""
    host = (urlparse(url).hostname or "").lower()
    if host not in _SHORTLINK_HOSTS:
        return url
    try:
        resp = requests.get(
            url,
            allow_redirects=True,
            timeout=10,
            headers={"User-Agent": _UA},
        )
        return resp.url or url
    except requests.RequestException as exc:  # network hiccup expanding shortlink
        raise UrlError(f"could not expand short link: {exc}") from exc


def resolve(url: str) -> ResolvedUrl:
    url = url.strip()
    if not url:
        raise UrlError("empty URL")
    if not url.startswith(("http://", "https://")):
        url = "https://" + url

    url = _expand(url)
    host = (urlparse(url).hostname or "").lower()

    if "tiktok.com" in host:
        # e.g. /@user/video/1234567890123456789
        m = re.search(r"/video/(\d+)", url)
        if not m:
            raise UrlError("could not find TikTok video id in URL")
        vid = m.group(1)
        return ResolvedUrl(url, "tiktok", vid, f"tiktok:{vid}")

    if "instagram.com" in host:
        # e.g. /reel/<shortcode>/ , /reels/<shortcode>/ , /p/<shortcode>/
        m = re.search(r"/(?:reel|reels|p|tv)/([A-Za-z0-9_-]+)", url)
        if not m:
            raise UrlError("could not find Instagram shortcode in URL")
        vid = m.group(1)
        return ResolvedUrl(url, "instagram", vid, f"instagram:{vid}")

    raise UrlError(f"unsupported platform for host: {host or 'unknown'}")
