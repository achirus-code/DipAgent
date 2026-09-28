"""DipAgent – REST API for the macOS app plus the always-on bot engine.

Every response is rendered in the language of the request (``Accept-Language``: German or English).
"""

from __future__ import annotations

import asyncio
import logging
import re
import secrets
import time
from datetime import datetime
from contextlib import asynccontextmanager
from decimal import Decimal
from typing import Any

import httpx
from fastapi import APIRouter, Depends, FastAPI, Header, HTTPException, Query, Request, Response
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field

from . import backup
from .config import load_settings
from .credentials import CredentialStore
from .db import Database
from .engine import Engine
from .exchange import Exchange, MockExchange, RevolutXExchange
from .i18n import Problem, as_message, lang_from_header, m, render, text
from .revolutx import RevolutXClient, RevolutXError
from .strategies import STRATEGIES
from .strategies.ai import AiStrategy

VERSION = "1.4.0"
# the app polls balances every few seconds – don't turn every poll into an exchange request
BALANCES_CACHE_SECONDS = 10

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("dipagent")

settings = load_settings()
db = Database(settings.db_path)


class UnconfiguredExchange(Exchange):
    """Placeholder until Revolut X is connected: every exchange call fails with a helpful message."""

    name = "revolutx"

    def __init__(self, reason: dict):
        self.reason = reason

    def __getattribute__(self, item: str) -> Any:
        if item in {"ticker", "candles", "pairs", "balances", "place_market_order", "get_order", "find_order", "pair"}:
            reason = object.__getattribute__(self, "reason")

            async def fail(*_: Any, **__: Any) -> Any:
                raise Problem(reason["k"], **reason.get("a", {}))

            return fail
        return object.__getattribute__(self, item)


def build_exchange() -> Exchange:
    if settings.exchange == "mock":
        log.warning("Demo mode: simulated market (EXCHANGE=mock)")
        return MockExchange(settings.taker_fee, settings.mock_speed)
    store = CredentialStore(settings)
    active = store.active()
    if active is None:
        return UnconfiguredExchange(store.missing_reason())
    api_key, private_pem = active
    return RevolutXExchange(RevolutXClient(api_key, private_pem, settings.revx_base_url))


def swap_exchange(new: Exchange) -> None:
    """Switch the engine to new credentials without restarting the container."""
    global _balances_cache
    _balances_cache = None
    engine.replace_exchange(new)


credentials = CredentialStore(settings)
engine = Engine(db, build_exchange(), settings)
_balances_cache: tuple[float, dict[str, tuple[Decimal, Decimal]]] | None = None


@asynccontextmanager
async def lifespan(_: FastAPI):
    task = asyncio.create_task(engine.run())
    if not engine.live_trading_enabled():
        log.warning("Live trading is off – all bots trade simulated (paper trading)")
    yield
    # let a tick that is tracking an order finish (its pending order is persisted either way)
    task.cancel()
    try:
        await asyncio.wait_for(task, timeout=10)
    except (asyncio.CancelledError, asyncio.TimeoutError):
        pass
    await engine.shutdown()
    db.close()


app = FastAPI(title="DipAgent", version=VERSION, lifespan=lifespan)
_bearer = HTTPBearer(auto_error=False)


def get_lang(accept_language: str | None = Header(default=None)) -> str:
    return lang_from_header(accept_language)


def require_token(
    creds: HTTPAuthorizationCredentials | None = Depends(_bearer), lang: str = Depends(get_lang)
) -> None:
    if creds is None or not secrets.compare_digest(creds.credentials.encode(), settings.api_token.encode()):
        raise HTTPException(status_code=401, detail=text("api.invalid_token", lang))


def fail(status: int, lang: str, key: str, **args: Any) -> HTTPException:
    return HTTPException(status, text(key, lang, **args))


def fail_with(status: int, lang: str, exc: BaseException) -> HTTPException:
    return HTTPException(status, render(as_message(exc), lang))


api = APIRouter(prefix="/api", dependencies=[Depends(require_token)])


# --- request bodies -----------------------------------------------------------------------


