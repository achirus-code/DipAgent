"""SQLite persistence for bots, trades and events."""

from __future__ import annotations

import json
import os
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any

from .i18n import dump

SCHEMA = """
CREATE TABLE IF NOT EXISTS bots (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT    NOT NULL,
    strategy    TEXT    NOT NULL,
    symbol      TEXT    NOT NULL,
    params      TEXT    NOT NULL DEFAULT '{}',
    enabled     INTEGER NOT NULL DEFAULT 0,
    paper       INTEGER NOT NULL DEFAULT 1,
    state       TEXT    NOT NULL DEFAULT '{}',
    status      TEXT    NOT NULL DEFAULT '',
    last_check  INTEGER,
    created_at  INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS trades (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    bot_id       INTEGER NOT NULL,
    bot_name     TEXT    NOT NULL,
    symbol       TEXT    NOT NULL,
    side         TEXT    NOT NULL,
    price        TEXT    NOT NULL,
    base_qty     TEXT    NOT NULL,
    quote_amount TEXT    NOT NULL,
    fee          TEXT    NOT NULL,
    pnl          TEXT,
    order_id     TEXT,
    paper        INTEGER NOT NULL,
    reason       TEXT    NOT NULL DEFAULT '',
    created_at   INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS trades_bot ON trades(bot_id, created_at);
CREATE TABLE IF NOT EXISTS events (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    bot_id      INTEGER,
    level       TEXT    NOT NULL,
    message     TEXT    NOT NULL,
    created_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS events_bot ON events(bot_id, created_at);
-- an exchange order can only ever be booked once
CREATE UNIQUE INDEX IF NOT EXISTS trades_order ON trades(order_id) WHERE order_id IS NOT NULL;
-- every answer of the "AI decides" strategy, so the app can show how Claude judged the market over time
CREATE TABLE IF NOT EXISTS ai_decisions (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    bot_id      INTEGER NOT NULL,
    action      TEXT    NOT NULL,
    confidence  INTEGER NOT NULL,
    reason_en   TEXT    NOT NULL,
    reason_de   TEXT    NOT NULL,
    price       TEXT    NOT NULL,
    profit_pct  REAL,
    created_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS ai_decisions_bot ON ai_decisions(bot_id, id);
CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""

# Schema changes after the initial release, applied once each (tracked in ``PRAGMA user_version``).
MIGRATIONS: list[str] = [
    # 1: the P&L summary filters trades by time – give it an index
    "CREATE INDEX IF NOT EXISTS trades_created ON trades(created_at);",
]

DEFAULT_LIMITS: dict[str, Any] = {
    "max_open_positions": 3,        # how many bots may hold a position at the same time (0 = unlimited)
    "max_total_invested": 0.0,      # sum of all open positions in quote currency (0 = unlimited)
    "one_position_per_symbol": True,  # only one bot at a time may hold a given pair
}


def now_ms() -> int:
    return int(time.time() * 1000)


class Database:
    def __init__(self, path: Path):
        self.path = path
        self._lock = threading.Lock()
        self._open()

    def _open(self) -> None:
        self._conn = sqlite3.connect(self.path, check_same_thread=False, isolation_level=None)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA journal_mode=WAL")
        # WAL + NORMAL: no fsync per statement (every tick writes bot states) – still safe against crashes
        self._conn.execute("PRAGMA synchronous=NORMAL")
        self._conn.execute("PRAGMA busy_timeout=5000")
        self._conn.executescript(SCHEMA)
        self._migrate()

    def _migrate(self) -> None:
        version = int(self._conn.execute("PRAGMA user_version").fetchone()[0])
        for number, sql in enumerate(MIGRATIONS[version:], start=version + 1):
            self._conn.executescript(sql)
            self._conn.execute(f"PRAGMA user_version={number}")

    def close(self) -> None:
        self._conn.close()

    # --- Backup -----------------------------------------------------------

    def snapshot(self) -> bytes:
        """A consistent copy of the whole database (including what is still in the WAL) as a single file."""
        with self._lock:
            copy = sqlite3.connect(":memory:")
            try:
                self._conn.backup(copy)
                return copy.serialize()
            finally:
                copy.close()

    def replace_with(self, source: Path) -> None:
        """Swap in a restored database file (same file system) and reopen; the caller pauses the engine."""
        with self._lock:
            self._conn.close()
            for suffix in ("-wal", "-shm"):
                Path(str(self.path) + suffix).unlink(missing_ok=True)
            os.replace(source, self.path)
            self._open()

    def _all(self, sql: str, args: tuple = ()) -> list[dict[str, Any]]:
        with self._lock:
            return [dict(r) for r in self._conn.execute(sql, args).fetchall()]

    def _one(self, sql: str, args: tuple = ()) -> dict[str, Any] | None:
        rows = self._all(sql, args)
        return rows[0] if rows else None

    def _exec(self, sql: str, args: tuple = ()) -> int:
        with self._lock:
            cur = self._conn.execute(sql, args)
            return cur.lastrowid or cur.rowcount

    # --- Bots -------------------------------------------------------------

    @staticmethod
    def _bot(row: dict[str, Any] | None) -> dict[str, Any] | None:
        if row is None:
            return None
        row["params"] = json.loads(row["params"])
        row["state"] = json.loads(row["state"])
        row["enabled"] = bool(row["enabled"])
        row["paper"] = bool(row["paper"])
        return row

    def list_bots(self) -> list[dict[str, Any]]:
        return [self._bot(r) for r in self._all("SELECT * FROM bots ORDER BY id")]

    def get_bot(self, bot_id: int) -> dict[str, Any] | None:
        return self._bot(self._one("SELECT * FROM bots WHERE id = ?", (bot_id,)))

    def create_bot(self, name: str, strategy: str, symbol: str, params: dict, enabled: bool, paper: bool) -> int:
        return self._exec(
            "INSERT INTO bots (name, strategy, symbol, params, enabled, paper, created_at) VALUES (?,?,?,?,?,?,?)",
            (name, strategy, symbol, json.dumps(params), int(enabled), int(paper), now_ms()),
        )

    def update_bot(self, bot_id: int, **fields: Any) -> None:
        if not fields:
            return
        cols, args = [], []
        for key, value in fields.items():
            if key in {"params", "state"}:
                value = json.dumps(value)
            elif key == "status":
                value = dump(value)  # i18n message -> JSON
            elif key in {"enabled", "paper"}:
                value = int(value)
            cols.append(f"{key} = ?")
            args.append(value)
        self._exec(f"UPDATE bots SET {', '.join(cols)} WHERE id = ?", (*args, bot_id))

    def delete_bot(self, bot_id: int) -> None:
        self._exec("DELETE FROM bots WHERE id = ?", (bot_id,))
        self._exec("DELETE FROM events WHERE bot_id = ?", (bot_id,))

    # --- Settings ---------------------------------------------------------

    def get_setting(self, key: str, default: Any = None) -> Any:
        row = self._one("SELECT value FROM settings WHERE key = ?", (key,))
        return json.loads(row["value"]) if row else default

    def set_setting(self, key: str, value: Any) -> None:
        self._exec(
            "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (key, json.dumps(value)),
        )

    def get_limits(self) -> dict[str, Any]:
        stored = {r["key"]: json.loads(r["value"]) for r in self._all("SELECT key, value FROM settings")}
        return {k: stored.get(k, v) for k, v in DEFAULT_LIMITS.items()}

    def set_limits(self, limits: dict[str, Any]) -> None:
        for key, value in limits.items():
            if key in DEFAULT_LIMITS:
                self._exec(
                    "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    (key, json.dumps(value)),
                )

    # --- Trades -----------------------------------------------------------

    def trade_exists(self, order_id: str) -> bool:
        return self._one("SELECT 1 AS x FROM trades WHERE order_id = ?", (order_id,)) is not None

    def booked_for_order(self, order_id: str) -> dict[str, Any]:
        """Quantity, amount and fee already booked for an exchange order (late fills are booked as ``id#2`` …)."""
        row = self._one(
            "SELECT COUNT(*) AS n, COALESCE(SUM(CAST(base_qty AS REAL)), 0) AS qty, "
            "COALESCE(SUM(CAST(quote_amount AS REAL)), 0) AS amount, COALESCE(SUM(CAST(fee AS REAL)), 0) AS fee "
            "FROM trades WHERE order_id = ? OR order_id LIKE ?",
            (order_id, f"{order_id}#%"),
        )
        return row or {"n": 0, "qty": 0.0, "amount": 0.0, "fee": 0.0}

    def add_trade(self, **t: Any) -> int:
        t.setdefault("created_at", now_ms())
        t["reason"] = dump(t.get("reason") or "")
        cols = ", ".join(t)
        marks = ", ".join("?" for _ in t)
        return self._exec(f"INSERT INTO trades ({cols}) VALUES ({marks})", tuple(t.values()))

    def delete_paper_trades(self, bot_id: int) -> int:
        """Removes a bot's simulated trades (live trades stay). Returns how many were deleted."""
        count = self._one("SELECT COUNT(*) AS n FROM trades WHERE bot_id = ? AND paper = 1", (bot_id,))["n"]
        self._exec("DELETE FROM trades WHERE bot_id = ? AND paper = 1", (bot_id,))
        return int(count)

    def list_trades(self, bot_id: int | None = None, limit: int = 200) -> list[dict[str, Any]]:
        if bot_id is None:
            return self._all("SELECT * FROM trades ORDER BY created_at DESC, id DESC LIMIT ?", (limit,))
        return self._all(
            "SELECT * FROM trades WHERE bot_id = ? ORDER BY created_at DESC, id DESC LIMIT ?", (bot_id, limit)
        )

    def trade_stats(self) -> dict[int, dict[str, Any]]:
        rows = self._all(
            """SELECT bot_id,
                      COUNT(*) AS trades,
                      SUM(CASE WHEN pnl IS NOT NULL THEN CAST(pnl AS REAL) ELSE 0 END) AS realized,
                      SUM(CASE WHEN pnl IS NOT NULL AND CAST(pnl AS REAL) > 0 THEN 1 ELSE 0 END) AS wins,
                      SUM(CASE WHEN pnl IS NOT NULL AND CAST(pnl AS REAL) <= 0 THEN 1 ELSE 0 END) AS losses
               FROM trades GROUP BY bot_id"""
        )
        return {r["bot_id"]: r for r in rows}

    def realized_since(self, since_ms: int, paper: bool | None = None) -> list[dict[str, Any]]:
        return self._all(
            "SELECT symbol, SUM(CAST(pnl AS REAL)) AS pnl FROM trades "
            f"WHERE pnl IS NOT NULL AND created_at >= ? {self._mode(paper)} GROUP BY symbol",
            (since_ms,),
        )

    def realized_by_symbol(self, paper: bool | None = None) -> list[dict[str, Any]]:
        return self._all(
            f"SELECT symbol, SUM(CAST(pnl AS REAL)) AS pnl FROM trades WHERE pnl IS NOT NULL {self._mode(paper)} GROUP BY symbol"
        )

    def fees_by_symbol(self, paper: bool | None = None) -> list[dict[str, Any]]:
        """Exchange fees paid so far (buys and sells), in the quote currency."""
        return self._all(f"SELECT symbol, SUM(CAST(fee AS REAL)) AS fee FROM trades WHERE 1=1 {self._mode(paper)} GROUP BY symbol")

    def trades_count(self, paper: bool | None = None) -> int:
        return int(self._one(f"SELECT COUNT(*) AS n FROM trades WHERE 1=1 {self._mode(paper)}")["n"])

    @staticmethod
    def _mode(paper: bool | None) -> str:
        """SQL filter for simulated (paper) or real trades – None means both."""
        return "" if paper is None else f"AND paper = {1 if paper else 0}"

    # --- Events -----------------------------------------------------------

    def add_event(self, bot_id: int | None, level: str, message: dict | str) -> None:
        self._exec(
            "INSERT INTO events (bot_id, level, message, created_at) VALUES (?,?,?,?)",
            (bot_id, level, dump(message), now_ms()),
        )
        # keep the log bounded
        self._exec("DELETE FROM events WHERE id <= (SELECT MAX(id) - 5000 FROM events)")

    # --- AI decisions -----------------------------------------------------

    def add_ai_decision(self, bot_id: int, action: str, confidence: int, reason_en: str, reason_de: str,
                        price: str, profit_pct: float | None) -> None:
        self._exec(
            "INSERT INTO ai_decisions (bot_id, action, confidence, reason_en, reason_de, price, profit_pct, created_at) "
            "VALUES (?,?,?,?,?,?,?,?)",
            (bot_id, action, confidence, reason_en, reason_de, price, profit_pct, now_ms()),
        )
        # keep the journal bounded per bot
        self._exec(
            "DELETE FROM ai_decisions WHERE bot_id = ? AND id <= "
            "(SELECT id FROM ai_decisions WHERE bot_id = ? ORDER BY id DESC LIMIT 1 OFFSET 500)",
            (bot_id, bot_id),
        )

    def list_ai_decisions(self, bot_id: int, limit: int = 100) -> list[dict[str, Any]]:
        return self._all("SELECT * FROM ai_decisions WHERE bot_id = ? ORDER BY id DESC LIMIT ?", (bot_id, limit))

    def list_events(self, bot_id: int | None = None, limit: int = 100) -> list[dict[str, Any]]:
        if bot_id is None:
            return self._all("SELECT * FROM events ORDER BY id DESC LIMIT ?", (limit,))
        return self._all("SELECT * FROM events WHERE bot_id = ? ORDER BY id DESC LIMIT ?", (bot_id, limit))
