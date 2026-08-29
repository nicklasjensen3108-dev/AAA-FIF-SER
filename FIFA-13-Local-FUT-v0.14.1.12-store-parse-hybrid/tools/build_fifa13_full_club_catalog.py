#!/usr/bin/env python3
"""Build the full FIFA 13 FUT base-player club catalogue from the user's game.

The authoritative base-card identities live in ``cards0.big`` ->
``cards_ng_db.db`` -> ``fcc_playercards``.  This intentionally does not use a
fan-site page id as ``resourceId``: the retail CardsDLL resolves each base card
by its native ``carddbid`` from the same shipped database.

The output is a compact cache consumed by ``server/fut13-rs4-server.ps1``.  It
contains only metadata needed for club search/filtering and to emit safe base
player items; player names and card art remain client-owned.
"""
from __future__ import annotations

import argparse
import collections
import csv
import hashlib
import json
import re
import struct
import sys
import unicodedata
import urllib.parse
import zlib
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any, Iterator, NamedTuple

# Tools live beside this script; importing by filename keeps the release package
# dependency-free beyond Python's standard library.
from bigfile import entries as big_entries
from chunkzip import unpack as unpack_chunkzip

DB_MAGIC = b"DB\x00\x08\x00\x00\x00\x00"
POSITION_NAMES = {
    0: "GK", 2: "RWB", 3: "RB", 5: "CB", 7: "LB", 8: "LWB",
    10: "CDM", 12: "RM", 14: "CM", 16: "LM", 18: "CAM",
    20: "RF", 21: "CF", 22: "LF", 23: "RW", 25: "ST", 27: "LW",
}
BAD_CHARS = ['"', ',', '\a', '\b', '\f', '\r', '\t']


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(4 << 20), b""):
            h.update(block)
    return h.hexdigest().upper()


def _decode_payload(payload: bytes) -> bytes:
    if not payload.startswith(b"chunkzip"):
        return payload
    try:
        return unpack_chunkzip(payload)
    except Exception as first_error:
        # cards0.big uses the same container, but retail repacks have been seen
        # where the per-chunk size/flag records are absent or padded differently
        # from the frontend archives our local helper was originally written for.
        # Fall back to the donor project's proven reader: starting at byte 40,
        # scan a short window for each raw-deflate stream and accept it only when
        # it expands to the exact announced chunk size.
        if len(payload) < 40:
            raise first_error
        try:
            version, total, chunk_size, count = struct.unpack_from(">IIII", payload, 8)
            if version <= 0 or total <= 0 or chunk_size <= 0 or count <= 0:
                raise ValueError("invalid chunkzip header")
            pos = 40
            out = bytearray()
            for index in range(count):
                expected = min(chunk_size, total - len(out))
                found = False
                for skip in range(4096):
                    if pos + skip >= len(payload):
                        break
                    tail = payload[pos + skip:]
                    try:
                        dec = zlib.decompressobj(-15)
                        piece = dec.decompress(tail) + dec.flush()
                    except zlib.error:
                        continue
                    if len(piece) != expected:
                        continue
                    consumed = len(tail) - len(dec.unused_data)
                    if consumed <= 0:
                        continue
                    out.extend(piece)
                    pos += skip + consumed
                    found = True
                    break
                if not found:
                    raise ValueError(
                        f"chunk {index}: no raw-deflate stream produced {expected} bytes"
                    )
            if len(out) != total:
                raise ValueError(f"decoded {len(out)} bytes, header announced {total}")
            return bytes(out)
        except Exception as fallback_error:
            raise ValueError(
                f"chunkzip decode failed (record reader: {first_error}; "
                f"raw-deflate fallback: {fallback_error})"
            ) from fallback_error


