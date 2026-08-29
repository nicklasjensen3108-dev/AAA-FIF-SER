#!/usr/bin/env python3
"""Read and write FIFA 13's "chunkzip" container.

The game's archive loader (0x0129AB80) does not take raw files: data files ship
wrapped in this container. Dropping a plain-XML cfgrouting.xml into the game
folder crashed it at startup, while the byte-identical file served over HTTP
parsed fine — the local path was reading a chunkzip header and finding "<?xml".

Layout, recovered from the .chunkzip files in analysis/extracted (all integers
big-endian):

    0x00  "chunkzip"            8 bytes magic
    0x08  version               = 2
    0x0C  uncompressed size     matches the extracted plain file exactly
    0x10  chunk size            = 0x40000 (262144)
    0x14  chunk count           = 1
    0x18  header size           = 16
    0x1C  reserved              = 0
    0x20  reserved              = 0
    0x24  reserved              = 0
    0x28  compressed size       = len(file) - 0x30
    0x2C  reserved              = 1
    0x30  payload               raw deflate (wbits=-15), no zlib/gzip wrapper

Only single-chunk files have been observed; payloads here are a few kB, well
under the 256 kB chunk size, so this writer emits one chunk.

    python tools/chunkzip.py unpack futmain.big.chunkzip futmain.big
    python tools/chunkzip.py pack cfgrouting.xml cfgrouting.xml.chunkzip
    python tools/chunkzip.py selftest
"""
from __future__ import annotations

import struct
import zlib

MAGIC = b"chunkzip"
VERSION = 2
CHUNK_SIZE = 0x40000
HEADER_SIZE = 0x30


def _read_chunk(blob: bytes, offset: int, expected: int, index: int):
    """Read one chunk record at or shortly after `offset`.

    Chunks are separated by a few bytes of padding whose rule is not obvious
    (futmain.big has 11 bytes between the end of chunk 0 and the next record,
    which is neither 8- nor 16-byte alignment from that point). Rather than
    guess it, scan forward for the first record that actually decodes to the
    expected size — cheap, and immune to whatever the real alignment is.
    """
    limit = min(offset + 4096, len(blob) - 8)
    for position in range(offset, limit + 1):
        csize, flag = struct.unpack(">II", blob[position:position + 8])
        if flag != 1 or not (0 < csize <= len(blob) - position - 8):
            continue
        try:
            piece = zlib.decompress(blob[position + 8:position + 8 + csize], -15)
        except zlib.error:
            continue
        if len(piece) == expected:
            return piece, position + 8 + csize
    raise ValueError(f"chunk {index}: no valid record after 0x{offset:x}")


def unpack(blob: bytes) -> bytes:
    """Return the decompressed payload of a chunkzip container.

    Multi-chunk files (futmain.big, cards_bg_69.big) repeat an 8-byte record
    before each chunk: compressed size, then a flag observed as 1. The single
    chunk case is just this layout with one record, which is why the fixed
    0x28/0x2C fields matched it.
    """
    if blob[:8] != MAGIC:
        raise ValueError("not a chunkzip container")
    version, usize, chunk_size, nchunks, _hdr = struct.unpack(">IIIII", blob[8:28])
    if version != VERSION:
        raise ValueError(f"unexpected chunkzip version: {version}")

    out = bytearray()
    offset = 0x28
    for index in range(nchunks):
        expected = min(chunk_size, usize - len(out))
        piece, offset = _read_chunk(blob, offset, expected, index)
        out += piece
    if len(out) != usize:
        raise ValueError(f"decompressed size {len(out)} != announced size {usize}")
    return bytes(out)


def pack(payload: bytes) -> bytes:
    """Wrap payload in a single-chunk chunkzip container."""
    if len(payload) > CHUNK_SIZE:
        raise ValueError("payload larger than one chunk: not supported")
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    body = compressor.compress(payload) + compressor.flush()
    header = MAGIC + struct.pack(
        ">IIIIIIII",
        VERSION, len(payload), CHUNK_SIZE, 1, 16, 0, 0, 0,
    ) + struct.pack(">II", len(body), 1)
    assert len(header) == HEADER_SIZE, len(header)
    return header + body


def main() -> int:
    import argparse
    from pathlib import Path

    parser = argparse.ArgumentParser(description="Encode/decode a chunkzip container.")
    parser.add_argument("mode", choices=("pack", "unpack", "selftest"))
    parser.add_argument("source", nargs="?", type=Path)
    parser.add_argument("destination", nargs="?", type=Path)
    args = parser.parse_args()

    if args.mode == "selftest":
        # Round-trip every extracted pair: unpack must reproduce the plain file,
        # and pack->unpack must be lossless.
        root = Path(__file__).resolve().parents[1] / "analysis" / "extracted"
        failures = 0
        for container in sorted(root.glob("*.chunkzip")):
            plain = Path(str(container)[: -len(".chunkzip")])
            got = unpack(container.read_bytes())
            if plain.exists():
                want = plain.read_bytes()
                ok = got == want
                print(f"  unpack {container.name:44} {'OK' if ok else 'DIFFERENT'} ({len(got)} B)")
                failures += 0 if ok else 1
            else:
                print(f"  unpack {container.name:44} OK ({len(got)} B, no plain file to compare against)")
            again = unpack(pack(got))
            ok = again == got
            print(f"  pack   {container.name:44} {'OK' if ok else 'LOSSY'}")
            failures += 0 if ok else 1
        print("selftest:", "OK" if failures == 0 else f"{failures} failure(s)")
        return 1 if failures else 0

    if args.source is None or args.destination is None:
        parser.error("source and destination are required")
    data = args.source.read_bytes()
    args.destination.write_bytes(pack(data) if args.mode == "pack" else unpack(data))
    print(f"{args.mode}: {args.source} -> {args.destination} ({args.destination.stat().st_size} B)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
