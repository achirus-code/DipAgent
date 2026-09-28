"""Regression tests for the order-execution edge cases and the market-data caching of the engine."""

from decimal import Decimal
from pathlib import Path

import httpx
import pytest

from app import engine as engine_module
from app.engine import ERROR_BACKOFF_MS, TRANSIENT_BACKOFF_MS, CandleCache, definitely_not_placed
from app.exchange import Candle, RevolutXExchange
from app.i18n import Problem, render
from app.revolutx import RevolutXClient, RevolutXError
from app.strategies import STRATEGIES, Param
from tests.test_core import HOUR, FakeExchange, make_engine


class CountingExchange(FakeExchange):
    """Counts market-data requests so the tests can check batching and caching."""

    def __init__(self, ref, price):
        super().__init__(ref, price)
        self.ticker_calls = 0
        self.batch_calls = 0
        self.candle_calls = 0

    async def ticker(self, symbol):
        self.ticker_calls += 1
        return await super().ticker(symbol)

    async def tickers(self, symbols):
        self.batch_calls += 1
        result = {}
        for symbol in symbols:  # (no comprehension: super() doesn't work inside one)
            result[symbol] = await FakeExchange.ticker(self, symbol)
        return result

    async def candles(self, symbol, interval, since, until):
        self.candle_calls += 1
        return await super().candles(symbol, interval, since, until)


# --- order execution -----------------------------------------------------------------------


async def test_rejected_manual_close_leaves_no_pending_order(tmp_path: Path):
    ex = FakeExchange("2000", "1970")
    db, engine = make_engine(tmp_path, ex, live=True)
    bot_id = db.create_bot("A", "dip", "ETH-EUR", {}, True, False)
    await engine.tick()  # live buy

    async def reject(*_, **__):
        raise RevolutXError(400, "insufficient funds")

    ex.place_market_order = reject
    with pytest.raises(RevolutXError):
        await engine.close_position(bot_id)
    bot = db.get_bot(bot_id)
    assert bot["state"].get("pending_order") is None  # a refused order is gone from the DB, not just from memory
    assert bot["state"]["position"]
    assert "insufficient funds" in render(bot["status"], "en")


async def test_reconciled_order_clears_backoff_and_error_status(tmp_path: Path):
    ex = FakeExchange("2000", "1970")
    ex.lose_next_response = True
    db, engine = make_engine(tmp_path, ex, live=True)
    bot_id = db.create_bot("A", "dip", "ETH-EUR", {"stop_loss": 1}, True, False)
    await engine.tick()  # response lost -> "order unclear", 5 min backoff
    assert db.get_bot(bot_id)["state"].get("retry_after")

    await engine.tick()  # found via client_order_id and booked
    bot = db.get_bot(bot_id)
    assert bot["state"]["position"] and not bot["state"].get("pending_order")
    assert not bot["state"].get("retry_after"), "the backoff must not outlive the reconciled order"
    assert "Error" not in render(bot["status"], "en")

    ex.price = Decimal("1900")  # -3.5 % -> stop-loss must fire right away, not after the old backoff
    await engine.tick()
    assert db.get_bot(bot_id)["state"]["position"] is None
    assert len(ex.placed) == 2


async def test_unreadable_response_is_treated_as_unclear_not_as_refused(tmp_path: Path):
    ex = FakeExchange("2000", "1970")
    db, engine = make_engine(tmp_path, ex, live=True)
    bot_id = db.create_bot("A", "dip", "ETH-EUR", {}, True, False)
    original = ex.place_market_order

    async def garbled(*args, **kwargs):
        await original(*args, **kwargs)  # the exchange did execute it …
        raise ValueError("Expecting value: line 1 column 1 (char 0)")  # … but the body was unreadable

    ex.place_market_order = garbled
    await engine.tick()
    bot = db.get_bot(bot_id)
    assert bot["state"]["pending_order"], "a ValueError must not be taken as 'order was not placed'"
    await engine.tick()  # looked up by client_order_id instead of being resent
    assert len(ex.placed) == 1
    assert db.get_bot(bot_id)["state"]["position"]


def test_definitely_not_placed_classification():
    assert definitely_not_placed(Problem("err.no_position"))
    assert definitely_not_placed(RevolutXError(400, "bad request"))
    assert not definitely_not_placed(RevolutXError(429, "slow down"))
    assert not definitely_not_placed(RevolutXError(502, "bad gateway"))
    assert not definitely_not_placed(ValueError("json"))
    assert not definitely_not_placed(httpx.ReadTimeout("timeout"))


