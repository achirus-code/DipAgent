"""Backup export/import: consistent snapshot out, validated archive in, live trading off afterwards."""

import importlib
import io
import json
import stat
import tarfile

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi.testclient import TestClient

from app import backup


@pytest.fixture
def api(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    monkeypatch.setenv("API_TOKEN", "t")
    monkeypatch.setenv("EXCHANGE", "mock")
    monkeypatch.setenv("REVX_API_KEY", "")
    import app.main as main

    main = importlib.reload(main)
    client = TestClient(main.app)
    client.headers["Authorization"] = "Bearer t"
    return client, main, tmp_path


def _bot(client, name: str) -> dict:
    r = client.post("/api/bots", json={"name": name, "strategy": "dip", "symbol": "ETH-EUR", "params": {}, "enabled": False})
    assert r.status_code in (200, 201), r.text
    return r.json()


def _pem() -> bytes:
    return Ed25519PrivateKey.generate().private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    )


def test_export_contains_snapshot_but_not_the_token(api):
    client, main, data = api
    _bot(client, "alpha")
    main.db.add_trade(bot_id=1, bot_name="alpha", symbol="ETH-EUR", side="buy", price="1", base_qty="1",
                      quote_amount="1", fee="0", pnl=None, order_id="o1", paper=1, reason="")

    r = client.get("/api/backup")
    assert r.status_code == 200
    assert r.headers["content-type"] == "application/gzip"
    assert r.headers["content-disposition"].startswith('attachment; filename="dipagent-backup-')

    with tarfile.open(fileobj=io.BytesIO(r.content), mode="r:gz") as tar:
        names = set(tar.getnames())
        manifest = json.load(tar.extractfile("manifest.json"))
    assert names == {"manifest.json", "dipagent.db"}  # no credentials set up, never the API token
    assert manifest["format"] == backup.FORMAT and manifest["app"] == "dipagent"
    assert manifest["agent_version"] == main.VERSION and manifest["credentials"] is False

    # the snapshot includes what is still in the WAL: restore it elsewhere and read the bot + trade back
    unpacked = backup.unpack(r.content, data)
    import sqlite3

    conn = sqlite3.connect(unpacked.db_path)
    assert [row[0] for row in conn.execute("SELECT name FROM bots")] == ["alpha"]
    assert conn.execute("SELECT count(*) FROM trades").fetchone()[0] == 1
    conn.close()
    unpacked.cleanup()
    assert not list(data.glob("restore.*"))


def test_restore_replaces_data_and_turns_live_trading_off(api):
    client, main, data = api
    _bot(client, "alpha")
    archive = client.get("/api/backup").content

    # meanwhile: other data, live trading on (set directly – the mock exchange refuses it via the API)
    _bot(client, "beta")
    main.db.set_setting("live_trading", True)
    main.db.set_limits({"max_open_positions": 7, "max_total_invested": 0.0, "one_position_per_symbol": True})

    r = client.post("/api/restore", content=archive, headers={"Content-Type": "application/gzip"})
    assert r.status_code == 200, r.text
    result = r.json()
    assert result["bots"] == 1 and result["trades"] == 0
    assert result["live_trading_disabled"] is True and result["credentials_restored"] is False
    assert result["agent_version"] == main.VERSION

    assert [b["name"] for b in client.get("/api/bots").json()] == ["alpha"]
    assert client.get("/api/status").json()["live_trading_allowed"] is False
    assert client.get("/api/limits").json()["max_open_positions"] == 3
    events = [e["message"] for e in client.get("/api/events").json()]
    assert any(e.startswith("Backup from") for e in events)
    assert any("Live trading disabled after the restore" in e for e in events)
    assert not list(data.glob("restore.*"))
    # the database keeps working after the swap
    _bot(client, "gamma")
    assert len(client.get("/api/bots").json()) == 2


def test_backup_taken_while_live_is_restored_in_paper_mode(api):
    client, main, data = api
    main.db.set_setting("live_trading", True)
    archive = client.get("/api/backup").content
    main.db.set_setting("live_trading", False)

    r = client.post("/api/restore", content=archive, headers={"Content-Type": "application/gzip"})
    assert r.status_code == 200 and r.json()["live_trading_disabled"] is True
    assert client.get("/api/status").json()["live_trading_allowed"] is False


def test_restore_brings_back_app_credentials(api):
    client, main, data = api
    main.credentials.save("K" * 64, _pem())
    archive = client.get("/api/backup").content
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
        assert {"revx_api_key", "revx_private.pem"} <= set(tar.getnames())
        assert tar.getmember("revx_private.pem").mode == 0o600

    main.credentials.clear()
    assert main.credentials.source == "none"
    r = client.post("/api/restore", content=archive, headers={"Content-Type": "application/gzip"})
    assert r.status_code == 200, r.text
    assert r.json()["credentials_restored"] is True
    assert main.credentials.source == "app"
    assert stat.S_IMODE((data / "revx_private.pem").stat().st_mode) == 0o600


def test_restore_keeps_current_credentials_when_backup_has_none(api):
    client, main, data = api
    archive = client.get("/api/backup").content
    main.credentials.save("K" * 64, _pem())
    assert client.post("/api/restore", content=archive, headers={"Content-Type": "application/gzip"}).status_code == 200
    assert main.credentials.source == "app"


def _archive(files: dict[str, bytes]) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for name, content in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(content)
            tar.addfile(info, io.BytesIO(content))
    return buf.getvalue()


def test_restore_rejects_foreign_files(api):
    client, main, data = api
    manifest = json.dumps({"format": backup.FORMAT, "app": "dipagent"}).encode()
    good_db = backup.unpack(client.get("/api/backup").content, data)
    db_bytes = good_db.db_path.read_bytes()
    good_db.cleanup()

    cases = {
        "garbage": b"not a tar",
        "stray entry": _archive({"manifest.json": manifest, "dipagent.db": db_bytes, "../etc/passwd": b"x"}),
        "no manifest": _archive({"dipagent.db": db_bytes}),
        "wrong app": _archive({"manifest.json": json.dumps({"format": 1, "app": "other"}).encode(), "dipagent.db": db_bytes}),
        "future format": _archive({"manifest.json": json.dumps({"format": 99, "app": "dipagent"}).encode(), "dipagent.db": db_bytes}),
        "not sqlite": _archive({"manifest.json": manifest, "dipagent.db": b"hello"}),
        "half credentials": _archive({"manifest.json": manifest, "dipagent.db": db_bytes, "revx_api_key": b"k"}),
    }
    for label, body in cases.items():
        r = client.post("/api/restore", content=body, headers={"Content-Type": "application/gzip", "Accept-Language": "de"})
        assert r.status_code == 400, label
        assert r.json()["detail"].startswith("Kein gültiges DipAgent-Backup"), label
    assert not list(data.glob("restore.*"))
    assert client.get("/api/bots").json() == []  # nothing changed


def test_backup_needs_the_token(api):
    client, main, data = api
    assert client.get("/api/backup", headers={"Authorization": "Bearer wrong"}).status_code == 401
    assert client.post("/api/restore", content=b"x", headers={"Authorization": "Bearer wrong"}).status_code == 401
