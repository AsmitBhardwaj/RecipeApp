"""Generic-web page fetch + article-text extraction (CLAUDE.md §5, web tier).

Kept separate from `fetch.py` (which is the IG/TikTok video path) since this
tier scrapes arbitrary blog HTML rather than going through yt-dlp. Every network
call here routes through `netguard.assert_fetchable` first — the SSRF guard is
not optional.

`safe_get` follows redirects MANUALLY (auto-redirects disabled) so each hop is
re-validated by the guard, and caps timeout + response size so a hostile or
broken page can't hang or exhaust memory.
"""
from __future__ import annotations

from typing import Optional, Tuple
from urllib.parse import urljoin

import requests
import trafilatura
from bs4 import BeautifulSoup

from . import netguard

# Browser-like UA: many recipe sites serve a thin/blocked response to a bare
# python-requests UA (same lesson as the Instagram fetch path).
_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
)

_TIMEOUT = 15
_MAX_BYTES = 5 * 1024 * 1024   # 5 MB cap — recipe pages are far smaller
_MAX_REDIRECTS = 5


class WebFetchError(Exception):
    """Raised when a web page can't be fetched or isn't usable HTML."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def safe_get(url: str) -> Tuple[str, str]:
    """Fetch `url` as HTML, returning (html, final_url).

    Validates the URL (and every redirect target) through the SSRF guard,
    follows redirects manually with a hop cap, requires an HTML content-type,
    and enforces a response-size budget. `netguard.BlockedURLError` propagates
    to the caller unchanged so it can be reported as a distinct failure.
    """
    session = requests.Session()
    session.headers.update({"User-Agent": _UA})

    current = url
    for _ in range(_MAX_REDIRECTS + 1):
        netguard.assert_fetchable(current)  # re-validated on every hop
        try:
            resp = session.get(
                current,
                timeout=_TIMEOUT,
                allow_redirects=False,
                stream=True,
            )
        except requests.RequestException as exc:
            raise WebFetchError("fetch_failed", str(exc)) from exc

        if resp.is_redirect or resp.status_code in (301, 302, 303, 307, 308):
            location = resp.headers.get("Location")
            resp.close()
            if not location:
                raise WebFetchError("fetch_failed", "redirect without a Location header")
            current = urljoin(current, location)
            continue

        try:
            resp.raise_for_status()
        except requests.HTTPError as exc:
            raise WebFetchError("fetch_failed", str(exc)) from exc

        content_type = (resp.headers.get("Content-Type") or "").lower()
        if "html" not in content_type:
            raise WebFetchError("not_html", f"unsupported content-type: {content_type or 'unknown'}")

        html = _read_capped(resp)
        return html, current

    raise WebFetchError("too_many_redirects", "exceeded redirect limit")


def _read_capped(resp: requests.Response) -> str:
    """Read the body up to `_MAX_BYTES`, then decode. Guards against oversized
    responses / decompression bombs."""
    total = 0
    chunks = []
    for chunk in resp.iter_content(chunk_size=8192):
        if not chunk:
            continue
        total += len(chunk)
        if total > _MAX_BYTES:
            resp.close()
            raise WebFetchError("too_large", "response exceeded size limit")
        chunks.append(chunk)
    resp.close()
    encoding = resp.encoding or "utf-8"
    return b"".join(chunks).decode(encoding, errors="replace")


def extract_article_text(html: str) -> str:
    """Main article text with nav/ads/comments stripped (trafilatura)."""
    extracted = trafilatura.extract(html) if html else None
    return extracted or ""


def og_image(html: str) -> Optional[str]:
    """The page's og:image, used as the article path's image candidate."""
    if not html:
        return None
    soup = BeautifulSoup(html, "lxml")
    tag = soup.find("meta", attrs={"property": "og:image"})
    if tag and tag.get("content"):
        return tag["content"].strip()
    return None
