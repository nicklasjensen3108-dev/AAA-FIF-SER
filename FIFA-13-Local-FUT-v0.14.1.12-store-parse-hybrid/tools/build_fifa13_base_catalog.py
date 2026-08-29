"""Build a normalized FIFA 13 base-card catalogue from the bundled WeFUT CSVs.

The integer in a wefut.com/player/13/<id>/ URL identifies WeFUT's page, not
EA's FUT assetId.  Keep it as ``wefutPageId`` so it can never accidentally be
sent to CardsDLL as a player resource id.
"""

from __future__ import annotations

import csv
import json
import re
import unicodedata
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
IMPORTS = ROOT / "src" / "references" / "fifalocal" / "imports" / "fut-db"
OUT = ROOT / "data" / "wefut-fifa13-base.json"
BASE_TYPES = {"goldrare", "gold", "silverrare", "silver", "bronzerare", "bronze"}


def integer(value: str | None) -> int:
    try:
        return int(value or 0)
    except ValueError:
        return 0


def normalized_name(value: str) -> str:
    folded = unicodedata.normalize("NFKD", value)
    return "".join(c for c in folded if not unicodedata.combining(c)).casefold()


def load(path: Path, goalkeeper: bool) -> list[dict]:
    result: list[dict] = []
    with path.open("r", encoding="utf-8-sig", newline="") as source:
        for row in csv.DictReader(source):
            card_type = (row.get("Card") or "").strip().casefold()
            if card_type not in BASE_TYPES:
                continue
            link = (row.get("Link") or "").strip()
            match = re.search(r"/player/13/(\d+)/", link)
            attributes = (
                [integer(row.get(k)) for k in ("DIV", "HAN", "KIC", "REF", "SPE", "POS")]
                if goalkeeper
                else [integer(row.get(k)) for k in ("PAC", "SHO", "PAS", "DRI", "DEF", "PHY")]
            )
            result.append(
                {
                    "name": (row.get("Name") or "").strip(),
                    "normalizedName": normalized_name(row.get("Name") or ""),
                    "rating": integer(row.get("Rtg")),
                    "position": "GK" if goalkeeper else (row.get("Pos") or "").strip().upper(),
                    "cardType": card_type,
                    "nation": (row.get("Nation") or "").strip(),
                    "attributes": attributes,
                    "wefutPageId": integer(match.group(1)) if match else 0,
                    "sourceUrl": link,
                }
            )
    return result


def main() -> None:
    cards = load(IMPORTS / "Players" / "Players" / "Fifa13.csv", False)
    cards += load(IMPORTS / "GKs" / "GKs" / "FifA13gk.csv", True)

    # Duplicate base records exist for transfers/updates. Prefer the highest
    # base rating, then rare, while retaining only one default card per name.
    cards.sort(
        key=lambda card: (
            card["normalizedName"],
            -card["rating"],
            0 if card["cardType"].endswith("rare") else 1,
            card["wefutPageId"],
        )
    )
    unique: dict[str, dict] = {}
    for card in cards:
        unique.setdefault(card["normalizedName"], card)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(
        json.dumps(
            {
                "gameYear": 2013,
                "source": "https://wefut.com/player-database/13",
                "warning": "wefutPageId is not an EA assetId",
                "cards": list(unique.values()),
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"wrote {len(unique)} FIFA 13 base cards to {OUT}")


if __name__ == "__main__":
    main()
