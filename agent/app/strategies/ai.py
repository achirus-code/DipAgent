"""AI decides: Claude looks at the market every N minutes and decides whether to buy, hold or sell.

The engine still applies its safety net – a sell below break-even (after fees) is held back unless the bot's own
stop-loss fires – so Claude decides *when* to take a profit or to wait, not whether to realize a loss.
"""

from __future__ import annotations

import json
import logging
import os
import statistics
from dataclasses import dataclass
from decimal import Decimal
from typing import Any, Literal

import anthropic
from pydantic import BaseModel, Field

from ..i18n import L, dur, m, pct
from .base import Buy, Context, Decision, Param, Sell, Strategy, cooldown_left

log = logging.getLogger("dipagent")

MODEL = "claude-opus-5"
# the Anthropic SDK also accepts an OAuth token; both end up here as environment variables
API_KEY_VARS = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")
RETRY_AUTH_MS = 60 * 60_000
RETRY_RATE_LIMIT_MS = 5 * 60_000

SYSTEM_PROMPT = """You manage one small crypto spot position for a retail trading bot on Revolut X.

Every few minutes you receive a market brief for one trading pair and decide on ONE action:
- without a position: "buy" (open a position with the configured amount) or "wait"
- with a position: "sell" (close the whole position at market) or "hold"

Judge for yourself which circumstances matter: the trend over the last hours and days, how volatile the market has
been recently, momentum, whether the price sits near a recent high or low, and – when news are provided or you can
search for them – the current market sentiment. Weigh them as an experienced, patient trader would:
- Fees are paid on every buy and sell; do not churn. Only buy when you see a real edge, only sell when the profit is
  worth taking or the picture has clearly turned.
- The bot never realizes a loss on your say-so: a "sell" below break-even is blocked by the engine (only the
  configured stop-loss may sell at a loss). If the position is under water, "hold" and explain what you wait for.
- High volatility means wider swings: be quicker to secure a good profit, slower to buy into a falling knife.
- Be decisive but not hasty; "wait"/"hold" are fine answers.

Answer with the requested JSON only. Give the reason in two short sentences at most, once in English and once in
German, written for the bot owner (no jargon, name the concrete facts you based the decision on)."""


class AiUnavailable(ValueError):
    """Claude gave no usable decision (refusal or unparsable answer) – treated like a transient error."""


class AiDecision(BaseModel):
    action: Literal["buy", "wait", "hold", "sell"]
    confidence: int = Field(ge=0, le=100, description="0-100")
    reason_en: str = Field(description="reason in English, max two sentences")
    reason_de: str = Field(description="the same reason in German")


@dataclass
class MarketBrief:
    """Everything Claude gets to see – built from the exchange data the other strategies use as well."""

    symbol: str
    quote: str
    price: float
    bid: float
    ask: float
    changes: dict[str, float]  # e.g. {"1h": -0.4, "4h": 1.2, "24h": -3.1, "72h": 2.0}
    volatility_4h: float  # std deviation of 15-minute returns over the last 4 h, in %
    volatility_24h: float  # std deviation of 15-minute returns, in %
    range_24h: float  # (high - low) / low over 24 h, in %
    distance_to_high_72h: float  # price vs. the 72 h high, in %
    distance_to_low_72h: float
    hourly_closes: list[float]  # last 12 hours
    fee_rate: float
    position: dict[str, Any] | None
    amount: float
    stop_loss: float

    def to_text(self) -> str:
        return json.dumps(self.__dict__, ensure_ascii=False, default=float, indent=1)


def _price_at(candles: list, interval: int, t0: int) -> Decimal | None:
    """Price at ``t0`` from a candle series (same rule as MarketView.price_at)."""
    if not candles:
        return None
    before = [c for c in candles if c.start <= t0]
    if not before:
        return candles[0].open
    c = before[-1]
    return c.close if (t0 - c.start) > interval * 30_000 else c.open


def _returns_stdev(values: list[Decimal]) -> float:
    closes = [float(v) for v in values if v]
    if len(closes) < 3:
        return 0.0
    returns = [(b / a - 1) * 100 for a, b in zip(closes, closes[1:]) if a]
    return statistics.pstdev(returns) if len(returns) > 1 else 0.0


