#!/usr/bin/env python3
"""List and extract entries from the BIGF archives that hold FIFA 13's ION screens.

Each screen ships as one .big whose entries are named by number: "0" is the
Scaleform APT data ("Apt Data:1:7:4"), "1" is its constant pool, and the rest
are textures and geometry. Entry names are the numeric ids the APT refers to,
so keeping them verbatim matters.

Layout (sizes and offsets big-endian, archive size little-endian):

    0x00  "BIGF"
    0x04  archive size          little-endian
    0x08  entry count
    0x0C  header size           where the entry table stops
    0x10  entry table           offset, size, NUL-terminated name, repeated
          trailer               a short "L###" tag before the first payload

    python tools/bigfile.py list futmain.big
    python tools/bigfile.py extract futmain.big analysis/extracted/futmain
"""
from __future__ import annotations

import struct
from pathlib import Path

MAGICS = (b"BIGF", b"BIG4")


def entries(blob: bytes) -> list[tuple[str, int, int]]:
    """Return (name, offset, size) for every entry, in table order.

    BIG4 is the same layout as BIGF; the game's own data0..data7 archives use
    it and, unlike the .bh side index whose names are hashed away, they carry
    the full path of every entry inline.
    """
    if blob[:4] not in MAGICS:
        raise ValueError("not a BIGF/BIG4 archive")
    count, _header_size = struct.unpack(">II", blob[8:16])
    result = []
    position = 16
    for index in range(count):
        offset, size = struct.unpack(">II", blob[position:position + 8])
        position += 8
        end = blob.index(b"\0", position)
        result.append((blob[position:end].decode("ascii", "replace"), offset, size))
        position = end + 1
    return result


def read(blob: bytes, name: str) -> bytes:
    for entry_name, offset, size in entries(blob):
        if entry_name == name:
            return blob[offset:offset + size]
    raise KeyError(name)


def kind(payload: bytes) -> str:
    """Name the payload from its own magic, so the numeric ids stay meaningful."""
    for magic, label in (
        (b"Apt Data", "apt"),
        (b"Apt constant file", "const"),
        (b"BIGF", "bigf"),
        (b"chunkzip", "chunkzip"),
        (b"\x89PNG", "png"),
        (b"DDS ", "dds"),
    ):
        if payload.startswith(magic):
            return label
    return "bin"


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description="List or extract a BIGF archive.")
    parser.add_argument("mode", choices=("list", "extract"))
    parser.add_argument("archive", type=Path)
    parser.add_argument("destination", nargs="?", type=Path)
    args = parser.parse_args()

    blob = args.archive.read_bytes()
    table = entries(blob)
    if args.mode == "list":
        for name, offset, size in table:
            payload = blob[offset:offset + size]
            print(f"  {name:12} @0x{offset:08x}  {size:9} B  {kind(payload) if size else 'empty'}")
        return 0

    destination = args.destination or args.archive.with_suffix("")
    destination.mkdir(parents=True, exist_ok=True)
    for name, offset, size in table:
        if not size:
            continue
        payload = blob[offset:offset + size]
        target = destination / f"{name}.{kind(payload)}"
        target.write_bytes(payload)
        print(f"  {target.name:24} {size} B")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
