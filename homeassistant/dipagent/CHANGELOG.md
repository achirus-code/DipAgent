# Changelog

All notable changes to DipAgent are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.3.0] – 2026-09-28

### Changed

- **A position is never sold at a loss by a target rule.** Before every strategy sell the agent checks the net
  proceeds at the current bid – sell fee included, rounded up to a full cent the way Revolut X does it for fiat –
  and holds the position while they are below its cost (`engine.hold_no_loss` status). Only the stop-loss, a
  manual "Sell position now" and the end of live trading may realize a loss. Background: a 2 € dip position was
  sold at "+0.33 %" gross and ended at −0.01 € because the sell fee was rounded from 0.0018 € to 0.01 €.
- **Dip buyer:** the minimum profit can no longer be negative.
- **Rebound + trailing stop:** once activated, the trailing stop never sits below break-even (cost plus sell fee),
  so a trailing distance wider than the activation cannot turn into a loss.
- **Price zones:** a reached target price is only sold when it also covers the entry; otherwise the bot holds
  and says so.
- `GET /api/status` reports the exchange fee (`taker_fee`), `GET /api/summary` the fees paid per currency.

### Added

- **Bot editor: cost check.** Below the rules the app shows what a buy plus sell costs at the chosen amount and
  whether the rules' profit target covers it; tiny orders (cent-rounded fee) get a warning with one-click fixes.
- **Bots tab:** bots are grouped into *Active* and *Stopped*, stopped bots get a compact card. A small sort menu
  (running first, result, name, newest) sits in the header, "New bot" moved below the list. Tab order is now
  Bots · Trades · Settings.
- **Statistics card:** the total result is the headline; fees so far and the Revolut X balance (cash plus open
  live positions) sit below it as small lines. Losses are shown in the normal text color, not red.
- **Panel height** can be changed by dragging its bottom edge; the height is remembered.
- **Refresh interval** options are now 30 s, 60 s, 2 min and 5 min (default 60 s).
- *Settings → Trading mode* moves below the agent details once live trading is switched on.

### Fixed

- Results and percentages no longer show "-0,00" for values that round to zero.

## [1.2.0] – 2026-09-28

### Added

- **Backup export and import in the app** (*Settings → Backup*). Export saves bots, trades, settings and the
  Revolut X key as a `.tgz` (`GET /api/backup`, a consistent SQLite snapshot; the API token is not included).
  Import (`POST /api/restore`) replaces the agent's data with such a file without a restart – e.g. to move from
  Docker to the Home Assistant add-on. Live trading is switched off after every restore.
- **Home Assistant add-on** (`homeassistant/dipagent/`). Add this repository in the add-on store, configure the
  token and exchange in the add-on's *Configuration* tab and point the macOS app at your Home Assistant host. The
  add-on uses the very same image as Docker users and stores its data in the add-on data directory (part of
  Home Assistant backups).
- **Released image on GHCR:** `ghcr.io/achirus-code/dipagent` (amd64 + arm64) is built by the release workflow
  from a `vX.Y.Z` tag; `docker compose up -d` pulls it instead of building locally. `scripts/sync-addon.py` keeps
  the add-on version and changelog in sync with the agent (checked in CI).

### Changed

- The container starts as root, takes ownership of `/data` and drops to the unprivileged user (uid 10001) before
  the agent starts (`app/entrypoint.py`). Needed because Home Assistant mounts the data directory root-owned; a
  bind mount on plain Docker is now chowned to uid 10001 as well.

## [1.1.0] – 2026-09-28

Review of the agent with a focus on order execution, stability and load on the exchange API. No changes to
strategies or to the macOS app.

### Fixed

- **A rejected manual close left a ghost order behind.** `POST /api/bots/{id}/close` (and switching back to paper
  mode) persisted the pending order before sending it but did not write the state back when the exchange refused
  it (e.g. insufficient funds). The bot then showed *Waiting for order execution* for three minutes, could not sell
  or be closed in that time and finally logged a misleading *order not found* event.