def _find_members(big_path: Path) -> tuple[bytes, bytes]:
    """Return (cards_ng_db.db bytes, cards_ng_db-meta.xml bytes).

    Match by basename so archive prefixes can differ between distributions.
    Also inspect one nested BIG/chunkzip level; this costs little and makes the
    extractor resilient to repacked retail archives.
    """
    outer = big_path.read_bytes()
    if outer[:4] not in (b"BIG4", b"BIGF"):
        raise ValueError(f"{big_path} is not a BIG4/BIGF archive")

    wanted_db = "cards_ng_db.db"
    wanted_meta = "cards_ng_db-meta.xml"
    found: dict[str, bytes] = {}

    def consider(name: str, payload: bytes, depth: int = 0) -> None:
        base = name.replace("\\", "/").rsplit("/", 1)[-1].lower()
        if base in (wanted_db, wanted_meta):
            found[base] = _decode_payload(payload)
            return
        if depth >= 1:
            return
        decoded = _decode_payload(payload)
        if decoded[:4] in (b"BIG4", b"BIGF"):
            try:
                for child_name, off, size in big_entries(decoded):
                    consider(child_name, decoded[off:off + size], depth + 1)
            except Exception:
                pass

    for name, offset, size in big_entries(outer):
        consider(name, outer[offset:offset + size])
        if wanted_db in found and wanted_meta in found:
            break

    # Last-resort DB discovery: the T3DB magic may be embedded in a decoded
    # member whose archive name is opaque. The reader itself tolerates bytes
    # before DB_MAGIC, so retaining the whole decoded payload is correct.
    if wanted_db not in found:
        for name, offset, size in big_entries(outer):
            payload = _decode_payload(outer[offset:offset + size])
            if DB_MAGIC in payload:
                found[wanted_db] = payload
                break

    if wanted_db not in found or wanted_meta not in found:
        names = [name for name, _, _ in big_entries(outer)]
        hints = [n for n in names if "cards_ng" in n.lower() or "meta" in n.lower()]
        raise FileNotFoundError(
            "Could not find both cards_ng_db.db and cards_ng_db-meta.xml inside "
            f"{big_path}. Candidate archive entries: {hints[:20]}"
        )
    return found[wanted_db], found[wanted_meta]


def _parse_schema(xml_bytes: bytes) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, int]]]:
    root = ET.fromstring(xml_bytes)
    tables: dict[str, dict[str, Any]] = {}
    rangelow: dict[str, dict[str, int]] = {}
    for table_el in root.findall(".//table"):
        name = table_el.get("name")
        shortname = table_el.get("shortname")
        if not name or not shortname:
            continue
        fields = []
        lows: dict[str, int] = {}
        fields_el = table_el.find("fields")
        if fields_el is not None:
            for f in fields_el.findall("field"):
                fname = f.get("name")
                fshort = f.get("shortname")
                if not fname or not fshort:
                    continue
                ftype = f.get("type") or ""
                fields.append({"name": fname, "shortname": fshort, "type": ftype})
                lows[fname] = int(f.get("rangelow", "0")) if ftype == "DBOFIELDTYPE_INTEGER" else 0
        tables[shortname] = {"name": name, "shortname": shortname, "fields": fields}
        rangelow[name] = lows
    if not tables:
        raise ValueError("cards_ng_db-meta.xml contained no table definitions")
    return tables, rangelow


def _u8(data: bytes, pos: int) -> int:
    return data[pos]


def _u16le(data: bytes, pos: int) -> int:
    return struct.unpack_from("<H", data, pos)[0]


def _u32le(data: bytes, pos: int) -> int:
    return struct.unpack_from("<I", data, pos)[0]


def _read_string(data: bytes, pos: int, max_len: int) -> str:
    try:
        end = data.index(b"\x00", pos, min(len(data), pos + max_len))
    except ValueError:
        end = min(len(data), pos + max_len)
    value = data[pos:end].decode("latin-1", errors="replace")
    for c in BAD_CHARS:
        value = value.replace(c, "")
    return value.replace("\n", "\\n")