class LiveTradingIn(BaseModel):
    enabled: bool
    confirm: str | None = None  # must be "LIVE" to switch on – the app asks twice before sending it


class ApiKeyIn(BaseModel):
    api_key: str = Field(min_length=16, max_length=256)


class LimitsIn(BaseModel):
    max_open_positions: int = Field(ge=0, le=100)
    max_total_invested: float = Field(ge=0)
    one_position_per_symbol: bool


class BotIn(BaseModel):
    name: str = Field(min_length=1, max_length=60)
    strategy: str
    symbol: str = Field(min_length=3, max_length=20)
    params: dict[str, Any] = Field(default_factory=dict)
    enabled: bool = False
    paper: bool = True


# --- helpers ------------------------------------------------------------------------------


async def _validate(body: BotIn, lang: str) -> tuple[str, dict[str, Any]]:
    strategy = STRATEGIES.get(body.strategy)
    if strategy is None:
        raise fail(422, lang, "api.unknown_strategy", strategy=body.strategy)
    symbol = body.symbol.strip().upper().replace("/", "-")
    try:
        pairs = await engine.exchange.pairs()
    except Exception:  # noqa: BLE001 - exchange offline: accept, the engine will report problems
        pairs = None
    if pairs is not None and symbol not in pairs:
        raise fail(422, lang, "api.pair_unavailable", symbol=symbol)
    return symbol, strategy.normalize(body.params)


def _bot_or_404(bot_id: int, lang: str) -> dict[str, Any]:
    bot = db.get_bot(bot_id)
    if bot is None:
        raise fail(404, lang, "api.bot_not_found")
    return bot


def _describe(bot_id: int, lang: str) -> dict[str, Any]:
    return engine.describe_bot(_bot_or_404(bot_id, lang), db.trade_stats(), lang)


def _status(lang: str) -> dict[str, Any]:
    error = getattr(engine.exchange, "reason", None) or engine.exchange_error
    return {
        "version": VERSION,
        "exchange": engine.exchange.name,
        "exchange_ok": error is None,
        "exchange_error": render(error, lang) if error else None,
        "engine_error": render(engine.instance_error, lang) if engine.instance_error else None,
        "live_trading_allowed": engine.live_trading_enabled(),
        "last_tick": engine.last_tick,
        "tick_seconds": settings.tick_seconds,
        "taker_fee": float(settings.taker_fee),
        "ai_configured": AiStrategy.configured(),
    }


# --- general --------------------------------------------------------------------------------


@app.get("/api/health")
async def health() -> dict[str, Any]:
    return {"ok": True, "version": VERSION}


@api.get("/status")
async def status(lang: str = Depends(get_lang)) -> dict[str, Any]:
    return _status(lang)


@api.get("/summary")
async def summary() -> dict[str, Any]:
    return engine.summary()


# --- Revolut X setup from the app ------------------------------------------------------------


def _exchange_info(lang: str) -> dict[str, Any]:
    error = getattr(engine.exchange, "reason", None) or engine.exchange_error
    return {
        **credentials.describe(),
        "mode": settings.exchange,
        "connected": settings.exchange == "revolutx" and credentials.source != "none" and error is None,
        "error": render(error, lang) if error else None,
        "api_keys_url": "https://exchange.revolut.com/account/api-keys",
    }


def _require_app_setup(lang: str) -> None:
    if settings.exchange == "mock":
        raise fail(409, lang, "api.demo_mode")
    if credentials.source == "env":
        raise fail(409, lang, "api.env_configured")


@api.get("/exchange")
async def exchange_info(lang: str = Depends(get_lang)) -> dict[str, Any]:
    return _exchange_info(lang)


@api.post("/exchange/keypair")
async def generate_keypair(lang: str = Depends(get_lang)) -> dict[str, Any]:
    _require_app_setup(lang)
    credentials.generate_pending()
    db.add_event(None, "info", m("event.keypair"))
    return _exchange_info(lang)


