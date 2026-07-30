"""SSRF guard for the generic-web fetch path (mandatory — CLAUDE.md §7 safety).

The web import feature makes the server fetch *arbitrary user-supplied URLs*.
Without a guard, a user could point us at internal infrastructure — cloud
metadata (169.254.169.254), localhost, or private RFC1918 hosts — and read the
response back through the recipe. This module is the single chokepoint that
blocks that: `assert_fetchable` MUST be called before every web request AND on
every redirect hop (see `web.safe_get`).

It refuses:
  * any scheme that isn't http/https (file://, ftp://, gopher://, data:, ...)
  * any host that resolves to a private / loopback / link-local / reserved /
    multicast / unspecified IP — checking EVERY address the host resolves to,
    not just the first, so a multi-record or partially-internal host can't slip
    a bad address through.

Residual risk (documented, not yet closed): `requests` re-resolves DNS when it
actually connects, so there is a TOCTOU / DNS-rebinding window between our
validation and the socket connect. The v1 mitigation is to disable automatic
redirects and re-validate each hop (done in `web.safe_get`). Fully closing it
requires pinning the vetted IP (connect by IP, preserve Host/SNI); that is a
deliberate later hardening, called out here so this guard is not mistaken for
airtight.
"""
from __future__ import annotations

import ipaddress
import socket
from urllib.parse import urlparse

_ALLOWED_SCHEMES = {"http", "https"}


class BlockedURLError(Exception):
    """Raised when a URL must not be fetched (bad scheme or non-public host)."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def _is_blocked_ip(ip: ipaddress._BaseAddress) -> bool:
    """True if `ip` is anything other than a public, routable address."""
    # IPv4-mapped IPv6 (e.g. ::ffff:169.254.169.254) must be unwrapped and
    # re-checked, or a mapped internal address would read as "global".
    mapped = getattr(ip, "ipv4_mapped", None)
    if mapped is not None:
        return _is_blocked_ip(mapped)
    return (
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_reserved
        or ip.is_multicast
        or ip.is_unspecified
    )


def assert_fetchable(url: str) -> None:
    """Raise `BlockedURLError` unless `url` is an http(s) URL whose host resolves
    exclusively to public IP addresses."""
    parsed = urlparse(url)

    if parsed.scheme.lower() not in _ALLOWED_SCHEMES:
        raise BlockedURLError(
            "blocked_scheme", f"scheme not allowed: {parsed.scheme or '(none)'}"
        )

    host = parsed.hostname
    if not host:
        raise BlockedURLError("blocked_host", "URL has no host")

    # A bare IP literal still has to clear the same checks.
    try:
        literal = ipaddress.ip_address(host)
    except ValueError:
        literal = None
    if literal is not None:
        if _is_blocked_ip(literal):
            raise BlockedURLError("blocked_host", f"host resolves to non-public IP: {host}")
        return

    try:
        port = parsed.port or (443 if parsed.scheme.lower() == "https" else 80)
    except ValueError as exc:  # malformed port
        raise BlockedURLError("blocked_host", f"invalid port: {exc}") from exc

    try:
        infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
    except socket.gaierror as exc:
        raise BlockedURLError("dns_error", f"could not resolve host: {host}") from exc

    if not infos:
        raise BlockedURLError("dns_error", f"host did not resolve: {host}")

    for info in infos:
        addr = info[4][0]
        try:
            ip = ipaddress.ip_address(addr)
        except ValueError:
            raise BlockedURLError("blocked_host", f"unparseable resolved address: {addr}")
        if _is_blocked_ip(ip):
            raise BlockedURLError(
                "blocked_host", f"host {host} resolves to non-public IP {addr}"
            )
