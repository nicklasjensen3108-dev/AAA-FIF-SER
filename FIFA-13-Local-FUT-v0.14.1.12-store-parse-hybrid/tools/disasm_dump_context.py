"""Print the aligned instructions immediately around a minidump exception."""

import struct
import sys

from capstone import Cs, CS_ARCH_X86, CS_MODE_32

import readdump


def main() -> None:
    blob = open(sys.argv[1], "rb").read()
    stream_count, directory = struct.unpack_from("<II", blob, 8)
    streams = {}
    for index in range(stream_count):
        stream_type, _size, rva = struct.unpack_from("<III", blob, directory + index * 12)
        streams[stream_type] = rva

    exception = streams[readdump.STREAM_EXCEPTION]
    address = struct.unpack_from("<Q", blob, exception + 24)[0]
    context_size, context_rva = struct.unpack_from("<II", blob, exception + 160)
    if context_size >= 204:
        context = blob[context_rva:context_rva + context_size]
        register_offsets = {
            "edi": 156, "esi": 160, "ebx": 164, "edx": 168,
            "ecx": 172, "eax": 176, "ebp": 180, "eip": 184, "esp": 196,
        }
        registers = {name: struct.unpack_from("<I", context, offset)[0]
                     for name, offset in register_offsets.items()}
        print("exception registers:")
        print("  " + " ".join(f"{name}=0x{value:08X}" for name, value in registers.items()))
    ranges = readdump.memory_ranges(blob, streams)
    start = address - 0x80
    code = readdump.read_memory(blob, ranges, start, 0xC0)
    if code is None:
        raise SystemExit("exception context is absent from the dump")

    decoder = Cs(CS_ARCH_X86, CS_MODE_32)
    decoder.skipdata = True
    for offset in range(min(0x80, len(code))):
        instructions = list(decoder.disasm(code[offset:], start + offset))
        fault_index = next((i for i, ins in enumerate(instructions) if ins.address == address), None)
        if fault_index is None:
            continue
        for ins in instructions[max(0, fault_index - 24):fault_index + 12]:
            marker = ">>" if ins.address == address else "  "
            print(f"{marker} 0x{ins.address:08X} {ins.bytes.hex():<16} {ins.mnemonic:<8} {ins.op_str}")
        if len(sys.argv) > 2:
            ebp = int(sys.argv[2], 0)
            stack = readdump.read_memory(blob, ranges, ebp - 0x2C0, 0x2E0)
            if stack:
                print("\nselected frame locals:")
                for displacement in (-0x2AC, -0x260, -0x230, -0x50, -0x34, -0x18, -0x10, -0xC, -8):
                    offset = displacement + 0x2C0
                    value = struct.unpack_from("<I", stack, offset)[0]
                    print(f"  [ebp{displacement:+#x}] = 0x{value:08X}")
        return
    raise SystemExit("could not recover an instruction boundary leading to the fault")


if __name__ == "__main__":
    main()
