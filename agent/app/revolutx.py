"""Minimal async client for the Revolut X REST API (https://revx.revolut.com/api/1.0).

Authentication: every private request is signed with Ed25519 over
``timestamp + METHOD + path + query + body`` and sent via the
X-Revx-API-Key / X-Revx-Timestamp / X-Revx-Signature headers.
"""

from __future__ import annotations

import base64
import json
import time
import uuid
from typing import Any
from urllib.parse import urlencode

import httpx
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

API_PREFIX = "/api/1.0"


class RevolutXError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(f"Revolut X {status}: {message}")
        self.status = status
        self.message = message


class RevolutXClient:
    def __init__(self, api_key: str, private_key_pem: bytes, base_url: str = "https://revx.revolut.com"):
        key = serialization.load_pem_private_key(private_key_pem, password=None)
        if not isinstance(key, Ed25519PrivateKey):
            raise ValueError("The Revolut X private key must be an Ed25519 key")
        self._api_key = api_key
        self._key = key
        self._http = httpx.AsyncClient(base_url=base_url, timeout=httpx.Timeout(15.0))

    async def close(self) -> None:
        await self._http.aclose()

    def _sign(self, timestamp: str, method: str, path: str, query: str, body: str) -> str:
        message = f"{timestamp}{method}{path}{query}{body}".encode()
        return base64.b64encode(self._key.sign(message)).decode()

    async def request(
        self,
        method: str,
        path: str,
        params: dict[str, Any] | None = None,
        body: dict[str, Any] | None = None,
    ) -> Any:
        full_path = API_PREFIX + path
        clean = {k: v for k, v in (params or {}).items() if v is not None}
        query = urlencode(clean, safe=",")
        body_str = json.dumps(body, separators=(",", ":")) if body is not None else ""
        timestamp = str(int(time.time() * 1000))
        headers = {
            "Accept": "application/json",
            "X-Revx-API-Key": self._api_key,
            "X-Revx-Timestamp": timestamp,
            "X-Revx-Signature": self._sign(timestamp, method, full_path, query, body_str),
        }
        if body_str:
            headers["Content-Type"] = "application/json"
        url = full_path + (f"?{query}" if query else "")
        resp = await self._http.request(method, url, content=body_str or None, headers=headers)
        if resp.status_code >= 400:
            try:
                message = resp.json().get("message", resp.text)
            except ValueError:
                message = resp.text
            raise RevolutXError(resp.status_code, message)
        if resp.status_code == 204 or not resp.content:
            return None
        return resp.json()

    # --- Market data -----------------------------------------------------

    async def tickers(self, symbols: list[str] | None = None) -> list[dict]:
        params = {"symbols": ",".join(symbols)} if symbols else None
        return (await self.request("GET", "/tickers", params))["data"]

    async def candles(self, symbol: str, interval: int, since: int, until: int) -> list[dict]:
        params = {"interval": interval, "since": since, "until": until}
        return (await self.request("GET", f"/candles/{symbol}", params))["data"]

    # --- Account / config ------------------------------------------------

    async def balances(self) -> list[dict]:
        return await self.request("GET", "/balances")

    async def pairs(self) -> dict[str, dict]:
        return await self.request("GET", "/configuration/pairs")

    # --- Orders ----------------------------------------------------------

    async def place_market_order(
        self,
        symbol: str,
        side: str,
        *,
        client_order_id: str | None = None,
        base_size: str | None = None,
        quote_size: str | None = None,
    ) -> dict:
        market: dict[str, str] = {}
        if base_size is not None:
            market["base_size"] = base_size
        if quote_size is not None:
            market["quote_size"] = quote_size
        body = {
            "client_order_id": client_order_id or str(uuid.uuid4()),
            "symbol": symbol,
            "side": side,
            "order_configuration": {"market": market},
        }
        return (await self.request("POST", "/orders", body=body))["data"]

    async def get_order(self, venue_order_id: str) -> dict:
        return (await self.request("GET", f"/orders/{venue_order_id}"))["data"]

    async def active_orders(self, symbol: str) -> list[dict]:
        return (await self.request("GET", "/orders/active", {"symbols": symbol}))["data"]

    async def historical_orders(self, symbol: str, start_date: int) -> list[dict]:
        return (await self.request("GET", "/orders/historical", {"symbols": symbol, "start_date": start_date}))["data"]
