import hashlib
import secrets
from datetime import UTC, datetime

import jwt
from fastapi import Header, HTTPException, status

from .config import settings


def utc_now() -> datetime:
    return datetime.now(UTC)


def hash_value(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def generate_otp(length: int = 6) -> str:
    if length <= 0:
        raise ValueError("length must be positive")
    max_value = 10**length
    return str(secrets.randbelow(max_value)).zfill(length)


def generate_activation_token() -> str:
    return secrets.token_urlsafe(32)


def decode_admin_jwt(token: str) -> dict:
    return jwt.decode(token, settings.jwt_secret, algorithms=[settings.jwt_algorithm])


def parse_bearer_token(authorization: str | None) -> str | None:
    if not authorization:
        return None
    parts = authorization.split(" ", 1)
    if len(parts) != 2 or parts[0].lower() != "bearer":
        return None
    return parts[1].strip()


def require_admin_auth(
    x_admin_api_key: str | None = Header(default=None),
    authorization: str | None = Header(default=None),
) -> None:
    if x_admin_api_key and secrets.compare_digest(x_admin_api_key, settings.admin_api_key):
        return

    token = parse_bearer_token(authorization)
    if token:
        try:
            claims = decode_admin_jwt(token)
        except Exception as exc:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=f"Invalid JWT: {exc}") from exc
        if claims.get("role") == "admin":
            return

    raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Admin authentication failed")