def _read_db(data: bytes, meta: bytes, wanted: set[str]) -> dict[str, list[dict[str, Any]]]:
    schema, rangelow = _parse_schema(meta)
    offset = data.index(DB_MAGIC)
    pos = offset + len(DB_MAGIC)
    _db_size = _u32le(data, pos); pos += 4
    pos += 4
    table_count = _u32le(data, pos); pos += 4
    pos += 4

    table_names, table_offsets = [], []
    for _ in range(table_count):
        table_names.append(data[pos:pos + 4].decode("ascii", errors="replace")); pos += 4
        table_offsets.append(_u32le(data, pos)); pos += 4
    pos += 4
    tables_start = pos

    result: dict[str, list[dict[str, Any]]] = {}
    for index in range(table_count):
        shortname = table_names[index]
        table = schema.get(shortname)
        if table is None or table["name"] not in wanted:
            continue
        table_name = table["name"]
        p = tables_start + table_offsets[index]
        p += 4
        record_size = _u32le(data, p); p += 4
        p += 10
        valid_records = _u16le(data, p); p += 2
        p += 4
        fields_count = _u8(data, p); p += 1
        p += 11
        if valid_records <= 0:
            result[table_name] = []
            continue

        field_defs = []
        by_short = {f["shortname"]: f["name"] for f in table["fields"]}
        for _ in range(fields_count):
            field_type = _u32le(data, p); p += 4
            bit_offset = _u32le(data, p); p += 4
            fshort = data[p:p + 4].decode("ascii", errors="replace"); p += 4
            bit_depth = _u32le(data, p); p += 4
            field_defs.append((bit_offset, field_type, fshort, bit_depth))
        field_defs.sort(key=lambda f: f[0])

        rows = []
        row_pos = p
        for _ in range(valid_records):
            current_position = row_pos
            tmp_byte = 0
            current_bit_pos = 0
            record: dict[str, Any] = {}
            cursor = current_position
            for bit_offset, ftype, fshort, bit_depth in field_defs:
                fname = by_short.get(fshort)
                if ftype == 0:  # inline string
                    tmp_byte = 0
                    current_bit_pos = 0
                    cursor = current_position + (bit_offset >> 3)
                    value = _read_string(data, cursor, bit_depth >> 3)
                    cursor = current_position + (bit_offset >> 3) + (bit_depth >> 3)
                elif ftype == 13:  # string reference id
                    tmp_byte = 0
                    current_bit_pos = 0
                    cursor = current_position + (bit_offset >> 3)
                    value = _u32le(data, cursor)
                    cursor += 4
                elif ftype == 3:  # packed integer
                    value_bits = 0
                    start_bit = 0
                    if current_bit_pos != 0:
                        start_bit = 8 - current_bit_pos
                        value_bits = tmp_byte >> current_bit_pos
                    while start_bit < bit_depth:
                        tmp_byte = _u8(data, cursor); cursor += 1
                        value_bits += tmp_byte << start_bit
                        start_bit += 8
                    current_bit_pos = (bit_depth + 8 - start_bit) & 7
                    value_bits &= (1 << bit_depth) - 1
                    value = value_bits + (rangelow.get(table_name, {}).get(fname or "", 0))
                elif ftype == 4:  # shipped reader treats float as raw u32
                    current_bit_pos = 0
                    cursor = current_position + (bit_offset >> 3)
                    value = _u32le(data, cursor)
                    cursor += 4
                else:
                    value = None
                if fname:
                    record[fname] = value
            rows.append(record)
            row_pos = current_position + record_size
        result[table_name] = rows
    return result



# ---------------------------------------------------------------------------
# Verified FIFA 13 special-card import (donor WeFUT archive)
# ---------------------------------------------------------------------------
# The retail fcc_playercards table contains only base cards. FIFA 13 encodes a
# special as (variant << 24) | base_carddbid. The client resolves the face/name
# from the low 24 bits but, because variant != 0, it does NOT load rating/team/
# attributes from fcc_playercards. Those fields therefore have to travel in the
# FUT item JSON. This is the exact model recovered by the working donor build.
OUTFIELD_STATS = ("PAC", "SHO", "PAS", "DRI", "DEF", "PHY")
KEEPER_STATS = ("DIV", "HAN", "KIC", "REF", "SPE", "POS")
POSITION_IDS = {v: k for k, v in POSITION_NAMES.items()}
BASE_TYPES = frozenset({"bronze", "bronzerare", "silver", "silverrare", "gold", "goldrare"})
MAX_VARIANT = 0xF
MAX_PLAYER_ID = 0xFFFFFF
CARD_TYPE_RAREFLAG = {
    "goldif": 3, "silverif": 3, "bronzeif": 3,
    "toty": 5,
    "special": 6,          # FIFA 13 record-breaker treatment (Messi)
    "motm": 8,
    "goldblue": 11, "silverblue": 11, "bronzeblue": 11,  # TOTS
}
NATION_ALIASES = {
    "Republic of Ireland": "Ireland Republic",
    "Netherlands": "Holland",
    "Trinidad & Tobago": "Trinidad and Tobago",
    "Central African Rep.": "Central African Rep",
    "Antigua & Barbuda": "Antigua and Barbuda",
    "Luxemburg": "Luxembourg",
}
_TRANSLITERATE = {
    "ł": "l", "Ł": "l", "ß": "ss", "ð": "d", "Ð": "d", "đ": "d", "Đ": "d",
    "æ": "ae", "Æ": "ae", "þ": "th", "Þ": "th", "ø": "o", "Ø": "o",
    "œ": "oe", "Œ": "oe", "ı": "i", "ħ": "h", "ŋ": "n",
}
_WEFUT_ID = re.compile(r"/player/\d+/(\d+)/")


