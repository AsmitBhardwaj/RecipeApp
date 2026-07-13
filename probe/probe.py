#!/usr/bin/env python3
"""
Instagram Reel caption-extraction probe  (THROWAWAY MEASUREMENT TOOL)
=====================================================================

WHAT THIS MEASURES
------------------
For a list of Instagram Reel URLs, how reliably can we pull the *caption*
(the text we extract recipes from) using ONLY Instagram's public embed
endpoint — no login, no headless browser? And how often does the caption
actually contain quantities (a proxy for "is this a usable recipe")?

The point is to decide two things:
  1. Do I need a residential proxy? Run this from your laptop, from a VPS
     with no proxy, and from a VPS with a proxy, and compare success rates.
     If direct-from-VPS success is low but proxy success is high, datacenter
     IPs are being blocked and a proxy is warranted.
  2. Which extraction tier should be the default? The "winning strategy"
     breakdown tells you whether the structured JSON path carries most
     cases or whether you're leaning on the HTML/meta fallbacks.

For each URL it tries an ordered chain; first non-empty caption wins:
  1. gql_json       — GET .../embed/captioned/, parse the `gql_data` JSON
                      blob and recursively find `edge_media_to_caption`.
  2. caption_div    — same response, scrape the embed HTML caption <div>.
  3. og_description — same response, read the og:description meta tag.

HOW TO RUN
----------
  cd probe
  python3 -m pip install requests          # only dependency
  # 1) put your real Reel URLs in urls.txt (one per line)
  # 2a) direct, no proxy:
  python3 probe.py
  # 2b) through a proxy (standard http://user:pass@host:port):
  PROXY_URL="http://user:pass@gate.example.com:7000" python3 probe.py

Output: a per-URL table + a summary to stdout, and full raw results
(including the captured caption text) to probe/results.json.

WHAT NUMBER TO LOOK FOR
-----------------------
Compare the "success rate %" across the three runs. If laptop is high but
VPS-direct is low and VPS-proxy is high, you need the proxy. If VPS-direct
is already high, you don't. See the printed guidance at the end of a run.
"""
from __future__ import annotations

import html as html_lib
import json
import os
import random
import re
import time
from collections import Counter
from typing import Any, Optional, Tuple
from urllib.parse import urlparse

import requests

# A realistic desktop-Chrome UA — Instagram serves different/emptier markup
# to obvious bots.
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
)
HEADERS = {
    "User-Agent": USER_AGENT,
    "Accept-Language": "en-US,en;q=0.9",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
}

TIMEOUT = 20  # seconds per request

# shortcode lives in /reel|reels|p|tv/<shortcode>
_SHORTCODE_RE = re.compile(r"/(reel|reels|p|tv)/([A-Za-z0-9_-]+)")

# has_quantities heuristic: digit+unit (2 tbsp, 200g), a "1/2" fraction, or a
# unicode fraction glyph.
_QTY_RE = re.compile(
    r"(\d+(\.\d+)?\s*(g|kg|ml|l|tbsp|tsp|cup|cups|oz|lb|lbs)\b)"
    r"|(\d\s*/\s*\d)"
    r"|[½⅓⅔¼¾⅛⅜⅝⅞]",
    re.IGNORECASE,
)


# --------------------------------------------------------------------------- #
# URL handling
# --------------------------------------------------------------------------- #


def _match_shortcode(url: str) -> Optional[Tuple[str, str]]:
    """Return (kind, shortcode) from a URL path, ignoring query params.

    `/share/...` links carry a redirect token that merely *looks* like a
    shortcode (e.g. /share/reel/<token>) — return None so the caller resolves
    the redirect to the canonical URL first."""
    path = urlparse(url).path
    if "/share/" in path:
        return None
    m = _SHORTCODE_RE.search(path)
    if m:
        return m.group(1), m.group(2)
    return None


