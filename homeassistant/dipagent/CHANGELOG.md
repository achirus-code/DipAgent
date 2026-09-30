# Changelog

All notable changes to DipAgent are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- **App: trades show their result in percent** next to the amount (e.g. *+1.03 € +2.06 %*) – in the trade list and
  under the bot's recent trades. Relative to what the sold coins cost, fees included.

- **App: Claude's decisions** in the bot view scroll inside a fixed height once there are more than a few – the
  sections below stay in reach. The list now holds all loaded answers instead of the last 30.
- **App: faster bot view and editor.** Claude's decisions are built lazily (only the rows in view). The trading
  pair is chosen from a searchable list instead of a menu with several hundred pairs that was rebuilt on every
  keystroke in the editor.

## [1.14.0] – 2026-09-30

### Added

- **Reset a bot's paper result.** In the bot view of a paper bot, *Reset paper result* deletes the bot's simulated
  trades and discards its open paper trades – the result starts at zero. Live trades are never deleted; a bot with
  an open live trade or an order in flight refuses.

### Fixed

- **App: new bot settings after an agent update.** The app reloads the strategies when the agent's version
  changes – before, new settings (e.g. *Max. open trades*) only appeared after restarting the app.

## [1.13.0] – 2026-09-30

### Added

- **Several trades per bot.** Dip buyer, Rebound + trailing stop and Price zones get *Max. open trades* (default 1 –
  existing bots behave as before) and *Distance between trades*: the bot may buy again while earlier trades are
  open, but only once the price is that far below the lowest open entry. Each trade has its own entry, target and
  stop and is sold on its own. Every trade counts towards *Max. open positions* and the capital limit. Positions
  stored by older versions are taken over as one trade.
- **App: open trades on the card and in the bot view.** The card shows *Open trades 2/3* with one line per trade
  (value, result, its target); the bot view has a card per trade with *Sell this trade now*. The headline shows the
  distance to the next trade. The editor shows how much can be invested at the same time.

- **App: quit button** at the top right of the panel. It asks first – the bots keep trading on the agent – with a
  "Don't ask again" checkbox; *Settings → Ask before quitting* turns the question back on.

### Changed

- **App: bot cards** show only the percentage to the next trade (e.g. *−1.80 % to buy*); the amount in the quote
  currency had too many decimals for cheap coins.
- **App: open position on the bot card** shows its size – current value and invested amount – above amount and
  entry price.

## [1.12.0] – 2026-09-29

### Added

- **AI decides: Fear & Greed index.** New option per bot – *Off* (default), *As background information* or *As a
  contrarian signal at extremes*. The agent fetches the Crypto Fear & Greed index (alternative.me, no key needed,
  cached for an hour) and adds today's value with the last seven days to Claude's market brief. In contrarian
  mode Claude is told to use it only below 25 (leaning towards patient buying) and above 75 (leaning towards
  taking profits) and to ignore it in between. If the index cannot be fetched, the brief goes out without it.
- **Bot cards show how far the next trade is.** Instead of the coin price, a running bot's card leads with the
  distance to its trigger in percent and in the quote currency (e.g. *−1.80 % · −42.00 $ to buy*, *+2.40 % · +58.00 $
  to sell*, or the distance to the trailing stop), followed by the trigger price, the stop and the current price in
  small print. Strategies without a fixed trigger (AI decides, the savings plan's next instalment) show their note.
  Needs agent 1.12 – the agent now reports the prices each bot waits for.

## [1.11.0] – 2026-09-29

### Added

- **Statistics per trading mode.** The summary keeps paper and live results apart: the card shows the active
  mode's numbers (result, realized, open, today, fees, trades), the other mode's result is a small footnote.
  Open positions count in the mode they were bought in. Switching modes deletes nothing.
- **App: prompt page.** The AI bot's "Additional instructions" are edited on their own page with a full-height
  text area, character count and "Clear"; the editor shows a preview and an "Edit…" button.
- **App: capital limit in the statistics.** What the bots may still invest and how much of the limit is in use –
  so a new bot is not sized straight into the limit. The exchange balance became a small footnote.

### Changed

- **App: "Ask now"** is a small round button with a brain symbol and asks for confirmation before the extra
  Claude call.

## [1.10.0] – 2026-09-29

### Added

- **AI decides: "Ask now".** A small button on the bot card gets a fresh decision from Claude right away instead
  of waiting for the next check (`POST /bots/{id}/ask`). One extra Claude call; minimum confidence, cooldown,
  limits and the no-loss rule apply as in a scheduled check, and the regular rhythm continues from that moment.

## [1.9.0] – 2026-09-29

### Added

- **Blocked buys stay visible.** A buy signal skipped by the limits (capital, open positions, one per symbol) used
  to be in the bot status for a single tick – *AI decides* signals once per check, so the skip was gone right
  away. The engine now keeps the blocked buy in the bot state and reports it as a `hint` until the limits allow
  it; the status then just says "Buy signal". The app shows the hint in orange on the bot card and in the
  details, and posts a notification when a bot becomes blocked.
- **AI decides: minimum confidence.** New per-bot parameter – buy and sell decisions below the threshold are not
  executed and stay visible as "below the threshold, not executed" until the next check. Default 0 keeps every
  decision executed. Claude is asked for an honestly calibrated confidence (50 = coin toss, 80+ = clear setup).

### Fixed

- **App: empty window on first open.** The SwiftUI settings scene opened an empty "DipAgent Settings" window the
  first time the app was activated; the entry point is now plain AppKit.
- **App: start tab.** The panel opens on *Bots*; only when the connection failed or is not configured it opens
  on *Settings*. The choice is made when the panel first opens, not before the first connection attempt.

## [1.8.0] – 2026-09-29

### Added

- **AI decides: additional instructions.** An optional free-text field in the bot's rules – your own rules or
  focus for Claude (e.g. "only buy on strong dips") – is sent with every check. New parameter type `text` for
  strategies; the app renders it as a multi-line field.

## [1.7.1] – 2026-09-29

### Changed

- AI decides: the model options are just the model names; the app shows the estimated cost per check and per
  month under the field. Without an Anthropic API key on the agent the *AI decides* card in the bot editor is
  greyed out with a note.

## [1.7.0] – 2026-09-29

### Added

- **AI decides: the model is selectable per bot** – Claude Opus 5 (~4 ct per check), Claude Sonnet 5
  (~1.5 ct) or Claude Haiku 4.5 (~1 ct). New default is Sonnet 5; existing AI bots switch to it unless you
  pick Opus in the bot editor.

## [1.6.0] – 2026-09-29

### Added

- **Claude's decision history.** Every answer of an *AI decides* bot is kept (action, how sure Claude was, the
  reason, price and open result at that moment; `GET /api/bots/{id}/decisions`). The bot view shows them as a
  list with an action badge and a confidence bar, the bot card gets a *Decisions* button. The bot status is
  now short – "Claude: hold (71 % sure) · next check in 12 min" – instead of carrying the whole reason.