async def test_order_not_found_after_grace_stops_the_bot(tmp_path: Path, monkeypatch):
    ex = FakeExchange("2000", "1970")
    ex.lose_next_response = True
    db, engine = make_engine(tmp_path, ex, live=True)
    bot_id = db.create_bot("A", "dip", "ETH-EUR", {}, True, False)
    await engine.tick()  # placed, response lost

    async def not_found(*_, **__):
        return None

    ex.find_order = not_found
    await engine.tick()  # within the grace period: keep waiting
    assert db.get_bot(bot_id)["state"]["pending_order"] and db.get_bot(bot_id)["enabled"]

    monkeypatch.setattr(engine_module, "ORDER_LOOKUP_GRACE_MS", -1)
    await engine.tick()
    bot = db.get_bot(bot_id)
    assert not bot["enabled"], "no guessing: the bot stops instead of possibly buying a second time"
    assert not bot["state"].get("pending_order") and not bot["state"].get("retry_after")
    assert "Bot gestoppt" in render(bot["status"], "de")
    assert db.list_events(bot_id)[0]["level"] == "error"
    await engine.tick()  # stopped bots are left alone
    assert len(ex.placed) == 1


async def test_unknown_order_id_after_grace_stops_the_bot(tmp_path: Path, monkeypatch):
    ex = FakeExchange("2000", "1970")
    db, engine = make_engine(tmp_path, ex, live=True)
    bot_id = db.create_bot("A", "dip", "ETH-EUR", {}, True, False)
    await engine.tick()
    bot = db.get_bot(bot_id)
    bot["state"]["pending_order"] = {"client_order_id": "c", "id": "gone", "side": "sell", "reason": "x",
                                     "placed_at": 0, "quote_size": None}
    db.update_bot(bot_id, state=bot["state"])

    async def missing(order_id):
        raise RevolutXError(404, "order not found")

    ex.get_order = missing
    await engine.tick()
    bot = db.get_bot(bot_id)
    assert not bot["enabled"] and not bot["state"].get("pending_order")


async def test_transient_errors_use_the_short_backoff(tmp_path: Path):
    ex = FakeExchange("2000", "1970")
    db, engine = make_engine(tmp_path, ex, live=True)
    bot_id = db.create_bot("A", "dip", "ETH-EUR", {}, True, False)

    async def flaky():
        raise httpx.ConnectError("connection reset")

    ex.balances = flaky
    await engine.tick()
    bot = db.get_bot(bot_id)
    wait = bot["state"]["retry_after"] - engine_module.now_ms()
    assert 0 < wait <= TRANSIENT_BACKOFF_MS < ERROR_BACKOFF_MS

    async def broken():
        raise Problem("err.unknown_pair", symbol="ETH-EUR")

    ex.balances = broken
    bot["state"].pop("retry_after")
    db.update_bot(bot_id, state=bot["state"])
    await engine.tick()
    wait = db.get_bot(bot_id)["state"]["retry_after"] - engine_module.now_ms()
    assert wait > TRANSIENT_BACKOFF_MS


async def test_savings_plan_closes_paper_position_when_going_live(tmp_path: Path):
    ex = FakeExchange("2000", "1970")
    db, engine = make_engine(tmp_path, ex, live=False)
    bot_id = db.create_bot("DCA", "dca", "ETH-EUR", {"interval_hours": 1, "take_profit": 0}, True, True)
    await engine.tick()  # simulated buy
    assert db.get_bot(bot_id)["state"]["position"]["paper"] is True

    db.set_setting("live_trading", True)
    db.update_bot(bot_id, paper=False)
    ex.now += 2 * HOUR  # next instalment is due
    await engine.tick()
    bot = db.get_bot(bot_id)
    trades = db.list_trades(bot_id)
    assert [(t["side"], bool(t["paper"])) for t in trades] == [("buy", False), ("sell", True), ("buy", True)]
    assert bot["state"]["position"]["paper"] is False
    assert len(ex.placed) == 1  # exactly one real order


async def test_stopped_bots_and_the_buy_lock_do_not_block_others(tmp_path: Path):
    ex = FakeExchange("2000", "1970")
    db, engine = make_engine(tmp_path, ex, live=True)
    db.set_limits({"max_open_positions": 0, "one_position_per_symbol": False})
    a = db.create_bot("A", "dip", "ETH-EUR", {}, True, False)
    b = db.create_bot("B", "dip", "ETH-EUR", {}, True, False)
    await engine.tick()
    assert all(db.get_bot(i)["state"]["position"] for i in (a, b))
    assert not engine._buy_lock.locked()


# --- market data -----------------------------------------------------------------------------


async def test_tickers_are_batched_and_candles_cached_across_ticks(tmp_path: Path):
    ex = CountingExchange("2000", "1990")
    db, engine = make_engine(tmp_path, ex)
    for sym in ("ETH-EUR", "BTC-EUR", "SOL-EUR"):
        db.create_bot(sym, "dip", sym, {}, True, True)
    await engine.tick()
    assert ex.batch_calls == 1 and ex.ticker_calls == 0
    assert ex.candle_calls == 3  # one 24 h series per symbol, shared by snapshot and strategy
    await engine.tick()
    await engine.tick()
    assert ex.batch_calls == 3
    assert ex.candle_calls == 3, "the same candle window is not fetched again within a candle interval"


