"""Request/response models for the /auth endpoints."""
from __future__ import annotations

from typing import Optional

from pydantic import BaseModel, EmailStr, Field


class RegisterRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=200)
    full_name: Optional[str] = Field(default=None, max_length=200)


class LoginRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=1, max_length=200)


class AppleRequest(BaseModel):
    # The identity token from the native Sign in with Apple flow.
    identity_token: str
    # Apple returns the user's name ONLY on the very first authorization; the
    # client forwards it here so we can capture it (Stage 3).
    full_name: Optional[str] = Field(default=None, max_length=200)


class GoogleRequest(BaseModel):
    id_token: str
    full_name: Optional[str] = Field(default=None, max_length=200)


class RefreshRequest(BaseModel):
    refresh_token: str


class LogoutRequest(BaseModel):
    refresh_token: str


class UserResponse(BaseModel):
    id: str
    email: Optional[str] = None
    email_verified: bool = False
    full_name: Optional[str] = None


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int  # access-token lifetime, seconds
    user: UserResponse
