"""Additional strategies: price zones, savings plan (DCA) and rebound with trailing stop."""

from __future__ import annotations

from decimal import Decimal

from ..i18n import L, dur, m, money, num, pct
from .base import Buy, Context, Decision, Param, Sell, Strategy, cooldown_left

COOLDOWN_LABEL = L("Pause after selling", "Pause nach Verkauf")
STOP_LOSS_OFF = L("0 = off.", "0 = aus.")


class PriceZoneStrategy(Strategy):
    key = "zones"
    name = L("Price zones", "Preiszonen")
    description = L(
        "Buys when the price falls below a fixed price and sells above a target price.",
        "Kauft, wenn der Kurs unter einen festen Preis fällt, und verkauft über einem Zielpreis.",
    )
    icon = "arrow.up.and.down.square"
    params = [
        Param("amount", L("Amount per buy", "Betrag pro Kauf"), "money", 50.0, min=1),
        Param("buy_below", L("Buy below price", "Kaufen unter Preis"), "money", 0.0,
              L("Buy price limit. 0 = the bot does not buy.", "Kaufpreis-Grenze. 0 = Bot kauft nicht."), min=0),
        Param("sell_above", L("Sell above price", "Verkaufen über Preis"), "money", 0.0,
              L("Target price for selling.", "Zielpreis für den Verkauf."), min=0),
        Param("stop_price", L("Stop-loss price", "Stop-Loss-Preis"), "money", 0.0,
              L("Sell if the price drops below. 0 = off.", "Verkauf, falls der Kurs darunter fällt. 0 = aus."), min=0),
        Param("cooldown_minutes", COOLDOWN_LABEL, "int", 30, min=0, max=10080, unit="min"),
    ]

    async def evaluate(self, ctx: Context) -> Decision:
        p, market, pos, q = ctx.params, ctx.market, ctx.position, ctx.quote
        price = market.price
        if pos is None:
            if p["buy_below"] <= 0:
                return Decision(m("zones.no_price"))
            wait = cooldown_left(ctx, p["cooldown_minutes"])
            if wait:
                return Decision(m("cooldown", left=dur(wait)))
            if price <= Decimal(str(p["buy_below"])):
                reason = m("zones.buy_reason", price=money(price, q), limit=money(p["buy_below"], q))
                return Decision(m("zones.buy_signal"), Buy(Decimal(str(p["amount"])), reason))
            return Decision(m("zones.waiting", price=money(price, q), limit=money(p["buy_below"], q)))

        bid = market.bid
        if p["stop_price"] > 0 and bid <= Decimal(str(p["stop_price"])):
            return Decision(m("stop_loss"), Sell(m("zones.stop_reason", price=money(bid, q), stop=money(p["stop_price"], q))))
        if p["sell_above"] > 0 and bid >= Decimal(str(p["sell_above"])):
            return Decision(m("zones.target"), Sell(m("zones.target_reason", price=money(bid, q), target=money(p["sell_above"], q))))
        return Decision(m("zones.position", profit=pct(pos.pnl_pct(bid)), target=money(p["sell_above"], q)))


class DcaStrategy(Strategy):
    key = "dca"
    name = L("Savings plan", "Sparplan")
    description = L(
        "Buys a fixed amount at fixed intervals (dollar-cost averaging) and optionally sells everything at the profit target.",
        "Kauft in festen Abständen einen festen Betrag (Durchschnittskosten-Effekt) und verkauft optional alles beim Gewinnziel.",
    )
    icon = "calendar.badge.clock"
    accumulates = True
    params = [
        Param("amount", L("Amount per buy", "Betrag pro Kauf"), "money", 25.0, min=1),
        Param("interval_hours", L("Interval", "Intervall"), "int", 24,
              L("Hours between two buys.", "Stunden zwischen zwei Käufen."), min=1, max=24 * 31, unit="h"),
        Param("take_profit", L("Profit target (sell all)", "Gewinnziel (alles verkaufen)"), "percent", 10.0,
              L("0 = never sell.", "0 = nie verkaufen."), min=0, max=1000, step=0.5),
        Param("max_invest", L("Invest at most", "Maximal investieren"), "money", 500.0,
              L("Upper limit for the open position. 0 = unlimited.", "Obergrenze für die offene Position. 0 = unbegrenzt."), min=0),
        Param("max_buys", L("Max. buys per position", "Max. Käufe pro Position"), "int", 20,
              L("How often the plan may buy before selling. 0 = unlimited.",
                "Wie oft nachgekauft werden darf, bevor verkauft wird. 0 = unbegrenzt."), min=0, max=1000),
    ]

    async def evaluate(self, ctx: Context) -> Decision:
        p, market, pos, q = ctx.params, ctx.market, ctx.position, ctx.quote
        invested = pos.cost if pos else Decimal(0)
        if pos and p["take_profit"] > 0:
            profit = pos.pnl_pct(market.bid)
            if profit >= p["take_profit"]:
                return Decision(m("take_profit"), Sell(m("dca.take_profit_reason", profit=pct(profit), target=pct(p["take_profit"]))))

        amount = Decimal(str(p["amount"]))
        if pos and p["max_buys"] > 0 and pos.buys >= p["max_buys"]:
            return Decision(m("dca.max_buys", count=p["max_buys"], invested=money(invested, q), profit=pct(pos.pnl_pct(market.bid))))
        if p["max_invest"] > 0 and invested + amount > Decimal(str(p["max_invest"])):
            return Decision(m("dca.max_invest", invested=money(invested, q)))

        next_buy = int(ctx.state.get("last_buy_at") or 0) + p["interval_hours"] * 3_600_000
        if ctx.now >= next_buy:
            return Decision(m("dca.due"), Buy(amount, m("dca.reason")))
        if pos:
            return Decision(m("dca.next_profit", left=dur(next_buy - ctx.now), invested=money(invested, q),
                              profit=pct(pos.pnl_pct(market.bid))))
        return Decision(m("dca.next", left=dur(next_buy - ctx.now), invested=money(invested, q)))


