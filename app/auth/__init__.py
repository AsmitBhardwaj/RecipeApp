"""Authentication (Stage 1): real user accounts on the existing FastAPI backend.

Layout:
  * security.py   — password hashing (argon2) + our own access/refresh JWTs.
  * providers.py  — server-side verification of Apple/Google identity tokens.
  * service.py    — user/account persistence and the sign-in/upsert logic.
  * schemas.py    — request/response models for the /auth endpoints.
  * router.py     — the /auth/* endpoints and the `current_user` dependency.
"""
