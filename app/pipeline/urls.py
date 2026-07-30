"""URL normalization + canonical video-ID extraction (CLAUDE.md §5).

The canonical video ID is the cache/idempotency key, so we must derive it
*before* any extraction work. Short links (vm.tiktok.com, etc.) are expanded
by following redirects.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from urllib.parse import parse_qsl, urlencode, urlparse, urlsplit, urlunsplit

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
    platform: str  # "instagram" | "tiktok" | "web"
    video_id: str  # platform-native id/shortcode ("" for generic web)
    canonical_video_id: str  # "<platform>:<video_id>" or "web:<url>" — cache key


# Query params that are tracking noise, stripped when normalizing a blog URL so
# the same recipe shared with different UTM tags maps to one cache entry.
_TRACKING_PREFIXES = ("utm_",)
_TRACKING_KEYS = {"fbclid", "gclid", "mc_cid", "mc_eid", "igshid", "ref", "ref_src"}


def _normalize_web_url(url: str) -> str:
    """Canonicalize a blog URL into a stable cache key: lowercase scheme+host,
    drop default port + fragment, strip tracking params, drop trailing slash."""
    parts = urlsplit(url)
    scheme = parts.scheme.lower()
    host = (parts.hostname or "").lower()

    netloc = host
    if parts.port and not (
        (scheme == "http" and parts.port == 80)
        or (scheme == "https" and parts.port == 443)
    ):
        netloc = f"{host}:{parts.port}"

    path = parts.path.rstrip("/") or "/"

    kept = [
        (k, v)
        for k, v in parse_qsl(parts.query, keep_blank_values=True)
        if not k.lower().startswith(_TRACKING_PREFIXES) and k.lower() not in _TRACKING_KEYS
    ]
    query = urlencode(kept)

    return urlunsplit((scheme, netloc, path, query, ""))


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

    # Generic web / blog: no video id. The normalized URL is the cache key.
    # A parseable host is still required — a hostless URL is genuinely invalid.
    if not host:
        raise UrlError("could not parse a host from URL")
    normalized = _normalize_web_url(url)
    return ResolvedUrl(normalized, "web", "", f"web:{normalized}")
