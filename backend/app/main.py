"""FastAPI app entrypoint with lifespan, CORS, and routers."""

from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager
from datetime import datetime

from fastapi import FastAPI, Request, Response
from fastapi.middleware.cors import CORSMiddleware

from app.auth import load_or_generate_keys
from app.auth import router as auth_router
from app.config import settings
from app.docker_ctl import ContainerPool, create_backend, init_pool
from app.models import SessionStatus
from app.security import cleanup_expired_tickets
from app.sessions import get_session_registry
from app.sessions import router as sessions_router
from app.terminal_ws import router as ws_router
from app.uploads import router as uploads_router

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)


async def _periodic_cleanup(pool: ContainerPool) -> None:
    """Background task: clean up expired tickets and idle sessions."""
    while True:
        await asyncio.sleep(60)
        try:
            # Clean up expired WS tickets
            cleanup_expired_tickets()

            # Auto-sleep idle sessions
            now = datetime.utcnow()
            sessions = get_session_registry()
            for session in list(sessions.values()):
                if session.status != SessionStatus.ACTIVE:
                    continue
                idle_seconds = (now - session.last_active).total_seconds()
                idle_minutes = idle_seconds / 60
                if idle_minutes >= settings.idle_timeout_minutes:
                    logger.info(
                        "Auto-sleeping idle session %s (idle %.0fm)",
                        session.session_id[:8], idle_minutes,
                    )
                    try:
                        await pool.backend.pause_container(session.container_id)
                        session.status = SessionStatus.SLEEPING
                    except Exception as e:
                        logger.error("Failed to auto-sleep session: %s", e)
        except Exception as e:
            logger.error("Periodic cleanup error: %s", e)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan: startup and shutdown."""
    # Startup
    logger.info("Starting Pocket AI Terminal backend")

    # 1. Load/generate RSA keys for JWT
    load_or_generate_keys()

    # 2. Initialize container pool
    backend = create_backend()
    pool = init_pool(backend)
    await pool.initialize()

    # 3. Start background cleanup task
    cleanup_task = asyncio.create_task(_periodic_cleanup(pool))

    yield

    # Shutdown
    logger.info("Shutting down Pocket AI Terminal backend")
    cleanup_task.cancel()

    # Stop all assigned containers
    for session_id in list(pool.assigned.keys()):
        try:
            await pool.release(session_id)
        except Exception as e:
            logger.error("Failed to release session %s: %s", session_id[:8], e)

    # Clean up pool
    for container_id in pool.available:
        try:
            await pool.backend.stop_container(container_id)
            await pool.backend.remove_container(container_id)
        except Exception:
            pass


app = FastAPI(
    title="Pocket AI Terminal",
    version="0.1.0",
    lifespan=lifespan,
)

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# HSTS header
@app.middleware("http")
async def add_security_headers(request: Request, call_next) -> Response:
    response = await call_next(request)
    response.headers["Strict-Transport-Security"] = (
        "max-age=31536000; includeSubDomains"
    )
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    return response


# Routers
app.include_router(auth_router)
app.include_router(sessions_router)
app.include_router(uploads_router)
app.include_router(ws_router)


# Health check
@app.get("/health")
async def health() -> dict:
    from app.docker_ctl import get_container_pool

    pool = get_container_pool()
    return {
        "status": "ok",
        "pool_available": len(pool.available),
        "pool_assigned": len(pool.assigned),
    }
