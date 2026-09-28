"""Container entrypoint: Home Assistant add-on options → environment, take over /data, drop root, exec uvicorn.

Plain Docker users configure the agent with environment variables (see ``config.py``). As a Home Assistant add-on
the Supervisor writes the options the user entered to ``/data/options.json`` instead; this script maps them to the
very same variables so the agent itself does not know the difference.
"""

from __future__ import annotations

import json
import os
import pwd
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import Any

OPTIONS_FILE = Path("/data/options.json")
RUN_AS = "dipagent"
PORT = 3470

# add-on option → environment variable (only these are ever taken from options.json)
OPTION_ENV = {
    "api_token": "API_TOKEN",
    "exchange": "EXCHANGE",
    "tick_seconds": "TICK_SECONDS",
    "taker_fee": "TAKER_FEE",
    "mock_speed": "MOCK_SPEED",
    "anthropic_api_key": "ANTHROPIC_API_KEY",
}

UVICORN = ["-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", str(PORT), "--proxy-headers"]


def read_options(path: Path = OPTIONS_FILE) -> dict[str, Any]:
    """The add-on options, or an empty dict outside Home Assistant. Must run before dropping root (file is 0600)."""
    if not path.is_file():
        return {}
    data = json.loads(path.read_text())
    return data if isinstance(data, dict) else {}


def env_from_options(options: Mapping[str, Any], env: Mapping[str, str]) -> dict[str, str]:
    """Known keys only, empty values skipped (empty token = the agent generates one), existing variables win."""
    out: dict[str, str] = {}
    for key, var in OPTION_ENV.items():
        value = options.get(key)
        if value is None or value == "" or var in env:
            continue
        if isinstance(value, bool):
            value = "true" if value else "false"
        out[var] = str(value).strip()
    return out


def take_over_data_dir(data_dir: Path, uid: int, gid: int) -> None:
    """chown the (flat) data dir to the runtime user. options.json stays root's – the Supervisor rewrites it."""
    for path in [data_dir, *data_dir.iterdir()]:
        if path.name == OPTIONS_FILE.name:
            continue
        try:
            os.chown(path, uid, gid)
        except OSError as exc:
            print(f"entrypoint: cannot chown {path}: {exc}", file=sys.stderr)


def drop_privileges(uid: int, gid: int) -> None:
    os.setgroups([])
    os.setgid(gid)
    os.setuid(uid)


def main() -> None:
    os.environ.update(env_from_options(read_options(), os.environ))
    if os.geteuid() == 0:
        user = pwd.getpwnam(RUN_AS)
        take_over_data_dir(Path(os.environ.get("DATA_DIR", "/data")), user.pw_uid, user.pw_gid)
        drop_privileges(user.pw_uid, user.pw_gid)
    os.execv(sys.executable, [sys.executable, *UVICORN])


if __name__ == "__main__":
    main()
