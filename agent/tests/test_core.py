import base64
from decimal import Decimal
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from app.config import Settings
from app.db import Database
from app.engine import Engine
from app.exchange import Candle, Exchange, MockExchange, OrderResult, PairInfo, Ticker
from app.i18n import render
from app.revolutx import RevolutXClient
from app.strategies import STRATEGIES, Buy, Context, MarketView, Position, Sell

HOUR = 3_600_000


class FakeExchange(Exchange):
    """Price was `ref` 24 h ago and is `price` now."""

    def __init__(self, ref: str, price: str):
        self.ref, self.price = Decimal(ref), Decimal(price)
        self.now = 100 * HOUR

    def now_ms(self):
        return self.now

    async def ticker(self, symbol):
        return Ticker(self.price, self.price, self.price)

    async def candles(self, symbol, interval, since, until):
        step = interval * 60_000
        return [Candle(t, self.ref, self.ref, self.ref, self.ref) for t in range(since - since % step, until, step)]

    async def pairs(self):
        return {
            s: PairInfo(s, s[:3], "EUR", Decimal("0.0000001"), Decimal("0.01"), Decimal("0.00001"), Decimal("1"))
            for s in ("ETH-EUR", "BTC-EUR", "SOL-EUR")
        }

    # --- live order simulation (for duplicate-protection tests) ---
    placed: list = []
    lose_next_response = False

    async def balances(self):
        return {c: (Decimal(10_000), Decimal(10_000)) for c in ("EUR", "ETH", "BTC", "SOL")}

    async def place_market_order(self, symbol, side, *, client_order_id, base_size=None, quote_size=None):
        self.placed = [*self.placed, client_order_id]
        oid = f"order-{len(self.placed)}"
        qty = quote_size / self.price if quote_size else base_size
        self.orders = {**getattr(self, "orders", {}), client_order_id: OrderResult(oid, "filled", qty, qty * self.price, self.price, Decimal(0), "EUR")}
        if self.lose_next_response:
            self.lose_next_response = False
            raise ConnectionError("timeout")
        return oid

    async def get_order(self, order_id):
        return next(o for o in self.orders.values() if o.order_id == order_id)

    async def find_order(self, symbol, client_order_id, since):
        return getattr(self, "orders", {}).get(client_order_id)


def ctx(ex, position=None, state=None, **params):
    s = STRATEGIES["dip"]
    view = MarketView(ex, "ETH-EUR", Ticker(ex.price, ex.price, ex.price), ex.now)
    return Context(s.normalize(params), position, state or {}, view)


@pytest.mark.asyncio
async def test_dip_buys_after_drop_and_sells_on_recovery():
    s = STRATEGIES["dip"]
    assert (await s.evaluate(ctx(FakeExchange("2000", "1990")))).action is None  # -0.5 %
    d = await s.evaluate(ctx(FakeExchange("2000", "1970")))  # -1.5 %
    assert isinstance(d.action, Buy) and d.action.quote_amount == Decimal("50.0")

    pos = Position(Decimal("0.025"), Decimal("50"), 0, Decimal("1970"))  # entry 2000
    # 24h change back to 0 %, but no profit -> hold
    assert (await s.evaluate(ctx(FakeExchange("2000", "2000"), pos))).action is None
    # change >= 0 and profit >= min_profit -> sell
    assert isinstance((await s.evaluate(ctx(FakeExchange("2000", "2010"), pos))).action, Sell)
    # stop loss
    d = await s.evaluate(ctx(FakeExchange("2000", "1800"), pos, stop_loss=5))
    assert isinstance(d.action, Sell)


