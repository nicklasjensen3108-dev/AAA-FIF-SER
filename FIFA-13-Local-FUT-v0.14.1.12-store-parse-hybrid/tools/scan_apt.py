#!/usr/bin/env python3
"""Search every ION screen in the game archives for a string.

Screen text lives in the APT constant pool, not as loose bytes, so grepping a
.big (or the whole data archive) misses names the ActionScript plainly uses.
This walks data*.big -> screen .big -> APT constant pool and greps there.

The archives are read from the install that tools/gamepath.py resolves, so set
FIFA13_GAME_DIR if the game is not at the default EA Games path.

    python tools/scan_apt.py ENTER_FUT
    python tools/scan_apt.py changeScreen --archive data1
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import bigfile
import chunkzip
import apt
import gamepath


def screen_pool(payload: bytes) -> list[str] | None:
    """Return the constant pool of a screen payload, or None if it has none."""
    if payload[:8] == chunkzip.MAGIC:
        payload = chunkzip.unpack(payload)
    if payload[:4] not in bigfile.MAGICS:
        return None
    table = bigfile.entries(payload)
    for name, offset, size in table:
        if size and payload[offset:offset + 17] == apt.CONST_MAGIC:
            return apt.constants(payload[offset:offset + size])
    return None


def archives(selected: str | None) -> list[Path]:
    game = gamepath.require(gamepath.GAME_DIR, "game directory")
    found = sorted(game.glob("data*.big")) + [game / "cards_patch.big"]
    return [path for path in found if selected is None or path.stem == selected]


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Grep the APT constant pools of every screen.")
    parser.add_argument("needle")
    parser.add_argument("--archive", help="scan only one archive, e.g. data1")
    parser.add_argument("--max-entry", type=int, default=4 * 1024 * 1024,
                        help="skip entries larger than this (video, audio)")
    args = parser.parse_args()

    needle = args.needle.lower()
    total_screens = 0
    for archive in archives(args.archive):
        with archive.open("rb") as handle:
            head = handle.read(16)
            if head[:4] not in bigfile.MAGICS:
                continue
            _count, header_size = struct.unpack(">II", head[8:16])
            handle.seek(0)
            table = bigfile.entries(handle.read(header_size))
            for name, offset, size in table:
                if not size or size > args.max_entry or not name.lower().endswith(".big"):
                    continue
                handle.seek(offset)
                try:
                    pool = screen_pool(handle.read(size))
                except Exception:
                    continue
                if pool is None:
                    continue
                total_screens += 1
                hits = [(index, value) for index, value in enumerate(pool) if needle in value.lower()]
                if hits:
                    print(f"=== {archive.name} :: {name}  ({len(pool)} constants)")
                    for index, value in hits:
                        print(f"    [{index}] {value}")
    print(f"-- {total_screens} APT screens scanned", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
