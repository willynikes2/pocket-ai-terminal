"""JWT authentication with RS256, dev-token login, and refresh token rotation."""

from __future__ import annotations

import hashlib
import logging
import secrets
from datetime import datetime, timedelta
from pathlib import Path
from typing import Annotated

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi import APIRouter, Depends, Header, HTTPException, status
from jose import JWTError, jwt

from app.config import settings
from app.models import DevTokenRequest, RefreshRequest, TokenResponse

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/auth", tags=["auth"])

# --- RSA Key Management ---

_private_key: str = ""
_public_key: str = ""


def load_or_generate_keys() -> None:
    """Load RSA keys from disk, or generate if not found."""
    global _private_key, _public_key

    priv_path = Path(settings.jwt_private_key_path)
    pub_path = Path(settings.jwt_public_key_path)

    if priv_path.exists() and pub_path.exists():
        _private_key = priv_path.read_text()
        _public_key = pub_path.read_text()
        logger.info("Loaded RSA keys from disk")
        return

    # Generate new keypair
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    _private_key = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode()

    _public_key = key.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    ).decode()

    # Persist
    priv_path.parent.mkdir(parents=True, exist_ok=True)
    priv_path.write_text(_private_key)
    pub_path.write_text(_public_key)
    logger.info("Generated and saved new RSA keypair")


# --- In-Memory Token Stores ---

# SHA-256 hash -> { user_id, created_at, used }
_refresh_token_store: dict[str, dict] = {}

# Users with all tokens revoked (theft detected)
_revoked_users: set[str] = set()


def reset_auth_state() -> None:
    """Reset all in-memory auth state. Used in tests."""
    _refresh_token_store.clear()
    _revoked_users.clear()


def _hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


# --- Token Creation ---

def create_access_token(user_id: str, session_ids: list[str] | None = None) -> str:
    """Create RS256 JWT access token (15 min TTL)."""
    now = datetime.utcnow()
    claims = {
        "sub": user_id,
        "iat": now,
        "exp": now + timedelta(minutes=settings.access_token_expire_minutes),
        "session_ids": session_ids or [],
    }
    return jwt.encode(claims, _private_key, algorithm=settings.jwt_algorithm)


def create_refresh_token(user_id: str) -> str:
    """Create cryptographically random refresh token, store its hash."""
    token = secrets.token_urlsafe(48)
    token_hash = _hash_token(token)
    _refresh_token_store[token_hash] = {
        "user_id": user_id,
        "created_at": datetime.utcnow(),
        "used": False,
    }
    return token


# --- Token Validation ---

def validate_access_token(token: str) -> dict:
    """Decode and validate RS256 JWT. Returns claims dict."""
    try:
        claims = jwt.decode(
            token, _public_key, algorithms=[settings.jwt_algorithm]
        )
    except JWTError as e:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Invalid token: {e}",
        )

    user_id = claims.get("sub")
    if user_id in _revoked_users:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="All tokens revoked for this user",
        )

    return claims


def rotate_refresh_token(old_token: str) -> tuple[str, str, str]:
    """
    Validate and rotate refresh token. Returns (new_access, new_refresh, user_id).

    If a previously-used token is presented, REVOKE ALL tokens for that user
    (indicates token theft).
    """
    old_hash = _hash_token(old_token)
    record = _refresh_token_store.get(old_hash)

    if not record:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid refresh token",
        )

    user_id = record["user_id"]

    # Theft detection: if token was already used, revoke everything
    if record["used"]:
        _revoked_users.add(user_id)
        # Purge all refresh tokens for this user
        hashes_to_remove = [
            h for h, r in _refresh_token_store.items()
            if r["user_id"] == user_id
        ]
        for h in hashes_to_remove:
            del _refresh_token_store[h]
        logger.warning("Refresh token reuse detected for user %s — revoking all tokens", user_id)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token reuse detected — all tokens revoked",
        )

    # Check expiry
    created = record["created_at"]
    if datetime.utcnow() - created > timedelta(days=settings.refresh_token_expire_days):
        del _refresh_token_store[old_hash]
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Refresh token expired",
        )

    # Mark as used (not deleted — needed for theft detection)
    record["used"] = True

    # Issue new pair
    new_access = create_access_token(user_id)
    new_refresh = create_refresh_token(user_id)

    return new_access, new_refresh, user_id


# --- FastAPI Dependencies ---

async def get_current_user(
    authorization: Annotated[str, Header()],
) -> str:
    """Extract Bearer token, validate, return user_id."""
    if not authorization.startswith("Bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authorization header must be 'Bearer <token>'",
        )
    token = authorization[7:]
    claims = validate_access_token(token)
    return claims["sub"]


# --- Routes ---

@router.post("/dev-token", response_model=TokenResponse)
async def dev_token_login(request: DevTokenRequest) -> TokenResponse:
    """Exchange a dev token for JWT access + refresh tokens."""
    if request.token != settings.dev_token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid dev token",
        )

    user_id = "dev-user-1"
    access_token = create_access_token(user_id)
    refresh_token = create_refresh_token(user_id)

    return TokenResponse(
        access_token=access_token,
        refresh_token=refresh_token,
        expires_in=settings.access_token_expire_minutes * 60,
    )


@router.post("/refresh", response_model=TokenResponse)
async def refresh(request: RefreshRequest) -> TokenResponse:
    """Rotate refresh token and issue new access + refresh pair."""
    new_access, new_refresh, _ = rotate_refresh_token(request.refresh_token)

    return TokenResponse(
        access_token=new_access,
        refresh_token=new_refresh,
        expires_in=settings.access_token_expire_minutes * 60,
    )