@pytest.mark.asyncio
async def test_target_rules_never_sell_at_a_loss(tmp_path: Path):
    """A 2 € dip position: +0.33 % gross looks like a profit, but the cent-rounded sell fee makes it a loss."""
    ex = FakeExchange("2000", "1970")
    db, engine = make_engine(tmp_path, ex)
    bot_id = db.create_bot("Tiny", "dip", "ETH-EUR", {"amount": 2, "sell_mode": "profit", "take_profit": 0.1}, True, True)
    await engine.tick()
    position = db.get_bot(bot_id)["state"]["position"]
    assert position
    ex.price = Decimal("1976.5")  # +0.33 % gross ≥ target, but 0.01 € fee on a 2 € sale = 0.5 %
    await engine.tick()
    bot = db.get_bot(bot_id)
    assert bot["state"]["position"], bot["status"]
    assert "never sells at a loss" in render(bot["status"], "en")
    ex.price = Decimal("2000")  # +1.5 %: clearly above cost + fee
    await engine.tick()
    assert db.get_bot(bot_id)["state"]["position"] is None
    assert Decimal(db.list_trades(bot_id)[0]["pnl"]) > 0


@pytest.mark.asyncio
async def test_stop_loss_may_sell_at_a_loss(tmp_path: Path):
    ex = FakeExchange("2000", "1970")
    db, engine = make_engine(tmp_path, ex)
    bot_id = db.create_bot("Stop", "dip", "ETH-EUR", {"amount": 50, "stop_loss": 2}, True, True)
    await engine.tick()
    ex.price = Decimal("1900")  # −3.5 %
    await engine.tick()
    assert db.get_bot(bot_id)["state"]["position"] is None
    assert Decimal(db.list_trades(bot_id)[0]["pnl"]) < 0


@pytest.mark.asyncio
async def test_zones_wait_for_break_even_when_target_is_below_entry():
    s = STRATEGIES["zones"]
    ex = FakeExchange("2000", "1900")
    pos = Position(Decimal("0.025"), Decimal("50"), 0, Decimal("1900"))  # entry 2000
    view = MarketView(ex, "ETH-EUR", Ticker(ex.price, ex.price, ex.price), ex.now)
    c = Context(s.normalize({"buy_below": 1950, "sell_above": 1850}), pos, {}, view)
    d = await s.evaluate(c)  # target 1850 reached, but the position is at −5 %
    assert d.action is None and "below break-even" in render(d.status, "en")
    ex.price = Decimal("2010")
    view = MarketView(ex, "ETH-EUR", Ticker(ex.price, ex.price, ex.price), ex.now)
    d = await s.evaluate(Context(s.normalize({"buy_below": 1950, "sell_above": 1850}), pos, {}, view))
    assert isinstance(d.action, Sell)


@pytest.mark.asyncio
async def test_trailing_stop_never_below_break_even():
    s = STRATEGIES["trailing"]
    pos = Position(Decimal("0.025"), Decimal("50"), 0, Decimal("2030"))  # entry 2000, peak 2030 (+1.5 %)
    # trail 2 % from the peak would be 1989.4 – below the entry; the stop is lifted to break-even instead
    ex = FakeExchange("2000", "1995")
    view = MarketView(ex, "ETH-EUR", Ticker(ex.price, ex.price, ex.price), ex.now)
    d = await s.evaluate(Context(s.normalize({"activation": 1.5, "trail": 2}), pos, {}, view))
    assert isinstance(d.action, Sell)  # price below the lifted stop -> sell signal (the engine then checks the net)
    ex.price = Decimal("2020")
    view = MarketView(ex, "ETH-EUR", Ticker(ex.price, ex.price, ex.price), ex.now)
    d = await s.evaluate(Context(s.normalize({"activation": 1.5, "trail": 2}), pos, {}, view))
    assert d.action is None and "Trailing active" in render(d.status, "en")


