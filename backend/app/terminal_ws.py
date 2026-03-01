"""WebSocket relay with binary framing, ticket auth, and PTY relay."""

from __future__ import annotations

import asyncio
import json
import logging
from datetime import datetime

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from app.auth import rotate_refresh_token
from app.docker_ctl import get_container_pool
from app.models import WSMessageType
from app.security import validate_ws_ticket, ws_rate_limiter
from app.sessions import get_session_registry

logger = logging.getLogger(__name__)

router = APIRouter()

# Active WS connections: session_id -> list[WebSocket]
_active_connections: dict[str, list[WebSocket]] = {}


# --- Frame Helpers ---


async def _send_stdout(ws: WebSocket, data: bytes) -> None:
    await ws.send_bytes(bytes([WSMessageType.STDOUT]) + data)


async def _send_session_info(ws: WebSocket, session_id: str, state: str) -> None:
    payload = json.dumps({"state": state, "session_id": session_id})
    await ws.send_bytes(bytes([WSMessageType.SESSION_INFO]) + payload.encode())


async def _send_pong(ws: WebSocket) -> None:
    await ws.send_bytes(bytes([WSMessageType.PONG]))


async def _send_token_refreshed(ws: WebSocket, access_token: str) -> None:
    payload = json.dumps({"access_token": access_token})
    await ws.send_bytes(bytes([WSMessageType.TOKEN_REFRESHED]) + payload.encode())


async def _send_error(ws: WebSocket, code: str, message: str) -> None:
    payload = json.dumps({"code": code, "message": message})
    await ws.send_bytes(bytes([WSMessageType.ERROR]) + payload.encode())


# --- Relay Tasks ---


async def _client_to_container(
    websocket: WebSocket,
    input_stream: object,
    session_id: str,
    user_id: str,
) -> None:
    """Read client messages, dispatch by type byte."""
    sessions = get_session_registry()
    pool = get_container_pool()

    while True:
        data = await websocket.receive_bytes()

        if not data:
            continue

        # Rate limiting
        if not ws_rate_limiter.check(user_id):
            await _send_error(websocket, "rate_limited", "Too many messages")
            continue

        msg_type = data[0]
        payload = data[1:]

        if msg_type == WSMessageType.STDIN:
            await input_stream.write(payload)
            session = sessions.get(session_id)
            if session:
                session.last_active = datetime.utcnow()

        elif msg_type == WSMessageType.RESIZE:
            try:
                resize = json.loads(payload)
                cols = int(resize["cols"])
                rows = int(resize["rows"])
                session = sessions.get(session_id)
                if session and session.container_id:
                    await pool.backend.exec_in_container(
                        session.container_id,
                        f"tmux resize-window -t pat -x {cols} -y {rows}",
                    )
            except (json.JSONDecodeError, KeyError, ValueError) as e:
                logger.warning("Invalid resize message: %s", e)

        elif msg_type == WSMessageType.PING:
            await _send_pong(websocket)

        elif msg_type == WSMessageType.TOKEN_REFRESH:
            try:
                refresh_data = json.loads(payload)
                new_access, _, _ = rotate_refresh_token(
                    refresh_data["refresh_token"]
                )
                await _send_token_refreshed(websocket, new_access)
            except Exception as e:
                await _send_error(
                    websocket, "refresh_failed", str(e)
                )


async def _container_to_client(
    websocket: WebSocket,
    output_stream: object,
    session_id: str,
) -> None:
    """Read container PTY output, forward to client with STDOUT prefix."""
    sessions = get_session_registry()

    while True:
        chunk = await output_stream.read(4096)
        if not chunk:
            await asyncio.sleep(0.01)
            continue
        await _send_stdout(websocket, chunk)
        session = sessions.get(session_id)
        if session:
            session.last_active = datetime.utcnow()


# --- WebSocket Endpoint ---


@router.websocket("/sessions/{session_id}/ws")
async def terminal_websocket(websocket: WebSocket, session_id: str) -> None:
    """WebSocket endpoint for terminal I/O with binary framing."""
    await websocket.accept()

    # Phase 1: Ticket authentication (first message must be AUTH)
    try:
        first_msg = await asyncio.wait_for(
            websocket.receive_bytes(), timeout=10.0
        )
    except asyncio.TimeoutError:
        await _send_error(websocket, "auth_timeout", "No auth message received")
        await websocket.close(code=4001)
        return

    if not first_msg or first_msg[0] != WSMessageType.AUTH:
        await _send_error(websocket, "auth_required", "First message must be AUTH")
        await websocket.close(code=4001)
        return

    try:
        ticket_data = json.loads(first_msg[1:])
    except json.JSONDecodeError:
        await _send_error(websocket, "invalid_auth", "Malformed auth message")
        await websocket.close(code=4001)
        return

    user_id = validate_ws_ticket(ticket_data.get("ticket", ""), session_id)
    if not user_id:
        await _send_error(websocket, "invalid_ticket", "Ticket invalid or expired")
        await websocket.close(code=4001)
        return

    # Phase 2: Validate session ownership
    sessions = get_session_registry()
    session = sessions.get(session_id)
    if not session or session.user_id != user_id:
        await _send_error(websocket, "not_found", "Session not found")
        await websocket.close(code=4003)
        return

    if not session.container_id:
        await _send_error(websocket, "no_container", "No container assigned")
        await websocket.close(code=4003)
        return

    # Phase 3: Attach to container tmux and replay
    pool = get_container_pool()
    backend = pool.backend

    # Replay last 100 lines for reconnection
    try:
        replay = await backend.capture_tmux_pane(session.container_id, lines=100)
        if replay:
            await _send_stdout(websocket, replay.encode())
    except Exception as e:
        logger.warning("Failed to replay tmux pane: %s", e)

    # Send session info
    await _send_session_info(websocket, session_id, session.status.value)

    # Attach to tmux for live I/O
    try:
        input_stream, output_stream = await backend.attach_to_tmux(
            session.container_id, cols=80, rows=24
        )
    except Exception as e:
        await _send_error(websocket, "attach_failed", f"Failed to attach: {e}")
        await websocket.close(code=4003)
        return

    # Track connection
    _active_connections.setdefault(session_id, []).append(websocket)
    logger.info("WS connected: session=%s user=%s", session_id[:8], user_id)

    # Phase 4: Bidirectional relay
    try:
        await asyncio.gather(
            _client_to_container(websocket, input_stream, session_id, user_id),
            _container_to_client(websocket, output_stream, session_id),
        )
    except WebSocketDisconnect:
        logger.info("WS disconnected: session=%s", session_id[:8])
    except Exception as e:
        logger.error("WS error: session=%s error=%s", session_id[:8], e)
    finally:
        conns = _active_connections.get(session_id, [])
        if websocket in conns:
            conns.remove(websocket)
        if hasattr(input_stream, "close"):
            input_stream.close()
        if hasattr(output_stream, "close"):
            output_stream.close()
