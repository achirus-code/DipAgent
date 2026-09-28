"""Tiny i18n layer (English / German).

Texts that end up in the database (bot status, events, trade reasons) are stored language-neutral as
``{"k": <message key>, "a": {<args>}}`` and rendered per request in the language of the app
(``Accept-Language``). Numeric arguments are typed (see ``pct``/``money``/``qty``/``dur``/``num``) so that
they are formatted per language as well (``1,234.56`` vs. ``1.234,56``).
"""

from __future__ import annotations

import json
from decimal import Decimal
from typing import Any

LANGUAGES = ("en", "de")
DEFAULT_LANGUAGE = "en"


class L:
    """A text in both languages."""

    __slots__ = ("en", "de")

    def __init__(self, en: str, de: str):
        self.en, self.de = en, de

    def __call__(self, lang: str) -> str:
        return self.de if lang == "de" else self.en


def lang_from_header(accept_language: str | None) -> str:
    """"de-DE,de;q=0.9,en;q=0.8" -> "de"; everything that isn't German gets English."""
    first = (accept_language or "").split(",")[0].strip().lower()
    return "de" if first.startswith("de") else DEFAULT_LANGUAGE


# --- typed arguments ------------------------------------------------------------------


def pct(value: float) -> dict:
    return {"$": "pct", "v": float(value)}


def money(value: Decimal | float, currency: str) -> dict:
    return {"$": "money", "v": float(value), "c": currency}


def qty(value: Decimal | float) -> dict:
    return {"$": "qty", "v": float(value)}


def dur(ms: int) -> dict:
    return {"$": "dur", "v": int(ms)}


def num(value: float, decimals: int = 1) -> dict:
    return {"$": "num", "v": float(value), "d": decimals}


def m(key: str, **args: Any) -> dict:
    """A message: rendered later in the reader's language."""
    return {"k": key, "a": args}


class Problem(Exception):
    """An error with a translatable message (str() gives English, for logs)."""

    def __init__(self, key: str, **args: Any):
        self.msg = m(key, **args)
        super().__init__(render(self.msg, DEFAULT_LANGUAGE))


def as_message(exc: BaseException) -> dict | str:
    return exc.msg if isinstance(exc, Problem) else str(exc)


# --- rendering ----------------------------------------------------------------------------


def _number(value: float, decimals: int, lang: str) -> str:
    text = f"{value:,.{decimals}f}"
    return text.replace(",", "X").replace(".", ",").replace("X", ".") if lang == "de" else text