def _slug(text: str) -> str:
    text = "".join(_TRANSLITERATE.get(c, c) for c in text)
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z]", "", text.lower())


def _wefut_id(link: str) -> int:
    m = _WEFUT_ID.search(link)
    return int(m.group(1)) if m else 0


def _link_tail(link: str) -> str:
    return urllib.parse.unquote(link.rstrip("/").rsplit("/", 1)[-1])


def _link_slug(link: str) -> str:
    return _slug(_link_tail(link))


def _title_from_slug(link: str) -> str:
    return " ".join(part.capitalize() for part in _link_tail(link).split("-") if part)


class _WefutRow(NamedTuple):
    name: str
    rating: int
    position: int
    card_type: str
    nation: str
    stats: tuple[int, ...]
    is_keeper: bool
    link: str = ""

    @property
    def name_matches_link(self) -> bool:
        link = _link_slug(self.link)
        name = _slug(self.name)
        if not link or not name:
            return True
        return link in name or name in link


def _load_corrections(path: Path) -> dict[str, dict]:
    if not path.exists():
        return {}
    return {c["bad"]: c for c in json.loads(path.read_text(encoding="utf-8"))}


def _load_player_ids(path: Path) -> dict[str, int]:
    if not path.exists():
        return {}
    return {e["name"]: int(e["carddbid"]) for e in json.loads(path.read_text(encoding="utf-8"))}


def _corrected_lines(path: Path, corrections: dict[str, dict]) -> Iterator[str]:
    with path.open(encoding="utf-8-sig", errors="replace") as fh:
        for line in fh:
            stripped = line.rstrip("\r\n")
            fix = corrections.get(stripped)
            if fix is None:
                yield line
                continue
            good = fix.get("good")
            for replacement in ([good] if isinstance(good, str) else good or []):
                if replacement:
                    yield replacement + "\n"


def _read_wefut_rows(path: Path, corrections: dict[str, dict]) -> list[_WefutRow]:
    source = _corrected_lines(path, corrections) if corrections else None
    out: list[_WefutRow] = []
    with path.open(newline="", encoding="utf-8-sig", errors="replace") as fh:
        reader = csv.DictReader(source if source is not None else fh)
        fields = set(reader.fieldnames or ())
        keeper = "DIV" in fields
        stat_names = KEEPER_STATS if keeper else OUTFIELD_STATS
        for raw in reader:
            try:
                pos = 0 if keeper else POSITION_IDS[raw["Pos"].strip()]
                out.append(_WefutRow(
                    name=raw["Name"].strip(), rating=int(raw["Rtg"]), position=pos,
                    card_type=raw["Card"].strip().lower(), nation=raw["Nation"].strip(),
                    stats=tuple(int(raw[x]) for x in stat_names), is_keeper=keeper,
                    link=(raw.get("Link") or "").strip()))
            except (KeyError, ValueError, TypeError):
                continue
    return out


class _Shipped(NamedTuple):
    exact: dict[tuple, int]
    by_rating_position: dict[tuple, list[dict[str, Any]]]
    nations: dict[str, int]
    rating: dict[int, int]
    cards: dict[int, dict[str, Any]]


def _make_shipped(players: list[dict[str, Any]], nations_rows: list[dict[str, Any]]) -> _Shipped:
    exact: dict[tuple, int] = {}
    by_rp: dict[tuple, list[dict[str, Any]]] = collections.defaultdict(list)
    ratings: dict[int, int] = {}
    cards: dict[int, dict[str, Any]] = {}
    for r in players:
        cid = int(r.get("carddbid") or 0)
        if cid <= 0:
            continue
        attrs = tuple(int(r.get(f"attribute{i}") or 0) for i in range(1, 7))
        key = (int(r.get("rating") or 0), int(r.get("preferredposition") or 0)) + attrs
        exact[key] = cid
        by_rp[key[:2]].append(r)
        ratings[cid] = key[0]
        cards[cid] = r
    nations: dict[str, int] = {}
    for r in nations_rows:
        name = r.get("nationname")
        if isinstance(name, str) and name.strip():
            nations[name.strip()] = int(r.get("nationid") or 0)
    return _Shipped(exact, dict(by_rp), nations, ratings, cards)


