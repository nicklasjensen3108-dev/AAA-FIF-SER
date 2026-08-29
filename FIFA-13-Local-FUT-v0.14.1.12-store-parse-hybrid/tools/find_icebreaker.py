"""Locate the native code behind FUT_IcebreakerManager.SkipIceBreaker().

The APT bytecode calls SkipIceBreaker() as a method on FUT_IcebreakerManager,
so CardsDLL must publish a binding table mapping the ActionScript name to a
native function pointer. This finds the string, every data reference to it,
and the pointers that sit next to those references.

Nothing is written and nothing is patched -- the DLL is opened read-only. The
DLL comes from the install that tools/gamepath.py resolves, so set
FIFA13_GAME_DIR if the game is not at the default EA Games path.

    python tools/find_icebreaker.py
"""

import pefile
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import gamepath

NAMES = [
    b"SkipIceBreaker",
    b"IsUserIBPackRewarded",
    b"DisableUserIBPackRewarded",
    b"UpdateCaptainSelection",
    b"RetrievePackList",
    b"RetrievePack",
    b"FUT_IcebreakerManager",
]


def main():
    pe = pefile.PE(str(gamepath.require(gamepath.DLL, "CardsDLLzf.dll")), fast_load=True)
    base = pe.OPTIONAL_HEADER.ImageBase
    print(f"image base 0x{base:08X}")

    # Flatten the whole image the way the loader would, so a VA maps to an
    # index directly. Sections are sparse on disk but contiguous in memory.
    size = pe.OPTIONAL_HEADER.SizeOfImage
    image = bytearray(size)
    for sec in pe.sections:
        raw = sec.get_data()
        va = sec.VirtualAddress
        image[va:va + len(raw)] = raw
        print(f"  {sec.Name.rstrip(chr(0).encode()).decode():8s} "
              f"rva 0x{va:06X} vsize 0x{sec.Misc_VirtualSize:06X} raw {len(raw)}")
    image = bytes(image)

    # 1. String addresses
    addrs = {}
    for name in NAMES:
        needle = name + b"\x00"
        hits = []
        start = 0
        while True:
            i = image.find(needle, start)
            if i < 0:
                break
            # Only accept NUL-terminated starts, so "RetrievePack" does not
            # match inside "RetrievePackList".
            if i == 0 or image[i - 1] == 0:
                hits.append(i)
            start = i + 1
        addrs[name] = hits
        for h in hits:
            print(f"string {name.decode():28s} VA 0x{base + h:08X} (rva 0x{h:06X})")

    # 2. Data references to each string: a 4-byte little-endian VA anywhere
    #    in the image.
    print("\n--- references ---")
    for name in NAMES:
        for h in addrs[name]:
            va = base + h
            pat = struct.pack("<I", va)
            start = 0
            while True:
                i = image.find(pat, start)
                if i < 0:
                    break
                start = i + 1
                # Show the 8 dwords around the reference: a binding table
                # entry keeps the function pointer adjacent to the name.
                ctx = []
                for k in range(-4, 5):
                    off = i + k * 4
                    if 0 <= off <= size - 4:
                        val = struct.unpack_from("<I", image, off)[0]
                        mark = "<<" if k == 0 else "  "
                        ctx.append(f"{mark}[{k:+d}] 0x{val:08X}")
                print(f"\nref to {name.decode()} at VA 0x{base + i:08X}")
                print("   " + "  ".join(ctx))


if __name__ == "__main__":
    main()
