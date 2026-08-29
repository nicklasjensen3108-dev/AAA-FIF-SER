#!/usr/bin/env python3
"""Read the Scaleform APT pair that backs every FIFA 13 ION screen.

A screen's .big holds entry "0" = "Apt Data:1:7:4" (characters, frames and
ActionScript bytecode) and entry "1" = "Apt constant file" (the string pool
every instruction indexes into). Strings live only in the pool, length-prefixed
by nothing but their table entry, which is why a raw byte search over the .big
misses names the bytecode clearly uses.

Constant file:

    0x00  "Apt constant file" 0x1a + 2 pad
    0x14  APT entry offset      where the root Movie starts in the .apt
    0x18  constant count
    0x1c  constant table        (type, value) pairs; type 1 = offset of a C string

APT file, confirmed against gamehub.big (root Movie at 0xf24):

    +0x00 character type        9 = Movie
    +0x04 signature             0x09876543
    +0x08 8 bytes unused        absent from OpenSAGE's 1:8:2 layout
    +0x10 frames                count, offset
    +0x18 unused
    +0x1c characters            count, offset  (table of pointers, entry 0 = the movie)
    +0x24 screen width, height, milliseconds per frame
    +0x30 imports               count, offset
    +0x38 exports               count, offset

    python tools/apt.py analysis/extracted/apt/gamehub --header
    python tools/apt.py analysis/extracted/apt/gamehub --grep ENTER_FUT
"""
from __future__ import annotations

import struct
from pathlib import Path

APT_MAGIC = b"Apt Data"
CONST_MAGIC = b"Apt constant file"
MOVIE_SIGNATURE = 0x09876543


def _u32(blob: bytes, offset: int) -> int:
    return struct.unpack_from("<I", blob, offset)[0]


def _cstring(blob: bytes, offset: int) -> str:
    end = blob.index(b"\0", offset)
    return blob[offset:end].decode("utf-8", "replace")


def constants(const_blob: bytes) -> list[str]:
    """Return the string pool. Non-string entries keep a readable placeholder."""
    if not const_blob.startswith(CONST_MAGIC):
        raise ValueError("not an APT constant file")
    count = _u32(const_blob, 0x18)
    table = _u32(const_blob, 0x1C)
    out = []
    for index in range(count):
        item = table + index * 8
        kind, value = struct.unpack_from("<II", const_blob, item)
        out.append(_cstring(const_blob, value) if kind == 1 else f"<{kind}:0x{value:08x}>")
    return out


def root_offset(const_blob: bytes) -> int:
    return _u32(const_blob, 0x14)


def movie(apt_blob: bytes, root: int) -> dict:
    if _u32(apt_blob, root) != 9 or _u32(apt_blob, root + 4) != MOVIE_SIGNATURE:
        raise ValueError(f"not a Movie at 0x{root:x}")
    frame_count, frame_table = struct.unpack_from("<II", apt_blob, root + 0x10)
    char_count, char_table = struct.unpack_from("<II", apt_blob, root + 0x1C)
    width, height, ms = struct.unpack_from("<III", apt_blob, root + 0x24)
    import_count, import_table = struct.unpack_from("<II", apt_blob, root + 0x30)
    export_count, export_table = struct.unpack_from("<II", apt_blob, root + 0x38)
    return {
        "frames": (frame_count, frame_table),
        "characters": (char_count, char_table),
        "screen": (width, height, ms),
        "imports": (import_count, import_table),
        "exports": (export_count, export_table),
    }


def load(directory: Path) -> tuple[bytes, bytes]:
    return (directory / "0.apt").read_bytes(), (directory / "1.const").read_bytes()


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Dump an APT constant pool / header.")
    parser.add_argument("directory", type=Path, help="directory holding 0.apt and 1.const")
    parser.add_argument("--grep", action="append", default=[], help="only show constants containing this text")
    parser.add_argument("--header", action="store_true", help="also show the Movie header")
    args = parser.parse_args()

    apt_blob, const_blob = load(args.directory)
    pool = constants(const_blob)
    if args.header:
        info = movie(apt_blob, root_offset(const_blob))
        print(f"root=0x{root_offset(const_blob):x} {info}")
    needles = [needle.lower() for needle in args.grep]
    for index, value in enumerate(pool):
        if needles and not any(needle in value.lower() for needle in needles):
            continue
        print(f"[{index}] {value}")
    if not needles:
        print(f"-- {len(pool)} constants")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
