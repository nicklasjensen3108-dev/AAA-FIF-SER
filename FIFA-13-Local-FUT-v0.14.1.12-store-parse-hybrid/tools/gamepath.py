#!/usr/bin/env python3
r"""Locate the FIFA 13 install that the read-only tools in this directory inspect.

The game directory is read from the FIFA13_GAME_DIR environment variable and
falls back to the stock EA Games install path when that variable is unset, so a
default installation needs no configuration and any other one needs a single
variable. Nothing here writes to the game folder: the tools open fifa13.exe, the
FUT plug-in and the .big archives read-only.

Exports GAME_DIR (the install), EXE (fifa13.exe) and DLL (CardsDLLzf.dll, which
ships inside the dlc_CardsDLL DLC folder), plus require() to turn a missing file
into a message that names the variable to set.

    PowerShell:  $env:FIFA13_GAME_DIR = 'D:\Games\FIFA 13\Game'
    cmd.exe:     set FIFA13_GAME_DIR=D:\Games\FIFA 13\Game
    python tools/scan_field.py 0x5a
"""
from __future__ import annotations

import os
from pathlib import Path

ENV_VAR = "FIFA13_GAME_DIR"

# The stock EA Games install path. Kept as the default because it is where the
# whole reverse-engineering effort was carried out, so every offset and
# signature in these tools was measured against a copy living exactly here.
DEFAULT_GAME_DIR = Path(r"C:\Program Files\EA Games\FIFA 13\Game")

GAME_DIR = Path(os.environ.get(ENV_VAR) or DEFAULT_GAME_DIR)

EXE = GAME_DIR / "fifa13.exe"

# The FUT plug-in is not in the game root: it ships as a DLC payload, two "dlc"
# levels deep, which is why a search for CardsDLLzf.dll beside fifa13.exe finds
# nothing.
DLL = GAME_DIR / "dlc" / "dlc_CardsDLL" / "dlc" / "CardsDLLzf.dll"


def require(path: Path, what: str = "file") -> Path:
    """Return `path`, or exit with a message naming the variable to set.

    Every tool here fails the same way when the install lives elsewhere, and a
    FileNotFoundError raised deep inside pefile or glob says nothing about the
    fix. So the check happens up front and spells out the environment variable.
    """
    if not path.exists():
        origin = (f"taken from {ENV_VAR}" if os.environ.get(ENV_VAR)
                  else "the default install path")
        raise SystemExit(
            f"{what} not found: {path}\n"
            f"Game directory: {GAME_DIR} ({origin}).\n"
            f"Point {ENV_VAR} at your FIFA 13 'Game' folder, for example:\n"
            f"    PowerShell:  $env:{ENV_VAR} = 'D:\\Games\\FIFA 13\\Game'\n"
            f"    cmd.exe:     set {ENV_VAR}=D:\\Games\\FIFA 13\\Game"
        )
    return path


def main() -> int:
    """Print the resolved paths, so a misconfiguration is one command away."""
    print(f"{ENV_VAR:16} {os.environ.get(ENV_VAR) or '<unset>'}")
    for label, path in (("game directory", GAME_DIR), ("fifa13.exe", EXE),
                        ("CardsDLLzf.dll", DLL)):
        print(f"{label:16} {path}  {'ok' if path.exists() else 'MISSING'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
