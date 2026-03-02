"""Centralized configuration from environment variables."""

from pathlib import Path

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # Auth
    jwt_private_key_path: str = "keys/private.pem"
    jwt_public_key_path: str = "keys/public.pem"
    jwt_algorithm: str = "RS256"
    access_token_expire_minutes: int = 15
    refresh_token_expire_days: int = 30
    dev_token: str = "dev-token-change-me"

    # Docker
    docker_backend: str = "mock"  # "docker" or "mock"
    container_image: str = "pat-runtime:latest"
    container_runtime: str = "runsc"
    container_network: str = "pat-restricted"
    seccomp_profile_path: str = "docker/seccomp-profile.json"

    # Pool
    pool_size: int = 5
    pool_refill_interval_seconds: int = 30

    # Session limits
    max_concurrent_sessions: int = 3
    max_session_duration_hours: int = 6
    idle_timeout_minutes: int = 10

    # Container limits
    container_memory: str = "512m"
    container_cpus: float = 1.0
    container_pids_limit: int = 256
    container_disk_quota: str = "5g"

    # Upload limits
    max_file_size: int = 50 * 1024 * 1024  # 50MB
    max_files_per_upload: int = 10
    allowed_extensions: set[str] = {
        ".py", ".js", ".ts", ".json", ".yaml", ".yml", ".toml",
        ".md", ".txt", ".sh", ".css", ".html", ".csv", ".xml",
        ".rs", ".go", ".java", ".c", ".cpp", ".h", ".rb",
        ".png", ".jpg", ".jpeg", ".gif", ".svg", ".pdf", ".zip",
    }

    # WebSocket
    ws_max_message_size: int = 65536  # 64KB
    ws_max_connections_per_user: int = 5
    ws_ping_interval: int = 30
    ws_idle_timeout: int = 1800  # 30 minutes
    ws_ticket_ttl_seconds: int = 30

    # Rate limiting
    max_ws_messages_per_second: int = 100
    max_uploads_per_hour: int = 50
    max_upload_bytes_per_hour: int = 500 * 1024 * 1024  # 500MB

    # Server
    cors_origins: list[str] = ["*"]
    host: str = "0.0.0.0"
    port: int = 8000

    model_config = {"env_prefix": "PAT_"}

    @property
    def keys_dir(self) -> Path:
        return Path(self.jwt_private_key_path).parent


settings = Settings()
