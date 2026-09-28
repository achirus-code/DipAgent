"""Backup archives: everything the agent keeps in its data directory, minus what belongs to the installation.

A backup is a gzip'ed tar with a manifest, a consistent snapshot of the SQLite database and – when Revolut X was set
up via the app – the API key and the private key. The API token, the instance lock and the add-on options are not
part of it: they belong to the agent installation, not to the trading data.
"""

from __future__ import annotations

import io
import json
import os
import shutil
import sqlite3
import tarfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

FORMAT = 1
MANIFEST = "manifest.json"
DB_FILE = "dipagent.db"
CREDENTIAL_FILES = ("revx_api_key", "revx_private.pem")
ALLOWED = {MANIFEST, DB_FILE, *CREDENTIAL_FILES}
MAX_SIZE = 256 * 1024 * 1024  # a database of trades is a few MB; anything bigger is not one of ours


class InvalidBackup(Exception):
    """The uploaded file is not a DipAgent backup (message in English, rendered via api.invalid_backup)."""


def _add(tar: tarfile.TarFile, name: str, data: bytes, mode: int = 0o600) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = mode
    info.mtime = int(time.time())
    tar.addfile(info, io.BytesIO(data))


def create(db_snapshot: bytes, credentials: dict[str, bytes], meta: dict[str, Any]) -> tuple[bytes, str]:
    """Build the archive; returns (bytes, suggested file name)."""
    manifest = {"format": FORMAT, "app": "dipagent", "created_at": int(time.time() * 1000), **meta,
                "credentials": bool(credentials)}
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        _add(tar, MANIFEST, json.dumps(manifest, indent=2).encode(), 0o644)
        _add(tar, DB_FILE, db_snapshot, 0o644)
        for name in CREDENTIAL_FILES:
            if name in credentials:
                _add(tar, name, credentials[name])
    return buf.getvalue(), time.strftime("dipagent-backup-%Y%m%d-%H%M.tgz")


@dataclass
class Unpacked:
    """A validated backup, extracted into a temp folder next to the data directory (same file system)."""

    manifest: dict[str, Any]
    db_path: Path
    credentials: dict[str, bytes] = field(default_factory=dict)
    _tmp: Path | None = None

    def cleanup(self) -> None:
        if self._tmp is not None:
            shutil.rmtree(self._tmp, ignore_errors=True)


def unpack(data: bytes, data_dir: Path) -> Unpacked:
    """Extract and validate an uploaded backup. Raises InvalidBackup for anything that is not one of ours."""
    if len(data) > MAX_SIZE:
        raise InvalidBackup("file is too large")
    try:
        tar = tarfile.open(fileobj=io.BytesIO(data), mode="r:gz")
    except (tarfile.TarError, OSError, EOFError) as exc:
        raise InvalidBackup("not a gzip'ed tar archive") from exc

    members: dict[str, bytes] = {}
    with tar:
        for member in tar.getmembers():
            if member.name not in ALLOWED or not member.isfile():
                raise InvalidBackup(f"unexpected entry {member.name!r}")
            with tar.extractfile(member) as f:  # type: ignore[union-attr]
                members[member.name] = f.read()
    if MANIFEST not in members or DB_FILE not in members:
        raise InvalidBackup("manifest or database missing")
    try:
        manifest = json.loads(members[MANIFEST])
    except ValueError as exc:
        raise InvalidBackup("manifest is not valid JSON") from exc
    if not isinstance(manifest, dict) or manifest.get("app") != "dipagent":
        raise InvalidBackup("not a DipAgent backup")
    if manifest.get("format") != FORMAT:
        raise InvalidBackup(f"unsupported backup format {manifest.get('format')!r}")
    credentials = {name: members[name] for name in CREDENTIAL_FILES if name in members}
    if len(credentials) not in (0, len(CREDENTIAL_FILES)):
        raise InvalidBackup("incomplete Revolut X credentials")

    tmp = data_dir / f"restore.{os.getpid()}.tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(mode=0o700)
    db_path = tmp / DB_FILE
    db_path.write_bytes(members[DB_FILE])
    try:
        _check_database(db_path)
    except InvalidBackup:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    return Unpacked(manifest, db_path, credentials, tmp)


def _check_database(path: Path) -> None:
    try:
        conn = sqlite3.connect(path)
        try:
            if conn.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise InvalidBackup("database is corrupt")
            tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        finally:
            conn.close()
    except sqlite3.DatabaseError as exc:
        raise InvalidBackup("not a SQLite database") from exc
    if not {"bots", "trades", "settings"} <= tables:
        raise InvalidBackup("database has no DipAgent tables")
    # the temporary connection may have left journal files behind
    for suffix in ("-wal", "-shm", "-journal"):
        Path(str(path) + suffix).unlink(missing_ok=True)
