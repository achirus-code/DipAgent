"""Revolut X credentials: from .env/secrets (read-only) or set up via the app and stored in the data dir.

The Ed25519 private key is generated on the agent and never leaves it – the app only ever sees the public key.
"""

from __future__ import annotations

import os
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from .config import Settings
from .i18n import m


def _write_secret(path: Path, data: bytes) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


def public_key_pem(private_pem: bytes) -> str | None:
    try:
        key = serialization.load_pem_private_key(private_pem, password=None)
    except ValueError:
        return None  # unreadable key file – the engine reports the details
    return key.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    ).decode()


def mask(api_key: str) -> str:
    return f"{api_key[:4]}…{api_key[-4:]}" if len(api_key) > 10 else "…"


class CredentialStore:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.private_file = settings.data_dir / "revx_private.pem"
        self.pending_file = settings.data_dir / "revx_private.pending.pem"
        self.api_key_file = settings.data_dir / "revx_api_key"

    # --- where do the active credentials come from? --------------------------

    @property
    def source(self) -> str:
        """"env" (.env + secrets folder), "app" (set up via the app) or "none"."""
        if self.settings.revx_api_key and self.settings.revx_private_key_path.is_file():
            return "env"
        if self.api_key_file.is_file() and self.private_file.is_file():
            return "app"
        return "none"

    def active(self) -> tuple[str, bytes] | None:
        if self.source == "env":
            return self.settings.revx_api_key, self.settings.revx_private_key_path.read_bytes()
        if self.source == "app":
            return self.api_key_file.read_text().strip(), self.private_file.read_bytes()
        return None

    def missing_reason(self) -> dict:
        if self.settings.revx_api_key and not self.settings.revx_private_key_path.is_file():
            return m("exchange.key_file_missing", path=str(self.settings.revx_private_key_path))
        return m("exchange.not_set_up")

    # --- setup via the app ------------------------------------------------------

    def generate_pending(self) -> str:
        """Create a new key pair; it only becomes active once a matching API key was verified."""
        key = Ed25519PrivateKey.generate()
        pem = key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
        )
        _write_secret(self.pending_file, pem)
        return public_key_pem(pem)

    def pending_pem(self) -> bytes | None:
        return self.pending_file.read_bytes() if self.pending_file.is_file() else None

    def signing_key_for_new_api_key(self) -> bytes | None:
        """A freshly generated key pair wins; otherwise re-use the active app key (API key rotation)."""
        if pending := self.pending_pem():
            return pending
        return self.private_file.read_bytes() if self.private_file.is_file() else None

    def save(self, api_key: str, private_pem: bytes) -> None:
        _write_secret(self.private_file, private_pem)
        _write_secret(self.api_key_file, api_key.encode())
        self.pending_file.unlink(missing_ok=True)

    def clear(self) -> None:
        for f in (self.private_file, self.api_key_file, self.pending_file):
            f.unlink(missing_ok=True)

    def describe(self) -> dict:
        active = self.active()
        pending = self.pending_pem()
        return {
            "source": self.source,
            "api_key_masked": mask(active[0]) if active else None,
            "public_key": public_key_pem(active[1]) if active else None,
            "pending_public_key": public_key_pem(pending) if pending else None,
        }
