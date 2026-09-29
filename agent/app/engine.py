"""Bot engine: evaluates every enabled bot periodically and executes its orders.

All texts produced here (statuses, events, trade reasons) are i18n messages (see ``app.i18n``) that are
rendered in the app's language when they are read.
"""

from __future__ import annotations

import asyncio
import fcntl
import json
import logging
import uuid
from collections import defaultdict
from contextlib import asynccontextmanager
from datetime import datetime
from decimal import ROUND_DOWN, Decimal
from typing import Any

import httpx

from .config import Settings
from .db import Database, now_ms
from .exchange import Candle, Exchange, OrderResult, PairInfo, Ticker
from .i18n import Problem, as_message, dump, m, message_key, money, qty, render
from .revolutx import RevolutXError
from .strategies import STRATEGIES, Buy, Context, MarketView, Position, Sell

log = logging.getLogger("dipagent.engine")

# market orders usually fill within a second – poll quickly first, then back off (≈ 8 s in total)
ORDER_POLL_DELAYS = (0.3, 0.5, 0.7, 1.0, 1.0, 1.5, 1.5, 1.5)
ERROR_BACKOFF_MS = 5 * 60_000
# network hiccups and exchange-side errors clear up quickly – don't sit out a dip for 5 minutes because of one
TRANSIENT_BACKOFF_MS = 60_000
# an order whose placement response got lost and that can't be found at the exchange after this long stops the bot
ORDER_LOOKUP_GRACE_MS = 3 * 60_000
# a "filled" order whose reported fill is still short of what we asked for: re-read it for this long
FILL_CHECK_MS = 15 * 60_000
# how many symbols are fetched from the exchange concurrently during a tick
MARKET_DATA_CONCURRENCY = 4
# candles are re-fetched when a new candle starts or after this long, not on every tick
CANDLE_CACHE_MS = 5 * 60_000

Message = dict | str


def round_down(value: Decimal, step: Decimal) -> Decimal:
    if step <= 0:
        return value
    return (value / step).to_integral_value(rounding=ROUND_DOWN) * step


def split_symbol(symbol: str) -> tuple[str, str]:
    base, _, quote = symbol.partition("-")
    return base, quote


def bot_has_live_position(bot: dict[str, Any] | None) -> bool:
    position = Position.from_state(bot["state"].get("position")) if bot else None
    return bool(position and not position.paper)


def definitely_not_placed(exc: Exception) -> bool:
    """True only if the exchange clearly refused the order.

    Everything else (timeouts, 5xx, an unreadable response – note that a JSON decoding error is a ``ValueError``)
    means the order *may* have gone through and must be looked up instead of being sent again.
    """
    return isinstance(exc, Problem) or (isinstance(exc, RevolutXError) and not exc.transient)


def is_transient(exc: Exception) -> bool:
    """Network or exchange-side trouble that usually clears up by itself."""
    return isinstance(exc, (httpx.HTTPError, ConnectionError, TimeoutError)) or (
        isinstance(exc, RevolutXError) and exc.transient
    )


def short_fill(pending: dict, r: OrderResult) -> bool:
    """A terminal order whose reported fill is smaller than what we asked for. Revolut X can report "filled" a
    moment before the fill data is complete; booking that would leave part of the position unbooked."""
    if r.status != "filled":
        return False
    if pending.get("base_size"):
        return r.filled_qty < Decimal(pending["base_size"])
    if pending.get("quote_size"):
        return r.filled_amount < Decimal(pending["quote_size"]) * Decimal("0.98")
    return False


def backoff_for(exc: Exception) -> int:
    return TRANSIENT_BACKOFF_MS if is_transient(exc) else ERROR_BACKOFF_MS


class CandleCache:
    """Candles per (symbol, interval, window), shared by all bots and kept across ticks.

    The set of candles only changes when a new candle starts; in between only the forming candle moves, which is
    covered by the live ticker price the strategies use anyway. Re-fetched at the latest after ``CANDLE_CACHE_MS``.
    """

    def __init__(self) -> None:
        self._entries: dict[tuple[str, int, int], tuple[int, int, list[Candle]]] = {}

    def clear(self) -> None:
        self._entries.clear()

    async def fetch(self, exchange: Exchange, symbol: str, interval: int, since: int, until: int) -> list[Candle]:
        key = (symbol, interval, until - since)
        bucket = until // (interval * 60_000)
        entry = self._entries.get(key)
        if entry and entry[0] == bucket and now_ms() - entry[1] < CANDLE_CACHE_MS:
            return entry[2]
        candles = await exchange.candles(symbol, interval, since, until)
        self._entries[key] = (bucket, now_ms(), candles)
        return candles


