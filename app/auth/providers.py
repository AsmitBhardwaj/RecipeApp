"""Server-side verification of Apple and Google identity tokens.

The client performs the native Sign in with Apple / Google flow and sends us the
resulting identity token (a provider-signed JWT). We verify it here — signature
against the provider's published JWKS, plus issuer, audience, and expiry — and
extract the stable `sub` and email. A verified `sub` is the real, unspoofable
identity that `X-User-Id` never was.

Testability: `_verify` accepts an injected `signing_key`, so the verification
logic is exercised offline against a locally-signed token without any network
call to Apple/Google. In production `signing_key` is None and the key is fetched
(and cached) from the provider JWKS by key id.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional, Sequence

import jwt

from .. import config

_APPLE_ISSUER = "https://appleid.apple.com"
_APPLE_JWKS = "https://appleid.apple.com/auth/keys"
_GOOGLE_ISSUERS = ("https://accounts.google.com", "accounts.google.com")
_GOOGLE_JWKS = "https://www.googleapis.com/oauth2/v3/certs"


class ProviderError(Exception):
    """The identity token was missing, malformed, or failed verification."""


@dataclass(frozen=True)
class VerifiedIdentity:
    provider: str          # "apple" | "google"
    subject: str           # provider's stable user id (`sub`)
    email: Optional[str]
    email_verified: bool


# Cache one JWKS client per provider URL — it memoizes the fetched keys and only
# re-fetches on an unknown key id (provider key rotation).
_jwk_clients: dict[str, "jwt.PyJWKClient"] = {}


def _jwk_client(url: str) -> "jwt.PyJWKClient":
    client = _jwk_clients.get(url)
    if client is None:
        client = jwt.PyJWKClient(url)
        _jwk_clients[url] = client
    return client


def _as_bool(value) -> bool:
    # Apple sends email_verified as the string "true"/"false"; Google as a bool.
    if isinstance(value, bool):
        return value
    return str(value).lower() == "true"


def _verify(
    token: str,
    *,
    provider: str,
    allowed_issuers: Sequence[str],
    audiences: Sequence[str],
    jwks_url: str,
    signing_key=None,
) -> VerifiedIdentity:
    if not token:
        raise ProviderError("missing identity token")
    if not audiences:
        # Never verify against an empty audience allowlist — that would accept a
        # token minted for any other app. Force the client ids to be configured.
        raise ProviderError(f"{provider} sign-in is not configured (no client ids)")

    try:
        key = signing_key
        if key is None:
            key = _jwk_client(jwks_url).get_signing_key_from_jwt(token).key
        claims = jwt.decode(
            token,
            key,
            algorithms=["RS256"],
            audience=list(audiences),
            options={"require": ["exp", "iat", "sub"], "verify_iss": False},
        )
    except jwt.PyJWTError as exc:
        raise ProviderError(f"{provider} token verification failed: {exc}") from exc

    # Issuer checked explicitly so Google's two accepted forms both pass.
    if claims.get("iss") not in allowed_issuers:
        raise ProviderError(f"{provider} token has an unexpected issuer")

    subject = claims.get("sub")
    if not subject:
        raise ProviderError(f"{provider} token has no subject")

    return VerifiedIdentity(
        provider=provider,
        subject=str(subject),
        email=(claims.get("email") or None),
        email_verified=_as_bool(claims.get("email_verified")),
    )


def verify_apple(token: str, *, audiences: Optional[Sequence[str]] = None, signing_key=None) -> VerifiedIdentity:
    return _verify(
        token,
        provider="apple",
        allowed_issuers=(_APPLE_ISSUER,),
        audiences=audiences if audiences is not None else config.APPLE_CLIENT_IDS,
        jwks_url=_APPLE_JWKS,
        signing_key=signing_key,
    )


def verify_google(token: str, *, audiences: Optional[Sequence[str]] = None, signing_key=None) -> VerifiedIdentity:
    return _verify(
        token,
        provider="google",
        allowed_issuers=_GOOGLE_ISSUERS,
        audiences=audiences if audiences is not None else config.GOOGLE_CLIENT_IDS,
        jwks_url=_GOOGLE_JWKS,
        signing_key=signing_key,
    )
