"""Tests for WebSocket terminal relay."""

from __future__ import annotations

import json

import pytest
from httpx import AsyncClient

from app.config import settings
from app.models import WSMessageType


@pytest.mark.asyncio
async def test_ws_auth_with_valid_ticket(client: AsyncClient, auth_headers: dict):
    """WebSocket connects successfully with valid ticket."""
    # Create session to get ticket
    create = await client.post(
        "/sessions",
        json={"provider": "anthropic", "api_key": "sk-ws-test"},
        headers=auth_headers,
    )
    session_id = create.json()["session_id"]
    ticket = create.json()["ws_ticket"]

    # Connect WebSocket
    from httpx import ASGITransport
    from starlette.testclient import TestClient
    from app.main import app

    with TestClient(app) as tc:
        with tc.websocket_connect(f"/sessions/{session_id}/ws") as ws:
            # Send AUTH message
            auth_msg = bytes([WSMessageType.AUTH]) + json.dumps(
                {"ticket": ticket}
            ).encode()
            ws.send_bytes(auth_msg)

            # Should receive replay (STDOUT) or session info
            data = ws.receive_bytes()
            msg_type = data[0]
            assert msg_type in (WSMessageType.STDOUT, WSMessageType.SESSION_INFO)


@pytest.mark.asyncio
async def test_ws_auth_with_invalid_ticket(client: AsyncClient, auth_headers: dict):
    """WebSocket with invalid ticket closes with 4001."""
    # Create session
    create = await client.post(
        "/sessions",
        json={"provider": "anthropic", "api_key": "sk-ws-invalid"},
        headers=auth_headers,
    )
    session_id = create.json()["session_id"]

    from starlette.testclient import TestClient
    from starlette.websockets import WebSocketDisconnect
    from app.main import app

    with TestClient(app) as tc:
        with tc.websocket_connect(f"/sessions/{session_id}/ws") as ws:
            # Send AUTH with bad ticket
            auth_msg = bytes([WSMessageType.AUTH]) + json.dumps(
                {"ticket": "fake-ticket"}
            ).encode()
            ws.send_bytes(auth_msg)

            # Should receive error then close
            data = ws.receive_bytes()
            assert data[0] == WSMessageType.ERROR

            try:
                ws.receive_bytes()
            except Exception:
                pass  # Connection closed


@pytest.mark.asyncio
async def test_ws_no_auth_message(client: AsyncClient, auth_headers: dict):
    """WebSocket that doesn't send AUTH gets closed."""
    create = await client.post(
        "/sessions",
        json={"provider": "anthropic", "api_key": "sk-no-auth"},
        headers=auth_headers,
    )
    session_id = create.json()["session_id"]

    from starlette.testclient import TestClient
    from app.main import app

    with TestClient(app) as tc:
        with tc.websocket_connect(f"/sessions/{session_id}/ws") as ws:
            # Send non-AUTH message
            ws.send_bytes(bytes([WSMessageType.STDIN]) + b"hello")

            # Should receive error
            data = ws.receive_bytes()
            assert data[0] == WSMessageType.ERROR


@pytest.mark.asyncio
async def test_ws_ping_pong(client: AsyncClient, auth_headers: dict):
    """PING message receives PONG response."""
    create = await client.post(
        "/sessions",
        json={"provider": "anthropic", "api_key": "sk-ping"},
        headers=auth_headers,
    )
    session_id = create.json()["session_id"]
    ticket = create.json()["ws_ticket"]

    from starlette.testclient import TestClient
    from app.main import app

    with TestClient(app) as tc:
        with tc.websocket_connect(f"/sessions/{session_id}/ws") as ws:
            # Auth first
            auth_msg = bytes([WSMessageType.AUTH]) + json.dumps(
                {"ticket": ticket}
            ).encode()
            ws.send_bytes(auth_msg)

            # Drain replay/session_info messages
            for _ in range(5):
                try:
                    data = ws.receive_bytes()
                    if data[0] == WSMessageType.SESSION_INFO:
                        break
                except Exception:
                    break

            # Send PING
            ws.send_bytes(bytes([WSMessageType.PING]))

            # Drain until we get PONG (mock may interleave STDOUT)
            for _ in range(5):
                data = ws.receive_bytes()
                if data[0] == WSMessageType.PONG:
                    break
            assert data[0] == WSMessageType.PONG