def _format_arg(arg: Any, lang: str) -> str:
    if isinstance(arg, dict):
        if "k" in arg:
            return render(arg, lang)
        kind, v = arg.get("$"), arg.get("v", 0)
        if kind == "pct":
            sign = "+" if v >= 0 else "−"
            return f"{sign}{_number(abs(v), 2, lang)}{' %' if lang == 'de' else '%'}"
        if kind == "money":
            if v == 0 or abs(v) >= 0.01:
                text = _number(v, 2, lang)
            else:  # tiny prices, e.g. 0.000021
                text = f"{v:.6f}".rstrip("0")
                text = text.replace(".", ",") if lang == "de" else text
            return f"{text} {arg.get('c', '')}".strip()
        if kind == "qty":
            text = f"{v:.8f}".rstrip("0").rstrip(".")
            return text.replace(".", ",") if lang == "de" else text
        if kind == "dur":
            minutes = max(0, int(v) // 60_000)
            if minutes < 60:
                return f"{minutes} min"
            hours, rest = divmod(minutes, 60)
            return f"{hours} h {rest} min" if rest else f"{hours} h"
        if kind == "num":
            return _number(v, int(arg.get("d", 1)), lang)
        return str(arg)
    if isinstance(arg, list):
        return " / ".join(_format_arg(a, lang) for a in arg)
    if isinstance(arg, bool):
        return CATALOG["yes" if arg else "no"](lang)
    if isinstance(arg, float):
        return _number(arg, 2, lang)
    return str(arg)


def render(value: Any, lang: str) -> str:
    """Render a message dict, a JSON-encoded message (from the DB) or return plain strings as they are."""
    if value is None:
        return ""
    if isinstance(value, str):
        if not value.startswith("{"):
            return value  # legacy plain text
        try:
            value = json.loads(value)
        except ValueError:
            return value
    if not isinstance(value, dict) or "k" not in value:
        return str(value)
    template = CATALOG.get(value["k"])
    args = {k: _format_arg(v, lang) for k, v in (value.get("a") or {}).items()}
    if template is None:
        return value["k"]
    try:
        return template(lang).format(**args)
    except (KeyError, IndexError):
        return template(lang)


def message_key(value: Any) -> str | None:
    """The key of a stored message (None for legacy plain text)."""
    if isinstance(value, str) and value.startswith("{"):
        try:
            value = json.loads(value)
        except ValueError:
            return None
    return value.get("k") if isinstance(value, dict) else None


def text(key: str, lang: str, **args: Any) -> str:
    return render(m(key, **args), lang)


def dump(value: Any) -> Any:
    """Serialise messages for storage; plain strings stay as they are."""
    return json.dumps(value, ensure_ascii=False) if isinstance(value, dict) else value


def register(key: str, value: L) -> None:
    CATALOG[key] = value


# --- catalog ------------------------------------------------------------------------------

CATALOG: dict[str, L] = {
    "yes": L("yes", "ja"),
    "no": L("no", "nein"),
    "side.buy": L("buy", "Kauf"),
    "side.sell": L("sell", "Verkauf"),
    "paren": L("{text} ({detail})", "{text} ({detail})"),
    # --- shared strategy texts
    "window": L("{hours} h: {change}", "{hours} h: {change}"),
    "cooldown": L("Cooling down for {left}", "Pause noch {left}"),
    "cooldown.window": L("Cooling down for {left} · {window}", "Pause noch {left} · {window}"),
    "buy_signal": L("Buy signal", "Kaufsignal"),
    "stop_loss": L("Stop-loss", "Stop-Loss"),
    "stop_loss.reason": L("Stop-loss at {profit}", "Stop-Loss bei {profit}"),
    "take_profit": L("Profit target reached", "Gewinnziel erreicht"),
    "take_profit.reason": L("Profit target {profit} ≥ {target}", "Gewinnziel {profit} ≥ {target}"),
    # --- dip buyer
    "dip.buy_signal": L("Buy signal · {window}", "Kaufsignal · {window}"),
    "dip.buy_reason": L("{hours}h change {change} ≤ {threshold}", "{hours}h-Veränderung {change} ≤ {threshold}"),
    "dip.waiting": L("Waiting for a dip · {window} (buy at ≤ {threshold})", "Warte auf Dip · {window} (Kauf ≤ {threshold})"),
    "dip.recovered": L("Recovered", "Erholung erreicht"),
    "dip.recovered.reason": L(
        "{hours}h change {change} ≥ {threshold}, profit {profit}",
        "{hours}h-Veränderung {change} ≥ {threshold}, Gewinn {profit}",
    ),
    "dip.recovered_hold": L(
        "Recovered, but profit {profit} < minimum {min} · holding",
        "Erholt, aber Gewinn {profit} < Mindestgewinn {min} · halte",
    ),
    "dip.target_change": L("sell at {hours} h ≥ {threshold}", "Verkauf bei {hours} h ≥ {threshold}"),
    "dip.target_profit": L("target {target}", "Ziel {target}"),
    "dip.position": L("Position {profit} · {window} · {targets}", "Position {profit} · {window} · {targets}"),
    # --- price zones
    "zones.no_price": L("No buy price set", "Kein Kaufpreis eingestellt"),
    "zones.buy_signal": L("Buy zone reached", "Kaufzone erreicht"),
    "zones.buy_reason": L("Price {price} ≤ {limit}", "Kurs {price} ≤ {limit}"),
    "zones.waiting": L("Price {price} · buy below {limit}", "Kurs {price} · Kauf unter {limit}"),
    "zones.stop_reason": L("Price {price} ≤ stop {stop}", "Kurs {price} ≤ Stop {stop}"),
    "zones.target": L("Target price reached", "Zielpreis erreicht"),
    "zones.target_reason": L("Price {price} ≥ {target}", "Kurs {price} ≥ {target}"),
    "zones.position": L("Position {profit} · sell above {target}", "Position {profit} · Verkauf über {target}"),
    # --- savings plan
    "dca.take_profit_reason": L("Savings plan profit {profit} ≥ {target}", "Sparplan-Gewinn {profit} ≥ {target}"),
    "dca.max_buys": L(
        "Max. {count} buys reached · invested {invested} · {profit}",
        "Max. {count} Käufe erreicht · investiert {invested} · {profit}",
    ),
    "dca.max_invest": L("Maximum reached · invested {invested}", "Maximum erreicht · investiert {invested}"),
    "dca.due": L("Installment due", "Sparrate fällig"),
    "dca.reason": L("Savings plan installment", "Sparplan-Rate"),
    "dca.next": L("Next installment in {left} · invested {invested}", "Nächste Rate in {left} · investiert {invested}"),
    "dca.next_profit": L(
        "Next installment in {left} · invested {invested} · {profit}",
        "Nächste Rate in {left} · investiert {invested} · {profit}",
    ),
    # --- rebound + trailing stop
    "trailing.buy_reason": L("{distance} below {hours}h high {high}", "{distance} unter {hours}h-Hoch {high}"),
    "trailing.waiting": L(
        "{distance} below {hours}h high · buy at −{drop}%",
        "{distance} unter {hours}h-Hoch · Kauf ab −{drop} %",
    ),
    "trailing.triggered": L("Trailing stop triggered", "Trailing-Stop ausgelöst"),
    "trailing.triggered_reason": L(
        "Trailing stop {stop} (high {high}), profit {profit}",
        "Trailing-Stop {stop} (Hoch {high}), Gewinn {profit}",
    ),
    "trailing.active": L("Trailing active · stop {stop} · {profit}", "Trailing aktiv · Stop {stop} · {profit}"),
    "trailing.position": L("Position {profit} · trailing from {activation}", "Position {profit} · Trailing ab {activation}"),
    # --- engine
    "engine.instance_locked": L(
        "Another DipAgent engine is already running with this data directory – this instance does not trade.",
        "Eine andere DipAgent-Engine läuft bereits mit diesem Datenverzeichnis – diese Instanz handelt nicht.",
    ),
    "engine.no_market_data": L("No market data: {error}", "Keine Marktdaten: {error}"),
    "engine.waiting_for_order": L("Waiting for order execution …", "Warte auf Order-Ausführung …"),
    "engine.error": L("Error: {error}", "Fehler: {error}"),
    "engine.unknown_strategy": L("Unknown strategy “{strategy}”", "Unbekannte Strategie „{strategy}“"),
    "engine.manual_close": L("Closed manually", "Manuell geschlossen"),
    "engine.live_ended": L("Live trading ended – position sold", "Live-Handel beendet – Position verkauft"),
    "engine.live_close_failed": L("Live position could not be sold: {error}", "Live-Position konnte nicht verkauft werden: {error}"),
    "engine.order_running_no_buy": L("Order in progress – no further buy", "Order läuft bereits – kein weiterer Kauf"),
    "engine.position_open_no_buy": L("Position already open – no second buy", "Position bereits offen – kein zweiter Kauf"),
    "engine.mode_changed_paper": L(
        "Paper position open, mode was changed – selling only",
        "Paper-Position offen, Modus wurde geändert – nur noch Verkauf",
    ),
    "engine.mode_changed_live": L(
        "Live position open, mode was changed – selling only",
        "Live-Position offen, Modus wurde geändert – nur noch Verkauf",
    ),
    "engine.buy_skipped": L("Buy signal skipped · {reason}", "Kaufsignal übersprungen · {reason}"),
    "engine.no_position": L("No position", "Keine Position"),
    "engine.order_sent": L("Order {id} ({side}) sent", "Order {id} ({side}) gesendet"),
    "engine.order_not_found": L(
        "The order was not created at the exchange – discarded",
        "Order wurde bei der Börse nicht angelegt – verworfen",
    ),
    "engine.order_booked": L("Order already booked", "Order bereits verbucht"),
    "engine.order_failed": L("Order {status}", "Order {status}"),
    "engine.order_failed_reason": L("Order {status}: {reason}", "Order {status}: {reason}"),
    "engine.bought": L("Bought {qty} {base} for {amount}", "Gekauft: {qty} {base} für {amount}"),
    "engine.sold": L("Sold {qty} {base} for {amount} · result {pnl}", "Verkauft: {qty} {base} für {amount} · Ergebnis {pnl}"),
    "limit.positions": L("Limit reached: {count}/{max} positions open", "Limit erreicht: {count}/{max} Positionen offen"),
    "limit.symbol": L("Another bot already holds a {symbol} position", "Ein anderer Bot hält bereits eine {symbol}-Position"),
    "limit.capital": L("Capital limit: {invested} invested, max. {max}", "Kapital-Limit: {invested} investiert, max. {max}"),
    # --- errors
    "err.no_position": L("No open position", "Keine offene Position"),
    "err.order_running": L("An order is already in progress", "Es läuft bereits eine Order"),
    "err.amount_below_min": L("Amount {amount} is below the minimum of {min}", "Betrag {amount} unter Mindestgröße {min}"),
    "err.insufficient": L(
        "Not enough {currency}: available {available}, needed {needed}",
        "Nicht genug {currency}: verfügbar {available}, benötigt {needed}",
    ),
    "err.sell_below_min": L(
        "Sell amount {qty} {base} is below the minimum of {min} (available: {available})",
        "Verkaufsmenge {qty} {base} unter Mindestgröße {min} (verfügbar: {available})",
    ),
    "err.order_unclear": L(
        "Order status unclear ({error}) – it will be checked automatically, no new order is sent",
        "Order-Status unklar ({error}) – wird automatisch geprüft, keine neue Order",
    ),
    "err.unknown_pair": L("Unknown trading pair: {symbol}", "Unbekanntes Handelspaar: {symbol}"),
    "err.no_ticker": L("No ticker for {symbol}", "Kein Ticker für {symbol}"),
    "err.not_enough": L("Not enough {currency}", "Nicht genug {currency}"),
    "exchange.key_file_missing": L("Revolut X not configured: {path} is missing", "Revolut X nicht konfiguriert: {path} fehlt"),
    "exchange.not_set_up": L(
        "Revolut X is not set up – connect it in the app under Settings → Revolut X",
        "Revolut X nicht eingerichtet – in der App unter Einstellungen → Revolut X verbinden",
    ),
    # --- API
    "api.invalid_token": L("Invalid or missing API token", "Ungültiges oder fehlendes API-Token"),
    "api.unknown_strategy": L("Unknown strategy: {strategy}", "Unbekannte Strategie: {strategy}"),
    "api.pair_unavailable": L("Trading pair {symbol} is not available on Revolut X", "Handelspaar {symbol} ist auf Revolut X nicht verfügbar"),
    "api.bot_not_found": L("Bot not found", "Bot nicht gefunden"),
    "api.demo_mode": L("The agent runs in demo mode (EXCHANGE=mock)", "Der Agent läuft im Demo-Modus (EXCHANGE=mock)"),
    "api.env_configured": L(
        "Revolut X is configured in the agent's .env file and can only be changed there",
        "Revolut X ist über die .env-Datei des Agents konfiguriert und kann nur dort geändert werden",
    ),
    "api.api_key_chars": L(
        "The API key may only contain letters and digits (Revolut X: 64 characters)",
        "Der API-Key darf nur Buchstaben und Ziffern enthalten (Revolut X: 64 Zeichen)",
    ),
    "api.keypair_first": L("Please generate a key pair first", "Bitte zuerst ein Schlüsselpaar erzeugen"),
    "api.key_rejected": L("Revolut X rejected the key: {error}", "Revolut X hat den Key abgelehnt: {error}"),
    "api.key_rejected_hint": L(
        "Revolut X rejected the key: {error} – is the public key registered with exactly this API key?",
        "Revolut X hat den Key abgelehnt: {error} – ist der Public Key bei genau diesem API-Key hinterlegt?",
    ),
    "api.revx_unreachable": L("Revolut X is not reachable: {error}", "Revolut X nicht erreichbar: {error}"),
    "api.public_ip_failed": L("Could not determine the public IP: {error}", "Öffentliche IP nicht ermittelbar: {error}"),
    "api.no_live_in_demo": L(
        "There is no live trading on the demo market (EXCHANGE=mock)",
        "Im Demo-Markt (EXCHANGE=mock) gibt es keinen Live-Handel",
    ),
    "api.connect_revx_first": L("Please connect Revolut X first", "Bitte zuerst Revolut X verbinden"),
    "api.confirm_live": L("Live trading must be confirmed explicitly", "Live-Handel muss ausdrücklich bestätigt werden"),
    "api.revx_unreachable_live": L(
        "Revolut X is not reachable – live trading stays off: {error}",
        "Revolut X nicht erreichbar – Live-Handel bleibt aus: {error}",
    ),
    "api.locked_pair_strategy": L(
        "Trading pair/strategy cannot be changed while a position is open",
        "Handelspaar/Strategie kann bei offener Position nicht geändert werden",
    ),
    "api.locked_mode": L(
        "Paper/live mode cannot be switched while a position is open",
        "Paper-/Live-Modus kann bei offener Position nicht gewechselt werden",
    ),
    "api.delete_open_position": L(
        "The bot has an open position – close it first or delete with force",
        "Bot hat eine offene Position – erst schließen oder mit force löschen",
    ),
    # --- statuses and events
    "status.starting": L("Starting …", "Wird gestartet …"),
    "status.stopped": L("Stopped", "Gestoppt"),
    "event.bot_created": L("Bot created ({strategy}, {symbol})", "Bot angelegt ({strategy}, {symbol})"),
    "event.settings_changed": L("Settings changed", "Einstellungen geändert"),
    "event.bot_started": L("Bot started", "Bot gestartet"),
    "event.bot_stopped": L("Bot stopped", "Bot gestoppt"),
    "event.limits_changed": L("Limits changed", "Limits geändert"),
    "event.keypair": L("New Revolut X key pair generated", "Neues Revolut-X-Schlüsselpaar erzeugt"),
    "event.revx_connected": L("Revolut X connected", "Revolut X verbunden"),
    "event.revx_removed": L("Revolut X access removed", "Revolut-X-Zugang entfernt"),
    "event.live_off_access_removed": L(
        "Live trading disabled (Revolut X access removed)",
        "Live-Handel deaktiviert (Revolut-X-Zugang entfernt)",
    ),
    "event.live_on": L("Live trading ENABLED – real orders on Revolut X", "Live-Handel AKTIVIERT – echte Orders auf Revolut X"),
    "event.live_off": L("Live trading disabled – paper trading only", "Live-Handel deaktiviert – nur noch Paper-Trading"),
    "event.bot_live": L("Switched to live (live trading enabled)", "Live geschaltet (Live-Handel aktiviert)"),
}
