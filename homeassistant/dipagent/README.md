# DipAgent

Trading bots for [Revolut X](https://exchange.revolut.com) that run 24/7 on your Home Assistant – controlled from
the DipAgent macOS menu bar app.

The add-on runs the DipAgent agent (REST API + bot engine) and stores bots, trades, settings and the Revolut X key in
the add-on's data directory, which is part of your Home Assistant backups. There is no web UI: install the macOS app
from <https://github.com/achirus-code/DipAgent>, point it at your Home Assistant host (port 3470) and enter the API
token.

Everything starts in **paper mode** (real prices, simulated orders). Crypto trading can lose money – this is a
personal project, not financial advice.
