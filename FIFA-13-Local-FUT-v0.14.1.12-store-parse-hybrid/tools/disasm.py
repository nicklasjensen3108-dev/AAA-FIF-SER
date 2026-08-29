"""Disassemble a range of CardsDLLzf.dll (or any PE) by virtual address.

    python tools/disasm.py 0x10073E00 0x300
    python tools/disasm.py 0x10073E00 0x300 --exe        # fifa13.exe instead

Read-only: the binary is opened, mapped in memory the way the loader would,
and never written back.

The binaries come from the install that tools/gamepath.py resolves, so set
FIFA13_GAME_DIR if the game is not at the default EA Games path.
"""

# This file used to be tools/dis.py. It was renamed because a module named
# dis.py in the tools directory shadows Python's stdlib `dis` module, and
# capstone imports `dis` -- so running the old name broke capstone's import with
# an error that pointed nowhere near the real cause. Do not rename it back.

import argparse
import sys
from pathlib import Path

import pefile
import struct
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

sys.path.insert(0, str(Path(__file__).resolve().parent))

import gamepath


def load(path):
    pe = pefile.PE(path, fast_load=True)
    base = pe.OPTIONAL_HEADER.ImageBase
    image = bytearray(pe.OPTIONAL_HEADER.SizeOfImage)
    for sec in pe.sections:
        raw = sec.get_data()
        image[sec.VirtualAddress:sec.VirtualAddress + len(raw)] = raw
    return base, bytes(image)


def cstring(image, rva, limit=96):
    end = image.find(b"\x00", rva, rva + limit)
    if end < 0:
        return None
    try:
        s = image[rva:end].decode("ascii")
    except UnicodeDecodeError:
        return None
    return s if s.isprintable() else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("va", type=lambda s: int(s, 0), help="virtual address to start at")
    ap.add_argument("length", type=lambda s: int(s, 0), nargs="?", default=0x100,
                    help="number of bytes to disassemble (default 0x100)")
    ap.add_argument("--exe", action="store_true",
                    help="read fifa13.exe instead of CardsDLLzf.dll")
    args = ap.parse_args()

    target = gamepath.EXE if args.exe else gamepath.DLL
    base, image = load(str(gamepath.require(target, "fifa13.exe" if args.exe else "CardsDLLzf.dll")))
    start = args.va - base
    code = image[start:start + args.length]

    md = Cs(CS_ARCH_X86, CS_MODE_32)
    md.detail = False
    for ins in md.disasm(code, args.va):
        note = ""
        # Annotate any immediate or displacement that lands on a readable
        # string -- that is what turns a table of pointers into a table of
        # names.
        for tok in ins.op_str.replace(",", " ").replace("[", " ").replace("]", " ").split():
            if tok.startswith("0x"):
                try:
                    val = int(tok, 16)
                except ValueError:
                    continue
                rva = val - base
                if 0 < rva < len(image):
                    s = cstring(image, rva)
                    if s and len(s) > 2:
                        note = f"   ; \"{s}\""
        print(f"0x{ins.address:08X}  {ins.bytes.hex():<20s} {ins.mnemonic:<8s} {ins.op_str}{note}")


if __name__ == "__main__":
    main()
