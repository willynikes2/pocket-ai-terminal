"""Container orchestration: abstract backend, Docker/mock implementations, pool."""

from __future__ import annotations

import asyncio
import logging
import uuid
from abc import ABC, abstractmethod
from typing import Any

from app.config import settings

logger = logging.getLogger(__name__)


# --- Abstract Container Backend ---


class ContainerBackend(ABC):
    """Abstract interface for container operations."""

    @abstractmethod
    async def create_container(self, session_id: str | None = None) -> str:
        """Create a container. Returns container_id."""

    @abstractmethod
    async def start_container(self, container_id: str) -> None:
        """Start a created container."""

    @abstractmethod
    async def pause_container(self, container_id: str) -> None:
        """Pause (freeze) a running container."""

    @abstractmethod
    async def unpause_container(self, container_id: str) -> None:
        """Unpause a paused container."""

    @abstractmethod
    async def stop_container(self, container_id: str) -> None:
        """Stop a running container."""

    @abstractmethod
    async def remove_container(self, container_id: str) -> None:
        """Remove a stopped container."""

    @abstractmethod
    async def exec_in_container(
        self,
        container_id: str,
        cmd: str,
        *,
        environment: dict[str, str] | None = None,
        user: str | None = None,
    ) -> tuple[int, bytes]:
        """Execute a command in the container. Returns (exit_code, output)."""

    @abstractmethod
    async def attach_to_tmux(
        self, container_id: str, cols: int, rows: int
    ) -> tuple[Any, Any]:
        """
        Attach to tmux session in container.
        Returns (input_stream, output_stream) for bidirectional I/O.
        """

    @abstractmethod
    async def capture_tmux_pane(
        self, container_id: str, lines: int = 100
    ) -> str:
        """Capture last N lines from tmux pane for replay on reconnect."""


# --- Docker Container Backend (Production) ---


class DockerContainerBackend(ContainerBackend):
    """Real Docker SDK implementation with gVisor and all security flags."""

    def __init__(self) -> None:
        import docker as docker_lib

        self.client = docker_lib.from_env()

    async def create_container(self, session_id: str | None = None) -> str:
        loop = asyncio.get_event_loop()
        sid = session_id or str(uuid.uuid4())

        def _create() -> str:
            container = self.client.containers.create(
                image=settings.container_image,
                detach=True,
                runtime=settings.container_runtime,
                cap_drop=["ALL"],
                cap_add=["CHOWN", "SETUID", "SETGID"],
                security_opt=[
                    "no-new-privileges",
                    f"seccomp={settings.seccomp_profile_path}",
                ],
                read_only=True,
                tmpfs={
                    "/tmp": "noexec,nosuid,size=100m",
                    "/var/tmp": "noexec,nosuid,size=50m",
                    "/run/secrets": "noexec,nosuid,size=1m",
                },
                mem_limit=settings.container_memory,
                nano_cpus=int(settings.container_cpus * 1e9),
                pids_limit=settings.container_pids_limit,
                user="1000:1000",
                network=settings.container_network,
                volumes={
                    f"pat-workspace-{sid}": {
                        "bind": "/workspace",
                        "mode": "rw",
                    }
                },
                labels={"pat.session_id": sid},
            )
            return container.id

        return await loop.run_in_executor(None, _create)

    async def start_container(self, container_id: str) -> None:
        loop = asyncio.get_event_loop()
        await loop.run_in_executor(
            None, lambda: self.client.containers.get(container_id).start()
        )

    async def pause_container(self, container_id: str) -> None:
        loop = asyncio.get_event_loop()
        await loop.run_in_executor(
            None, lambda: self.client.containers.get(container_id).pause()
        )

    async def unpause_container(self, container_id: str) -> None:
        loop = asyncio.get_event_loop()
        await loop.run_in_executor(
            None, lambda: self.client.containers.get(container_id).unpause()
        )

    async def stop_container(self, container_id: str) -> None:
        loop = asyncio.get_event_loop()
        await loop.run_in_executor(
            None, lambda: self.client.containers.get(container_id).stop(timeout=10)
        )

    async def remove_container(self, container_id: str) -> None:
        loop = asyncio.get_event_loop()
        await loop.run_in_executor(
            None,
            lambda: self.client.containers.get(container_id).remove(force=True),
        )

    async def exec_in_container(
        self,
        container_id: str,
        cmd: str,
        *,
        environment: dict[str, str] | None = None,
        user: str | None = None,
    ) -> tuple[int, bytes]:
        loop = asyncio.get_event_loop()

        def _exec() -> tuple[int, bytes]:
            container = self.client.containers.get(container_id)
            result = container.exec_run(
                cmd,
                environment=environment or {},
                user=user or "",
            )
            return result.exit_code, result.output

        return await loop.run_in_executor(None, _exec)

    async def attach_to_tmux(
        self, container_id: str, cols: int, rows: int
    ) -> tuple[Any, Any]:
        """Attach to tmux via docker exec with PTY."""
        loop = asyncio.get_event_loop()

        def _attach():
            container = self.client.containers.get(container_id)
            # Create exec with PTY for interactive tmux
            exec_id = self.client.api.exec_create(
                container.id,
                f"tmux attach-session -t pat",
                stdin=True,
                tty=True,
                environment={"COLUMNS": str(cols), "LINES": str(rows)},
            )
            socket = self.client.api.exec_start(
                exec_id, socket=True, tty=True
            )
            return socket

        raw_socket = await loop.run_in_executor(None, _attach)
        # Wrap in async streams
        reader = asyncio.StreamReader()
        input_queue: asyncio.Queue[bytes] = asyncio.Queue()

        return MockStream(input_queue), DockerOutputStream(raw_socket, reader)

    async def capture_tmux_pane(
        self, container_id: str, lines: int = 100
    ) -> str:
        exit_code, output = await self.exec_in_container(
            container_id, f"tmux capture-pane -t pat -p -S -{lines}"
        )
        if exit_code == 0:
            return output.decode(errors="replace")
        return ""