def resolve_shortcode(
    url: str, session: requests.Session, proxies: Optional[dict]
) -> Tuple[Optional[str], Optional[str], str]:
    """(kind, shortcode, final_url). Resolves share/redirect links first."""
    direct = _match_shortcode(url)
    if direct:
        return direct[0], direct[1], url

    final = url
    # HEAD (follow redirects) to resolve share-sheet links.
    try:
        h = session.head(url, allow_redirects=True, timeout=TIMEOUT, proxies=proxies)
        final = h.url or url
        m = _match_shortcode(final)
        if m:
            return m[0], m[1], final
    except requests.RequestException:
        pass

    # Some share links don't answer HEAD usefully — resolve with a GET.
    try:
        g = session.get(
            url, allow_redirects=True, timeout=TIMEOUT, proxies=proxies, stream=True
        )
        final = g.url or final
        g.close()
        m = _match_shortcode(final)
        if m:
            return m[0], m[1], final
    except requests.RequestException:
        pass

    return None, None, final


def embed_url(kind: str, shortcode: str) -> str:
    # /reels/ has no embed form — normalize to /reel/. p and tv keep their kind.
    kind = "reel" if kind in ("reel", "reels") else kind
    return f"https://www.instagram.com/{kind}/{shortcode}/embed/captioned/"


# --------------------------------------------------------------------------- #
# Caption extraction strategies
# --------------------------------------------------------------------------- #


def _find_key(obj: Any, key: str) -> Optional[Any]:
    """Recursively search a nested dict/list for the first value under `key`.

    Instagram nests edge_media_to_caption inconsistently, so we search rather
    than walk a fixed path."""
    if isinstance(obj, dict):
        if key in obj:
            return obj[key]
        for v in obj.values():
            found = _find_key(v, key)
            if found is not None:
                return found
    elif isinstance(obj, list):
        for v in obj:
            found = _find_key(v, key)
            if found is not None:
                return found
    return None


def _extract_escaped_string_value(page: str) -> Optional[str]:
    """Extract the raw (still-escaped) value of the contextJSON blob.

    On the real embed page this appears as a JSON key,  "contextJSON":"{...}"
    (older builds used the attribute form  contextJSON="{...}" ), whose value
    is a JSON-escaped string. We must read from just after the opening quote to
    the matching CLOSING quote — the one preceded by an EVEN number of
    backslashes, so escaped quotes (\\") inside the value don't terminate it."""
    for marker in ('contextJSON":"', 'contextJSON="'):
        i = page.find(marker)
        if i == -1:
            continue
        start = i + len(marker)
        j = start
        while j < len(page):
            if page[j] == '"':
                k, backslashes = j - 1, 0
                while k >= start and page[k] == "\\":
                    backslashes += 1
                    k -= 1
                if backslashes % 2 == 0:  # unescaped quote -> end of value
                    return page[start:j]
            j += 1
    return None


def strategy_context_json(page: str) -> Optional[str]:
    """Strategy 1: the contextJSON blob (the real structure on embed pages).

    Extract the escaped string value, un-escape it ONCE, json.loads it, then
    walk gql_data.shortcode_media.edge_media_to_caption.edges[0].node.text —
    falling back to a recursive search if that exact path isn't present.

    Un-escaping is done via json.loads('"' + raw + '"'): wrapping the escaped
    value as a JSON string literal and decoding it reverses every JSON escape
    (\\" \\\\ \\/ \\n \\uXXXX) in one correct pass — more robust than a fixed
    set of string substitutions, which would leave \\n / \\uXXXX mangled."""
    raw = _extract_escaped_string_value(page)
    if not raw:
        return None
    try:
        inner = json.loads('"' + raw + '"')  # un-escape one level
        data = json.loads(inner)  # parse the real payload
    except (json.JSONDecodeError, ValueError):
        return None

    # Preferred exact path.
    try:
        text = data["gql_data"]["shortcode_media"]["edge_media_to_caption"][
            "edges"
        ][0]["node"]["text"]
        if text and text.strip():
            return text.strip()
    except (KeyError, IndexError, TypeError):
        pass

    # Fallback: recursive search for the caption key anywhere in the payload.
    cap = _find_key(data, "edge_media_to_caption")
    if isinstance(cap, dict):
        try:
            text = cap["edges"][0]["node"]["text"]
            if text and text.strip():
                return text.strip()
        except (KeyError, IndexError, TypeError):
            pass
    return None


