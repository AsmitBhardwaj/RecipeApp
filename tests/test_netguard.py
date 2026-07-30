"""SSRF-guard truth table (app/pipeline/netguard.py).

The guard is the one thing standing between "fetch arbitrary user URLs" and an
attacker reading internal services (cloud metadata, localhost, RFC1918). These
tests pin its behavior: bad schemes rejected, non-public IPs rejected whether
they arrive as a literal or via DNS, and EVERY resolved address checked (not
just the first). DNS is mocked so nothing here touches the network.

    python3 -m unittest tests.test_netguard
"""
from __future__ import annotations

import socket
import unittest
from unittest import mock

from app.pipeline import netguard
from app.pipeline.netguard import BlockedURLError


def _addrinfo(*ips: str):
    """Build a socket.getaddrinfo-shaped return value for the given IP strings."""
    out = []
    for ip in ips:
        family = socket.AF_INET6 if ":" in ip else socket.AF_INET
        sockaddr = (ip, 0, 0, 0) if family == socket.AF_INET6 else (ip, 0)
        out.append((family, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", sockaddr))
    return out


class SchemeTests(unittest.TestCase):
    def test_non_http_schemes_blocked(self):
        for url in (
            "file:///etc/passwd",
            "ftp://example.com/x",
            "gopher://example.com/",
            "data:text/plain,hi",
        ):
            with self.assertRaises(BlockedURLError) as ctx:
                netguard.assert_fetchable(url)
            self.assertEqual(ctx.exception.code, "blocked_scheme")


class IPLiteralTests(unittest.TestCase):
    """Literal IPs never touch DNS — they must be judged directly."""

    def test_blocked_literals(self):
        for url in (
            "http://127.0.0.1/",
            "http://169.254.169.254/latest/meta-data/",  # cloud metadata
            "http://10.0.0.5/",
            "http://192.168.1.1/",
            "http://172.16.0.9/",
            "http://[::1]/",
            "http://0.0.0.0/",
            "http://[::ffff:169.254.169.254]/",  # IPv4-mapped IPv6
        ):
            with self.assertRaises(BlockedURLError) as ctx:
                netguard.assert_fetchable(url)
            self.assertEqual(ctx.exception.code, "blocked_host", msg=url)

    def test_public_literal_allowed(self):
        # A public IP literal needs no DNS and must pass.
        netguard.assert_fetchable("http://93.184.216.34/")


class DNSTests(unittest.TestCase):
    def test_public_host_allowed(self):
        with mock.patch.object(
            netguard.socket, "getaddrinfo", return_value=_addrinfo("93.184.216.34")
        ):
            netguard.assert_fetchable("https://example.com/recipe")  # no raise

    def test_host_resolving_to_private_blocked(self):
        # DNS-rebinding shape: benign name, internal address.
        with mock.patch.object(
            netguard.socket, "getaddrinfo", return_value=_addrinfo("10.1.2.3")
        ):
            with self.assertRaises(BlockedURLError) as ctx:
                netguard.assert_fetchable("https://evil.example.com/")
            self.assertEqual(ctx.exception.code, "blocked_host")

    def test_any_private_address_among_many_blocks(self):
        # A public + private mix must be rejected — every address is checked.
        with mock.patch.object(
            netguard.socket,
            "getaddrinfo",
            return_value=_addrinfo("93.184.216.34", "169.254.169.254"),
        ):
            with self.assertRaises(BlockedURLError) as ctx:
                netguard.assert_fetchable("https://sneaky.example.com/")
            self.assertEqual(ctx.exception.code, "blocked_host")

    def test_unresolvable_host_is_dns_error(self):
        with mock.patch.object(
            netguard.socket, "getaddrinfo", side_effect=socket.gaierror("nope")
        ):
            with self.assertRaises(BlockedURLError) as ctx:
                netguard.assert_fetchable("https://does-not-exist.example/")
            self.assertEqual(ctx.exception.code, "dns_error")


class HostTests(unittest.TestCase):
    def test_missing_host_blocked(self):
        with self.assertRaises(BlockedURLError) as ctx:
            netguard.assert_fetchable("https:///path-only")
        self.assertEqual(ctx.exception.code, "blocked_host")


if __name__ == "__main__":
    unittest.main()
