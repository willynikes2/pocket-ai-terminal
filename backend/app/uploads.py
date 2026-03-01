"""File upload endpoint with layered validation."""

from __future__ import annotations

import base64
import re
from pathlib import PurePosixPath

from fastapi import APIRouter, Depends, HTTPException, UploadFile

from app.auth import get_current_user
from app.config import settings
from app.docker_ctl import get_container_pool
from app.models import UploadResponse, UploadedFile
from app.sessions import _get_user_session

router = APIRouter(tags=["uploads"])

# Magic bytes for binary file verification
MAGIC_BYTES: dict[str, bytes] = {
    ".png": b"\x89PNG",
    ".jpg": b"\xff\xd8\xff",
    ".jpeg": b"\xff\xd8\xff",
    ".gif": b"GIF8",
    ".pdf": b"%PDF",
    ".zip": b"PK\x03\x04",
}


async def _validate_upload(file: UploadFile) -> tuple[str, bytes]:
    """Layered validation: extension, size, path traversal, magic bytes."""
    if not file.filename:
        raise HTTPException(status_code=400, detail="Filename required")

    # 1. Path traversal prevention — strip to bare filename (PurePosixPath for container paths)
    safe_name = PurePosixPath(file.filename).name
    if ".." in safe_name or "/" in safe_name or "\\" in safe_name:
        raise HTTPException(status_code=400, detail="Invalid filename")

    # Reject filenames with only dots or empty after stripping
    if not safe_name or not re.search(r"[a-zA-Z0-9]", safe_name):
        raise HTTPException(status_code=400, detail="Invalid filename")

    # 2. Extension allowlist
    ext = PurePosixPath(safe_name).suffix.lower()
    if ext not in settings.allowed_extensions:
        raise HTTPException(status_code=400, detail=f"File type {ext} not allowed")

    # 3. Size check
    content = await file.read()
    if len(content) > settings.max_file_size:
        raise HTTPException(status_code=400, detail="File too large")

    # 4. Magic byte verification for binary files
    if ext in MAGIC_BYTES:
        expected = MAGIC_BYTES[ext]
        if not content.startswith(expected):
            raise HTTPException(
                status_code=400,
                detail=f"File content doesn't match {ext} format",
            )

    return safe_name, content


async def _write_to_container(
    backend: object, container_id: str, filename: str, content: bytes
) -> None:
    """Write file content into container's /workspace/uploads/ via exec."""
    # Base64 encode to safely transfer binary data through shell
    encoded = base64.b64encode(content).decode()

    # Create uploads dir if needed, decode and write file
    cmd = (
        f"sh -c 'mkdir -p /workspace/uploads "
        f"&& echo \"{encoded}\" | base64 -d > /workspace/uploads/{filename}'"
    )
    exit_code, output = await backend.exec_in_container(container_id, cmd)
    if exit_code != 0:
        raise HTTPException(
            status_code=500,
            detail=f"Failed to write file to container: {output.decode(errors='replace')}",
        )


@router.post(
    "/sessions/{session_id}/upload",
    response_model=UploadResponse,
)
async def upload_files(
    session_id: str,
    files: list[UploadFile],
    user_id: str = Depends(get_current_user),
) -> UploadResponse:
    """Upload files into session's /workspace/uploads/ directory."""
    session = _get_user_session(session_id, user_id)

    if len(files) > settings.max_files_per_upload:
        raise HTTPException(
            status_code=400,
            detail=f"Max {settings.max_files_per_upload} files per upload",
        )

    pool = get_container_pool()
    uploaded: list[UploadedFile] = []

    for file in files:
        safe_name, content = await _validate_upload(file)

        await _write_to_container(
            pool.backend, session.container_id, safe_name, content
        )

        uploaded.append(UploadedFile(
            name=safe_name,
            path=f"/workspace/uploads/{safe_name}",
            size=len(content),
        ))

    return UploadResponse(uploaded=uploaded)