def _strip_tags(fragment: str) -> str:
    no_tags = re.sub(r"<[^>]+>", " ", fragment)
    return re.sub(r"\s+", " ", html_lib.unescape(no_tags)).strip()


def strategy_caption_div(page: str) -> Optional[str]:
    """Strategy 2: scrape the embed HTML caption <div>."""
    m = re.search(
        r'<div[^>]*class="[^"]*Caption[^"]*"[^>]*>(.*?)</div>',
        page,
        re.DOTALL | re.IGNORECASE,
    )
    if not m:
        return None
    text = _strip_tags(m.group(1))
    return text or None


def strategy_og_description(page: str) -> Optional[str]:
    """Strategy 3: og:description meta tag."""
    m = re.search(
        r'<meta\s+property="og:description"\s+content="([^"]*)"', page, re.IGNORECASE
    )
    if not m:
        return None
    text = html_lib.unescape(m.group(1)).strip()
    return text or None


STRATEGIES = [
    ("gql_json", strategy_context_json),
    ("caption_div", strategy_caption_div),
    ("og_description", strategy_og_description),
]


def has_quantities(caption: str) -> bool:
    return bool(_QTY_RE.search(caption or ""))


# --------------------------------------------------------------------------- #
# Per-URL probe
# --------------------------------------------------------------------------- #


def probe_one(
    url: str, session: requests.Session, proxies: Optional[dict]
) -> dict:
    row: dict = {
        "url": url,
        "shortcode": None,
        "final_url": None,
        "embed_url": None,
        "http_status": None,
        "winning_strategy": None,
        "caption": None,
        "caption_len": 0,
        "has_quantities": False,
        "ok": False,
        "reason": None,
    }
    try:
        kind, shortcode, final = resolve_shortcode(url, session, proxies)
        row["final_url"] = final
        if not shortcode:
            row["reason"] = "no shortcode (could not resolve URL)"
            return row
        row["shortcode"] = shortcode

        eurl = embed_url(kind, shortcode)
        row["embed_url"] = eurl

        resp = session.get(eurl, timeout=TIMEOUT, proxies=proxies)
        row["http_status"] = resp.status_code
        page = resp.text

        for name, fn in STRATEGIES:
            try:
                caption = fn(page)
            except Exception as exc:  # a parser bug on one page must not crash
                row["reason"] = f"{name} parser error: {exc}"
                caption = None
            if caption:
                row["winning_strategy"] = name
                row["caption"] = caption
                row["caption_len"] = len(caption)
                row["has_quantities"] = has_quantities(caption)
                row["ok"] = True
                row["reason"] = None
                return row

        if row["reason"] is None:
            row["reason"] = f"no caption found (http {resp.status_code})"
        return row

    except requests.Timeout:
        row["reason"] = "timeout"
        return row
    except requests.RequestException as exc:
        row["reason"] = f"request error: {exc}"
        return row
    except Exception as exc:  # last-resort catch — never crash the run
        row["reason"] = f"unexpected error: {exc}"
        return row


# --------------------------------------------------------------------------- #
# Input / output
# --------------------------------------------------------------------------- #


def read_urls(path: str) -> list:
    urls = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            urls.append(line)
    return urls


def print_table(rows: list) -> None:
    header = ("shortcode", "winning_strategy", "http", "cap_len", "has_qty", "ok")
    widths = (13, 16, 5, 8, 8, 4)

    def fmt(cols):
        return "  ".join(str(c)[:w].ljust(w) for c, w in zip(cols, widths))

    print(fmt(header))
    print("  ".join("-" * w for w in widths))
    for r in rows:
        print(
            fmt(
                (
                    r["shortcode"] or "-",
                    r["winning_strategy"] or "-",
                    r["http_status"] if r["http_status"] is not None else "-",
                    r["caption_len"],
                    "yes" if r["has_quantities"] else "no",
                    "OK" if r["ok"] else "FAIL",
                )
            )
        )