@pytest.mark.asyncio
async def test_ai_strategy_buys_and_sells_on_claude_decision(tmp_path: Path, monkeypatch):
    from app.strategies.ai import AiDecision, AiStrategy

    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")
    strategy = STRATEGIES["ai"]
    assert isinstance(strategy, AiStrategy)
    answers: list[str] = []
    briefs = []

    async def fake_ask(brief, news):
        briefs.append(brief)
        return AiDecision(action=answers.pop(0), confidence=80, reason_en="test", reason_de="Test")

    monkeypatch.setattr(strategy, "ask", fake_ask)
    ex = FakeExchange("2000", "1970")
    db, engine = make_engine(tmp_path, ex)
    bot_id = db.create_bot("AI", "ai", "ETH-EUR", {"amount": 50, "ai_interval": 30}, True, True)

    answers.append("wait")
    await engine.tick()
    assert db.get_bot(bot_id)["state"].get("position") is None
    assert briefs[-1].position is None and "24h" in briefs[-1].changes
    # within the interval Claude is not asked again – the last answer is repeated
    await engine.tick()
    assert len(briefs) == 1 and "Claude waits" in render(db.get_bot(bot_id)["status"], "en")

    ex.now += 31 * 60_000
    answers.append("buy")
    await engine.tick()
    assert db.get_bot(bot_id)["state"]["position"], db.get_bot(bot_id)["status"]
    assert briefs[-1].position is None

    ex.now += 31 * 60_000
    ex.price = Decimal("2030")
    answers.append("hold")
    await engine.tick()
    assert db.get_bot(bot_id)["state"]["position"] and briefs[-1].position["profit_pct"] > 0
    assert "Claude holds" in render(db.get_bot(bot_id)["status"], "en")

    ex.now += 31 * 60_000
    answers.append("sell")
    await engine.tick()
    assert db.get_bot(bot_id)["state"].get("position") is None
    trades = db.list_trades(bot_id)
    assert [t["side"] for t in trades] == ["sell", "buy"] and "Claude (80 %" in render(trades[0]["reason"], "en")