def _recover_named_player(row: _WefutRow, shipped: _Shipped) -> int | None:
    candidates = shipped.by_rating_position.get((row.rating, row.position))
    nation = shipped.nations.get(NATION_ALIASES.get(row.nation, row.nation))
    if not candidates or nation is None:
        return None
    candidates = [c for c in candidates if int(c.get("nation") or 0) == nation]
    for i, want in enumerate(row.stats, start=1):
        narrowed = [c for c in candidates if int(c.get(f"attribute{i}") or 0) == want]
        if not narrowed:
            break
        candidates = narrowed
    return int(candidates[0]["carddbid"]) if len(candidates) == 1 else None


def _link_identities(rows: list[_WefutRow]) -> tuple[dict, dict]:
    spellings = collections.defaultdict(collections.Counter)
    nations = collections.defaultdict(collections.Counter)
    for row in rows:
        slug = _slug(row.name)
        if slug:
            spellings[slug][row.name] += 1
        if row.name_matches_link and row.nation:
            nations[_link_slug(row.link)][row.nation] += 1
    return spellings, nations


def _repair_shallow(row: _WefutRow, shipped: _Shipped, spellings: dict, nations: dict):
    if row.card_type not in BASE_TYPES:
        return None
    cid = shipped.exact.get((row.rating, row.position) + row.stats)
    if cid is None:
        return None
    card = shipped.cards[cid]
    nation = shipped.nations.get(NATION_ALIASES.get(row.nation, row.nation))
    if nation is not None and int(card.get("nation") or 0) == nation:
        return row._replace(link=f"https://wefut.com/player/13/0/{_slug(row.name)}")
    slug = _link_slug(row.link)
    if not slug:
        return None
    known = spellings.get(slug)
    name = known.most_common(1)[0][0] if known else _title_from_slug(row.link)
    nation_name = nations[slug].most_common(1)[0][0] if nations.get(slug) else ""
    return row._replace(name=name, nation=nation_name)


def _unsplice(rows: list[_WefutRow], shipped: _Shipped) -> tuple[list[_WefutRow], dict[int, str], dict]:
    spellings, nations = _link_identities(rows)
    out: list[_WefutRow] = []
    recovered: dict[int, str] = {}
    report = collections.Counter()
    for row in rows:
        if row.name_matches_link:
            out.append(row)
            continue
        report["spliced"] += 1
        is_base = row.card_type in BASE_TYPES
        repaired = _repair_shallow(row, shipped, spellings, nations)
        if repaired is not None:
            out.append(repaired)
            report["kept shallow"] += 1
            continue
        cid = _recover_named_player(row, shipped) if is_base else None
        if cid is not None and cid not in recovered:
            recovered[cid] = row.name
            report["dropped, named player recovered"] += 1
        elif is_base:
            report["dropped, unidentifiable"] += 1
        else:
            report["dropped special"] += 1
    return out, recovered, dict(report)


def _pick_revisions(rows: list[_WefutRow], index: dict[tuple, int]) -> dict[int, _WefutRow]:
    groups = collections.defaultdict(list)
    for row in rows:
        if row.card_type in BASE_TYPES:
            groups[(_link_slug(row.link), row.card_type, row.position)].append(row)
    chosen: dict[int, _WefutRow] = {}
    for group in groups.values():
        matched = [r for r in group if index.get((r.rating, r.position) + r.stats)]
        if not matched:
            continue
        by_cid = {index[(r.rating, r.position) + r.stats]: r for r in matched}
        if len(by_cid) > 1:
            chosen.update(by_cid)
            continue
        shipped = min(matched, key=lambda r: (_wefut_id(r.link), r.rating))
        cid = index[(shipped.rating, shipped.position) + shipped.stats]
        chosen[cid] = max(group, key=lambda r: (_wefut_id(r.link), r.rating))
    return chosen


