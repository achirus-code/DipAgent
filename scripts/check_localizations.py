#!/usr/bin/env python3
"""Checks that every user-facing English string in the Swift sources of both apps (macOS, iPhone) and the
shared package has a translation in each ``shared/Localization/<lang>.lproj/Localizable.strings`` (and that no
translations are left over).

English is the development language: the source strings themselves are the keys. Interpolations
(``\\(value)``) become ``%@`` in the key, so only interpolate *Strings* into localized texts.

    python3 scripts/check_localizations.py            # check, exit code 1 on problems
    python3 scripts/check_localizations.py --missing  # print missing entries as a .strings skeleton
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [ROOT / "shared" / "DipAgentKit" / "Sources", ROOT / "macos" / "Sources", ROOT / "ios" / "DipAgent"]
RESOURCES = ROOT / "shared" / "Localization"

# literals that are not UI text (identifiers, protocol values, product names …)
IGNORE = {
    "EUR", "USD", "GBP", "CHF", "PLN", "PAPER", "LIVE", "Revolut X", "DipAgent", "English", "Deutsch", "System",
    "Authorization", "Accept", "Accept-Language", "Content-Type", "application/json",
    "GET", "POST", "PUT", "DELETE", "AppleLanguages", "LIVE", "Bots", "Trades", "Name", "Agent",
    " · Paper", " (Paper)", " · ", "–", "App", "ETH-EUR", "-EUR", "apiToken", "Not Found",
}
# lines that never contain UI text
IGNORE_LINE = re.compile(
    r"NSLog\(|print\(|forHTTPHeaderField|forKey|Process\(|arguments =|executableURL|URL\(string|"
    r"systemName:|Image\(|case \w+ = \"|CFBundle|Bearer|kSec[A-Z]|infoDictionary|\"/api|client\.(get|post|send|delete)|"
    r"Text\(verbatim:|service = \"|@AppStorage\("
)


def swift_literals(source: str):
    """Yield (line, literal) for every single-line string literal, incl. literals nested in interpolations."""
    i, line, n = 0, 1, len(source)
    while i < n:
        c = source[i]
        if c == "\n":
            line += 1
        elif source.startswith("//", i):
            while i < n and source[i] != "\n":
                i += 1
            continue
        elif source.startswith('"""', i):
            end = source.find('"""', i + 3)
            line += source.count("\n", i, end)
            i = end + 3
            continue
        elif c == '"':
            literal, i = _read_literal(source, i + 1)
            yield line, literal
            continue
        i += 1


def _read_literal(source: str, i: int):
    out = []
    while source[i] != '"':
        if source[i] == "\\" and source[i + 1] == "(":
            depth, j = 1, i + 2
            while depth:
                if source[j] == "(":
                    depth += 1
                elif source[j] == ")":
                    depth -= 1
                elif source[j] == '"':
                    _, j = _read_literal(source, j + 1)
                    continue
                j += 1
            out.append("\x00")  # interpolation marker
            i = j
            continue
        if source[i] == "\\":
            out.append(source[i : i + 2])
            i += 2
            continue
        out.append(source[i])
        i += 1
    return "".join(out), i + 1


def to_key(literal: str) -> str:
    if "\x00" in literal:
        literal = literal.replace("%", "%%")
    return literal.replace("\x00", "%@")


def is_ui_text(literal: str) -> bool:
    text = literal.replace("\x00", "")
    if literal in IGNORE or text.strip() in IGNORE or not re.search(r"[A-Za-z]", text):
        return False
    if re.fullmatch(r"[a-z0-9_.\-/]+", text):  # identifiers, symbol names, paths
        return False
    return " " in text or bool(re.search(r"[A-Z]", text))


def source_keys() -> dict[str, str]:
    keys: dict[str, str] = {}
    for path in sorted(p for root in SOURCES if root.exists() for p in root.rglob("*.swift")):
        if path.name == "Snapshot.swift":
            continue
        lines = path.read_text().splitlines()
        for line_no, literal in swift_literals(path.read_text()):
            if IGNORE_LINE.search(lines[line_no - 1]) or not is_ui_text(literal):
                continue
            keys.setdefault(to_key(literal), f"{path.relative_to(ROOT)}:{line_no}")
    return keys


def read_strings(path: Path) -> dict[str, str]:
    pattern = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', re.M)
    return dict(pattern.findall(path.read_text()))


def main() -> int:
    keys = source_keys()
    problems = 0
    for strings in sorted(RESOURCES.glob("*.lproj/Localizable.strings")):
        lang = strings.parent.stem
        if lang == "en":
            continue  # English = the source strings
        table = read_strings(strings)
        missing = [k for k in keys if k not in table]
        unused = [k for k in table if k not in keys]
        for k, v in table.items():
            if k in keys and k.count("%@") != v.count("%@"):
                print(f"[{lang}] placeholder mismatch: \"{k}\"")
                problems += 1
        if "--missing" in sys.argv:
            for k in missing:
                print(f'"{k}" = "";  // {keys[k]}')
            continue
        for k in missing:
            print(f"[{lang}] missing: \"{k}\"  ({keys[k]})")
        for k in unused:
            print(f"[{lang}] unused: \"{k}\"")
        problems += len(missing) + len(unused)
        print(f"[{lang}] {len(table)} translations, {len(keys)} source strings")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
