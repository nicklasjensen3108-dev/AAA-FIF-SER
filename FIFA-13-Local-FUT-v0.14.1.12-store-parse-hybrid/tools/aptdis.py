#!/usr/bin/env python3
"""Disassemble the ActionScript in a FIFA 13 APT screen.

The character header in FIFA's APT 1:7:4 is 16 bytes, not the 8 that OpenSAGE
and analysis/ChunkZipInspector/AptAnalyzer.cs assume for C&C's 1:8:2 — type,
the 0x09876543 parent-anim placeholder, then 8 unused bytes before the union.
Assuming 8 makes the character table point into the file header, which is what
made AptAnalyzer fail with "Invalid character 0 offset 0x20747041" ("Apt " read
as a pointer). Confirmed on gamehub.big: with 16, the movie's screen size lands
on 1280x720 and the import table on 0x10, immediately after the magic.

    +0x00 type                      1 shape .. 4 button, 5 sprite, 9 movie
    +0x04 0x09876543
    +0x10 union
          sprite/movie: frame count, frame table, labels
          movie also:   character count/table, width, height, ms, imports, exports

    python tools/aptdis.py analysis/extracted/apt/futmain
    python tools/aptdis.py analysis/extracted/apt/futmain --grep SkipIceBreaker
    python tools/aptdis.py analysis/extracted/apt/futmain --output futmain.txt
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import apt

CHARACTER_BODY = 0x10
SIGNATURE = 0x09876543

TYPE_BUTTON, TYPE_SPRITE, TYPE_MOVIE = 4, 5, 9
DO_ACTION, PLACE_OBJECT2, DO_INIT_ACTION = 1, 3, 8

OPCODES = {
    4: "nextFrame", 5: "prevFrame", 6: "play", 7: "stop", 10: "addOld", 11: "subtract",
    12: "multiply", 13: "divide", 14: "equalsOld", 15: "lessThanOld", 16: "and", 17: "or",
    18: "not", 19: "stringEq", 23: "pop", 28: "getVariable", 29: "setVariable",
    32: "setTarget", 33: "concat", 34: "getProperty", 35: "setProperty", 38: "trace",
    42: "throw", 60: "defineLocal", 61: "callFunction", 62: "return", 64: "newObject",
    65: "defineLocal2", 66: "initArray", 67: "initObject", 68: "typeOf", 71: "add",
    72: "lessThan", 73: "equals", 74: "toNumber", 75: "toString", 76: "duplicate",
    77: "swap", 78: "getMember", 79: "setMember", 80: "increment", 81: "decrement",
    82: "callMethod", 83: "newMethod", 84: "instanceOf", 85: "enumerate", 86: "pushThis",
    88: "pushGlobal", 89: "push0", 90: "push1", 91: "callFunctionPop",
    92: "callFunctionSetVar", 93: "callMethodPop", 94: "callMethodSetVar", 96: "bitAnd",
    97: "bitOr", 98: "bitXor", 99: "shiftLeft", 100: "shiftRight", 101: "shiftRightUnsigned",
    102: "strictEquals", 103: "greaterThan", 105: "extends", 112: "pushThisVariable",
    113: "pushGlobalVariable", 114: "push0SetVar", 115: "pushTrue", 116: "pushFalse",
    117: "pushNull", 118: "pushUndefined", 119: "traceStart", 129: "gotoFrame",
    131: "getUrl", 135: "storeRegister", 136: "defineDictionary", 138: "waitForFrame",
    139: "setTarget2", 140: "gotoLabel", 142: "defineFunction2", 143: "try", 148: "with",
    150: "push", 153: "jump", 154: "getUrl2", 155: "defineFunction", 157: "jumpIfTrue",
    158: "callFrame", 159: "gotoAndPlay", 161: "pushString", 162: "pushDictByte",
    163: "pushDictWord", 164: "pushStringGetVar", 165: "pushStringGetMember",
    166: "pushStringSetVar", 167: "pushStringSetMember", 174: "dictByteGetVar",
    175: "dictByteGetMember", 176: "dictCallFunctionPop", 177: "dictCallFunctionSetVar",
    178: "dictCallMethodPop", 179: "dictCallMethodSetVar", 180: "pushFloat",
    181: "pushByte", 182: "pushWord", 183: "pushDWord", 184: "jumpIfFalse",
    185: "pushRegister",
}


class Apt:
    def __init__(self, apt_blob: bytes, const_blob: bytes):
        self.data = apt_blob
        self.pool = apt.constants(const_blob)
        self.root = apt.root_offset(const_blob)

    def u32(self, offset: int) -> int:
        return struct.unpack_from("<I", self.data, offset)[0]

    def string(self, pointer: int) -> str:
        if not pointer:
            return ""
        end = self.data.index(b"\0", pointer)
        return self.data[pointer:end].decode("utf-8", "replace")

    def constant(self, index: int) -> str:
        return self.pool[index] if 0 <= index < len(self.pool) else f"const[{index}]"

    # -- structure ---------------------------------------------------------

    def characters(self) -> list[int]:
        count = self.u32(self.root + 0x1C)
        table = self.u32(self.root + 0x20)
        return [self.u32(table + index * 4) for index in range(count)]

    def streams(self):
        """Yield (label, offset) for every action stream reachable from the root."""
        seen_characters, seen_streams = set(), set()
        pending = [("root", self.root)]
        for index, character in enumerate(self.characters()):
            if character:
                pending.append((f"char{index}", character))
        for label, character in pending:
            if character in seen_characters:
                continue
            seen_characters.add(character)
            kind = self.u32(character)
            if kind in (TYPE_SPRITE, TYPE_MOVIE):
                yield from self._movie(label, character, seen_streams)
            elif kind == TYPE_BUTTON:
                yield from self._button(label, character, seen_streams)

    def _emit(self, label, stream, seen):
        if stream and stream not in seen:
            seen.add(stream)
            yield label, stream

    def _movie(self, label, character, seen):
        frame_count = self.u32(character + CHARACTER_BODY)
        frame_table = self.u32(character + CHARACTER_BODY + 4)
        for frame_index in range(frame_count):
            frame = frame_table + frame_index * 8
            controls = self.u32(frame)
            table = self.u32(frame + 4)
            for control_index in range(controls):
                control = self.u32(table + control_index * 4)
                if not control:
                    continue
                kind = self.u32(control)
                where = f"{label}/frame{frame_index}"
                if kind == DO_ACTION:
                    yield from self._emit(f"{where}/DoAction", self.u32(control + 4), seen)
                elif kind == DO_INIT_ACTION:
                    yield from self._emit(f"{where}/DoInitAction", self.u32(control + 8), seen)
                elif kind == PLACE_OBJECT2:
                    actions = self.u32(control + 60)
                    if not actions:
                        continue
                    count = self.u32(actions)
                    entries = self.u32(actions + 4)
                    for event in range(count):
                        entry = entries + event * 12
                        yield from self._emit(f"{where}/on(0x{self.u32(entry):x})", self.u32(entry + 8), seen)

    def _button(self, label, character, seen):
        count = self.u32(character + 0x3C)
        table = self.u32(character + 0x40)
        for condition in range(count):
            entry = table + condition * 8
            yield from self._emit(f"{label}/button{condition}", self.u32(entry + 4), seen)

    # -- bytecode ----------------------------------------------------------

    def disassemble(self, stream: int, limit: int = 200_000) -> list[str]:
        out, position, dictionary = [], stream, {}
        align = lambda value: (value + 3) & ~3
        for _ in range(limit):
            opcode = self.data[position]
            start = position
            position += 1
            if opcode == 0:
                out.append(f"  0x{start:X}: end")
                return out
            name = OPCODES.get(opcode, f"opcode_{opcode}")
            detail = ""
            if opcode in (119, 180, 183):
                detail = str(self.u32(position)); position += 4
            elif opcode in (129, 135, 153, 157, 159, 184):
                position = align(position); detail = str(struct.unpack_from("<i", self.data, position)[0]); position += 4
            elif opcode == 131:
                position = align(position)
                detail = f"{self.string(self.u32(position))!r} {self.string(self.u32(position + 4))!r}"
                position += 8
            elif opcode in (136, 150):
                position = align(position)
                count, table = self.u32(position), self.u32(position + 4)
                values = []
                for item in range(count):
                    value = self.constant(self.u32(table + item * 4))
                    values.append(value)
                    if opcode == 136:
                        dictionary[item] = value
                detail = " | ".join(repr(value) for value in values)
                position += 8
            elif opcode in (139, 140, 161, 164, 165, 166, 167):
                position = align(position); detail = repr(self.string(self.u32(position))); position += 4
            elif opcode == 142:
                position = align(position); detail = self._function2(position); position += 28
            elif opcode == 143:
                position = align(position)
                detail = f"try={self.u32(position)} catch={self.u32(position + 4)} finally={self.u32(position + 8)}"
                position += 20
            elif opcode == 148:
                position = align(position); detail = f"end=+{self.u32(position)}"; position += 4
            elif opcode == 155:
                position = align(position); detail = self._function(position); position += 24
            elif opcode in (162, 174, 175, 176, 177, 178, 179):
                detail = repr(dictionary.get(self.data[position], f"dict[{self.data[position]}]")); position += 1
            elif opcode == 163:
                index = struct.unpack_from("<H", self.data, position)[0]
                detail = repr(dictionary.get(index, f"dict[{index}]")); position += 2
            elif opcode in (181, 185):
                detail = str(self.data[position]); position += 1
            elif opcode == 182:
                detail = str(struct.unpack_from("<H", self.data, position)[0]); position += 2
            out.append(f"  0x{start:X}: {name}{' ' + detail if detail else ''}")
        out.append("  !! limit reached")
        return out

    def _function(self, position: int) -> str:
        count, table = self.u32(position + 4), self.u32(position + 8)
        params = [self.string(self.u32(table + index * 4)) for index in range(count)]
        return f"{self.string(self.u32(position))}({', '.join(params)}) size={self.u32(position + 12)}"

    def _function2(self, position: int) -> str:
        count, table = self.u32(position + 4), self.u32(position + 12)
        params = [self.string(self.u32(table + index * 8 + 4)) for index in range(count)]
        return f"{self.string(self.u32(position))}({', '.join(params)}) size={self.u32(position + 16)}"


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Disassemble a screen's ActionScript.")
    parser.add_argument("directory", type=Path, help="directory holding 0.apt and 1.const")
    parser.add_argument("--output", type=Path, help="write the listing to this file instead of stdout")
    parser.add_argument("--grep", help="only show streams mentioning this text")
    args = parser.parse_args()

    apt_blob, const_blob = apt.load(args.directory)
    image = Apt(apt_blob, const_blob)
    lines = []
    for label, stream in image.streams():
        body = image.disassemble(stream)
        if args.grep and not any(args.grep.lower() in line.lower() for line in body):
            continue
        lines.append(f"ACTION {label} @0x{stream:X}")
        lines.extend(body)
    text = "\n".join(lines)
    if args.output:
        args.output.write_text(text, encoding="utf-8")
        print(f"{len(lines)} lines -> {args.output}")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
