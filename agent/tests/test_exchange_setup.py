import dataclasses
import importlib
import stat

import pytest
from fastapi.testclient import TestClient

from app.revolutx import RevolutXClient, RevolutXError

KEY = "A" * 64


@pytest.fixture
def api(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    monkeypatch.setenv("API_TOKEN", "t")
    monkeypatch.setenv("EXCHANGE", "revolutx")
    monkeypatch.setenv("REVX_API_KEY", "")
    monkeypatch.setenv("REVX_PRIVATE_KEY_PATH", str(tmp_path / "none.pem"))
    import app.main as main

    main = importlib.reload(main)
    client = TestClient(main.app)
    client.headers["Authorization"] = "Bearer t"
    client.headers["Accept-Language"] = "de-DE,de;q=0.9"
    return client, main, tmp_path


def test_setup_flow(api, monkeypatch):
    client, main, data = api
    info = client.get("/api/exchange").json()
    assert info["source"] == "none" and not info["connected"]

    # 1) key pair is generated on the agent, only the public key is returned
    info = client.post("/api/exchange/keypair").json()
    assert info["pending_public_key"].startswith("-----BEGIN PUBLIC KEY-----")
    assert "PRIVATE" not in str(info)
    assert stat.S_IMODE((data / "revx_private.pending.pem").stat().st_mode) == 0o600

    # 2) wrong key -> rejected, nothing stored
    async def reject(self):
        raise RevolutXError(401, "Unauthorized")

    monkeypatch.setattr(RevolutXClient, "balances", reject)
    r = client.put("/api/exchange/credentials", json={"api_key": KEY})
    assert r.status_code == 422 and "abgelehnt" in r.json()["detail"]
    assert client.get("/api/exchange").json()["source"] == "none"

    # 3) valid key -> stored, exchange swapped live
    async def ok(self):
        return []

    monkeypatch.setattr(RevolutXClient, "balances", ok)
    info = client.put("/api/exchange/credentials", json={"api_key": KEY}).json()
    assert info["source"] == "app" and info["api_key_masked"] == "AAAA…AAAA"
    assert info["public_key"] and info["pending_public_key"] is None
    assert main.engine.exchange.name == "revolutx" and not hasattr(main.engine.exchange, "reason")

    # 4) remove
    info = client.delete("/api/exchange/credentials").json()
    assert info["source"] == "none"
    assert not (data / "revx_api_key").exists()


def test_env_credentials_are_read_only(api, monkeypatch, tmp_path):
    client, main, _ = api
    (tmp_path / "k.pem").write_bytes(b"key from secrets folder")
    env_settings = dataclasses.replace(main.settings, revx_api_key=KEY, revx_private_key_path=tmp_path / "k.pem")
    monkeypatch.setattr(main.credentials, "settings", env_settings)
    assert client.get("/api/exchange").json()["source"] == "env"
    assert client.post("/api/exchange/keypair").status_code == 409
    assert client.delete("/api/exchange/credentials").status_code == 409


def test_live_trading_switch(api, monkeypatch):
    client, main, _ = api
    assert client.get("/api/status").json()["live_trading_allowed"] is False  # default: paper only
    # not possible without Revolut X
    assert client.put("/api/live-trading", json={"enabled": True, "confirm": "LIVE"}).status_code == 409

    async def ok(self):
        return []

    monkeypatch.setattr(RevolutXClient, "balances", ok)
    client.post("/api/exchange/keypair")
    client.put("/api/exchange/credentials", json={"api_key": KEY})
    main.db.create_bot("A", "dip", "ETH-EUR", {}, False, True)  # paper bot
    assert client.get("/api/bots").json()[0]["paper"] is True
    # confirmation required
    assert client.put("/api/live-trading", json={"enabled": True}).status_code == 422
    r = client.put("/api/live-trading", json={"enabled": True, "confirm": "LIVE"})
    assert r.status_code == 200 and r.json()["live_trading_allowed"] is True
    # existing bots are switched to live as well
    bot = client.get("/api/bots").json()[0]
    assert bot["paper"] is False and bot["paper_requested"] is False
    # switching off needs no confirmation
    assert client.put("/api/live-trading", json={"enabled": False}).json()["live_trading_allowed"] is False
    # removing the Revolut X access switches live trading off
    client.put("/api/live-trading", json={"enabled": True, "confirm": "LIVE"})
    client.delete("/api/exchange/credentials")
    assert client.get("/api/status").json()["live_trading_allowed"] is False


def test_bot_changes_are_refused_while_an_order_is_pending(api):
    client, main, _ = api
    bot_id = main.db.create_bot("A", "dip", "ETH-EUR", {}, True, False)
    pending = {"client_order_id": "c", "id": None, "side": "buy", "reason": "x", "placed_at": 0, "quote_size": "50"}
    main.db.update_bot(bot_id, state={"pending_order": pending})
    body = {"name": "A", "strategy": "dip", "symbol": "BTC-EUR", "params": {}, "enabled": True, "paper": False}
    assert client.put(f"/api/bots/{bot_id}", json=body).status_code == 409
    assert client.delete(f"/api/bots/{bot_id}").status_code == 409
    body["symbol"] = "ETH-EUR"
    assert client.put(f"/api/bots/{bot_id}", json=body).status_code == 200  # renaming etc. stays possible
    assert client.delete(f"/api/bots/{bot_id}", params={"force": "true"}).status_code == 204


def test_balances_come_from_the_exchange(api, monkeypatch):
    """Caching is the Revolut X wrapper's job (see test_core) – the endpoint just asks the exchange."""
    client, main, _ = api

    class Fixed(main.Exchange):
        async def balances(self):
            return {"EUR": (main.Decimal(1), main.Decimal(2)), "DUST": (main.Decimal(0), main.Decimal(0))}

    monkeypatch.setattr(main.engine, "exchange", Fixed())
    assert client.get("/api/balances").json() == [{"currency": "EUR", "available": 1.0, "total": 2.0}]