@api.put("/exchange/credentials")
async def save_credentials(body: ApiKeyIn, lang: str = Depends(get_lang)) -> dict[str, Any]:
    _require_app_setup(lang)
    api_key = body.api_key.strip()
    if not re.fullmatch(r"[A-Za-z0-9]+", api_key):
        raise fail(422, lang, "api.api_key_chars")
    private_pem = credentials.signing_key_for_new_api_key()
    if private_pem is None:
        raise fail(409, lang, "api.keypair_first")

    client = RevolutXClient(api_key, private_pem, settings.revx_base_url)
    try:
        await client.balances()  # proves that API key + private key + IP whitelist fit together
    except RevolutXError as exc:
        await client.close()
        key = "api.key_rejected_hint" if exc.status in (401, 403) else "api.key_rejected"
        raise fail(422, lang, key, error=exc.message) from exc
    except httpx.HTTPError as exc:
        await client.close()
        raise fail(502, lang, "api.revx_unreachable", error=str(exc)) from exc

    credentials.save(api_key, private_pem)
    swap_exchange(RevolutXExchange(client))
    db.add_event(None, "info", m("event.revx_connected"))
    return _exchange_info(lang)


@api.delete("/exchange/credentials")
async def delete_credentials(lang: str = Depends(get_lang)) -> dict[str, Any]:
    _require_app_setup(lang)
    credentials.clear()
    if engine.live_trading_enabled():
        db.set_setting("live_trading", False)
        db.add_event(None, "info", m("event.live_off_access_removed"))
    swap_exchange(UnconfiguredExchange(credentials.missing_reason()))
    db.add_event(None, "info", m("event.revx_removed"))
    return _exchange_info(lang)


@api.get("/exchange/public-ip")
async def public_ip(lang: str = Depends(get_lang)) -> dict[str, Any]:
    """The agent's public IP – Revolut X can restrict API keys to whitelisted IPs."""
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            ip = (await client.get("https://api.ipify.org", params={"format": "json"})).json()["ip"]
    except Exception as exc:  # noqa: BLE001
        raise fail(502, lang, "api.public_ip_failed", error=str(exc)) from exc
    return {"ip": ip}


# --- trading mode ------------------------------------------------------------------------------


@api.put("/live-trading")
async def set_live_trading(body: LiveTradingIn, lang: str = Depends(get_lang)) -> dict[str, Any]:
    if body.enabled:
        if settings.exchange != "revolutx":
            raise fail(409, lang, "api.no_live_in_demo")
        if credentials.source == "none":
            raise fail(409, lang, "api.connect_revx_first")
        if body.confirm != "LIVE":
            raise fail(422, lang, "api.confirm_live")
        try:
            await engine.exchange.balances()  # only switch on with a working connection
        except Exception as exc:  # noqa: BLE001
            raise fail(502, lang, "api.revx_unreachable_live", error=as_message(exc)) from exc

    closed: list[dict[str, Any]] = []
    if body.enabled != engine.live_trading_enabled():
        db.set_setting("live_trading", body.enabled)  # first: no new live buys from here on
        db.add_event(None, "info", m("event.live_on" if body.enabled else "event.live_off"))
        if body.enabled:
            # the app told the user: all existing bots go live (bots that shouldn't must be deleted beforehand).
            # Open paper positions keep being simulated until they are sold – see Engine._buy/_sell.
            for bot in db.list_bots():
                if bot["paper"]:
                    db.update_bot(bot["id"], paper=False)
                    db.add_event(bot["id"], "info", m("event.bot_live"))
        log.warning("Live trading %s", "ENABLED" if body.enabled else "disabled")
    if not body.enabled:
        # back to paper mode: the app warned that all open live positions are sold right away
        closed = await engine.close_live_positions(m("engine.live_ended"))
        for result in closed:
            result["message"] = render(result["message"], lang)
    engine.wake()
    return {**_status(lang), "closed_positions": closed}


# --- limits ----------------------------------------------------------------------------------


@api.get("/limits")
async def get_limits() -> dict[str, Any]:
    count, invested, _ = engine.exposure()
    return {**db.get_limits(), "open_positions": count, "invested": float(invested)}


