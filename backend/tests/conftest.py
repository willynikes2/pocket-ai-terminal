"""Shared test fixtures."""

from __future__ import annotations

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

# Force mock backend before importing app
from app.config import settings

settings.docker_backend = "mock"

from app.auth import load_or_generate_keys, reset_auth_state  # noqa: E402
from app.docker_ctl import MockContainerBackend, init_pool  # noqa: E402
from app.main import app as fastapi_app  # noqa: E402
from app.security import _tickets  # noqa: E402
from app.sessions import _sessions  # noqa: E402


@pytest_asyncio.fixture(autouse=True)
async def _setup_app():
    """Initialize RSA keys and container pool for tests, clean up after."""
    load_or_generate_keys()
    pool = init_pool(MockContainerBackend())
    await pool.initialize()
    yield
    # Clean up all in-memory state between tests
    _sessions.clear()
    _tickets.clear()
    reset_auth_state()
    pool.available.clear()
    pool.assigned.clear()


@pytest_asyncio.fixture
async def client():
    """Async HTTP client for testing FastAPI endpoints."""
    transport = ASGITransport(app=fastapi_app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


@pytest_asyncio.fixture
async def auth_headers(client: AsyncClient) -> dict[str, str]:
    """Get valid JWT auth headers by logging in with dev token."""
    response = await client.post(
        "/auth/dev-token",
        json={"token": settings.dev_token},
    )
    assert response.status_code == 200
    token = response.json()["access_token"]
    return {"Authorization": f"Bearer {token}"}
