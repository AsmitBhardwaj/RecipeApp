"""Image resolution (CLAUDE.md §5).

    if video_thumbnail exists and looks food-relevant:
        video_thumbnail
    else:
        stock photo search (Pexels) by title
    else:
        none

ASSUMPTION: "looks food-relevant" genuinely needs an image classifier / vision
call, which is out of MVP scope. Since every source here is a cooking video, we
treat a present thumbnail as food-relevant. The persistent `image_source` badge
(surfaced to the client) still lets the user tell a real thumbnail from a stock
photo, satisfying the hard rule in §5.

We use Pexels (env var PEXELS_API_KEY): single-header auth, no OAuth, generous
free tier. No AI image generation is used (deferred, §2).
"""
from __future__ import annotations

from typing import Optional, Tuple

import requests

from .. import config

_ImageResult = Tuple[Optional[str], str]  # (image_url, image_source)


def _search_pexels(title: str) -> Optional[str]:
    if not config.PEXELS_API_KEY or not title.strip():
        return None
    try:
        resp = requests.get(
            "https://api.pexels.com/v1/search",
            params={"query": title, "per_page": 1, "orientation": "square"},
            headers={"Authorization": config.PEXELS_API_KEY},
            timeout=10,
        )
        resp.raise_for_status()
        photos = resp.json().get("photos", [])
        if photos:
            return photos[0]["src"].get("large") or photos[0]["src"].get("original")
    except (requests.RequestException, ValueError, KeyError):
        return None
    return None


def resolve_image(thumbnail_url: Optional[str], title: str) -> _ImageResult:
    if thumbnail_url:
        return thumbnail_url, "video_thumbnail"

    stock = _search_pexels(title)
    if stock:
        return stock, "stock_photo"

    return None, "none"