- **A reconciled order kept the bot in error state for five minutes.** When the response to an order got lost, the
  next tick found and booked the order but the *order unclear* backoff stayed in place: no evaluation (so no
  stop-loss) for five minutes and an *Error* status although the position was open.
- **An unreadable response to an order counted as "order not placed".** `ValueError` (which includes JSON decoding
  errors) was treated like an explicit rejection, so a garbled 2xx response could lead to a second live order. Only
  an explicit `Problem` or a non-transient 4xx from Revolut X is now treated as "definitely not placed"; everything
  else is looked up by `client_order_id` before anything is sent again.
- **Pending orders no longer vanish silently.** An order that cannot be found at the exchange after the grace period
  (placement response lost, or the exchange no longer knows the order id) stops the bot with an error status and
  event instead of being discarded – if it was executed after all, buying again would double the position. The same
  applies to an order id the exchange answers with 404 for.
- **Bots with an order in flight are protected like bots with a position:** trading pair, strategy and mode cannot be
  changed and the bot cannot be deleted without `force` while a `pending_order` exists.
- **Savings plan stuck after enabling live trading.** A DCA bot with an open paper position could neither buy (mode
  changed) nor sell (no profit target). It now closes the paper position with a simulated sell when the next
  instalment is due and continues live.
- **Stale bot state could be written back** when market data for a symbol was missing; the bot is re-read under its
  lock first.
- **Strategy parameters reject `NaN` and `Infinity`** (Python's JSON parser accepts them), which would have broken
  every Decimal comparison in the engine.
- **Exchange error messages** are parsed robustly when the error body is not a JSON object.

### Changed

- **Transient errors back off for one minute instead of five.** Network errors, 429 and 5xx from Revolut X are
  distinguished from real problems, so a single hiccup before a buy no longer costs the dip.
- **Idempotent requests are retried** (GET: three retries with backoff on network errors, 429 and 5xx). Orders are
  never resent – the existing reconciliation covers them.
- **Order tracking polls faster first** (0.3 s … 1.5 s, still about 8 s in total) and the global buy lock is released
  as soon as the pending order is persisted, so other bots are not held up while an order fills.
- **Exchange swap without dropping the running tick:** after entering or removing Revolut X credentials the old HTTP
  client is closed once the current tick has finished instead of mid-request.
- **Graceful shutdown:** the engine task is awaited (up to 10 s), background tasks are cancelled and the database is
  closed.
- The status of a stopped-by-reconciliation bot is flagged as an error in the API (`status_error`).
- API version reported as 1.1.0.

### Performance

- **SQLite:** `synchronous=NORMAL` in WAL mode (no fsync per statement – every tick used to fsync once per bot),
  `busy_timeout`, and a `created_at` index for the P&L summary. Schema changes are now tracked with
  `PRAGMA user_version` (migration list in `app/db.py`).
- **Bot state is only written when it changes;** the last check time is kept in memory and persisted with the next
  real change.
- **Market data:** all tickers of a tick are fetched in one request (with a per-symbol fallback), candles are cached
  across ticks and shared by all bots (re-fetched when a new candle starts or after five minutes), and symbols are
  fetched concurrently (4 at a time). Stopped bots without a position or order no longer cause market-data requests.
- **`GET /api/balances` is cached for 10 s** so the app's polling does not turn into an exchange request every time.
- The pair list keeps the cached copy (retry in five minutes) when a refresh fails instead of failing every order.

### Tests

- 20 new tests (`tests/test_engine_robustness.py`, `tests/test_exchange_setup.py`) covering the fixes above, the
  candle cache, ticker batching, write-on-change, client retries and the API guards.

### Known limitations

- Fee handling of live orders assumes Revolut X reports `filled_amount` *without* the fee and `total_fee` /
  `fee_currency` separately. This has not been verified against a real order yet – if `filled_amount` already
  includes the fee, cost and P&L of live buys are overstated by the fee.
- A bot stopped because its order could not be found has to be checked and restarted by hand; there is no API to
  reset a pending order manually.

## [1.0.0]

Initial release.