def _special_resource_id(base_id: int, variant: int) -> int:
    if not 0 < base_id <= MAX_PLAYER_ID:
        raise ValueError(f"base id {base_id} is outside 24-bit player identity")
    if not 1 <= variant <= MAX_VARIANT:
        raise ValueError(f"variant {variant} is outside the FIFA 13 nibble")
    return (variant << 24) | base_id


def _build_special_catalog(players: list[dict[str, Any]], nations_rows: list[dict[str, Any]],
                           team_league: dict[int, int], reference_root: Path) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    csv_root = reference_root / "wefut"
    csvs = [csv_root / "Fifa13.csv", csv_root / "FifA13gk.csv"]
    missing = [str(x) for x in csvs if not x.is_file()]
    if missing:
        return [], {"available": False, "missing": missing}
    corrections = _load_corrections(reference_root / "wefut_corrections.json")
    player_ids = _load_player_ids(reference_root / "wefut_player_ids.json")
    shipped = _make_shipped(players, nations_rows)
    loaded: list[_WefutRow] = []
    for path in csvs:
        loaded.extend(_read_wefut_rows(path, corrections))
    loaded, recovered_names, splice_report = _unsplice(loaded, shipped)

    def identity(row: _WefutRow) -> tuple:
        return (row.name, row.rating, row.position, row.card_type, row.stats)
    seen: set[tuple] = set()
    unique: list[_WefutRow] = []
    duplicate_rows = 0
    for row in loaded:
        key = identity(row)
        if key in seen:
            duplicate_rows += 1
            continue
        seen.add(key)
        unique.append(row)

    base_updates = _pick_revisions(unique, shipped.exact)
    by_name: dict[str, tuple[int, int]] = {}
    def claim(name: str, cid: int, rating: int) -> None:
        best = by_name.get(name)
        if best is None or rating > best[1]:
            by_name[name] = (cid, rating)
    for cid, row in base_updates.items():
        claim(row.name, cid, row.rating)
    for cid, name in recovered_names.items():
        if cid not in base_updates:
            claim(name, cid, shipped.rating.get(cid, 0))
    for name, cid in player_ids.items():
        if cid not in base_updates and cid not in recovered_names and cid in shipped.cards:
            claim(name, cid, shipped.rating.get(cid, 0))

    per_player: dict[int, list[_WefutRow]] = collections.defaultdict(list)
    no_base = 0
    for row in unique:
        if row.card_type in BASE_TYPES:
            continue
        base = by_name.get(row.name)
        if base is None:
            no_base += 1
            continue
        per_player[base[0]].append(row)

    specials: list[dict[str, Any]] = []
    overflow = 0
    type_counts = collections.Counter()
    for base_id, rows in per_player.items():
        rows.sort(key=lambda r: (-r.rating, _wefut_id(r.link)))
        base = shipped.cards.get(base_id)
        if base is None:
            continue
        team = int(base.get("teamid") or 0)
        for variant, row in enumerate(rows, start=1):
            if variant > MAX_VARIANT:
                overflow += 1
                continue
            resource = _special_resource_id(base_id, variant)
            rareflag = CARD_TYPE_RAREFLAG.get(row.card_type, 3)
            specials.append({
                "assetId": resource,
                "resourceId": resource,
                "baseAssetId": base_id,
                "rating": row.rating,
                "position": POSITION_NAMES.get(row.position, "GK" if row.position == 0 else "ST"),
                "preferredPositionId": row.position,
                "teamId": team,
                "leagueId": int(team_league.get(team, 0)),
                "nationId": int(base.get("nation") or 0),
                "rareFlag": rareflag,
                "attributes": list(row.stats),
                "cardType": row.card_type,
                "isSpecial": True,
                "variant": variant,
                "name": row.name,
                "wefutRecordId": _wefut_id(row.link),
            })
            type_counts[row.card_type] += 1
    specials.sort(key=lambda p: (-int(p["rating"]), int(p["resourceId"])))
    return specials, {
        "available": True,
        "sourceRows": len(loaded),
        "uniqueRows": len(unique),
        "duplicateRows": duplicate_rows,
        "specialCount": len(specials),
        "specialTypes": dict(sorted(type_counts.items())),
        "noBasePlayer": no_base,
        "variantOverflow": overflow,
        "splices": splice_report,
    }