@pytest.mark.asyncio
async def test_ai_strategy_without_key_does_nothing(tmp_path: Path, monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.delenv("ANTHROPIC_AUTH_TOKEN", raising=False)
    db, engine = make_engine(tmp_path, FakeExchange("2000", "1970"))
    bot_id = db.create_bot("AI", "ai", "ETH-EUR", {"amount": 50}, True, True)
    await engine.tick()
    bot = db.get_bot(bot_id)
    assert bot["state"].get("position") is None and "ANTHROPIC_API_KEY" in render(bot["status"], "en")


@pytest.mark.asyncio
async def test_ai_sell_at_a_loss_is_held_back(tmp_path: Path, monkeypatch):
    from app.strategies.ai import AiDecision

    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")
    answers = ["buy", "sell"]

    async def fake_ask(brief, news):
        return AiDecision(action=answers.pop(0), confidence=90, reason_en="x", reason_de="x")

    monkeypatch.setattr(STRATEGIES["ai"], "ask", fake_ask)
    ex = FakeExchange("2000", "1970")
    db, engine = make_engine(tmp_path, ex)
    bot_id = db.create_bot("AI", "ai", "ETH-EUR", {"amount": 50, "ai_interval": 5}, True, True)
    await engine.tick()
    assert db.get_bot(bot_id)["state"]["position"]
    ex.now += 6 * 60_000
    ex.price = Decimal("1950")  # under water: Claude's "sell" must not go through
    await engine.tick()
    bot = db.get_bot(bot_id)
    assert bot["state"]["position"] and "never sells at a loss" in render(bot["status"], "en")


def test_min_profit_cannot_be_negative():
    assert STRATEGIES["dip"].normalize({"min_profit": -1})["min_profit"] == 0


def test_signature_matches_revolut_spec():
    key = Ed25519PrivateKey.generate()
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    client = RevolutXClient("k" * 64, pem)
    sig = client._sign("1765360896219", "GET", "/api/1.0/orders/active", "limit=10", "")
    key.public_key().verify(base64.b64decode(sig), b"1765360896219GET/api/1.0/orders/activelimit=10")


@pytest.mark.asyncio
async def test_engine_paper_roundtrip(tmp_path: Path):
    settings = Settings(tmp_path, "t", "mock", "", tmp_path / "x", "", 30, Decimal("0.0009"), 1)
    db = Database(settings.db_path)
    ex = FakeExchange("2000", "1970")
    engine = Engine(db, ex, settings)
    bot_id = db.create_bot("ETH Dip", "dip", "ETH-EUR", {"amount": 100}, True, True)

    await engine.tick()
    bot = db.get_bot(bot_id)
    assert bot["state"]["position"], bot["status"]
    ex.price = Decimal("2030")
    await engine.tick()
    bot = db.get_bot(bot_id)
    assert bot["state"]["position"] is None, bot["status"]
    trades = db.list_trades(bot_id)
    assert [t["side"] for t in trades] == ["sell", "buy"]
    assert Decimal(trades[0]["pnl"]) > 0
    assert engine.summary()["currencies"][0]["realized"] > 0


@pytest.mark.asyncio
async def test_mock_exchange_live_order_flow(tmp_path: Path):
    settings = Settings(tmp_path, "t", "mock", "", tmp_path / "x", "", 30, Decimal("0.0009"), 1)
    db = Database(settings.db_path)
    db.set_setting("live_trading", True)
    ex = MockExchange(Decimal("0.0009"))
    engine = Engine(db, ex, settings)
    bot_id = db.create_bot("DCA", "dca", "BTC-EUR", {"amount": 25}, True, False)
    await engine.tick()
    assert db.get_bot(bot_id)["state"]["position"]
    await engine.close_position(bot_id)
    assert db.get_bot(bot_id)["state"]["position"] is None
    assert len(db.list_trades(bot_id)) == 2


def make_engine(tmp_path, ex, live=False):
    settings = Settings(tmp_path, "t", "mock", "", tmp_path / "x", "", 30, Decimal("0.0009"), 1)
    db = Database(settings.db_path)
    db.set_setting("live_trading", live)
    return db, Engine(db, ex, settings)


def open_positions(db):
    return sum(1 for b in db.list_bots() if b["state"].get("position"))


async def test_max_open_positions_limit(tmp_path: Path):
    ex = FakeExchange("2000", "1970")
    db, engine = make_engine(tmp_path, ex)
    db.set_limits({"max_open_positions": 2})
    for sym in ("ETH-EUR", "BTC-EUR", "SOL-EUR"):
        db.create_bot(sym, "dip", sym, {}, True, True)
    await engine.tick()
    await engine.tick()
    assert open_positions(db) == 2
    blocked = [b for b in db.list_bots() if not b["state"].get("position")][0]
    assert "Limit erreicht: 2/2" in render(blocked["status"], "de")
    assert "Limit reached: 2/2" in render(blocked["status"], "en")


async def test_one_position_per_symbol(tmp_path: Path):
    ex = FakeExchange("2000", "1970")
    db, engine = make_engine(tmp_path, ex)
    db.set_limits({"max_open_positions": 0, "one_position_per_symbol": True})
    db.create_bot("A", "dip", "ETH-EUR", {}, True, True)
    db.create_bot("B", "trailing", "ETH-EUR", {"drop_percent": 0.5}, True, True)
    await engine.tick()
    assert open_positions(db) == 1
    db.set_limits({"one_position_per_symbol": False})
    await engine.tick()
    assert open_positions(db) == 2


async def test_capital_limit(tmp_path: Path):
    ex = FakeExchange("2000", "1970")
    db, engine = make_engine(tmp_path, ex)
    db.set_limits({"max_open_positions": 0, "max_total_invested": 120})
    db.create_bot("A", "dip", "ETH-EUR", {"amount": 100}, True, True)
    db.create_bot("B", "dip", "BTC-EUR", {"amount": 100}, True, True)
    await engine.tick()
    assert open_positions(db) == 1
    assert len(db.list_trades()) == 1


async def test_no_second_buy_while_position_open(tmp_path: Path):
    ex = FakeExchange("2000", "1970")
    db, engine = make_engine(tmp_path, ex)
    bot_id = db.create_bot("A", "dip", "ETH-EUR", {}, True, True)
    for _ in range(5):
        await engine.tick()
    assert len(db.list_trades(bot_id)) == 1
    # engine guard, even if a strategy asked for another buy
    bot = db.get_bot(bot_id)
    status = await engine._buy(bot, bot["state"], None, Decimal(50), "test")
    assert "kein zweiter Kauf" in render(status, "de")
    assert len(db.list_trades(bot_id)) == 1


async def test_lost_order_response_is_not_resent(tmp_path: Path):
    ex = FakeExchange("2000", "1970")
    ex.lose_next_response = True
    db, engine = make_engine(tmp_path, ex, live=True)
    bot_id = db.create_bot("A", "dip", "ETH-EUR", {}, True, False)

    await engine.tick()  # order placed, response lost
    bot = db.get_bot(bot_id)
    assert bot["state"]["pending_order"] and not bot["state"].get("position")
    assert "unklar" in render(bot["status"], "de")

    await engine.tick()  # reconciled via client_order_id instead of sending a new order
    await engine.tick()
    bot = db.get_bot(bot_id)
    assert len(ex.placed) == 1
    assert bot["state"].get("position") and not bot["state"].get("pending_order")
    assert len(db.list_trades(bot_id)) == 1


async def test_only_one_engine_per_data_dir(tmp_path: Path):
    ex = FakeExchange("2000", "1970")
    _, first = make_engine(tmp_path, ex)
    _, second = make_engine(tmp_path, ex)
    assert first._acquire_instance_lock()
    assert not second._acquire_instance_lock()
    assert second.instance_error
    await second.run()  # returns immediately instead of trading


async def test_live_position_is_sold_live_after_switching_live_off(tmp_path: Path):
    ex = FakeExchange("2000", "1970")
    db, engine = make_engine(tmp_path, ex, live=True)
    bot_id = db.create_bot("A", "dip", "ETH-EUR", {}, True, False)
    await engine.tick()
    assert db.get_bot(bot_id)["state"]["position"]["paper"] is False
    assert len(ex.placed) == 1

    db.set_setting("live_trading", False)  # user switches live trading off
    ex.price = Decimal("2030")
    await engine.tick()
    assert len(ex.placed) == 2  # real sell order – the real coins are not left behind
    sell = db.list_trades(bot_id)[0]
    assert sell["side"] == "sell" and not sell["paper"]


async def test_no_paper_buy_into_live_position(tmp_path: Path):
    ex = FakeExchange("2000", "1970")
    db, engine = make_engine(tmp_path, ex, live=True)
    bot_id = db.create_bot("DCA", "dca", "ETH-EUR", {"interval_hours": 1}, True, False)
    await engine.tick()
    db.set_setting("live_trading", False)
    bot = db.get_bot(bot_id)
    status = await engine._buy(bot, bot["state"], None, Decimal(25), "Rate")
    assert "Modus wurde geändert" in render(status, "de")
    assert len(db.list_trades(bot_id)) == 1


async def test_switching_to_paper_sells_all_live_positions(tmp_path: Path):
    ex = FakeExchange("2000", "1970")
    db, engine = make_engine(tmp_path, ex, live=True)
    db.set_limits({"max_open_positions": 0, "one_position_per_symbol": False})
    live_a = db.create_bot("A", "dip", "ETH-EUR", {}, True, False)
    live_b = db.create_bot("B", "dip", "BTC-EUR", {}, True, False)
    paper = db.create_bot("P", "dip", "SOL-EUR", {}, True, True)
    await engine.tick()
    assert all(db.get_bot(i)["state"].get("position") for i in (live_a, live_b, paper))

    db.set_setting("live_trading", False)
    results = await engine.close_live_positions("Live-Handel beendet")
    assert sorted(r["bot_name"] for r in results) == ["A", "B"] and all(r["ok"] for r in results)
    assert db.get_bot(live_a)["state"]["position"] is None
    assert db.get_bot(live_b)["state"]["position"] is None
    assert db.get_bot(paper)["state"]["position"]  # simulated positions are not touched
    assert len(ex.placed) == 4  # 2 live buys + 2 live sells
