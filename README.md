# DipAgent

[![CI](https://github.com/achirus-code/DipAgent/actions/workflows/ci.yml/badge.svg)](https://github.com/achirus-code/DipAgent/actions/workflows/ci.yml)

**Trading bots for [Revolut X](https://exchange.revolut.com) that run 24/7 in Docker – controlled from a tiny macOS menu bar app.**

DipAgent consists of two parts:

- **Agent** (`agent/`) – a small Python service in a Docker container. It checks the market around the clock, runs
  your bots and places orders on Revolut X. Run it on any always-on machine: a home server, NAS, Raspberry Pi or Mac mini.
- **App** (`macos/`) – a native SwiftUI menu bar app. One icon in the menu bar; a click shows your trades, bots and
  profit, and lets you manage bots, limits and the Revolut X connection.

The app is available in **English and German** (follows the macOS language, can be changed in the app).

<p align="center">
  <img src="docs/screenshots/bots.png" width="240" alt="Bots">
  <img src="docs/screenshots/trades.png" width="240" alt="Trades">
  <img src="docs/screenshots/bot-detail.png" width="240" alt="Bot detail">
  <img src="docs/screenshots/new-bot.png" width="240" alt="New bot">
</p>

> **Disclaimer:** DipAgent is a personal project, not financial advice. Crypto trading can lose money. Everything
> starts in **paper mode** (real prices, simulated orders). Only enable live trading once you trust your setup –
> and start small.

## Features

- **Five strategies**, configurable per bot (see below) – e.g. *“buy ETH-EUR after the price dropped ≥ 1 % in 24 h,
  sell once it has recovered”*.
- **Paper mode by default.** Live trading is switched on in the app, only after Revolut X is connected and after a
  **double confirmation**. Switching back to paper mode sells all open live positions (with a warning first).
- **Risk limits:** max. open positions, max. invested capital, only one bot per trading pair.
- **No duplicate orders:** each bot holds at most one position, orders are persisted with their own
  `client_order_id` *before* they are sent and reconciled after connection drops, every exchange order is booked
  exactly once, and only one engine may trade per data directory. An order that cannot be found at the exchange
  for minutes stops the bot instead of being guessed about.
- **Revolut X setup from the app:** the agent generates the Ed25519 key pair – the private key never leaves the
  agent; the app shows the public key to register with Revolut X and verifies the API key you get back.
- **Menu bar app:** total and per-bot profit (realized/open/today), trade history, bot activity log, notifications
  for new trades, launch at login, light & dark mode.

## How it works

```
┌────────────────────────┐  HTTP · bearer token   ┌──────────────────────────────┐  signed REST calls  ┌───────────┐
│  macOS menu bar app    │ ─────────────────────▶ │  DipAgent agent (Docker)     │ ──────────────────▶ │ Revolut X │
│  trades · bots · setup │ ◀───────────────────── │  REST API · bot engine · DB  │ ◀────────────────── │  API 1.0  │
└────────────────────────┘      port 3470         └──────────────────────────────┘      Ed25519        └───────────┘
```

The agent evaluates every active bot every `TICK_SECONDS` (default 30 s), places market orders on Revolut X and
stores bots, trades, settings and the Revolut X key in a Docker volume (`/data`, SQLite).

## Strategies

| Strategy | Buys … | Sells … |
|---|---|---|
| **Dip buyer** | when the price change within a time window (default 24 h) is ≤ the buy threshold (default −1 %) | when the change is back to ≥ the sell threshold (default 0 %) *and* a minimum profit is reached, or at the profit target, or whichever comes first; optional stop-loss |
| **Rebound + trailing stop** | when the price is X % below the high of the last N hours | via a trailing stop once the activation profit is reached; optional stop-loss |
| **Price zones** | below a fixed price | above a target price or at a stop price |
| **Savings plan** | a fixed amount every N hours (up to a max. amount / number of buys) | optionally everything at the profit target |
| **AI decides** | when Claude sees an edge – it looks at trend, volatility of the last hours, momentum and optionally the news every N minutes | when Claude decides to take the profit; never at a loss (only the optional stop-loss may). Needs `ANTHROPIC_API_KEY` on the agent; every check costs a few cents |

> **Going live with open paper positions:** bots keep simulating an open paper position until it is sold, then buy
> live. The savings plan is the exception – it closes its paper position (simulated) with the next instalment and
> continues live, otherwise it could never buy again.

> **Note on the dip buyer:** the 24 h change is a *rolling* window. If the price keeps falling after the buy, the
> 24 h change can return to 0 % while the position is still at a loss. That's why the bot only sells in this mode
> once the **minimum profit** (default 0.25 %, covers fees) is reached. Set it negative to sell at a loss if needed.

## Quick start

### 1. Run the agent (Docker)

Requirements: Docker with Docker Compose v2 on an always-on machine (x86-64 or arm64). Running Home Assistant OS?
Use the [add-on](#home-assistant-add-on) instead.

```bash
git clone https://github.com/achirus-code/DipAgent.git
cd DipAgent/agent
cp .env.example .env
sed -i.bak "s/^API_TOKEN=.*/API_TOKEN=$(openssl rand -hex 24)/" .env && rm .env.bak
docker compose up -d                         # pulls ghcr.io/achirus-code/dipagent (or: up -d --build to build locally)
docker compose logs -f                       # "Engine started …"
```

The agent now listens on port **3470**. The token in `.env` is what the app uses to log in. If you leave `API_TOKEN`
empty, the agent generates one on first start and prints it to the log (it's also stored in the data volume:
`docker compose exec dipagent cat /data/api_token`).

#### Home Assistant add-on

The agent is also available as a Home Assistant add-on – the same image, configured from the add-on's
**Configuration** tab instead of `.env`:

1. **Settings → Add-ons → Add-on store → ⋮ → Repositories**, add `https://github.com/achirus-code/DipAgent`.
2. Install **DipAgent**, optionally set an API token under *Configuration* (empty = generated and printed to the
   add-on log), then **Start**.
3. In the app, use the Home Assistant host as the agent address. All data is stored in the add-on's data directory
   and is part of Home Assistant backups.

Details: [homeassistant/dipagent/DOCS.md](homeassistant/dipagent/DOCS.md).

### 2. Install the app

Requirements: macOS 14 or newer and the Xcode Command Line Tools (`xcode-select --install`) – Xcode itself isn't needed.

```bash
cd DipAgent/macos
./build-app.sh
cp -R build/DipAgent.app /Applications/
open /Applications/DipAgent.app
```

The chart icon appears in the menu bar. Open **Settings**, enter the agent's address (just the IP or host name,
e.g. `192.168.1.10` – port 3470 is added automatically) and the API token, then **Connect**.

> The app is ad-hoc signed. After each new build macOS may ask whether DipAgent may use the keychain (where the
> token is stored) – choose *Always Allow*. If Gatekeeper complains on first launch, right-click the app → *Open*.

### 3. Connect Revolut X

In the app: **Settings → Revolut X → Connect** and follow the three steps:

1. **Generate key pair** – created on the agent; the app shows the public key with a *Copy* button.
2. **Register with Revolut X** – the link opens <https://exchange.revolut.com/account/api-keys>. Create a new API key
   with the public key (including the `BEGIN`/`END` lines), allow trading, and – if Revolut X asks for allowed IPs – add
   the agent's public IP shown in the app. The panel stays open during the setup so you can copy back and forth.
3. **Enter the API key** – the agent verifies it right away (balance request) and switches to Revolut X without a
   restart.

### 4. Create bots, then go live (optional)

Create bots under **Bots → New bot**. They trade in paper mode first: real prices, simulated orders and fees. When
you're happy, enable **Settings → Trading mode → Live trading** (double confirmation). All existing bots are switched
to live then – delete bots that shouldn't trade with real money beforehand.

## Agent configuration

All settings are optional environment variables in `agent/.env`:

| Variable | Default | Description |
|---|---|---|
| `API_TOKEN` | generated | Token the app authenticates with |
| `EXCHANGE` | `revolutx` | `revolutx` = real exchange, `mock` = simulated market for trying things out |
| `TICK_SECONDS` | `30` | How often the bots check the market |
| `TAKER_FEE` | `0.0009` | Fee used for simulated (paper) trades |
| `TZ` | UTC | Time zone, used for "today" in the summary (e.g. `Europe/Berlin`) |
| `REVX_API_KEY` | – | Alternative to the in-app setup: API key here + private key in `agent/secrets/revx_private.pem` (takes precedence; read-only in the app) |
| `MOCK_SPEED` | `1` | Only for `EXCHANGE=mock`: time lapse (60 = one market hour per minute) |
| `ANTHROPIC_API_KEY` | – | Only for the *AI decides* strategy (Claude decides when to buy and sell). Key from console.anthropic.com |

Live trading, limits and bots are managed in the app and stored in the data volume – not in `.env`.

**Try it without Revolut X:** set `EXCHANGE=mock` (and e.g. `MOCK_SPEED=60`) – the agent then simulates a market
with realistic ups and downs.

### Operating the agent

```bash
docker compose logs -f                                # follow the log
docker compose pull && docker compose up -d           # update (or: git pull && … --build)
docker compose down                                   # stop (data stays in the volume)
docker run --rm -v dipagent_dipagent-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/dipagent-backup.tgz -C /data .      # backup of bots, trades, settings and key
```

- **Data** lives in the Docker volume `dipagent_dipagent-data` (SQLite database, API token, Revolut X key with file
  mode 600).
- **Backup from the app:** *Settings → Backup → Export* saves bots, trades, settings and the Revolut X key as a
  `.tgz`; *Import* restores such a file on any agent (e.g. when moving from Docker to the Home Assistant add-on).
  Importing replaces the agent's data and switches live trading off until you enable it again.
- **Network:** the app talks plain HTTP with a bearer token. Keep port 3470 inside your home network or reach it via a
  VPN such as Tailscale/WireGuard – don't expose it to the internet. Revolut X API keys can additionally be restricted
  to the agent's public IP.
- **One instance only:** the engine takes a lock in `/data`; a second container on the same volume refuses to trade.
- **User:** the container starts as root only to take ownership of `/data` (a bind mount is chowned to uid 10001)
  and drops to the unprivileged user `dipagent` (uid 10001) before the agent starts. `docker run --user 10001` on a
  volume that already belongs to that user works too.

## Development

```bash
# Agent: tests and a local instance with the simulated market
cd agent
python3.12 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest -q
DATA_DIR=./data EXCHANGE=mock MOCK_SPEED=120 API_TOKEN=devtoken TICK_SECONDS=5 \
  .venv/bin/uvicorn app.main:app --port 3470

# App: debug build, translation check, screenshots of every screen (light + dark) without the menu bar
cd macos
swift build
python3 scripts/check_localizations.py
./build-app.sh && build/DipAgent.app/Contents/MacOS/DipAgent --snapshot /tmp/shots \
  -serverURL 127.0.0.1 -apiToken devtoken -AppleLanguages "(de)"
```

### Project structure

```
agent/                    Python 3.12 · FastAPI · SQLite
  app/main.py             REST API (answers in the app's language via Accept-Language)
  app/engine.py           bot engine: evaluation, limits, idempotent order execution, bookkeeping
  app/strategies/         dip buyer, rebound + trailing stop, price zones, savings plan, AI decides (Claude)
  app/revolutx.py         Revolut X client (Ed25519 request signing)
  app/credentials.py      key pair generation / storage for the in-app Revolut X setup
  app/backup.py           backup archive (database snapshot + key) for export/import from the app
  app/i18n.py             English/German texts of the agent
  tests/
macos/                    SwiftUI menu bar app (Swift package, no Xcode project needed)
  Sources/DipAgent/       app, views, API client
  Resources/*.lproj/      localizations (English = source strings, German translations)
  scripts/                translation check
  build-app.sh            builds and signs DipAgent.app
homeassistant/dipagent/   Home Assistant add-on (config.yaml, docs, translations) – uses the released agent image
scripts/sync-addon.py     copies the agent version and CHANGELOG.md into the add-on (checked in CI)
```

### Releasing

The Docker image and the Home Assistant add-on come from **one build**: bump `VERSION` in `agent/app/main.py`, add
the `## [x.y.z]` section to `CHANGELOG.md`, run `python3 scripts/sync-addon.py` (writes the version into
`homeassistant/dipagent/config.yaml` and copies the changelog), commit, then push a tag `vx.y.z`. The release
workflow builds `ghcr.io/achirus-code/dipagent` for amd64 and arm64 and pushes the `x.y.z` and `latest` tags – Docker
users `docker compose pull`, Home Assistant offers the update in the add-on store.

### Adding a strategy

Create a `Strategy` subclass in `agent/app/strategies/` (name, description and parameters as `L("English", "Deutsch")`)
and register it in `STRATEGIES`. The app renders the settings form from the strategy's parameters automatically – no
app changes needed.

### Translations

The app's source strings are English; `macos/Resources/de.lproj/Localizable.strings` holds the German translations.
To add a language, add `<lang>.lproj/Localizable.strings` (+ `InfoPlist.strings`), list the language in
`Resources/Info.plist` (`CFBundleLocalizations`) and in the agent's `app/i18n.py`. `scripts/check_localizations.py`
(also run in CI) reports missing or unused translations.

### REST API

All routes except `/api/health` require `Authorization: Bearer <API_TOKEN>`; texts are returned in the language of
`Accept-Language` (`de` or English).

| Route | Description |
|---|---|
| `GET /api/status` · `GET /api/summary` | agent status, P&L summary |
| `GET/POST /api/bots` · `PUT/DELETE /api/bots/{id}` | manage bots |
| `POST /api/bots/{id}/start` · `/stop` · `/close` | start/stop a bot, sell its position |
| `GET /api/trades` · `GET /api/events` | trade history, activity log |
| `GET /api/strategies` · `GET /api/pairs` · `GET /api/balances` | strategy schemas, trading pairs, balances |
| `GET/PUT /api/limits` · `PUT /api/live-trading` | risk limits, trading mode |
| `GET /api/exchange` · `POST /api/exchange/keypair` · `PUT/DELETE /api/exchange/credentials` · `GET /api/exchange/public-ip` | Revolut X setup |
| `GET /api/backup` · `POST /api/restore` | backup as `.tgz` (database snapshot + Revolut X key), restore from it |

## License

[MIT](LICENSE) © Tillmann David
