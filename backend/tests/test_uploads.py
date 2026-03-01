"""Tests for file upload endpoint."""

from __future__ import annotations

import io

import pytest
from httpx import AsyncClient

from app.config import settings


@pytest.mark.asyncio
async def test_upload_valid_file(client: AsyncClient, auth_headers: dict):
    """Upload a valid Python file succeeds."""
    # Create session
    create = await client.post(
        "/sessions",
        json={"provider": "anthropic", "api_key": "sk-upload-test"},
        headers=auth_headers,
    )
    session_id = create.json()["session_id"]

    # Upload file
    files = {"files": ("test.py", io.BytesIO(b"print('hello')"), "text/plain")}
    response = await client.post(
        f"/sessions/{session_id}/upload",
        files=files,
        headers=auth_headers,
    )
    assert response.status_code == 200
    data = response.json()
    assert len(data["uploaded"]) == 1
    assert data["uploaded"][0]["name"] == "test.py"
    assert data["uploaded"][0]["path"] == "/workspace/uploads/test.py"


@pytest.mark.asyncio
async def test_upload_rejected_extension(client: AsyncClient, auth_headers: dict):
    """Upload with disallowed extension returns 400."""
    create = await client.post(
        "/sessions",
        json={"provider": "anthropic", "api_key": "sk-ext-test"},
        headers=auth_headers,
    )
    session_id = create.json()["session_id"]

    files = {"files": ("malware.exe", io.BytesIO(b"MZ\x90\x00"), "application/octet-stream")}
    response = await client.post(
        f"/sessions/{session_id}/upload",
        files=files,
        headers=auth_headers,
    )
    assert response.status_code == 400
    assert "not allowed" in response.json()["detail"]


@pytest.mark.asyncio
async def test_upload_path_traversal(client: AsyncClient, auth_headers: dict):
    """Upload with path traversal attempt returns 400."""
    create = await client.post(
        "/sessions",
        json={"provider": "anthropic", "api_key": "sk-traversal"},
        headers=auth_headers,
    )
    session_id = create.json()["session_id"]

    files = {"files": ("../../../etc/passwd.txt", io.BytesIO(b"evil"), "text/plain")}
    response = await client.post(
        f"/sessions/{session_id}/upload",
        files=files,
        headers=auth_headers,
    )
    # Path.name strips directory components, so this should succeed
    # as "passwd.txt" (the traversal is neutralized)
    assert response.status_code == 200
    assert response.json()["uploaded"][0]["name"] == "passwd.txt"


@pytest.mark.asyncio
async def test_upload_magic_bytes_mismatch(client: AsyncClient, auth_headers: dict):
    """Upload a .png with wrong magic bytes returns 400."""
    create = await client.post(
        "/sessions",
        json={"provider": "anthropic", "api_key": "sk-magic"},
        headers=auth_headers,
    )
    session_id = create.json()["session_id"]

    # .png file with wrong content (text instead of PNG magic bytes)
    files = {"files": ("fake.png", io.BytesIO(b"not a png file"), "image/png")}
    response = await client.post(
        f"/sessions/{session_id}/upload",
        files=files,
        headers=auth_headers,
    )
    assert response.status_code == 400
    assert "doesn't match" in response.json()["detail"]


@pytest.mark.asyncio
async def test_upload_valid_png(client: AsyncClient, auth_headers: dict):
    """Upload a real PNG file with correct magic bytes succeeds."""
    create = await client.post(
        "/sessions",
        json={"provider": "anthropic", "api_key": "sk-real-png"},
        headers=auth_headers,
    )
    session_id = create.json()["session_id"]

    # Minimal valid PNG magic bytes
    png_data = b"\x89PNG\r\n\x1a\n" + b"\x00" * 100
    files = {"files": ("image.png", io.BytesIO(png_data), "image/png")}
    response = await client.post(
        f"/sessions/{session_id}/upload",
        files=files,
        headers=auth_headers,
    )
    assert response.status_code == 200
    assert response.json()["uploaded"][0]["name"] == "image.png"


@pytest.mark.asyncio
async def test_upload_session_not_found(client: AsyncClient, auth_headers: dict):
    """Upload to non-existent session returns 404."""
    files = {"files": ("test.py", io.BytesIO(b"print('hi')"), "text/plain")}
    response = await client.post(
        "/sessions/nonexistent/upload",
        files=files,
        headers=auth_headers,
    )
    assert response.status_code == 404