class ReboundTrailingStrategy(Strategy):
    key = "trailing"
    name = L("Rebound + trailing stop", "Rebound + Trailing-Stop")
    description = L(
        "Buys when the price is X % below the high of the last hours. Once the activation profit is reached, a trailing "
        "stop follows the price and locks in gains while it keeps rising.",
        "Kauft, wenn der Kurs X % unter dem Hoch der letzten Stunden liegt. Nach Erreichen des Aktivierungsgewinns "
        "läuft ein Trailing-Stop mit, der Gewinne absichert, solange der Kurs weiter steigt.",
    )
    icon = "chart.line.uptrend.xyaxis"
    params = [
        Param("amount", L("Amount per buy", "Betrag pro Kauf"), "money", 50.0, min=1),
        Param("lookback_hours", L("High of the last", "Hoch der letzten"), "int", 48,
              L("Hours used to determine the high.", "Stunden, aus denen das Hoch bestimmt wird."), min=1, max=720, unit="h"),
        Param("drop_percent", L("Buy at distance from high", "Kaufen bei Abstand zum Hoch"), "percent", 4.0,
              L("e.g. 4 % below the high.", "z. B. 4 % unter dem Hoch."), min=0.1, max=90, step=0.1),
        Param("activation", L("Trailing active from profit", "Trailing aktiv ab Gewinn"), "percent", 1.5, min=0.1, max=100, step=0.1),
        Param("trail", L("Trailing distance", "Trailing-Abstand"), "percent", 0.8,
              L("Sell when the price falls this far from its high since buying.",
                "Verkauf, wenn der Kurs so weit vom Höchststand seit Kauf fällt."), min=0.1, max=50, step=0.1),
        Param("stop_loss", L("Stop-loss", "Stop-Loss"), "percent", 0.0, STOP_LOSS_OFF, min=0, max=90, step=0.5),
        Param("cooldown_minutes", COOLDOWN_LABEL, "int", 60, min=0, max=10080, unit="min"),
    ]

    async def evaluate(self, ctx: Context) -> Decision:
        p, market, pos, q = ctx.params, ctx.market, ctx.position, ctx.quote
        hours = p["lookback_hours"]
        if pos is None:
            wait = cooldown_left(ctx, p["cooldown_minutes"])
            if wait:
                return Decision(m("cooldown", left=dur(wait)))
            high = await market.high(hours)
            distance = float((market.price / high - 1) * 100)
            if distance <= -p["drop_percent"]:
                reason = m("trailing.buy_reason", distance=pct(distance), hours=hours, high=money(high, q))
                return Decision(m("buy_signal"), Buy(Decimal(str(p["amount"])), reason))
            return Decision(m("trailing.waiting", distance=pct(distance), hours=hours, drop=num(p["drop_percent"])))

        profit = pos.pnl_pct(market.bid)
        if p["stop_loss"] > 0 and profit <= -p["stop_loss"]:
            return Decision(m("stop_loss"), Sell(m("stop_loss.reason", profit=pct(profit))))
        peak_profit = float((pos.peak / pos.entry_price - 1) * 100) if pos.entry_price else 0.0
        if peak_profit >= p["activation"]:
            stop = pos.peak * (1 - Decimal(str(p["trail"])) / 100)
            if market.price <= stop:
                reason = m("trailing.triggered_reason", stop=money(stop, q), high=money(pos.peak, q), profit=pct(profit))
                return Decision(m("trailing.triggered"), Sell(reason))
            return Decision(m("trailing.active", stop=money(stop, q), profit=pct(profit)))
        return Decision(m("trailing.position", profit=pct(profit), activation=pct(p["activation"])))