class AiStrategy(Strategy):
    key = "ai"
    name = L("AI decides", "KI entscheidet")
    description = L(
        "Claude looks at the market every few minutes – trend, volatility of the last hours, momentum and optionally "
        "the news – and decides itself when to buy and when to close the position. Never sells at a loss (except via "
        "the stop-loss). Needs an Anthropic API key on the agent; every check costs a few cents.",
        "Claude schaut alle paar Minuten auf den Markt – Trend, Volatilität der letzten Stunden, Momentum und optional "
        "die Nachrichten – und entscheidet selbst, wann gekauft und wann die Position geschlossen wird. Verkauft nie "
        "im Minus (außer per Stop-Loss). Braucht einen Anthropic-API-Key auf dem Agenten; jede Prüfung kostet ein paar Cent.",
    )
    icon = "sparkles"
    params = [
        Param("amount", L("Amount per buy", "Betrag pro Kauf"), "money", 50.0, min=1),
        Param("ai_interval", L("Ask Claude every", "Claude fragen alle"), "int", 30,
              L("Minutes between two decisions. Shorter = more responsive, but every check costs money.",
                "Minuten zwischen zwei Entscheidungen. Kürzer = reagiert schneller, aber jede Prüfung kostet Geld."),
              min=5, max=1440, unit="min"),
        Param("news", L("Consider news", "Nachrichten einbeziehen"), "bool", False,
              L("Claude may search the web for current news and market sentiment before deciding (costs a bit more).",
                "Claude darf vor der Entscheidung im Web nach aktuellen Nachrichten und Marktstimmung suchen (kostet etwas mehr).")),
        Param("stop_loss", L("Stop-loss", "Stop-Loss"), "percent", 0.0,
              L("Sell at this loss. 0 = off.", "Verkauf bei so viel Verlust. 0 = aus."), min=0, max=90, step=0.5),
        Param("cooldown_minutes", L("Pause after selling", "Pause nach Verkauf"), "int", 60,
              L("Minutes to wait after a sale before buying again.", "Minuten Wartezeit nach einem Verkauf, bevor erneut gekauft wird."),
              min=0, max=10080, unit="min"),
    ]

    def __init__(self) -> None:
        self._client: anthropic.AsyncAnthropic | None = None

    # --- Claude -----------------------------------------------------------------

    @staticmethod
    def configured() -> bool:
        return any(os.getenv(var, "").strip() for var in API_KEY_VARS)

    def _get_client(self) -> anthropic.AsyncAnthropic:
        if self._client is None:
            self._client = anthropic.AsyncAnthropic(timeout=120.0, max_retries=2)
        return self._client

    async def ask(self, brief: MarketBrief, news: bool) -> AiDecision:
        """One decision from Claude. Overridden in tests."""
        request: dict[str, Any] = dict(
            model=MODEL,
            max_tokens=4000,
            output_config={"effort": "medium"},
            system=[{"type": "text", "text": SYSTEM_PROMPT, "cache_control": {"type": "ephemeral"}}],
            messages=[{
                "role": "user",
                "content": (
                    ("You may run up to 3 web searches for news and sentiment about this asset first.\n\n" if news else "")
                    + "Market brief:\n" + brief.to_text()
                ),
            }],
            output_format=AiDecision,
        )
        if news:
            request["tools"] = [{"type": "web_search_20260209", "name": "web_search", "max_uses": 3}]
        response = await self._get_client().messages.parse(**request)
        if response.stop_reason == "refusal" or response.parsed_output is None:
            raise AiUnavailable(f"no decision (stop_reason={response.stop_reason})")
        return response.parsed_output

    # --- market data ------------------------------------------------------------

    async def brief(self, ctx: Context) -> MarketBrief:
        """Two candle series only – 24 h in 15-minute candles (shared with the engine's 24 h change) and 72 h in
        hourly candles; the shorter windows are derived from the 24 h series instead of extra requests."""
        market, pos, p = ctx.market, ctx.position, ctx.params
        candles_24h, interval_24h = await market.candles(24)
        candles_72h, interval_72h = await market.candles(72)
        changes: dict[str, float] = {}
        for hours, candles, interval in ((1, candles_24h, interval_24h), (4, candles_24h, interval_24h),
                                         (24, candles_24h, interval_24h), (72, candles_72h, interval_72h)):
            ref = _price_at(candles, interval, ctx.now - hours * 3_600_000)
            if ref:
                changes[f"{hours}h"] = round(float((market.price / ref - 1) * 100), 2)
        per_4h = max(1, int(4 * 60 / interval_24h))
        candles_4h = candles_24h[-per_4h:]
        high_72h = max([c.high for c in candles_72h] + [market.price])
        low_72h = min([c.low for c in candles_72h] + [market.price])
        high_24h = max([c.high for c in candles_24h] + [market.price])
        low_24h = min([c.low for c in candles_24h] + [market.price])
        step = max(1, len(candles_24h) // 24)
        hourly = [float(c.close) for c in candles_24h[::step]][-12:]

        position = None
        if pos:
            position = {
                "qty": float(pos.qty),
                "cost": float(pos.cost),
                "entry_price": float(pos.entry_price),
                "break_even_price": float(pos.break_even_price(ctx.fee_rate, ctx.quote)),
                "profit_pct": round(pos.pnl_pct(market.bid), 2),
                "held_hours": round((ctx.now - pos.opened_at) / 3_600_000, 1),
                "peak_price_since_buy": float(pos.peak),
                "note": "a sell below break_even_price is blocked by the engine",
            }
        return MarketBrief(
            symbol=market.symbol, quote=ctx.quote,
            price=float(market.price), bid=float(market.bid), ask=float(market.ask),
            changes=changes,
            volatility_4h=round(_returns_stdev([c.close for c in candles_4h]), 3),
            volatility_24h=round(_returns_stdev([c.close for c in candles_24h]), 3),
            range_24h=round(float((high_24h - low_24h) / low_24h * 100), 2) if low_24h else 0.0,
            distance_to_high_72h=round(float((market.price / high_72h - 1) * 100), 2) if high_72h else 0.0,
            distance_to_low_72h=round(float((market.price / low_72h - 1) * 100), 2) if low_72h else 0.0,
            hourly_closes=hourly,
            fee_rate=ctx.fee_rate,
            position=position,
            amount=float(p["amount"]),
            stop_loss=float(p["stop_loss"]),
        )

    # --- strategy ---------------------------------------------------------------

    async def evaluate(self, ctx: Context) -> Decision:
        p, market, pos = ctx.params, ctx.market, ctx.position
        state = ctx.state.setdefault("ai", {})

        if pos is not None:
            profit = pos.pnl_pct(market.bid)
            if p["stop_loss"] > 0 and profit <= -p["stop_loss"]:
                return Decision(m("stop_loss"), Sell(m("stop_loss.reason", profit=pct(profit)), stop=True))
        else:
            wait = cooldown_left(ctx, p["cooldown_minutes"])
            if wait:
                return Decision(m("cooldown", left=dur(wait)))

        if not self.configured():
            return Decision(m("ai.no_key"))

        next_at = int(state.get("next_at") or 0)
        last = state.get("last")
        if ctx.now < next_at and last:
            reason = m("ai.reason", en=last["reason_en"], de=last["reason_de"])
            status_key = "ai.holding" if pos else "ai.waiting"
            if pos:
                return Decision(m(status_key, profit=pct(pos.pnl_pct(market.bid)), reason=reason, left=dur(next_at - ctx.now)))
            return Decision(m(status_key, reason=reason, left=dur(next_at - ctx.now)))
        if ctx.now < next_at:  # backing off after an error
            return Decision(m("ai.retry", left=dur(next_at - ctx.now)))

        state["next_at"] = ctx.now + int(p["ai_interval"]) * 60_000
        try:
            decision = await self.ask(await self.brief(ctx), bool(p["news"]))
        except anthropic.AuthenticationError:
            state["next_at"] = ctx.now + RETRY_AUTH_MS
            log.error("AI bot %s: Anthropic API key rejected", market.symbol)
            return Decision(m("ai.auth_error"))
        except anthropic.RateLimitError:
            state["next_at"] = ctx.now + RETRY_RATE_LIMIT_MS
            return Decision(m("ai.rate_limited", left=dur(RETRY_RATE_LIMIT_MS)))
        except (anthropic.APIError, ValueError) as exc:
            log.warning("AI bot %s: %s", market.symbol, exc)
            return Decision(m("ai.error", error=str(exc)[:120], left=dur(int(p["ai_interval"]) * 60_000)))

        state["last"] = {
            "action": decision.action, "confidence": decision.confidence,
            "reason_en": decision.reason_en, "reason_de": decision.reason_de, "at": ctx.now,
        }
        reason = m("ai.reason", en=decision.reason_en, de=decision.reason_de)
        trade_reason = m("ai.trade_reason", reason=reason, confidence=decision.confidence)

        if pos is None:
            if decision.action == "buy":
                return Decision(m("ai.buy", reason=reason), Buy(Decimal(str(p["amount"])), trade_reason))
            return Decision(m("ai.waiting", reason=reason, left=dur(int(p["ai_interval"]) * 60_000)))
        if decision.action == "sell":
            return Decision(m("ai.sell", reason=reason), Sell(trade_reason))
        return Decision(m("ai.holding", profit=pct(pos.pnl_pct(market.bid)), reason=reason,
                          left=dur(int(p["ai_interval"]) * 60_000)))