# --- Mock Container Backend (Dev/Test) ---


class MockStream:
    """Async stream wrapper around an asyncio.Queue for mock I/O."""

    def __init__(self, queue: asyncio.Queue[bytes] | None = None) -> None:
        self.queue: asyncio.Queue[bytes] = queue or asyncio.Queue()
        self._closed = False

    async def write(self, data: bytes) -> None:
        if not self._closed:
            await self.queue.put(data)

    async def read(self, n: int = 4096) -> bytes:
        try:
            return await asyncio.wait_for(self.queue.get(), timeout=30.0)
        except asyncio.TimeoutError:
            return b""

    def close(self) -> None:
        self._closed = True


class DockerOutputStream:
    """Wraps a raw Docker exec socket for async reads."""

    def __init__(self, socket: Any, reader: asyncio.StreamReader) -> None:
        self._socket = socket
        self._reader = reader

    async def read(self, n: int = 4096) -> bytes:
        loop = asyncio.get_event_loop()
        try:
            data = await loop.run_in_executor(
                None, lambda: self._socket._sock.recv(n)
            )
            return data
        except Exception:
            return b""

    def close(self) -> None:
        try:
            self._socket.close()
        except Exception:
            pass


class MockContainerBackend(ContainerBackend):
    """In-memory mock for dev/testing on Windows (no Docker required)."""

    def __init__(self) -> None:
        self._containers: dict[str, dict[str, Any]] = {}
        self._counter = 0

    async def create_container(self, session_id: str | None = None) -> str:
        self._counter += 1
        cid = f"mock-container-{self._counter}"
        self._containers[cid] = {
            "status": "created",
            "session_id": session_id,
            "secrets": {},
        }
        return cid

    async def start_container(self, container_id: str) -> None:
        if container_id in self._containers:
            self._containers[container_id]["status"] = "running"

    async def pause_container(self, container_id: str) -> None:
        if container_id in self._containers:
            self._containers[container_id]["status"] = "paused"

    async def unpause_container(self, container_id: str) -> None:
        if container_id in self._containers:
            self._containers[container_id]["status"] = "running"

    async def stop_container(self, container_id: str) -> None:
        if container_id in self._containers:
            self._containers[container_id]["status"] = "stopped"

    async def remove_container(self, container_id: str) -> None:
        self._containers.pop(container_id, None)

    async def exec_in_container(
        self,
        container_id: str,
        cmd: str,
        *,
        environment: dict[str, str] | None = None,
        user: str | None = None,
    ) -> tuple[int, bytes]:
        if container_id not in self._containers:
            return (1, b"container not found")

        # Simulate key injection
        if "/run/secrets/" in cmd and environment and "KEY" in environment:
            key_name = cmd.split("/run/secrets/")[1].split(" ")[0].split("'")[0]
            self._containers[container_id]["secrets"][key_name] = True
            return (0, b"")

        # Simulate tmux check
        if "tmux has-session" in cmd:
            return (0, b"")

        # Simulate tmux capture-pane
        if "tmux capture-pane" in cmd:
            return (0, b"PAT /workspace> \r\n")

        # Simulate tmux resize
        if "tmux resize" in cmd:
            return (0, b"")

        return (0, b"mock output\n")

    async def attach_to_tmux(
        self, container_id: str, cols: int, rows: int
    ) -> tuple[MockStream, MockStream]:
        """Return mock streams that echo input back as output."""
        input_stream = MockStream()
        output_stream = MockStream()

        # Echo task: read from input, write to output (simulates terminal)
        async def _echo_loop() -> None:
            while True:
                try:
                    data = await input_stream.read()
                    if not data:
                        break
                    # Echo input back as output (basic terminal simulation)
                    await output_stream.write(data)
                except Exception:
                    break

        asyncio.create_task(_echo_loop())

        # Send initial prompt
        await output_stream.write(b"PAT /workspace> ")

        return input_stream, output_stream

    async def capture_tmux_pane(
        self, container_id: str, lines: int = 100
    ) -> str:
        return "PAT /workspace> \r\n"


