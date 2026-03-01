"""Pydantic v2 models and protocol constants."""

from __future__ import annotations

import uuid
from datetime import datetime
from enum import Enum

from pydantic import BaseModel, Field


# --- Enums ---

class SessionStatus(str, Enum):
    ACTIVE = "active"
    SLEEPING = "sleeping"
    STOPPED = "stopped"


# --- WebSocket Binary Framing ---

class WSMessageType:
    """Single-byte type prefixes for binary WebSocket framing."""

    # Client -> Server
    AUTH = 0x00
    STDIN = 0x01
    RESIZE = 0x02
    PING = 0x03
    TOKEN_REFRESH = 0x04

    # Server -> Client
    STDOUT = 0x80
    SESSION_INFO = 0x81
    PONG = 0x82
    TOKEN_REFRESHED = 0x83
    ERROR = 0x84


# --- Auth Models ---

class DevTokenRequest(BaseModel):
    token: str


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    expires_in: int


class RefreshRequest(BaseModel):
    refresh_token: str


# --- Session Models ---

class SessionCreateRequest(BaseModel):
    provider: str = Field(pattern=r"^(anthropic|openai)$")
    api_key: str
    repo_url: str | None = None


class SessionResponse(BaseModel):
    session_id: str
    status: SessionStatus
    created_at: datetime
    last_active: datetime
    ws_ticket: str | None = None


# --- Upload Models ---

class UploadedFile(BaseModel):
    name: str
    path: str
    size: int


class UploadResponse(BaseModel):
    uploaded: list[UploadedFile]


# --- Internal Models ---

class SessionRecord(BaseModel):
    session_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    user_id: str
    status: SessionStatus = SessionStatus.ACTIVE
    container_id: str | None = None
    provider: str
    created_at: datetime = Field(default_factory=datetime.utcnow)
    last_active: datetime = Field(default_factory=datetime.utcnow)


class WSTicket(BaseModel):
    ticket: str
    session_id: str
    user_id: str
    created_at: datetime
    used: bool = False
