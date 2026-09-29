"""Dip buyer: buy after the price dropped by X % within a time window, sell on recovery."""

from __future__ import annotations

from decimal import Decimal

from ..i18n import L, dur, m, pct
from .base import Buy, Context, Decision, Option, Param, Sell, Strategy, cooldown_left


class DipStrategy(Strategy):
    key = "dip"
    name = L("Dip buyer", "Dip-Käufer")
    description = L(
        "Buys once the price change within the time window (e.g. 24 h) falls below the buy threshold (e.g. −1 %) "
        "and sells when the price has recovered (e.g. 24h change ≥ 0 %) or the profit target is reached.",
        "Kauft, sobald die Kursveränderung im Zeitfenster (z. B. 24 h) unter die Kaufschwelle fällt (z. B. −1 %), "
        "und verkauft, wenn sich der Kurs wieder erholt hat (z. B. 24h-Veränderung ≥ 0 %) oder das Gewinnziel erreicht ist.",
    )
    icon = "arrow.down.right.circle"
    params = [
        Param("amount", L("Amount per buy", "Betrag pro Kauf"), "money", 50.0,
              L("How much of the quote currency is invested per buy.", "Wie viel in der Quote-Währung pro Kauf investiert wird."), min=1),
        Param("lookback_hours", L("Time window", "Zeitfenster"), "int", 24,
              L("Over how many hours the change is measured.", "Über wie viele Stunden die Veränderung gemessen wird."),
              min=1, max=168, unit="h"),
        Param("buy_threshold", L("Buy at change ≤", "Kaufen bei Veränderung ≤"), "percent", -1.0,
              L("e.g. −1 % = the price fell by at least 1 % within the window.", "z. B. −1 % = Kurs ist im Zeitfenster um mind. 1 % gefallen."),
              min=-50, max=0, step=0.1),
        Param("sell_mode", L("Sell when", "Verkaufen wenn"), "select", "change", options=[
            Option("change", L("Change recovered", "Veränderung wieder erreicht")),
            Option("profit", L("Profit target reached", "Gewinnziel erreicht")),
            Option("either", L("Whichever comes first", "Was zuerst eintritt")),
        ]),
        Param("sell_threshold", L("Sell at change ≥", "Verkaufen bei Veränderung ≥"), "percent", 0.0,
              L("e.g. 0 % = the price is back at its level of 24 h ago.", "z. B. 0 % = Kurs liegt wieder auf dem Niveau von vor 24 h."),
              min=-50, max=50, step=0.1),
        Param("take_profit", L("Profit target", "Gewinnziel"), "percent", 2.0,
              L("Sell as soon as the position has this much profit.", "Verkauf, sobald die Position so viel Gewinn hat."),
              min=0.1, max=100, step=0.1),
        Param("min_profit", L("Minimum profit", "Mindestgewinn"), "percent", 0.25,
              L("With “Change recovered”, only sell with at least this profit. The bot never sells at a loss anyway – only the stop-loss does.",
                "Bei „Veränderung erreicht“ nur verkaufen, wenn mindestens dieser Gewinn erzielt wird. Mit Verlust verkauft der Bot ohnehin nie – nur der Stop-Loss."),
              min=0, max=100, step=0.05),
        Param("stop_loss", L("Stop-loss", "Stop-Loss"), "percent", 0.0,
              L("Sell at this loss. 0 = off.", "Verkauf bei so viel Verlust. 0 = aus."), min=0, max=90, step=0.5),
        Param("cooldown_minutes", L("Pause after selling", "Pause nach Verkauf"), "int", 60,
              L("Minutes to wait after a sale before buying again.", "Minuten Wartezeit nach einem Verkauf, bevor erneut gekauft wird."),
              min=0, max=10080, unit="min"),
    ]

    async def evaluate(self, ctx: Context) -> Decision:
        p, market, pos = ctx.params, ctx.market, ctx.position
        hours = p["lookback_hours"]
        ref = await market.price_at(hours)
        change = float((market.price / ref - 1) * 100) if ref else 0.0
        window = m("window", hours=hours, change=pct(change))

        if pos is None:
            ctx.targets(buy=ref * (1 + Decimal(str(p["buy_threshold"])) / 100))
            wait = cooldown_left(ctx, p["cooldown_minutes"])
            if wait:
                return Decision(m("cooldown.window", left=dur(wait), window=window))
            if change <= p["buy_threshold"]:
                reason = m("dip.buy_reason", hours=hours, change=pct(change), threshold=pct(p["buy_threshold"]))
                return Decision(m("dip.buy_signal", window=window), Buy(Decimal(str(p["amount"])), reason))
            return Decision(m("dip.waiting", window=window, threshold=pct(p["buy_threshold"])))

        profit = pos.pnl_pct(market.bid)
        mode = p["sell_mode"]
        # the price the sale waits for: profit target and/or recovered change (never below the minimum profit)
        entry = pos.entry_price
        sell_at = []
        if mode in {"profit", "either"}:
            sell_at.append(entry * (1 + Decimal(str(p["take_profit"])) / 100))
        if mode in {"change", "either"}:
            sell_at.append(max(ref * (1 + Decimal(str(p["sell_threshold"])) / 100), entry * (1 + Decimal(str(p["min_profit"])) / 100)))
        ctx.targets(sell=min(sell_at) if sell_at else None,
                    stop=entry * (1 - Decimal(str(p["stop_loss"])) / 100) if p["stop_loss"] > 0 else None)
        if p["stop_loss"] > 0 and profit <= -p["stop_loss"]:
            return Decision(m("stop_loss"), Sell(m("stop_loss.reason", profit=pct(profit)), stop=True))

        if mode in {"profit", "either"} and profit >= p["take_profit"]:
            return Decision(m("take_profit"), Sell(m("take_profit.reason", profit=pct(profit), target=pct(p["take_profit"]))))
        if mode in {"change", "either"} and change >= p["sell_threshold"]:
            if profit >= p["min_profit"]:
                reason = m("dip.recovered.reason", hours=hours, change=pct(change),
                           threshold=pct(p["sell_threshold"]), profit=pct(profit))
                return Decision(m("dip.recovered"), Sell(reason))
            return Decision(m("dip.recovered_hold", profit=pct(profit), min=pct(p["min_profit"])))

        targets = []
        if mode in {"change", "either"}:
            targets.append(m("dip.target_change", hours=hours, threshold=pct(p["sell_threshold"])))
        if mode in {"profit", "either"}:
            targets.append(m("dip.target_profit", target=pct(p["take_profit"])))
        return Decision(m("dip.position", profit=pct(profit), window=window, targets=targets))