class Engine:
    def __init__(self, db: Database, exchange: Exchange, settings: Settings):
        self.db = db
        self.exchange = exchange
        self.settings = settings
        self.snapshots: dict[str, dict[str, Any]] = {}
        self.last_tick: int | None = None
        self.exchange_error: Message | None = None
        self.instance_error: Message | None = None
        self._wake = asyncio.Event()
        self._locks: dict[int, asyncio.Lock] = defaultdict(asyncio.Lock)
        # serialises "check limits + place buy" across all bots so limits can't be overrun concurrently
        self._buy_lock = asyncio.Lock()
        # held while a tick runs – lets an exchange swap wait until in-flight requests are done
        self._tick_lock = asyncio.Lock()
        self._instance_lock_file = None
        self._candles = CandleCache()
        # last evaluation per bot; only persisted together with a state/status change (saves a write per tick)
        self._last_check: dict[int, int] = {}
        self._background: set[asyncio.Task] = set()

    # --- loop -------------------------------------------------------------

    def _acquire_instance_lock(self) -> bool:
        """Only one engine may trade per data directory (protects against a 2nd container/worker)."""
        self._instance_lock_file = open(self.settings.data_dir / "engine.lock", "w")  # noqa: SIM115
        try:
            fcntl.flock(self._instance_lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            self.instance_error = m("engine.instance_locked")
            log.error(render(self.instance_error, "en"))
            return False

    async def run(self) -> None:
        if not self._acquire_instance_lock():
            return
        log.info("Engine started (exchange: %s, interval: %ss)", self.exchange.name, self.settings.tick_seconds)
        while True:
            try:
                async with self._tick_lock:
                    await self.tick()
            except Exception:  # noqa: BLE001 - the loop must never die
                log.exception("Tick failed")
            try:
                await asyncio.wait_for(self._wake.wait(), timeout=self.settings.tick_seconds)
            except asyncio.TimeoutError:
                pass
            self._wake.clear()

    def wake(self) -> None:
        self._wake.set()

    def replace_exchange(self, new: Exchange) -> None:
        """Switch to new credentials without a restart. The old client is closed once the running tick is done."""
        old = self.exchange
        self.exchange = new
        self.exchange_error = None
        self._candles.clear()
        self.wake()

        async def close_old() -> None:
            async with self._tick_lock:
                await old.close()

        task = asyncio.create_task(close_old())
        self._background.add(task)
        task.add_done_callback(self._background.discard)

    @asynccontextmanager
    async def paused(self):
        """No tick runs while the body executes (used to swap the database during a restore)."""
        async with self._tick_lock:
            yield

    def reset_caches(self) -> None:
        """Forget everything derived from the old database (after a restore)."""
        self._last_check.clear()
        self._candles.clear()
        self.exchange_error = None

    async def shutdown(self) -> None:
        for task in list(self._background):
            task.cancel()
        await self.exchange.close()

    def live_trading_enabled(self) -> bool:
        """Global switch, off by default; only the app can turn it on (with double confirmation)."""
        return bool(self.db.get_setting("live_trading", False))

    def is_paper(self, bot: dict[str, Any]) -> bool:
        """Mode for *new* buys. Open positions keep the mode they were bought with."""
        return bot["paper"] or not self.live_trading_enabled()

    async def _fetch_candles(self, symbol: str, interval: int, since: int, until: int) -> list[Candle]:
        return await self._candles.fetch(self.exchange, symbol, interval, since, until)

    async def market_view(self, symbol: str, ticker: Ticker | None = None) -> MarketView:
        if ticker is None:
            ticker = await self.exchange.ticker(symbol)
        view = MarketView(self.exchange, symbol, ticker, self.exchange.now_ms(), fetch=self._fetch_candles)
        self.snapshots[symbol] = {
            "price": float(view.price),
            "bid": float(view.bid),
            "ask": float(view.ask),
            "change_24h": await view.change_pct(24),
            "updated_at": now_ms(),
        }
        return view

    async def _market_views(self, symbols: list[str]) -> tuple[dict[str, MarketView], dict[str, Message]]:
        """Ticker for all symbols in one request (where supported), candles concurrently."""
        views: dict[str, MarketView] = {}
        errors: dict[str, Message] = {}
        if not symbols:
            return views, errors
        try:
            tickers = await self.exchange.tickers(symbols)
        except Exception as exc:  # noqa: BLE001 – fall back to one request per symbol below
            log.warning("Ticker batch failed: %s", exc)
            tickers = {}
        semaphore = asyncio.Semaphore(MARKET_DATA_CONCURRENCY)

        async def build(symbol: str) -> None:
            async with semaphore:
                try:
                    views[symbol] = await self.market_view(symbol, tickers.get(symbol))
                except Exception as exc:  # noqa: BLE001
                    log.warning("Market data for %s failed: %s", symbol, exc)
                    errors[symbol] = as_message(exc)

        await asyncio.gather(*(build(symbol) for symbol in symbols))
        return views, errors

    async def tick(self) -> None:
        bots = self.db.list_bots()
        # stopped bots still need a price while they hold a position (unrealised P&L) or an order is in flight
        relevant = [b for b in bots if b["enabled"] or b["state"].get("position") or b["state"].get("pending_order")]
        views, errors = await self._market_views(sorted({b["symbol"] for b in relevant}))
        self.exchange_error = next(iter(errors.values()), None)
        self.last_tick = now_ms()

        for bot in bots:
            if not bot["enabled"]:
                continue
            view = views.get(bot["symbol"])
            if view is None:
                status = m("engine.no_market_data", error=errors.get(bot["symbol"], "?"))
                async with self._locks[bot["id"]]:
                    if current := self.db.get_bot(bot["id"]):  # re-read: the API may have changed it meanwhile
                        self._persist(current, current["state"], status, self._snapshot(current))
                continue
            await self.process(bot["id"], view)

    # --- per bot ------------------------------------------------------------

    @staticmethod
    def _snapshot(bot: dict[str, Any]) -> tuple[str, Any]:
        """What is in the database right now – ``_persist`` only writes when state/status differ from it."""
        return json.dumps(bot["state"]), dump(bot["status"])

    def _persist(self, bot: dict[str, Any], state: dict[str, Any], status: Message, before: tuple[str, Any]) -> None:
        """Write state/status back – only when something changed (the check time alone is kept in memory)."""
        self._last_check[bot["id"]] = now_ms()
        if (json.dumps(state), dump(status)) == before:
            return
        self.db.update_bot(bot["id"], state=state, status=status, last_check=self._last_check[bot["id"]])

    async def process(self, bot_id: int, view: MarketView) -> None:
        async with self._locks[bot_id]:
            bot = self.db.get_bot(bot_id)
            if not bot or not bot["enabled"]:
                return
            before = self._snapshot(bot)
            state = bot["state"]
            status: Message = bot["status"]
            try:
                if state.get("pending_order"):
                    status = await self._reconcile(bot, state) or status
                    if state.get("pending_order"):
                        status = m("engine.waiting_for_order")
                        return
                    if not bot["enabled"]:  # stopped by the reconciliation – needs a human look
                        return
                if int(state.get("retry_after") or 0) > now_ms():
                    return
                if state.get("fill_check") or self._sold_but_still_open(bot, state):
                    status = await self._complete_fill(bot, state) or status
                status = await self._evaluate(bot, state, view)
                state.pop("retry_after", None)
            except Exception as exc:  # noqa: BLE001
                log.warning("Bot %s: %s", bot["name"], exc)
                self.db.add_event(bot_id, "error", as_message(exc))
                status = m("engine.error", error=as_message(exc))
                state["retry_after"] = now_ms() + backoff_for(exc)
            finally:
                self._persist(bot, state, status, before)

    async def _evaluate(self, bot: dict[str, Any], state: dict[str, Any], view: MarketView) -> Message:
        strategy = STRATEGIES.get(bot["strategy"])
        if strategy is None:
            return m("engine.unknown_strategy", strategy=bot["strategy"])
        position = Position.from_state(state.get("position"))
        if position and view.price > position.peak:
            position.peak = view.price
            state["position"] = position.to_state()

        _, quote = split_symbol(bot["symbol"])
        ctx = Context(strategy.normalize(bot["params"]), position, state, view, quote, float(self.settings.taker_fee))
        decision = await strategy.evaluate(ctx)

        if isinstance(decision.action, Buy):
            return await self._buy(bot, state, view, decision.action.quote_amount, decision.action.reason)
        if isinstance(decision.action, Sell) and position:
            # Safety net: a target rule never sells at a loss. Fees, cent rounding and the sell fee are included –
            # strategies compare the gross profit, which a 2 € order can lose to a fee rounded up to 0.01.
            net = position.net_proceeds(view.bid, float(self.settings.taker_fee), quote)
            if not decision.action.stop and net < position.cost:
                return m("engine.hold_no_loss", net=money(net, quote), cost=money(position.cost, quote))
            return await self._sell(bot, state, view, decision.action.reason)
        return decision.status

    async def close_position(self, bot_id: int, reason: Message | None = None) -> Message:
        bot = self.db.get_bot(bot_id)
        if not bot:
            raise KeyError(bot_id)
        view = await self.market_view(bot["symbol"])
        async with self._locks[bot_id]:
            bot = self.db.get_bot(bot_id)
            if not bot:
                raise KeyError(bot_id)
            state = bot["state"]
            if not state.get("position"):
                raise Problem("err.no_position")
            if state.get("pending_order"):
                raise Problem("err.order_running")
            before = self._snapshot(bot)
            status: Message = bot["status"]
            try:
                status = await self._sell(bot, state, view, reason or m("engine.manual_close"))
            except Exception as exc:
                status = m("engine.error", error=as_message(exc))
                raise
            finally:
                # always write the state back: a rejected order must not leave a pending order behind
                self._persist(bot, state, status, before)
            return status

    async def close_live_positions(self, reason: Message) -> list[dict[str, Any]]:
        """Market-sell every open live position (used when switching back to paper mode)."""
        results = []
        for bot in self.db.list_bots():
            if not bot_has_live_position(bot):
                continue
            try:
                message = await self.close_position(bot["id"], reason)
                ok = not bot_has_live_position(self.db.get_bot(bot["id"]))
            except Exception as exc:  # noqa: BLE001 – report per bot, keep closing the others
                message, ok = as_message(exc), False
                self.db.add_event(bot["id"], "error", m("engine.live_close_failed", error=as_message(exc)))
            results.append({"bot_id": bot["id"], "bot_name": bot["name"], "ok": ok, "message": message})
        return results

    # --- limits -------------------------------------------------------------------

    def exposure(self, exclude_bot_id: int | None = None) -> tuple[int, Decimal, set[str]]:
        """Open positions (incl. buy orders in flight), invested capital and busy symbols of all bots."""
        count, invested, symbols = 0, Decimal(0), set()
        for b in self.db.list_bots():
            if b["id"] == exclude_bot_id:
                continue
            position = b["state"].get("position")
            pending = b["state"].get("pending_order") or {}
            if position or pending.get("side") == "buy":
                count += 1
                symbols.add(b["symbol"])
                invested += Decimal(position["cost"]) if position else Decimal(pending.get("quote_size") or 0)
        return count, invested, symbols

    def _limit_violation(self, bot: dict, state: dict, quote_size: Decimal) -> dict | None:
        limits = self.db.get_limits()
        count, invested, symbols = self.exposure(exclude_bot_id=bot["id"])
        position = state.get("position")
        if not position:  # this buy would open a new position
            max_positions = int(limits["max_open_positions"])
            if max_positions > 0 and count >= max_positions:
                return m("limit.positions", count=count, max=max_positions)
            if limits["one_position_per_symbol"] and bot["symbol"] in symbols:
                return m("limit.symbol", symbol=bot["symbol"])
        max_invested = Decimal(str(limits["max_total_invested"]))
        own = Decimal(position["cost"]) if position else Decimal(0)
        if max_invested > 0 and invested + own + quote_size > max_invested:
            _, quote = split_symbol(bot["symbol"])
            return m("limit.capital", invested=money(invested + own, quote), max=money(max_invested, quote))
        return None

    # --- order execution ------------------------------------------------------

    async def _buy(self, bot: dict, state: dict, view: MarketView, amount: Decimal, reason: Message) -> Message:
        strategy = STRATEGIES[bot["strategy"]]
        if state.get("pending_order"):
            return m("engine.order_running_no_buy")
        if state.get("position") and not strategy.accumulates:
            return m("engine.position_open_no_buy")
        open_position = Position.from_state(state.get("position"))
        if open_position and open_position.paper != self.is_paper(bot):
            if not (open_position.paper and strategy.accumulates):
                return m("engine.mode_changed_paper" if open_position.paper else "engine.mode_changed_live")
            # a savings plan would otherwise never buy again (and without a profit target never sell): close the
            # simulated position the simulated way and carry on live – real coins are never "sold" on paper
            pair = await self.exchange.pair(bot["symbol"])
            price = view.bid
            gross = open_position.qty * price
            fee = gross * self.settings.taker_fee
            self._record_sell(bot, state, pair, open_position.qty, gross - fee, price, fee, None, True,
                              m("engine.mode_changed_close"))
        pair = await self.exchange.pair(bot["symbol"])
        quote_size = round_down(amount, pair.quote_step)
        if quote_size < pair.min_order_size_quote:
            raise Problem("err.amount_below_min", amount=money(quote_size, pair.quote),
                          min=money(pair.min_order_size_quote, pair.quote))

        async with self._buy_lock:
            blocked = self._limit_violation(bot, state, quote_size)
            if blocked:
                status = m("engine.buy_skipped", reason=blocked)
                if render(bot["status"], "en") != render(status, "en"):  # log once, not every tick
                    self.db.add_event(bot["id"], "info", m("paren", text=status, detail=reason))
                return status

            if self.is_paper(bot):
                price = view.ask
                fee = quote_size * self.settings.taker_fee
                bought = (quote_size - fee) / price
                return self._record_buy(bot, state, pair, bought, quote_size, price, fee, None, True, reason)

            balances = await self.exchange.balances()
            available = balances.get(pair.quote, (Decimal(0), Decimal(0)))[0]
            if available < quote_size:
                raise Problem("err.insufficient", currency=pair.quote, available=money(available, pair.quote),
                              needed=money(quote_size, pair.quote))
            pending = await self._submit_order(bot, state, "buy", reason, quote_size=quote_size)
        # the pending order already counts towards the limits – don't hold up other bots while it fills
        return await self._track_order(bot, state, pair, pending)

    async def _sell(self, bot: dict, state: dict, view: MarketView, reason: Message) -> Message:
        position = Position.from_state(state.get("position"))
        if position is None:
            return m("engine.no_position")
        pair = await self.exchange.pair(bot["symbol"])
        amount = position.qty

        if position.paper:  # sell the way it was bought – never "simulate" selling real coins
            price = view.bid
            gross = amount * price
            fee = gross * self.settings.taker_fee
            return self._record_sell(bot, state, pair, amount, gross - fee, price, fee, None, True, reason)

        balances = await self.exchange.balances()
        available = balances.get(pair.base, (Decimal(0), Decimal(0)))[0]
        amount = round_down(min(amount, available), pair.base_step)
        if amount <= 0 or amount < pair.min_order_size:
            raise Problem("err.sell_below_min", qty=qty(amount), base=pair.base,
                          min=qty(pair.min_order_size), available=qty(available))
        pending = await self._submit_order(bot, state, "sell", reason, base_size=amount)
        return await self._track_order(bot, state, pair, pending)

    async def _submit_order(
        self, bot: dict, state: dict, side: str, reason: Message,
        *, base_size: Decimal | None = None, quote_size: Decimal | None = None,
    ) -> dict:
        """Place a market order exactly once.

        The pending order (with our own client_order_id) is persisted *before* it is sent. If the response
        gets lost, the next tick looks the order up by that id instead of sending a second one.
        """
        pending = {
            "client_order_id": str(uuid.uuid4()),
            "id": None,
            "side": side,
            "reason": reason,
            "placed_at": now_ms(),
            "quote_size": str(quote_size) if quote_size is not None else None,
            "base_size": str(base_size) if base_size is not None else None,
        }
        state["pending_order"] = pending
        self.db.update_bot(bot["id"], state=state)
        try:
            pending["id"] = await self.exchange.place_market_order(
                bot["symbol"], side, client_order_id=pending["client_order_id"],
                base_size=base_size, quote_size=quote_size,
            )
        except Exception as exc:
            if definitely_not_placed(exc):
                state.pop("pending_order", None)
                raise
            raise Problem("err.order_unclear", error=as_message(exc)) from exc
        self.db.update_bot(bot["id"], state=state)
        self.db.add_event(bot["id"], "info", m("engine.order_sent", id=pending["id"], side=m(f"side.{side}")))
        return pending

    async def _track_order(self, bot: dict, state: dict, pair: PairInfo, pending: dict) -> Message:
        result = None
        for delay in ORDER_POLL_DELAYS:
            await asyncio.sleep(delay)
            result = await self.exchange.get_order(pending["id"])
            if result.terminal and not short_fill(pending, result):
                return self._apply_order(bot, state, pair, pending, result)
        if result is not None and result.terminal:
            # Revolut X reported "filled" but the fill data still lags behind the order size – book what is
            # there and keep re-reading the order (see _complete_fill) so the rest is booked as well
            return self._apply_order(bot, state, pair, pending, result)
        return m("engine.waiting_for_order")

    async def _reconcile(self, bot: dict, state: dict) -> Message | None:
        """Finish a pending order. Returns the new status once the order is settled, else None."""
        pending = state["pending_order"]
        pair = await self.exchange.pair(bot["symbol"])
        overdue = now_ms() - pending["placed_at"] > ORDER_LOOKUP_GRACE_MS
        if not pending.get("id"):
            found = await self.exchange.find_order(bot["symbol"], pending["client_order_id"], pending["placed_at"] - 60_000)
            if found is None:
                return self._abandon_order(bot, state, pending) if overdue else None
            pending["id"] = found.order_id
            self.db.update_bot(bot["id"], state=state)
            result = found
        else:
            try:
                result = await self.exchange.get_order(pending["id"])
            except RevolutXError as exc:
                if exc.status == 404 and overdue:  # the exchange doesn't know the id (any more)
                    return self._abandon_order(bot, state, pending)
                raise
        if result.terminal and (not short_fill(pending, result) or overdue):
            return self._apply_order(bot, state, pair, pending, result)
        return None

    def _sold_but_still_open(self, bot: dict, state: dict) -> bool:
        """A position that survived a live sell: sells always close the whole position, so the exchange must have
        reported the fill short (seen on Revolut X right after placing) – re-read that order."""
        position = state.get("position")
        if not position or position.get("paper"):
            return False
        last = next(iter(self.db.list_trades(bot["id"], 1)), None)
        if not last or last["side"] != "sell" or not last["order_id"] or last["paper"]:
            return False
        if last["created_at"] < int(position.get("opened_at") or 0):
            return False
        order_id = last["order_id"].split("#")[0]
        if state.get("fill_checked") == order_id:  # already re-read to the end
            return False
        state["fill_check"] = {"order_id": order_id, "side": "sell", "until": last["created_at"] + FILL_CHECK_MS}
        return True

    async def _complete_fill(self, bot: dict, state: dict) -> Message | None:
        """Re-read a short-filled order and book what the exchange executed on top of what we booked."""
        check = state["fill_check"]
        order_id = check["order_id"]
        try:
            r = await self.exchange.get_order(order_id)
        except RevolutXError as exc:
            if exc.status == 404:
                state.pop("fill_check", None)
                state["fill_checked"] = order_id
            return None
        pair = await self.exchange.pair(bot["symbol"])
        booked = self.db.booked_for_order(order_id)
        fee_base = r.fee if r.fee_currency == pair.base else Decimal(0)
        fee_quote = r.fee if r.fee_currency == pair.quote else Decimal(0)
        fee_in_quote = fee_quote + fee_base * r.avg_price
        if check["side"] == "sell":
            qty_total, amount_total = r.filled_qty + fee_base, r.filled_amount - fee_quote
        else:
            qty_total, amount_total = r.filled_qty - fee_base, r.filled_amount + fee_quote
        more_qty = qty_total - Decimal(str(booked["qty"]))
        status: Message | None = None
        if more_qty >= pair.base_step:
            more_amount = amount_total - Decimal(str(booked["amount"]))
            more_fee = max(fee_in_quote - Decimal(str(booked["fee"])), Decimal(0))
            late_id = f"{order_id}#{int(booked['n']) + 1}"
            reason = m("engine.late_fill", id=order_id)
            if check["side"] == "sell" and state.get("position"):
                status = self._record_sell(bot, state, pair, more_qty, more_amount, r.avg_price, more_fee, late_id, False, reason)
            elif check["side"] == "buy":
                status = self._record_buy(bot, state, pair, more_qty, more_amount, r.avg_price, more_fee, late_id, False, reason)
            self.db.add_event(bot["id"], "info", m("engine.late_fill_booked", id=order_id, qty=qty(more_qty), base=pair.base))
        if r.terminal and (more_qty >= pair.base_step or now_ms() > check["until"]):
            state.pop("fill_check", None)
            state["fill_checked"] = order_id
        elif now_ms() > check["until"]:
            state.pop("fill_check", None)
            state["fill_checked"] = order_id
        return status

    def _abandon_order(self, bot: dict, state: dict, pending: dict) -> Message:
        """An order we can't find for minutes: don't guess. Drop it and stop the bot so nobody buys twice.

        If the order was in fact executed, the coins are on the account unbooked – a human has to check that
        at the exchange before starting the bot again.
        """
        state.pop("pending_order", None)
        state.pop("retry_after", None)
        bot["enabled"] = False
        self.db.update_bot(bot["id"], enabled=False)
        msg = m("engine.order_not_found", id=pending.get("id") or pending["client_order_id"])
        self.db.add_event(bot["id"], "error", msg)
        log.error("Bot %s: %s", bot["name"], render(msg, "en"))
        return msg

    def _apply_order(self, bot: dict, state: dict, pair: PairInfo, pending: dict, r: OrderResult) -> Message:
        state.pop("pending_order", None)
        state.pop("retry_after", None)  # the "order unclear" error is resolved with the order
        if self.db.trade_exists(r.order_id):  # never book the same exchange order twice
            return m("engine.order_booked")
        if short_fill(pending, r):
            state["fill_check"] = {"order_id": r.order_id, "side": pending["side"], "until": now_ms() + FILL_CHECK_MS}
        if r.filled_qty <= 0:
            msg = (m("engine.order_failed_reason", status=r.status, reason=r.reject_reason) if r.reject_reason
                   else m("engine.order_failed", status=r.status))
            self.db.add_event(bot["id"], "error", msg)
            state["retry_after"] = now_ms() + ERROR_BACKOFF_MS
            return msg
        fee_base = r.fee if r.fee_currency == pair.base else Decimal(0)
        fee_quote = r.fee if r.fee_currency == pair.quote else Decimal(0)
        fee_in_quote = fee_quote + fee_base * r.avg_price
        if pending["side"] == "buy":
            return self._record_buy(
                bot, state, pair, r.filled_qty - fee_base, r.filled_amount + fee_quote,
                r.avg_price, fee_in_quote, r.order_id, False, pending["reason"],
            )
        return self._record_sell(
            bot, state, pair, r.filled_qty + fee_base, r.filled_amount - fee_quote,
            r.avg_price, fee_in_quote, r.order_id, False, pending["reason"],
        )

    # --- bookkeeping ----------------------------------------------------------

    def _record_buy(self, bot, state, pair, bought, spent, price, fee, order_id, paper, reason) -> Message:
        position = Position.from_state(state.get("position"))
        if position:
            position.qty += bought
            position.cost += spent
            position.buys += 1
            position.peak = max(position.peak, price)
        else:
            position = Position(bought, spent, now_ms(), price, paper=paper)
        state["position"] = position.to_state()
        state["last_buy_at"] = self.exchange.now_ms()
        self.db.add_trade(
            bot_id=bot["id"], bot_name=bot["name"], symbol=bot["symbol"], side="buy",
            price=str(price), base_qty=str(bought), quote_amount=str(spent), fee=str(fee), pnl=None,
            order_id=order_id, paper=int(paper), reason=reason,
        )
        status = m("engine.bought", qty=qty(bought), base=pair.base, amount=money(spent, pair.quote))
        self.db.add_event(bot["id"], "trade", m("paren", text=status, detail=reason))
        return status

    def _record_sell(self, bot, state, pair, sold, proceeds, price, fee, order_id, paper, reason) -> Message:
        position = Position.from_state(state.get("position"))
        sold = min(sold, position.qty)
        cost_part = position.cost * sold / position.qty
        pnl = proceeds - cost_part
        position.qty -= sold
        position.cost -= cost_part
        if position.qty <= 0 or position.qty < pair.min_order_size:
            state["position"] = None  # only dust left
        else:
            state["position"] = position.to_state()
        state["last_sell_at"] = self.exchange.now_ms()
        self.db.add_trade(
            bot_id=bot["id"], bot_name=bot["name"], symbol=bot["symbol"], side="sell",
            price=str(price), base_qty=str(sold), quote_amount=str(proceeds), fee=str(fee), pnl=str(pnl),
            order_id=order_id, paper=int(paper), reason=reason,
        )
        status = m("engine.sold", qty=qty(sold), base=pair.base, amount=money(proceeds, pair.quote), pnl=money(pnl, pair.quote))
        self.db.add_event(bot["id"], "trade", m("paren", text=status, detail=reason))
        return status

    # --- views for the API ------------------------------------------------------

    def describe_bot(self, bot: dict[str, Any], stats: dict[int, dict[str, Any]], lang: str = "en") -> dict[str, Any]:
        base, quote = split_symbol(bot["symbol"])
        strategy = STRATEGIES.get(bot["strategy"])
        snap = self.snapshots.get(bot["symbol"])
        s = stats.get(bot["id"], {})
        position = Position.from_state(bot["state"].get("position"))
        pos_json = None
        if position:
            price = Decimal(str(snap["bid"])) if snap else position.entry_price
            value = position.value(price)
            pos_json = {
                "qty": float(position.qty),
                "cost": float(position.cost),
                "entry_price": float(position.entry_price),
                "opened_at": position.opened_at,
                "value": float(value),
                "unrealized_pnl": float(value - position.cost),
                "unrealized_pct": position.pnl_pct(price),
                "paper": position.paper,
            }
        return {
            "id": bot["id"],
            "name": bot["name"],
            "strategy": bot["strategy"],
            "strategy_name": strategy.name(lang) if strategy else bot["strategy"],
            "strategy_icon": strategy.icon if strategy else "questionmark.circle",
            "symbol": bot["symbol"],
            "base_currency": base,
            "quote_currency": quote,
            "params": strategy.normalize(bot["params"]) if strategy else bot["params"],
            "enabled": bot["enabled"],
            "paper": self.is_paper(bot),
            "paper_requested": bot["paper"],
            "status": render(bot["status"], lang),
            "status_error": message_key(bot["status"]) in {"engine.error", "engine.order_not_found"}
            or str(bot["status"]).startswith("Fehler"),
            "last_check": self._last_check.get(bot["id"], bot["last_check"]),
            "created_at": bot["created_at"],
            "pending_order": bool(bot["state"].get("pending_order")),
            "position": pos_json,
            "realized_pnl": float(s.get("realized") or 0),
            "trades_count": int(s.get("trades") or 0),
            "wins": int(s.get("wins") or 0),
            "losses": int(s.get("losses") or 0),
            "market": {"price": snap["price"], "change_24h": snap["change_24h"]} if snap else None,
        }

    def summary(self) -> dict[str, Any]:
        stats = self.db.trade_stats()
        bots = [self.describe_bot(b, stats) for b in self.db.list_bots()]
        start_of_day = int(datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp() * 1000)
        totals: dict[str, dict[str, float]] = {}

        def bucket(currency: str) -> dict[str, float]:
            return totals.setdefault(currency, {"realized": 0.0, "unrealized": 0.0, "today": 0.0, "invested": 0.0, "fees": 0.0})

        for row in self.db.realized_by_symbol():
            bucket(split_symbol(row["symbol"])[1])["realized"] += row["pnl"] or 0.0
        for row in self.db.fees_by_symbol():
            bucket(split_symbol(row["symbol"])[1])["fees"] += row["fee"] or 0.0
        for row in self.db.realized_since(start_of_day):
            bucket(split_symbol(row["symbol"])[1])["today"] += row["pnl"] or 0.0
        for b in bots:
            if b["position"]:
                t = bucket(b["quote_currency"])
                t["unrealized"] += b["position"]["unrealized_pnl"]
                t["invested"] += b["position"]["cost"]

        currencies = [
            {"currency": c, **v, "total": v["realized"] + v["unrealized"]}
            for c, v in sorted(totals.items(), key=lambda kv: -abs(kv[1]["realized"]) - kv[1]["invested"])
        ]
        return {
            "currencies": currencies,
            "bots_total": len(bots),
            "bots_active": sum(1 for b in bots if b["enabled"]),
            "open_positions": sum(1 for b in bots if b["position"]),
            "max_open_positions": int(self.db.get_limits()["max_open_positions"]),
            "trades_count": sum(b["trades_count"] for b in bots),
        }