# --- Container Pool ---


class ContainerPool:
    """Pre-warmed container pool manager."""

    def __init__(self, backend: ContainerBackend) -> None:
        self.backend = backend
        self.available: list[str] = []
        self.assigned: dict[str, str] = {}  # session_id -> container_id
        self._lock = asyncio.Lock()

    async def initialize(self) -> None:
        """Pre-create pool_size containers. Called on app startup."""
        logger.info("Initializing container pool (size=%d)", settings.pool_size)
        tasks = [self._create_warm() for _ in range(settings.pool_size)]
        results = await asyncio.gather(*tasks, return_exceptions=True)

        for result in results:
            if isinstance(result, str):
                self.available.append(result)
            else:
                logger.error("Failed to pre-warm container: %s", result)

        logger.info(
            "Container pool ready: %d/%d available",
            len(self.available), settings.pool_size,
        )

    async def assign(self, session_id: str) -> str:
        """Assign a pre-warmed container to a session."""
        async with self._lock:
            if self.available:
                container_id = self.available.pop(0)
            else:
                logger.warning("Pool empty — cold-creating container")
                container_id = await self._create_warm()

            self.assigned[session_id] = container_id

        # Refill pool asynchronously
        asyncio.create_task(self._refill())
        return container_id

    async def release(self, session_id: str) -> None:
        """Stop and remove a container, clear assignment."""
        async with self._lock:
            container_id = self.assigned.pop(session_id, None)

        if container_id:
            try:
                await self.backend.stop_container(container_id)
                await self.backend.remove_container(container_id)
            except Exception as e:
                logger.error("Failed to release container %s: %s", container_id, e)

    async def _create_warm(self) -> str:
        """Create and start a container with tmux ready."""
        cid = await self.backend.create_container()
        await self.backend.start_container(cid)

        # Wait for tmux to be ready
        for _ in range(10):
            exit_code, _ = await self.backend.exec_in_container(
                cid, "tmux has-session -t pat"
            )
            if exit_code == 0:
                return cid
            await asyncio.sleep(0.5)

        logger.warning("Container %s: tmux not ready after 5s", cid[:12])
        return cid

    async def _refill(self) -> None:
        """Refill pool to target size."""
        async with self._lock:
            deficit = settings.pool_size - len(self.available)

        for _ in range(max(0, deficit)):
            try:
                cid = await self._create_warm()
                async with self._lock:
                    self.available.append(cid)
            except Exception as e:
                logger.error("Failed to refill pool: %s", e)


# --- Module-Level Singleton ---

_pool: ContainerPool | None = None


def init_pool(backend: ContainerBackend | None = None) -> ContainerPool:
    """Initialize the global container pool."""
    global _pool
    if backend is None:
        backend = create_backend()
    _pool = ContainerPool(backend)
    return _pool


def get_container_pool() -> ContainerPool:
    """Get the global container pool. Raises if not initialized."""
    if _pool is None:
        raise RuntimeError("Container pool not initialized — call init_pool() first")
    return _pool


def create_backend() -> ContainerBackend:
    """Create the appropriate container backend based on config."""
    if settings.docker_backend == "docker":
        logger.info("Using Docker container backend (runtime=%s)", settings.container_runtime)
        return DockerContainerBackend()
    logger.info("Using Mock container backend (no Docker required)")
    return MockContainerBackend()