def _build_catalog(cards_big: Path, reference_root: Path) -> dict[str, Any]:
    db, meta = _find_members(cards_big)
    tables = _read_db(db, meta, {"fcc_playercards", "leagueteamlinks", "nations"})
    players = tables.get("fcc_playercards") or []
    if not players:
        raise ValueError("fcc_playercards was missing or empty in cards_ng_db")
    links = tables.get("leagueteamlinks") or []
    nations_rows = tables.get("nations") or []
    team_league = {int(r.get("teamid") or 0): int(r.get("leagueid") or 0) for r in links}

    out = []
    skipped_position = 0
    seen = set()
    for row in players:
        asset = int(row.get("carddbid") or 0)
        if asset <= 0 or asset in seen:
            continue
        seen.add(asset)
        raw_pos = int(row.get("preferredposition") or 0)
        position = POSITION_NAMES.get(raw_pos)
        if position is None:
            skipped_position += 1
            # A card with an unknown position is still valid and renderable;
            # omit only the unsupported text mapping rather than the player.
            position = "GK" if raw_pos == 0 else "ST"
        team = int(row.get("teamid") or 0)
        rating = int(row.get("rating") or 0)
        nation = int(row.get("nation") or 0)
        rare = int(row.get("rare") or 0)
        out.append({
            "assetId": asset,
            "rating": rating,
            "position": position,
            "preferredPositionId": raw_pos,
            "teamId": team,
            "leagueId": int(team_league.get(team, 0)),
            "nationId": nation,
            "rareFlag": rare,
            "attributes": [int(row.get(f"attribute{i}") or 0) for i in range(1, 7)],
            "baseAssetId": asset,
            "resourceId": asset,
            "isSpecial": False,
        })

    out.sort(key=lambda p: (-int(p["rating"]), int(p["assetId"])))
    specials, special_report = _build_special_catalog(players, nations_rows, team_league, reference_root)
    combined = out + specials
    combined.sort(key=lambda p: (-int(p["rating"]), -int(bool(p.get("isSpecial"))), int(p.get("resourceId", p["assetId"]))))
    stat = cards_big.stat()
    return {
        "schema": "fifa13-cards-ng-db-full-club-v2-specials",
        "source": "local FIFA 13 cards0.big + donor verified WeFUT FIFA 13 archive",
        "sourcePath": str(cards_big),
        "sourceSize": stat.st_size,
        "sourceMtimeNs": stat.st_mtime_ns,
        "sourceSha256": _sha256(cards_big),
        "basePlayerCount": len(out),
        "specialCardCount": len(specials),
        "playerCount": len(combined),
        "unknownPositionCount": skipped_position,
        "specialReport": special_report,
        "players": combined,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--game-dir", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    cards_big = args.game_dir / "dlc" / "dlc_CardsDLL" / "dlc" / "cards0.big"
    if not cards_big.is_file():
        raise FileNotFoundError(f"FIFA 13 cards0.big not found: {cards_big}")

    stat = cards_big.stat()
    if args.out.is_file() and not args.force:
        try:
            existing = json.loads(args.out.read_text(encoding="utf-8-sig"))
            if (existing.get("schema") == "fifa13-cards-ng-db-full-club-v2-specials"
                    and int(existing.get("sourceSize", -1)) == stat.st_size
                    and int(existing.get("sourceMtimeNs", -1)) == stat.st_mtime_ns
                    and int(existing.get("playerCount", 0)) > 1000
                    and int(existing.get("specialCardCount", 0)) > 0):
                print(f"Full FUT club catalogue already cached: {existing['playerCount']} players")
                return 0
        except Exception:
            pass

    reference_root = Path(__file__).resolve().parents[1] / "reference" / "donor-fut13-revival"
    catalog = _build_catalog(cards_big, reference_root)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    tmp = args.out.with_suffix(args.out.suffix + ".tmp")
    tmp.write_text(json.dumps(catalog, separators=(",", ":")) + "\n", encoding="utf-8")
    tmp.replace(args.out)
    print(
        f"Built full FIFA 13 FUT club catalogue: {catalog['basePlayerCount']} base + "
        f"{catalog['specialCardCount']} special = {catalog['playerCount']} player cards "
        f"from {cards_big.name} (unknown positions: {catalog['unknownPositionCount']})"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"FULL CLUB CATALOG ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