## [1.5.0] – 2026-09-29

### Added

- **Discard position (no sale).** In the bot view next to *Sell position now*: removes a position from the
  agent's books without placing an order (`POST /api/bots/{id}/discard`). For a position that is wrong in the
  books – e.g. booked from a short-reported fill – while the coins stay, or don't exist, on the exchange.

### Changed

- **Fewer requests to Revolut X**, without touching how orders are tracked: candle series are reused until the
  next candle starts instead of being re-fetched every 5 minutes; balances are cached for a minute in the
  exchange wrapper (shared by the app, the holdings check and the checks before buys and sells) and dropped
  after every own order; the app only fetches balances while the panel is open; the holdings check runs every
  30 minutes (plus right after every own fill); the *AI decides* brief is built from two candle series instead
  of four; the first read of a new order happens a second after placing it. Roughly halves the daily request
  count with the default settings. Trades the user makes directly on Revolut X are, as before, not tracked.

## [1.4.2] – 2026-09-29

### Added

- **Holdings check.** Every 5 minutes (and right after every live fill) the agent compares the live positions it
  has booked with the balances on the exchange. If the exchange holds less of a coin than the bots think they
  own, every bot with a live position in that coin is flagged with an error event and stops trading – status
  *"Books don't match the exchange … trading paused"* – until the books match again (e.g. after a late fill was
  booked). Holding more than booked is fine.
- **Write-off on manual close.** *Sell position now* on a flagged bot sells what the exchange holds and writes
  off the rest with an error event (no trade is booked for coins that were never sold), so a wrong position can
  always be cleaned up from the app.

### Changed

- An order is only booked once two consecutive reads of it agree on status and filled quantity; fill data that
  is still moving right after "filled" is no longer booked. A sell that finds less available on the exchange
  than the position says logs an error event with both numbers.

## [1.4.1] – 2026-09-29

### Fixed

- **Short-reported fills.** Revolut X can report a market order as "filled" a moment before its fill data is
  complete; the agent then booked only the first part (a manual close of 0.00128 ETH was booked as 0.00043 ETH,
  the rest stayed open as a position that no longer existed on the exchange). Now an order whose reported fill
  is smaller than the requested size is re-read while polling, and if it is still short after that, the agent
  keeps re-reading it for up to 15 minutes and books the remainder as a late fill (`order-id#2`). Positions that
  are still open after a live sell – bookkeeping from earlier versions – are reconciled the same way on the next
  tick.

## [1.4.0] – 2026-09-29

### Added

- **Strategy "AI decides".** Claude (`claude-opus-5`) gets a market brief every N minutes – price, changes over
  1 h / 4 h / 24 h / 72 h, volatility of the last 4 h and 24 h, 24 h range, distance to the 72 h high and low, the
  last hourly closes, fees and the open position – and decides itself whether to buy, wait, hold or sell, with a
  short reason in English and German that ends up in the bot status and the trade. Optionally it may run a few
  web searches for news and market sentiment first. Needs `ANTHROPIC_API_KEY` on the agent (add-on option
  `anthropic_api_key`); every check costs a few cents. The safety net applies: a sell below break-even is held
  back, only the bot's stop-loss may realize a loss. The app shows a hint in the bot editor while the agent has
  no key (`GET /api/status` reports `ai_configured`).

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