@api.put("/limits")
async def put_limits(body: LimitsIn) -> dict[str, Any]:
    db.set_limits(body.model_dump())
    db.add_event(None, "info", m("event.limits_changed"))
    engine.wake()
    return await get_limits()


# --- market data -----------------------------------------------------------------------------


@api.get("/strategies")
async def strategies(lang: str = Depends(get_lang)) -> list[dict[str, Any]]:
    return [s.to_json(lang) for s in STRATEGIES.values()]


@api.get("/pairs")
async def pairs(lang: str = Depends(get_lang)) -> list[str]:
    try:
        return sorted(await engine.exchange.pairs())
    except Exception as exc:  # noqa: BLE001
        raise fail_with(502, lang, exc) from exc


@api.get("/balances")
async def balances(lang: str = Depends(get_lang)) -> list[dict[str, Any]]:
    global _balances_cache
    if _balances_cache and time.monotonic() - _balances_cache[0] < BALANCES_CACHE_SECONDS:
        data = _balances_cache[1]
    else:
        try:
            data = await engine.exchange.balances()
        except Exception as exc:  # noqa: BLE001
            raise fail_with(502, lang, exc) from exc
        _balances_cache = (time.monotonic(), data)
    return [
        {"currency": c, "available": float(a), "total": float(t)}
        for c, (a, t) in sorted(data.items())
        if t > Decimal(0)
    ]


# --- bots ------------------------------------------------------------------------------------


@api.get("/bots")
async def list_bots(lang: str = Depends(get_lang)) -> list[dict[str, Any]]:
    stats = db.trade_stats()
    return [engine.describe_bot(b, stats, lang) for b in db.list_bots()]


@api.post("/bots", status_code=201)
async def create_bot(body: BotIn, lang: str = Depends(get_lang)) -> dict[str, Any]:
    symbol, params = await _validate(body, lang)
    bot_id = db.create_bot(body.name.strip(), body.strategy, symbol, params, body.enabled, body.paper)
    db.add_event(bot_id, "info", m("event.bot_created", strategy=m(f"strategy.{body.strategy}"), symbol=symbol))
    engine.wake()
    return _describe(bot_id, lang)


@api.put("/bots/{bot_id}")
async def update_bot(bot_id: int, body: BotIn, lang: str = Depends(get_lang)) -> dict[str, Any]:
    bot = _bot_or_404(bot_id, lang)
    symbol, params = await _validate(body, lang)
    # an order in flight is reconciled under the bot's pair – it must not change under it either
    busy = bot["state"].get("position") or bot["state"].get("pending_order")
    if busy and (symbol != bot["symbol"] or body.strategy != bot["strategy"]):
        raise fail(409, lang, "api.locked_pair_strategy")
    if busy and body.paper != bot["paper"]:
        raise fail(409, lang, "api.locked_mode")
    db.update_bot(
        bot_id, name=body.name.strip(), strategy=body.strategy, symbol=symbol,
        params=params, enabled=body.enabled, paper=body.paper,
    )
    db.add_event(bot_id, "info", m("event.settings_changed"))
    engine.wake()
    return _describe(bot_id, lang)


@api.delete("/bots/{bot_id}", status_code=204, response_class=Response)
async def delete_bot(bot_id: int, force: bool = False, lang: str = Depends(get_lang)) -> Response:
    bot = _bot_or_404(bot_id, lang)
    if (bot["state"].get("position") or bot["state"].get("pending_order")) and not force:
        raise fail(409, lang, "api.delete_open_position")
    db.delete_bot(bot_id)
    return Response(status_code=204)


@api.post("/bots/{bot_id}/start")
async def start_bot(bot_id: int, lang: str = Depends(get_lang)) -> dict[str, Any]:
    _bot_or_404(bot_id, lang)
    db.update_bot(bot_id, enabled=True, status=m("status.starting"))
    db.add_event(bot_id, "info", m("event.bot_started"))
    engine.wake()
    return _describe(bot_id, lang)


@api.post("/bots/{bot_id}/stop")
async def stop_bot(bot_id: int, lang: str = Depends(get_lang)) -> dict[str, Any]:
    _bot_or_404(bot_id, lang)
    db.update_bot(bot_id, enabled=False, status=m("status.stopped"))
    db.add_event(bot_id, "info", m("event.bot_stopped"))
    return _describe(bot_id, lang)


