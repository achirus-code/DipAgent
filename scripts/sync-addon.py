#!/usr/bin/env python3
"""Keep the Home Assistant add-on in sync with the agent: version from agent/app/main.py, CHANGELOG.md copied.

    python scripts/sync-addon.py          # write
    python scripts/sync-addon.py --check  # exit 1 if anything is stale (used in CI)
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAIN = ROOT / "agent" / "app" / "main.py"
CHANGELOG = ROOT / "CHANGELOG.md"
ADDON = ROOT / "homeassistant" / "dipagent"
CONFIG = ADDON / "config.yaml"
ADDON_CHANGELOG = ADDON / "CHANGELOG.md"


def agent_version() -> str:
    match = re.search(r'^VERSION = "([^"]+)"$', MAIN.read_text(), re.MULTILINE)
    if not match:
        sys.exit(f"{MAIN}: no VERSION = \"...\" line found")
    return match.group(1)


def main(check: bool) -> int:
    version = agent_version()
    changelog = CHANGELOG.read_text()
    if f"## [{version}]" not in changelog:
        print(f"{CHANGELOG}: no section '## [{version}]' for the agent version", file=sys.stderr)
        return 1

    config = CONFIG.read_text()
    new_config, n = re.subn(r'^version: "[^"]*"$', f'version: "{version}"', config, count=1, flags=re.MULTILINE)
    if n != 1:
        sys.exit(f"{CONFIG}: no version: line found")

    stale = []
    if new_config != config:
        stale.append(CONFIG)
    if not ADDON_CHANGELOG.exists() or ADDON_CHANGELOG.read_text() != changelog:
        stale.append(ADDON_CHANGELOG)

    if check:
        for path in stale:
            print(f"stale: {path.relative_to(ROOT)} – run scripts/sync-addon.py", file=sys.stderr)
        return 1 if stale else 0

    CONFIG.write_text(new_config)
    ADDON_CHANGELOG.write_text(changelog)
    print(f"add-on synced to version {version}")
    return 0


if __name__ == "__main__":
    sys.exit(main(check="--check" in sys.argv[1:]))
