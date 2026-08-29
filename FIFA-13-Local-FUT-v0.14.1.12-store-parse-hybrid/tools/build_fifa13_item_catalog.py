#!/usr/bin/env python3
"""Build the non-player FIFA 13 FUT card pool from the installed cards0.big.

This reads the same cards_ng_db tables that the retail CL1298564 CardsDLL uses,
so resourceIds in normal Bronze/Silver/Gold packs are native game ids rather
than invented placeholders.  It deliberately excludes shipped rows that the
retail client cannot render/use (league-logo stickers, crowd cards, the two
unresolved 5-4-1 training cards, and one missing-art stadium).
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
from pathlib import Path

from build_fifa13_full_club_catalog import _find_members, _read_db

FORMATION_NAMES = {
    3: "f4231", 6: "f4312", 7: "f4321", 8: "f433", 13: "f4222",
    14: "f41212", 16: "f442", 19: "f4411", 21: "f451", 23: "f3412",
    24: "f3421", 25: "f343", 27: "f352", 29: "f5212", 30: "f5221",
    31: "f532", 32: "f541",
}

# kind -> shipped table and wire facts.  Column names are copied from the
# donor's verified carddb importer; no web database ids are used here.
SOURCES = {
    "kit": dict(table="fcc_kitcards", wire="kit", subtype=9, rare="weightrare"),
    "badge": dict(table="fcc_badgecards", wire="custom", subtype=11, rare="weightrare"),
    "stadium": dict(table="fcc_stadium", wire="stadium", subtype=10, rare="weightrare"),
    "ball": dict(table="fcc_balls", wire="ball", subtype=30, rare="rare"),
    # League-logo stickers are intentionally NOT exported: their card art is
    # absent from FIFA 13 and every one renders as NOT FOUND.
    "training": dict(table="fcc_trainingcards", wire="training", subtype_col="cardsubtype", rare="weightrare"),
    "contract": dict(table="fcc_contractcards", wire="contract", subtype_col="cardsubtype", rare="weightrare"),
    "health": dict(table="fcc_healingcards", wire="health", subtype_col="cardsubtype", rare="weightrare"),
    "misc": dict(table="fcc_misccards", wire="misc", subtype_col="cardsubtype", rare="weightrare"),
    "headCoach": dict(table="headcoachcards", wire="headCoach", subtype=5, rare="rare"),
    "gkCoach": dict(table="gkcoachcards", wire="gkCoach", subtype=6, rare="rare"),
    "physio": dict(table="physiocards", wire="physio", subtype=7, rare="rare"),
    "fitnessCoach": dict(table="fitnesscoachcards", wire="fitnessCoach", subtype=8, rare="rare"),
}

MISC_COINS = 231
MISC_CROWD = 232
MISC_PACK = 233
BLOCKED_RESOURCE_IDS = {6200021}
UNRESOLVED_TRAINING_SUBTYPES = {83, 133}


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(4 << 20), b""):
            h.update(block)
    return h.hexdigest().upper()


def _level(value: int) -> str:
    if value <= 64:
        return "bronze"
    if value <= 74:
        return "silver"
    return "gold"


def _int(row: dict, key: str, default: int = 0) -> int:
    try:
        value = row.get(key)
        return default if value is None else int(value)
    except (TypeError, ValueError):
        return default


def build(cards_big: Path) -> dict:
    db, meta = _find_members(cards_big)
    wanted = {spec["table"] for spec in SOURCES.values()} | {"managercards", "leagueteamlinks"}
    tables = _read_db(db, meta, wanted)
    team_league = {
        _int(r, "teamid"): _int(r, "leagueid")
        for r in tables.get("leagueteamlinks", [])
    }

    items: list[dict] = []
    skipped = collections.Counter()
    by_kind = collections.Counter()
    by_level = collections.Counter()

    for kind, spec in SOURCES.items():
        for row in tables.get(spec["table"], []) or []:
            rid = _int(row, "carddbid")
            if rid <= 0:
                skipped["invalidId"] += 1
                continue
            if rid in BLOCKED_RESOURCE_IDS:
                skipped["missingArt"] += 1
                continue
            subtype = _int(row, spec.get("subtype_col", ""), _int({}, "", spec.get("subtype", 0))) \
                if spec.get("subtype_col") else int(spec.get("subtype", 0))
            if kind == "training" and subtype in UNRESOLVED_TRAINING_SUBTYPES:
                skipped["unresolvedFormation"] += 1
                continue
            if kind == "misc" and subtype == MISC_CROWD:
                skipped["crowdCard"] += 1
                continue

            effective_kind = kind
            wire = spec["wire"]
            if kind == "misc":
                if subtype == MISC_COINS:
                    effective_kind, wire = "coins", "misc"
                elif subtype == MISC_PACK:
                    effective_kind, wire = "pack", "misc"
                else:
                    skipped["unknownMisc"] += 1
                    continue

            rating = _int(row, "rating")
            value = _int(row, "value")
            tier_value = rating or value
            if tier_value <= 0:
                skipped["noTierValue"] += 1
                continue
            rare_weight = _int(row, spec["rare"])
            team_id = _int(row, "teamid")
            item = {
                "resourceId": rid,
                "kind": effective_kind,
                "itemType": wire,
                "cardsubtypeid": subtype,
                "rating": rating,
                "value": value,
                "level": _level(tier_value),
                "rare": bool(rare_weight),
                "rareWeight": rare_weight,
                "teamId": team_id,
                "leagueId": _int(row, "leagueid", team_league.get(team_id, 0)) or team_league.get(team_id, 0),
                "nationId": _int(row, "nation"),
                "assetId": _int(row, "assetid"),
                "amount": _int(row, "amount"),
                "capacity": _int(row, "capacity"),
                "boost": _int(row, "boost"),
                "category": _int(row, "category"),
                "bronze": _int(row, "bronze"),
                "silver": _int(row, "silver"),
                "gold": _int(row, "gold"),
            }
            items.append(item)
            by_kind[effective_kind] += 1
            by_level[item["level"]] += 1

    # Managers are a separate shipped table and use a real boolean rare flag.
    for row in tables.get("managercards", []) or []:
        rid = _int(row, "carddbid")
        value = _int(row, "value")
        if rid <= 0 or value <= 0:
            continue
        formation_id = _int(row, "formationid")
        item = {
            "resourceId": rid,
            "kind": "manager",
            "itemType": "manager",
            "cardsubtypeid": 4,
            "rating": 0,
            "value": value,
            "level": _level(value),
            "rare": bool(_int(row, "rare")),
            "rareWeight": 1,
            "teamId": 0,
            "leagueId": 0,
            "nationId": _int(row, "nation"),
            "assetId": 0,
            "amount": 0,
            "capacity": 0,
            "boost": 0,
            "category": 0,
            "bronze": 0,
            "silver": 0,
            "gold": 0,
            "formation": FORMATION_NAMES.get(formation_id, "f442"),
        }
        items.append(item)
        by_kind["manager"] += 1
        by_level[item["level"]] += 1

    items.sort(key=lambda x: (x["level"], x["kind"], x["resourceId"]))
    stat = cards_big.stat()
    return {
        "schema": "fifa13-native-item-catalog-v1",
        "source": "local FIFA 13 cards0.big / cards_ng_db",
        "sourcePath": str(cards_big),
        "sourceSize": stat.st_size,
        "sourceMtimeNs": stat.st_mtime_ns,
        "sourceSha256": _sha256(cards_big),
        "itemCount": len(items),
        "countsByKind": dict(sorted(by_kind.items())),
        "countsByLevel": dict(sorted(by_level.items())),
        "skipped": dict(sorted(skipped.items())),
        "items": items,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--game-dir", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    cards_big = args.game_dir / "dlc" / "dlc_CardsDLL" / "dlc" / "cards0.big"
    if not cards_big.is_file():
        raise FileNotFoundError(f"FIFA 13 cards0.big not found: {cards_big}")
    stat = cards_big.stat()
    if args.out.is_file() and not args.force:
        try:
            existing = json.loads(args.out.read_text(encoding="utf-8-sig"))
            if (existing.get("schema") == "fifa13-native-item-catalog-v1"
                    and int(existing.get("sourceSize", -1)) == stat.st_size
                    and int(existing.get("sourceMtimeNs", -1)) == stat.st_mtime_ns
                    and int(existing.get("itemCount", 0)) > 100):
                print(f"Native FUT item catalogue already cached: {existing['itemCount']} items")
                return 0
        except Exception:
            pass
    catalog = build(cards_big)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    tmp = args.out.with_suffix(args.out.suffix + ".tmp")
    tmp.write_text(json.dumps(catalog, separators=(",", ":")) + "\n", encoding="utf-8")
    tmp.replace(args.out)
    print(f"Built native FIFA 13 item catalogue: {catalog['itemCount']} items; "
          f"kinds={catalog['countsByKind']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