@api.post("/bots/{bot_id}/close")
async def close_position(bot_id: int, lang: str = Depends(get_lang)) -> dict[str, Any]:
    _bot_or_404(bot_id, lang)
    try:
        await engine.close_position(bot_id)
    except Problem as exc:
        raise fail_with(409, lang, exc) from exc
    except Exception as exc:  # noqa: BLE001
        raise fail_with(502, lang, exc) from exc
    return _describe(bot_id, lang)


# --- history ---------------------------------------------------------------------------------


@api.get("/trades")
async def trades(
    bot_id: int | None = None, limit: int = Query(200, ge=1, le=1000), lang: str = Depends(get_lang)
) -> list[dict[str, Any]]:
    rows = db.list_trades(bot_id, limit)
    for r in rows:
        for key in ("price", "base_qty", "quote_amount", "fee"):
            r[key] = float(r[key])
        r["pnl"] = float(r["pnl"]) if r["pnl"] is not None else None
        r["paper"] = bool(r["paper"])
        r["reason"] = render(r["reason"], lang)
    return rows


@api.get("/events")
async def events(
    bot_id: int | None = None, limit: int = Query(100, ge=1, le=1000), lang: str = Depends(get_lang)
) -> list[dict[str, Any]]:
    rows = db.list_events(bot_id, limit)
    for r in rows:
        r["message"] = render(r["message"], lang)
    return rows


# --- backup ----------------------------------------------------------------------------------


@api.get("/backup")
async def export_backup() -> Response:
    """Bots, trades, settings and the app-managed Revolut X key as a .tgz (the API token is not included)."""
    creds = {name: path.read_bytes() for name, path in credentials.files().items() if path.is_file()}
    data, filename = backup.create(db.snapshot(), creds, {"agent_version": VERSION, "exchange": settings.exchange})
    return Response(
        data, media_type="application/gzip", headers={"Content-Disposition": f'attachment; filename="{filename}"'}
    )


@api.post("/restore")
async def restore_backup(request: Request, lang: str = Depends(get_lang)) -> dict[str, Any]:
    """Replace the agent's data with an uploaded backup. Live trading is switched off afterwards, always."""
    body = await request.body()
    try:
        unpacked = backup.unpack(body, settings.data_dir)
    except backup.InvalidBackup as exc:
        raise fail(400, lang, "api.invalid_backup", error=str(exc)) from exc
    try:
        async with engine.paused():  # no tick touches the database while it is swapped
            live_was_on = engine.live_trading_enabled()
            db.replace_with(unpacked.db_path)
            if unpacked.credentials:
                credentials.save(unpacked.credentials["revx_api_key"].decode().strip(), unpacked.credentials["revx_private.pem"])
            # off in any case: the restored data may have been backed up with live trading on, and the agent
            # it lands on may have been live before – the user re-enables it consciously (double confirmation)
            live_was_on = live_was_on or engine.live_trading_enabled()
            if live_was_on:
                db.set_setting("live_trading", False)
            engine.reset_caches()
            swap_exchange(build_exchange())
            bots, trade_count = db.list_bots(), len(db.list_trades(limit=1000))
            created = unpacked.manifest.get("created_at")
            date = datetime.fromtimestamp(created / 1000).strftime("%Y-%m-%d %H:%M") if created else "?"
            db.add_event(None, "info", m("event.restored", date=date, bots=len(bots), trades=trade_count))
            if live_was_on:
                db.add_event(None, "info", m("event.live_off_restored"))
            engine.wake()
    finally:
        unpacked.cleanup()
    log.warning("Backup restored (%d bots, %d trades); live trading is off", len(bots), trade_count)
    return {
        "bots": len(bots),
        "trades": trade_count,
        "live_trading_disabled": live_was_on,
        "credentials_restored": bool(unpacked.credentials),
        "created_at": created,
        "agent_version": unpacked.manifest.get("agent_version"),
    }


app.include_router(api)
