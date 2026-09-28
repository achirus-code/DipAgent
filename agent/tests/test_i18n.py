from app.i18n import dump, lang_from_header, m, money, pct, qty, render
from app.strategies import STRATEGIES


def test_language_detection():
    assert lang_from_header("de-DE,de;q=0.9,en;q=0.8") == "de"
    assert lang_from_header("en-US") == "en"
    assert lang_from_header(None) == "en"
    assert lang_from_header("fr-FR") == "en"


def test_messages_are_rendered_per_language():
    msg = m("engine.sold", qty=qty(0.02187), base="ETH", amount=money(1234.5, "EUR"), pnl=money(-0.051, "EUR"))
    assert render(msg, "en") == "Sold 0.02187 ETH for 1,234.50 EUR · result -0.05 EUR"
    assert render(msg, "de") == "Verkauft: 0,02187 ETH für 1.234,50 EUR · Ergebnis -0,05 EUR"
    assert render(m("dip.buy_reason", hours=24, change=pct(-1.234), threshold=pct(-1)), "en") == "24h change −1.23% ≤ −1.00%"
    assert render(m("dip.buy_reason", hours=24, change=pct(-1.234), threshold=pct(-1)), "de") == "24h-Veränderung −1,23 % ≤ −1,00 %"


def test_stored_messages_and_legacy_text():
    stored = dump(m("status.stopped"))  # JSON string as in the database
    assert render(stored, "de") == "Gestoppt" and render(stored, "en") == "Stopped"
    assert render("Alter Status-Text", "en") == "Alter Status-Text"  # rows written before i18n
    assert render(m("event.bot_created", strategy=m("strategy.dip"), symbol="ETH-EUR"), "en") == "Bot created (Dip buyer, ETH-EUR)"


def test_strategy_metadata_is_translated():
    dip = STRATEGIES["dip"]
    en, de = dip.to_json("en"), dip.to_json("de")
    assert en["name"] == "Dip buyer" and de["name"] == "Dip-Käufer"
    assert en["params"][0]["label"] == "Amount per buy" and de["params"][0]["label"] == "Betrag pro Kauf"
    mode = next(p for p in de["params"] if p["key"] == "sell_mode")
    assert mode["options"][0] == {"value": "change", "label": "Veränderung wieder erreicht"}