def print_summary(rows: list) -> None:
    total = len(rows)
    ok_rows = [r for r in rows if r["ok"]]
    n_ok = len(ok_rows)
    n_qty = sum(1 for r in ok_rows if r["has_quantities"])
    rate = (n_ok / total * 100) if total else 0.0
    strat_counts = Counter(r["winning_strategy"] for r in ok_rows)

    print("\n" + "=" * 48)
    print("SUMMARY")
    print("=" * 48)
    print(f"total URLs           : {total}")
    print(f"caption success      : {n_ok}")
    print(f"success rate         : {rate:.1f}%")
    print(f"with quantities      : {n_qty}  ({(n_qty/total*100) if total else 0:.1f}% of all)")
    print("winning strategy breakdown (successes only):")
    if strat_counts:
        for name, _ in STRATEGIES:
            if strat_counts.get(name):
                print(f"    {name:<16}: {strat_counts[name]}")
    else:
        print("    (none)")

    # Failure reasons, to spot blocking vs parsing issues.
    fails = [r for r in rows if not r["ok"]]
    if fails:
        print("failure reasons:")
        for reason, count in Counter(r["reason"] for r in fails).most_common():
            print(f"    {count:>3}  {reason}")


def print_guidance(rows: list) -> None:
    proxy = os.environ.get("PROXY_URL")
    total = len(rows)
    n_ok = sum(1 for r in rows if r["ok"])
    rate = (n_ok / total * 100) if total else 0.0
    where = "WITH proxy" if proxy else "NO proxy (direct)"
    print("\n" + "-" * 48)
    print(f"This run: {where}  ->  success rate {rate:.1f}%")
    print("-" * 48)
    print(
        "Decision guide:\n"
        "  * Run this 3 times: laptop (no proxy), VPS (no proxy), VPS (proxy).\n"
        "  * If laptop is high but VPS-direct is much lower, your datacenter IP\n"
        "    is being throttled/blocked -> a residential proxy is warranted.\n"
        "  * If VPS-direct is already high (say >80%), you do NOT need a proxy.\n"
        "  * Default extraction tier = whichever strategy dominates the\n"
        "    'winning strategy breakdown' above.\n"
        "  * Low 'with quantities' even when success is high = captions are\n"
        "    present but recipe-poor; extraction quality, not fetching, is the\n"
        "    bottleneck."
    )


def main() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    urls_path = os.path.join(here, "urls.txt")
    results_path = os.path.join(here, "results.json")

    if not os.path.exists(urls_path):
        print(f"missing {urls_path}")
        return
    urls = read_urls(urls_path)
    if not urls:
        print(f"no URLs in {urls_path} (add real Reel URLs, one per line)")
        return

    proxy = os.environ.get("PROXY_URL")
    proxies = {"http": proxy, "https": proxy} if proxy else None

    session = requests.Session()
    session.headers.update({
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
})

    print(f"probing {len(urls)} URL(s)  |  proxy: {'yes' if proxy else 'no'}\n")

    rows = []
    for i, url in enumerate(urls):
        row = probe_one(url, session, proxies)
        rows.append(row)
        status = "OK" if row["ok"] else f"FAIL ({row['reason']})"
        print(f"[{i+1}/{len(urls)}] {row['shortcode'] or url[:40]:<20} {status}")
        if i < len(urls) - 1:
            time.sleep(random.uniform(2.0, 4.0))

    print()
    print_table(rows)
    print_summary(rows)
    print_guidance(rows)

    with open(results_path, "w", encoding="utf-8") as f:
        json.dump(rows, f, indent=2, ensure_ascii=False)
    print(f"\nraw results written to {results_path}")


if __name__ == "__main__":
    main()
