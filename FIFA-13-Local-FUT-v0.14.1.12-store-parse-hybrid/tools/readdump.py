"""Read a FIFA crash minidump: exception code, faulting address, owning module.

    python tools/readdump.py "C:\\...\\FIFACrashDump_....dmp"

Enough to answer the only question that matters first -- did the game fault in
its own code, in CardsDLL, or in something we injected. No debugger required.
"""

import struct
import sys

STREAM_MODULE_LIST = 4
STREAM_MEMORY_LIST = 5
STREAM_EXCEPTION = 6
STREAM_MEMORY64_LIST = 9

EXCEPTION_NAMES = {
    0xC0000005: "ACCESS_VIOLATION",
    0xC000001D: "ILLEGAL_INSTRUCTION",
    0xC0000094: "INTEGER_DIVIDE_BY_ZERO",
    0xC0000096: "PRIVILEGED_INSTRUCTION",
    0xC00000FD: "STACK_OVERFLOW",
    0x80000003: "BREAKPOINT",
}


def read_modules(blob, rva):
    count = struct.unpack_from("<I", blob, rva)[0]
    modules = []
    for i in range(count):
        off = rva + 4 + i * 108
        base, size = struct.unpack_from("<QI", blob, off)
        name_rva = struct.unpack_from("<I", blob, off + 20)[0]
        n = struct.unpack_from("<I", blob, name_rva)[0]
        name = blob[name_rva + 4:name_rva + 4 + n].decode("utf-16-le", "replace")
        modules.append((base, size, name))
    return modules


# fifa13.exe is packed: its .text is encrypted on disk, so the only readable copy
# of the faulting code is the one inside the dump, captured after the client
# decrypted itself. These two streams are where that copy lives.
def memory_ranges(blob, streams):
    ranges = []
    if STREAM_MEMORY64_LIST in streams:
        rva = streams[STREAM_MEMORY64_LIST]
        count, base_rva = struct.unpack_from("<QQ", blob, rva)
        cursor = base_rva
        for i in range(count):
            start, size = struct.unpack_from("<QQ", blob, rva + 16 + i * 16)
            ranges.append((start, size, cursor))
            cursor += size
    if STREAM_MEMORY_LIST in streams:
        rva = streams[STREAM_MEMORY_LIST]
        count = struct.unpack_from("<I", blob, rva)[0]
        for i in range(count):
            start, size, at = struct.unpack_from("<QII", blob, rva + 4 + i * 16)
            ranges.append((start, size, at))
    return ranges


def read_memory(blob, ranges, address, length):
    for start, size, at in ranges:
        if start <= address < start + size:
            offset = at + (address - start)
            available = min(length, size - (address - start))
            return blob[offset:offset + available]
    return None


def main():
    path = sys.argv[1]
    with open(path, "rb") as handle:
        blob = handle.read()

    if blob[:4] != b"MDMP":
        raise SystemExit("not a minidump")
    n_streams, dir_rva = struct.unpack_from("<II", blob, 8)

    streams = {}
    for i in range(n_streams):
        stype, _size, rva = struct.unpack_from("<III", blob, dir_rva + i * 12)
        streams[stype] = rva

    modules = read_modules(blob, streams[STREAM_MODULE_LIST]) if STREAM_MODULE_LIST in streams else []

    if STREAM_EXCEPTION not in streams:
        print("no exception stream")
    else:
        rva = streams[STREAM_EXCEPTION]
        thread_id = struct.unpack_from("<I", blob, rva)[0]
        code, flags = struct.unpack_from("<II", blob, rva + 8)
        address = struct.unpack_from("<Q", blob, rva + 24)[0]
        n_params = struct.unpack_from("<I", blob, rva + 32)[0]
        params = struct.unpack_from(f"<{min(n_params, 15)}Q", blob, rva + 40) if n_params else ()

        name = EXCEPTION_NAMES.get(code, "?")
        print(f"thread        {thread_id}")
        print(f"exception     0x{code:08X}  {name}  flags 0x{flags:X}")
        print(f"address       0x{address:016X}")
        if code == 0xC0000005 and len(params) >= 2:
            kind = {0: "read", 1: "write", 8: "execute"}.get(params[0], str(params[0]))
            print(f"              {kind} at 0x{params[1]:016X}")

        owner = next(((b, s, n) for (b, s, n) in modules if b <= address < b + s), None)
        if owner:
            print(f"module        {owner[2]}")
            print(f"              base 0x{owner[0]:08X}  offset +0x{address - owner[0]:X}")
        else:
            print("module        NONE -- address outside every loaded module")

    print(f"\n{len(modules)} modules; the ones that concern us:")
    for base, size, name in modules:
        low = name.lower()
        if any(k in low for k in ("fifa13", "cards", "frida", "python")):
            print(f"  0x{base:08X}  +0x{size:06X}  {name}")

    # Disassemble around the fault, reading the decrypted bytes out of the dump.
    if STREAM_EXCEPTION in streams:
        ranges = memory_ranges(blob, streams)
        try:
            from capstone import Cs, CS_ARCH_X86, CS_MODE_32
        except ImportError:
            print("\ncapstone not installed")
            return
        md = Cs(CS_ARCH_X86, CS_MODE_32)

        # The faulting address is the only guaranteed instruction boundary, so
        # decode forward from it. Decoding backwards from a fixed offset lands
        # mid-instruction and produces convincing nonsense -- it printed a lone
        # "std" the first time.
        forward = read_memory(blob, ranges, address, 0x40)
        if not forward:
            print("\nfaulting code: absent from the dump (memory not captured)")
            return
        print("\nfaulting instruction and what follows:")
        for ins in md.disasm(forward, address):
            mark = ">>" if ins.address == address else "  "
            print(f"{mark} 0x{ins.address:08X}  {ins.bytes.hex():<16s} {ins.mnemonic:<7s} {ins.op_str}")

        # Recover the preceding instructions by trying every start offset and
        # keeping the one whose decode lands exactly on the faulting address.
        back = read_memory(blob, ranges, address - 0x30, 0x30)
        if back:
            for start in range(0, 0x30):
                addrs = [i.address for i in md.disasm(back[start:], address - 0x30 + start)]
                if address in addrs:
                    print("\npreceding context (aligned):")
                    for ins in md.disasm(back[start:], address - 0x30 + start):
                        if ins.address >= address:
                            break
                        print(f"   0x{ins.address:08X}  {ins.bytes.hex():<16s} "
                              f"{ins.mnemonic:<7s} {ins.op_str}")
                    break


if __name__ == "__main__":
    main()
