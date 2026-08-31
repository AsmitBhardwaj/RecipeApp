"""The /auth endpoints and the `current_user` dependency other routes use to
require a signed-in account.

Endpoints:
  POST /auth/register   email + password → account + tokens
  POST /auth/login      email + password → tokens (brute-force limited)
  POST /auth/apple      Apple identity token → tokens
  POST /auth/google     Google identity token → tokens
  POST /auth/refresh    rotate a refresh token → new tokens
  POST /auth/logout     revoke a refresh token
  GET  /auth/me         the authenticated user

Tokens: a short-lived access JWT (Bearer) + a long-lived, single-use refresh JWT
whose id is tracked server-side so it can be rotated and revoked.
"""
from __future__ import annotations

import time

from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from .. import config, db
from . import providers, security, service
from .schemas import (
    AppleRequest,
    GoogleRequest,
    LoginRequest,
    LogoutRequest,
    RefreshRequest,
    RegisterRequest,
    TokenResponse,
    UserResponse,
)
from .service import User

router = APIRouter(prefix="/auth", tags=["auth"])
_bearer = HTTPBearer(auto_error=False)


# --------------------------------------------------------------------------- #
# Token issuance
# --------------------------------------------------------------------------- #


def _issue(user: User) -> TokenResponse:
    access, expires_in = security.create_access_token(user.id)
    refresh, jti, expires_at = security.create_refresh_token(user.id)
    service.record_refresh_token(jti, user.id, expires_at)
    return TokenResponse(
        access_token=access,
        refresh_token=refresh,
        expires_in=expires_in,
        user=UserResponse(
            id=user.id,
            email=user.email,
            email_verified=user.email_verified,
            full_name=user.full_name,
        ),
    )


# --------------------------------------------------------------------------- #
# Brute-force bound on password login (reuses the persistent rate-limit table)
# --------------------------------------------------------------------------- #


def _client_ip(request: Request) -> str:
    forwarded = request.headers.get("X-Forwarded-For")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def _login_guard(email: str, request: Request) -> None:
    window = config.LOGIN_WINDOW_SECONDS
    now = int(time.time())
    window_start = now - (now % window)
    limit = config.LOGIN_ATTEMPTS_PER_WINDOW
    for ident in (f"login:ip:{_client_ip(request)}:{window}", f"login:email:{email.lower()}:{window}"):
        if db.rate_limit_incr(ident, window_start) > limit:
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail="too many login attempts, try again later",
            )


# --------------------------------------------------------------------------- #
# Dependency: require a signed-in user
# --------------------------------------------------------------------------- #


def current_user(
    credentials: HTTPAuthorizationCredentials = Depends(_bearer),
) -> User:
    """Resolve the Bearer access token to a User, or 401. Other routers import
    this to gate authenticated endpoints (Stage 2 onward)."""
    if credentials is None or not credentials.credentials:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="not authenticated",
            headers={"WWW-Authenticate": "Bearer"},
        )
    try:
        claims = security.decode_token(credentials.credentials, expected_type="access")
    except security.TokenError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=str(exc),
            headers={"WWW-Authenticate": "Bearer"},
        )
    user = service.get_user_by_id(claims["sub"])
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="account no longer exists",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return user


# --------------------------------------------------------------------------- #
# Endpoints
# --------------------------------------------------------------------------- #


@router.post("/register", response_model=TokenResponse)
def register(req: RegisterRequest) -> TokenResponse:
    try:
        user = service.create_email_user(req.email, req.password, req.full_name)
    except service.EmailInUse:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="email already registered")
    return _issue(user)


@router.post("/login", response_model=TokenResponse)
def login(req: LoginRequest, request: Request) -> TokenResponse:
    _login_guard(req.email, request)
    user = service.authenticate_email(req.email, req.password)
    if user is None:
        # Same message whether the email is unknown or the password is wrong, so
        # the endpoint doesn't reveal which emails have accounts.
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid email or password")
    return _issue(user)


@router.post("/apple", response_model=TokenResponse)
def apple(req: AppleRequest) -> TokenResponse:
    try:
        identity = providers.verify_apple(req.identity_token)
    except providers.ProviderError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc))
    user = service.upsert_provider_user(identity, req.full_name)
    return _issue(user)


@router.post("/google", response_model=TokenResponse)
def google(req: GoogleRequest) -> TokenResponse:
    try:
        identity = providers.verify_google(req.id_token)
    except providers.ProviderError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc))
    user = service.upsert_provider_user(identity, req.full_name)
    return _issue(user)


@router.post("/refresh", response_model=TokenResponse)
def refresh(req: RefreshRequest) -> TokenResponse:
    try:
        claims = security.decode_token(req.refresh_token, expected_type="refresh")
    except security.TokenError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc))

    user_id, jti = claims["sub"], claims.get("jti", "")
    # Single-use: the presented refresh token must be one we issued and haven't
    # already rotated/revoked. Reuse of a rotated token is rejected here.
    if not service.refresh_token_active(jti, user_id):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="refresh token is no longer valid")

    user = service.get_user_by_id(user_id)
    if user is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="account no longer exists")

    service.revoke_refresh_token(jti)  # rotate
    return _issue(user)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
def logout(req: LogoutRequest) -> None:
    # Best-effort: decode to find the jti and revoke it. An invalid token is a
    # no-op (the client is signing out regardless).
    try:
        claims = security.decode_token(req.refresh_token, expected_type="refresh")
        if claims.get("jti"):
            service.revoke_refresh_token(claims["jti"])
    except security.TokenError:
        pass


@router.get("/me", response_model=UserResponse)
def me(user: User = Depends(current_user)) -> UserResponse:
    return UserResponse(
        id=user.id, email=user.email, email_verified=user.email_verified, full_name=user.full_name
    )


@router.delete("/me", status_code=status.HTTP_204_NO_CONTENT)
def delete_me(user: User = Depends(current_user)) -> None:
    # In-app account deletion (App Store Guideline 5.1.1). Requires a valid access
    # token (current_user); irreversibly removes the account and all data scoped
    # to it. Any outstanding refresh tokens are dropped, so existing sessions on
    # other devices can no longer refresh.
    db.delete_account(user.id)