async def test_candle_cache_refreshes_when_a_new_candle_starts():
    ex = CountingExchange("2000", "1990")
    cache = CandleCache()
    since, until = 50 * HOUR, 74 * HOUR
    first = await cache.fetch(ex, "ETH-EUR", 15, since, until)
    assert await cache.fetch(ex, "ETH-EUR", 15, since + 60_000, until + 60_000) is first
    later = await cache.fetch(ex, "ETH-EUR", 15, since + 15 * 60_000, until + 15 * 60_000)
    assert later is not first and ex.candle_calls == 2
    assert isinstance(later[0], Candle)


async def test_market_data_only_for_bots_that_need_it(tmp_path: Path):
    ex = CountingExchange("2000", "1990")
    db, engine = make_engine(tmp_path, ex)
    db.create_bot("stopped", "dip", "BTC-EUR", {}, False, True)
    active = db.create_bot("active", "dip", "ETH-EUR", {}, True, True)
    await engine.tick()
    assert "ETH-EUR" in engine.snapshots and "BTC-EUR" not in engine.snapshots
    # a stopped bot with a position still gets a price for its unrealised P&L
    db.update_bot(active, enabled=False, state={"position": {"qty": "1", "cost": "2000", "opened_at": 0, "peak": "2000"}})
    engine.snapshots.clear()
    await engine.tick()
    assert "ETH-EUR" in engine.snapshots


async def test_ticker_batch_failure_falls_back_to_single_requests(tmp_path: Path):
    ex = CountingExchange("2000", "1990")

    async def boom(symbols):
        raise RevolutXError(400, "unknown symbol")

    ex.tickers = boom
    db, engine = make_engine(tmp_path, ex)
    db.create_bot("A", "dip", "ETH-EUR", {}, True, True)
    await engine.tick()
    assert ex.ticker_calls == 1 and engine.exchange_error is None


async def test_state_is_only_written_when_it_changes(tmp_path: Path):
    ex = FakeExchange("2000", "1990")
    db, engine = make_engine(tmp_path, ex)
    bot_id = db.create_bot("A", "dip", "ETH-EUR", {}, True, True)
    await engine.tick()
    writes = []
    original = db.update_bot
    db.update_bot = lambda *a, **k: (writes.append(k), original(*a, **k))
    await engine.tick()  # same price, same status -> nothing to write
    assert writes == []
    stats = db.trade_stats()
    assert engine.describe_bot(db.get_bot(bot_id), stats)["last_check"] == engine._last_check[bot_id]


# --- exchange layer ----------------------------------------------------------------------------


def _client(handler) -> RevolutXClient:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    pem = Ed25519PrivateKey.generate().private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    )
    client = RevolutXClient("k" * 64, pem)
    client._http = httpx.AsyncClient(base_url="https://revx.test", transport=httpx.MockTransport(handler))
    return client


async def test_client_retries_idempotent_requests_only(monkeypatch):
    import asyncio

    async def no_sleep(_):
        return None

    monkeypatch.setattr(asyncio, "sleep", no_sleep)
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request.method)
        if len(calls) < 3:
            return httpx.Response(503, text="maintenance")
        return httpx.Response(200, json={"data": [{"symbol": "ETH/EUR", "last_price": "2000"}]})

    client = _client(handler)
    ex = RevolutXExchange(client)
    tickers = await ex.tickers(["ETH-EUR", "BTC-EUR"])
    assert calls == ["GET", "GET", "GET"] and tickers["ETH-EUR"].last == Decimal("2000")

    calls.clear()
    with pytest.raises(RevolutXError) as info:
        await client.place_market_order("ETH-EUR", "buy", quote_size="10")
    assert calls == ["POST"], "orders are never resent"
    assert info.value.status == 503 and info.value.transient


async def test_client_error_message_survives_odd_bodies():
    client = _client(lambda request: httpx.Response(400, json=["not", "a", "dict"]))
    with pytest.raises(RevolutXError) as info:
        await client.balances()
    assert info.value.status == 400 and '"not"' in info.value.message


async def test_pairs_keep_the_cached_list_when_the_refresh_fails():
    responses = iter([httpx.Response(200, json={"ETH/EUR": {
        "base": "ETH", "quote": "EUR", "base_step": "0.0001", "quote_step": "0.01",
        "min_order_size": "0.001", "min_order_size_quote": "1"}}), httpx.Response(500, text="down")])
    ex = RevolutXExchange(_client(lambda request: next(responses)))
    assert "ETH-EUR" in await ex.pairs()
    ex._pairs_at = 0  # cache expired
    assert "ETH-EUR" in await ex.pairs()


def test_params_reject_non_finite_numbers():
    amount = next(p for p in STRATEGIES["dip"].params if p.key == "amount")
    assert isinstance(amount, Param)
    assert amount.coerce(float("nan")) == amount.default
    assert amount.coerce("Infinity") == amount.default
    assert amount.coerce("75") == 75.0
