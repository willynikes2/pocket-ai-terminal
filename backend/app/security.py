"""WS ticket management, API key injection, rate limiting, and logging safety."""

from __future__ import annotations

import logging
import secrets
from collections import defaultdict
from datetime import datetime, timedelta

from app.config import settings
from app.models import WSTicket

logger = logging.getLogger(__name__)

# --- WS Ticket Management ---

_tickets: dict[str, WSTicket] = {}


def create_ws_ticket(session_id: str, user_id: str) -> str:
    """Generate cryptographically random ticket with 30s TTL."""
    ticket = secrets.token_urlsafe(32)
    _tickets[ticket] = WSTicket(
        ticket=ticket,
        session_id=session_id,
        user_id=user_id,
        created_at=datetime.utcnow(),
    )
    return ticket


def validate_ws_ticket(ticket: str, session_id: str) -> str | None:
    """
    Validate ticket: exists, not used, not expired, matches session.
    Returns user_id or None. Immediately invalidates (single-use).
    """
    record = _tickets.get(ticket)
    if not record:
        return None

    # Single-use: mark before any other checks
    if record.used:
        return None
    record.used = True

    # TTL check
    age = (datetime.utcnow() - record.created_at).total_seconds()
    if age > settings.ws_ticket_ttl_seconds:
        del _tickets[ticket]
        return None

    # Session match
    if record.session_id != session_id:
        return None

    return record.user_id


def cleanup_expired_tickets() -> None:
    """Remove tickets older than TTL. Called periodically."""
    now = datetime.utcnow()
    cutoff = timedelta(seconds=settings.ws_ticket_ttl_seconds * 2)
    expired = [
        t for t, r in _tickets.items()
        if now - r.created_at > cutoff
    ]
    for t in expired:
        del _tickets[t]
    if expired:
        logger.debug("Cleaned up %d expired WS tickets", len(expired))


# --- API Key Injection ---

async def inject_api_key(
    container_id: str,
    key_name: str,
    key_value: str,
    backend: object,
) -> None:
    """
    Write API key to container's tmpfs at /run/secrets/{key_name}.
    Zero the key bytes in memory after injection.
    """
    cmd = (
        f"sh -c 'printf \"%s\" \"$KEY\" > /run/secrets/{key_name} "
        f"&& chmod 400 /run/secrets/{key_name}'"
    )
    try:
        await backend.exec_in_container(
            container_id, cmd, environment={"KEY": key_value}, user="root"
        )
        logger.info(
            "Injected %s into container %s",
            key_name, mask_secret(container_id),
        )
    finally:
        # Best-effort memory zeroing
        key_bytes = bytearray(key_value.encode())
        for i in range(len(key_bytes)):
            key_bytes[i] = 0


# --- Rate Limiting ---

class RateLimiter:
    """Sliding window rate limiter per user_id."""

    def __init__(self, max_per_second: int = 100) -> None:
        self.max_per_second = max_per_second
        self._windows: dict[str, list[float]] = defaultdict(list)

    def check(self, user_id: str) -> bool:
        """Returns True if request is allowed, False if rate-limited."""
        now = datetime.utcnow().timestamp()
        window = self._windows[user_id]

        # Remove entries older than 1 second
        cutoff = now - 1.0
        self._windows[user_id] = [t for t in window if t > cutoff]
        window = self._windows[user_id]

        if len(window) >= self.max_per_second:
            return False

        window.append(now)
        return True

    def reset(self, user_id: str) -> None:
        """Clear rate limit state for a user."""
        self._windows.pop(user_id, None)


# Module-level rate limiter for WS messages
ws_rate_limiter = RateLimiter(max_per_second=settings.max_ws_messages_per_second)


# --- Logging Safety ---

def mask_secret(value: str) -> str:
    """Mask a secret for safe logging. Shows only last 4 chars."""
    if len(value) <= 4:
        return "***"
    return f"***{value[-4:]}"
