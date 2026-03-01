"""Session CRUD endpoints."""

from __future__ import annotations

import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException

from app.auth import get_current_user
from app.config import settings
from app.docker_ctl import get_container_pool
from app.models import (
    SessionCreateRequest,
    SessionRecord,
    SessionResponse,
    SessionStatus,
)
from app.security import create_ws_ticket, inject_api_key

router = APIRouter(prefix="/sessions", tags=["sessions"])

# In-memory session registry
_sessions: dict[str, SessionRecord] = {}


def get_session_registry() -> dict[str, SessionRecord]:
    """Access the session registry from other modules."""
    return _sessions


def _get_user_session(session_id: str, user_id: str) -> SessionRecord:
    """Look up a session, enforcing ownership."""
    session = _sessions.get(session_id)
    if not session or session.user_id != user_id:
        raise HTTPException(status_code=404, detail="Session not found")
    return session


def _to_response(session: SessionRecord, ws_ticket: str | None = None) -> SessionResponse:
    return SessionResponse(
        session_id=session.session_id,
        status=session.status,
        created_at=session.created_at,
        last_active=session.last_active,
        ws_ticket=ws_ticket,
    )


@router.post("", response_model=SessionResponse, status_code=201)
async def create_session(
    request: SessionCreateRequest,
    user_id: str = Depends(get_current_user),
) -> SessionResponse:
    """Create a new session, spawn container, return WS ticket."""
    # Check concurrent session limit
    active = [
        s for s in _sessions.values()
        if s.user_id == user_id and s.status == SessionStatus.ACTIVE
    ]
    if len(active) >= settings.max_concurrent_sessions:
        raise HTTPException(
            status_code=429,
            detail=f"Max concurrent sessions ({settings.max_concurrent_sessions}) reached",
        )

    session_id = str(uuid.uuid4())

    # Assign container from pool
    pool = get_container_pool()
    container_id = await pool.assign(session_id)

    # Inject API key into container tmpfs (then zero it)
    key_name = (
        "ANTHROPIC_API_KEY" if request.provider == "anthropic"
        else "OPENAI_API_KEY"
    )
    await inject_api_key(container_id, key_name, request.api_key, pool.backend)

    # Clone repo if provided
    if request.repo_url:
        await pool.backend.exec_in_container(
            container_id,
            f"git clone {request.repo_url} /workspace/project",
        )

    # Create session record (api_key is NOT stored)
    session = SessionRecord(
        session_id=session_id,
        user_id=user_id,
        container_id=container_id,
        provider=request.provider,
    )
    _sessions[session_id] = session

    # Generate WS ticket
    ticket = create_ws_ticket(session_id, user_id)

    return _to_response(session, ws_ticket=ticket)


@router.get("", response_model=list[SessionResponse])
async def list_sessions(
    user_id: str = Depends(get_current_user),
) -> list[SessionResponse]:
    """List all sessions for the current user."""
    return [
        _to_response(s)
        for s in _sessions.values()
        if s.user_id == user_id
    ]


@router.post("/{session_id}/resume", response_model=SessionResponse)
async def resume_session(
    session_id: str,
    user_id: str = Depends(get_current_user),
) -> SessionResponse:
    """Resume a sleeping session."""
    session = _get_user_session(session_id, user_id)

    if session.status == SessionStatus.ACTIVE:
        raise HTTPException(status_code=400, detail="Session already active")
    if session.status == SessionStatus.STOPPED:
        raise HTTPException(status_code=400, detail="Session is stopped and cannot be resumed")

    pool = get_container_pool()
    await pool.backend.unpause_container(session.container_id)
    session.status = SessionStatus.ACTIVE
    session.last_active = datetime.utcnow()

    ticket = create_ws_ticket(session_id, user_id)
    return _to_response(session, ws_ticket=ticket)


@router.post("/{session_id}/sleep")
async def sleep_session(
    session_id: str,
    user_id: str = Depends(get_current_user),
) -> dict:
    """Pause a running session."""
    session = _get_user_session(session_id, user_id)

    if session.status != SessionStatus.ACTIVE:
        raise HTTPException(status_code=400, detail="Session is not active")

    pool = get_container_pool()
    await pool.backend.pause_container(session.container_id)
    session.status = SessionStatus.SLEEPING

    return {"status": "sleeping"}


@router.delete("/{session_id}")
async def delete_session(
    session_id: str,
    user_id: str = Depends(get_current_user),
) -> dict:
    """Stop and remove a session."""
    session = _get_user_session(session_id, user_id)

    pool = get_container_pool()
    await pool.release(session_id)
    del _sessions[session_id]

    return {"status": "deleted"}
