"""Find every instruction in CardsDLLzf.dll that touches a given struct offset.

    python tools/scan_field.py 0x5a

A linear sweep of .text desynchronises on data islands and silently loses hits,
so this searches for the encodings directly (opcode + ModRM with an 8-bit
displacement) and decodes at the exact hit address to confirm. Read-only.

The DLL comes from the install that tools/gamepath.py resolves, so set
FIFA13_GAME_DIR if the game is not at the default EA Games path.
"""

import argparse
import sys
from pathlib import Path

import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

sys.path.insert(0, str(Path(__file__).resolve().parent))

import gamepath

# Byte-sized accesses through a register + disp8.
OPCODES = {
    0xC6: "mov  [r+d], imm8",
    0x88: "mov  [r+d], r8",
    0x8A: "mov  r8, [r+d]",
    0x80: "grp1 [r+d], imm8",
    0x38: "cmp  [r+d], r8",
    0x3A: "cmp  r8, [r+d]",
    0x84: "test [r+d], r8",
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("offset", type=lambda s: int(s, 0),
                    help="struct offset to look for, e.g. 0x5a")
    args = ap.parse_args()
    disp = args.offset & 0xFF

    pe = pefile.PE(str(gamepath.require(gamepath.DLL, "CardsDLLzf.dll")), fast_load=True)
    base = pe.OPTIONAL_HEADER.ImageBase
    text = next(s for s in pe.sections if s.Name.startswith(b".text"))
    code = text.get_data()
    secva = base + text.VirtualAddress

    md = Cs(CS_ARCH_X86, CS_MODE_32)
    seen = set()
    hits = []

    for i in range(len(code) - 8):
        op = code[i]
        # movzx / movsx are two-byte opcodes.
        if op == 0x0F and code[i + 1] in (0xB6, 0xBE):
            modrm, dpos = code[i + 2], i + 3
        elif op in OPCODES:
            modrm, dpos = code[i + 1], i + 2
        else:
            continue
        # mod=01 (disp8), rm != 100 (no SIB, keeps this simple and exact)
        if (modrm >> 6) != 1 or (modrm & 7) == 4:
            continue
        if code[dpos] != disp:
            continue
        va = secva + i
        if va in seen:
            continue
        for ins in md.disasm(code[i:i + 16], va):
            if f"0x{disp:x}]" in ins.op_str:
                hits.append(ins)
                seen.add(va)
            break

    for ins in hits:
        write = ins.op_str.startswith("byte ptr [")
        print(f"{'W' if write else 'r'} 0x{ins.address:08X}  {ins.bytes.hex():<16s} "
              f"{ins.mnemonic:<7s} {ins.op_str}")
    print(f"-- {len(hits)} accesses to +0x{disp:02X}")


if __name__ == "__main__":
    main()
