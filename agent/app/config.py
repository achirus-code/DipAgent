"""Agent configuration, read from environment variables."""

from __future__ import annotations

import logging
import os
import secrets
from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path

log = logging.getLogger("dipagent")



@dataclass(frozen=True)
class Settings:
    data_dir: Path
    api_token: str
    exchange: str  # "revolutx" | "mock"
    revx_api_key: str
    revx_private_key_path: Path
    revx_base_url: str
    tick_seconds: int
    taker_fee: Decimal
    mock_speed: float

    @property
    def db_path(self) -> Path:
        return self.data_dir / "dipagent.db"


def _resolve_token(data_dir: Path) -> str:
    token = os.getenv("API_TOKEN", "").strip()
    if token:
        return token
    token_file = data_dir / "api_token"
    if token_file.exists():
        return token_file.read_text().strip()
    token = secrets.token_urlsafe(32)
    token_file.write_text(token)
    token_file.chmod(0o600)
    log.warning("No API_TOKEN set – generated a new token: %s", token)
    return token


def load_settings() -> Settings:
    data_dir = Path(os.getenv("DATA_DIR", "/data"))
    data_dir.mkdir(parents=True, exist_ok=True)
    return Settings(
        data_dir=data_dir,
        api_token=_resolve_token(data_dir),
        exchange=os.getenv("EXCHANGE", "revolutx").strip().lower(),
        revx_api_key=os.getenv("REVX_API_KEY", "").strip(),
        revx_private_key_path=Path(os.getenv("REVX_PRIVATE_KEY_PATH", "/secrets/revx_private.pem")),
        revx_base_url=os.getenv("REVX_BASE_URL", "https://revx.revolut.com"),
        tick_seconds=max(5, int(os.getenv("TICK_SECONDS", "30"))),
        taker_fee=Decimal(os.getenv("TAKER_FEE", "0.0009")),
        mock_speed=float(os.getenv("MOCK_SPEED", "1")),
    )
