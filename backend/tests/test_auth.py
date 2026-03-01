"""Tests for authentication endpoints."""

from __future__ import annotations

import pytest
from httpx import AsyncClient

from app.config import settings


@pytest.mark.asyncio
async def test_dev_token_login(client: AsyncClient):
    """Valid dev token returns access + refresh tokens."""
    response = await client.post(
        "/auth/dev-token", json={"token": settings.dev_token}
    )
    assert response.status_code == 200
    data = response.json()
    assert "access_token" in data
    assert "refresh_token" in data
    assert data["expires_in"] == settings.access_token_expire_minutes * 60


@pytest.mark.asyncio
async def test_invalid_dev_token(client: AsyncClient):
    """Invalid dev token returns 401."""
    response = await client.post(
        "/auth/dev-token", json={"token": "wrong-token"}
    )
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_refresh_token_rotation(client: AsyncClient):
    """Refresh token returns new access + refresh pair."""
    # Login
    login = await client.post(
        "/auth/dev-token", json={"token": settings.dev_token}
    )
    refresh_token = login.json()["refresh_token"]

    # Refresh
    response = await client.post(
        "/auth/refresh", json={"refresh_token": refresh_token}
    )
    assert response.status_code == 200
    data = response.json()
    assert "access_token" in data
    assert "refresh_token" in data
    # New refresh token should be different
    assert data["refresh_token"] != refresh_token


@pytest.mark.asyncio
async def test_refresh_token_reuse_revokes_all(client: AsyncClient):
    """Reusing a refresh token revokes all tokens for the user."""
    # Login
    login = await client.post(
        "/auth/dev-token", json={"token": settings.dev_token}
    )
    refresh_token = login.json()["refresh_token"]

    # First use — should succeed
    first = await client.post(
        "/auth/refresh", json={"refresh_token": refresh_token}
    )
    assert first.status_code == 200

    # Second use of same token — should fail and revoke all
    second = await client.post(
        "/auth/refresh", json={"refresh_token": refresh_token}
    )
    assert second.status_code == 401
    assert "reuse" in second.json()["detail"].lower()


@pytest.mark.asyncio
async def test_invalid_refresh_token(client: AsyncClient):
    """Invalid refresh token returns 401."""
    response = await client.post(
        "/auth/refresh", json={"refresh_token": "totally-fake-token"}
    )
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_protected_endpoint_no_auth(client: AsyncClient):
    """Accessing protected endpoint without auth returns 422 (missing header)."""
    response = await client.get("/sessions")
    assert response.status_code == 422


@pytest.mark.asyncio
async def test_protected_endpoint_invalid_token(client: AsyncClient):
    """Accessing protected endpoint with invalid JWT returns 401."""
    response = await client.get(
        "/sessions", headers={"Authorization": "Bearer invalid-jwt"}
    )
    assert response.status_code == 401
