"""Tests for session CRUD endpoints."""

from __future__ import annotations

import pytest
from httpx import AsyncClient

from app.config import settings


@pytest.mark.asyncio
async def test_create_session(client: AsyncClient, auth_headers: dict):
    """Create session returns session_id and ws_ticket."""
    response = await client.post(
        "/sessions",
        json={"provider": "anthropic", "api_key": "sk-test-key-12345"},
        headers=auth_headers,
    )
    assert response.status_code == 201
    data = response.json()
    assert "session_id" in data
    assert data["status"] == "active"
    assert "ws_ticket" in data
    assert data["ws_ticket"] is not None


@pytest.mark.asyncio
async def test_list_sessions(client: AsyncClient, auth_headers: dict):
    """List sessions returns user's sessions."""
    # Create a session first
    await client.post(
        "/sessions",
        json={"provider": "anthropic", "api_key": "sk-test-key"},
        headers=auth_headers,
    )

    response = await client.get("/sessions", headers=auth_headers)
    assert response.status_code == 200
    data = response.json()
    assert isinstance(data, list)
    assert len(data) >= 1


@pytest.mark.asyncio
async def test_sleep_and_resume_session(client: AsyncClient, auth_headers: dict):
    """Sleep and resume a session."""
    # Create
    create = await client.post(
        "/sessions",
        json={"provider": "openai", "api_key": "sk-openai-key"},
        headers=auth_headers,
    )
    session_id = create.json()["session_id"]

    # Sleep
    sleep = await client.post(
        f"/sessions/{session_id}/sleep", headers=auth_headers
    )
    assert sleep.status_code == 200
    assert sleep.json()["status"] == "sleeping"

    # Resume
    resume = await client.post(
        f"/sessions/{session_id}/resume", headers=auth_headers
    )
    assert resume.status_code == 200
    data = resume.json()
    assert data["status"] == "active"
    assert data["ws_ticket"] is not None


@pytest.mark.asyncio
async def test_delete_session(client: AsyncClient, auth_headers: dict):
    """Delete a session removes it."""
    # Create
    create = await client.post(
        "/sessions",
        json={"provider": "anthropic", "api_key": "sk-delete-me"},
        headers=auth_headers,
    )
    session_id = create.json()["session_id"]

    # Delete
    delete = await client.delete(
        f"/sessions/{session_id}", headers=auth_headers
    )
    assert delete.status_code == 200
    assert delete.json()["status"] == "deleted"

    # Verify it's gone
    sleep = await client.post(
        f"/sessions/{session_id}/sleep", headers=auth_headers
    )
    assert sleep.status_code == 404


@pytest.mark.asyncio
async def test_session_not_found(client: AsyncClient, auth_headers: dict):
    """Accessing non-existent session returns 404."""
    response = await client.post(
        "/sessions/nonexistent-id/sleep", headers=auth_headers
    )
    assert response.status_code == 404


@pytest.mark.asyncio
async def test_max_concurrent_sessions(client: AsyncClient, auth_headers: dict):
    """Creating more sessions than allowed returns 429."""
    # Create max sessions
    for i in range(settings.max_concurrent_sessions):
        resp = await client.post(
            "/sessions",
            json={"provider": "anthropic", "api_key": f"sk-key-{i}"},
            headers=auth_headers,
        )
        assert resp.status_code == 201

    # One more should fail
    response = await client.post(
        "/sessions",
        json={"provider": "anthropic", "api_key": "sk-one-too-many"},
        headers=auth_headers,
    )
    assert response.status_code == 429
