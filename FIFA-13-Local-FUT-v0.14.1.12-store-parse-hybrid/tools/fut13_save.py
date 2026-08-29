#!/usr/bin/env python3
"""Tiny SQLite persistence layer for the localhost FUT 13 server.

The PowerShell RS4 service owns the live protocol state.  This helper gives that
state a durable lifetime without adding a third-party SQLite dependency:
Python's standard-library sqlite3 module writes one local save database.
"""
from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path

SCHEMA_VERSION = 1
DEFAULT_COINS = 100_000_000

SCHEMA = """
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS club (
  id INTEGER PRIMARY KEY CHECK(id=1),
  coins INTEGER NOT NULL,
  fifa_points INTEGER NOT NULL DEFAULT 0,
  squad_name TEXT NOT NULL DEFAULT 'Starting XI',
  formation TEXT NOT NULL DEFAULT 'f442',
  chemistry INTEGER,
  star_rating INTEGER,
  rating INTEGER
);
CREATE TABLE IF NOT EXISTS item (
  id INTEGER PRIMARY KEY,
  resource_id INTEGER NOT NULL,
  pile TEXT NOT NULL,
  payload TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_item_pile ON item(pile,id);
CREATE INDEX IF NOT EXISTS idx_item_resource ON item(resource_id);
CREATE TABLE IF NOT EXISTS squad_slot (
  slot INTEGER PRIMARY KEY CHECK(slot >= 0 AND slot < 23),
  item_id INTEGER
);
CREATE TABLE IF NOT EXISTS clientdata (
  bucket TEXT NOT NULL,
  key INTEGER NOT NULL,
  value INTEGER NOT NULL,
  PRIMARY KEY(bucket,key)
);
"""


def connect(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(path)
    con.row_factory = sqlite3.Row
    con.executescript(SCHEMA)
    con.execute("INSERT OR IGNORE INTO meta(key,value) VALUES('schema_version',?)", (str(SCHEMA_VERSION),))
    con.execute("INSERT OR IGNORE INTO meta(key,value) VALUES('next_item_id','20000')")
    con.execute("INSERT OR IGNORE INTO club(id,coins,fifa_points,squad_name,formation) VALUES(1,?,?,?,?)",
                (DEFAULT_COINS, 0, "Starting XI", "f442"))
    con.commit()
    return con


def load(path: Path) -> dict:
    with connect(path) as con:
        club = dict(con.execute("SELECT * FROM club WHERE id=1").fetchone())
        items = []
        for row in con.execute("SELECT id,resource_id,pile,payload FROM item ORDER BY id"):
            try:
                payload = json.loads(row["payload"])
            except Exception:
                payload = {}
            payload["id"] = int(row["id"])
            payload["resourceId"] = int(row["resource_id"])
            items.append({"pile": row["pile"], "item": payload})
        order = [0] * 23
        for row in con.execute("SELECT slot,item_id FROM squad_slot ORDER BY slot"):
            if 0 <= row["slot"] < 23:
                order[row["slot"]] = int(row["item_id"] or 0)
        buckets: dict[str, list[dict]] = {}
        for row in con.execute("SELECT bucket,key,value FROM clientdata ORDER BY bucket,key"):
            buckets.setdefault(row["bucket"], []).append({"key": row["key"], "value": row["value"]})
        next_id = int(con.execute("SELECT value FROM meta WHERE key='next_item_id'").fetchone()[0])
        return {
            "schemaVersion": SCHEMA_VERSION,
            "club": club,
            "items": items,
            "squadOrder": order,
            "clientData": buckets,
            "nextItemId": next_id,
        }


def snapshot(path: Path, document: dict) -> None:
    with connect(path) as con:
        club = document.get("club") or {}
        con.execute(
            "UPDATE club SET coins=?, fifa_points=?, squad_name=?, formation=?, chemistry=?, star_rating=?, rating=? WHERE id=1",
            (
                int(club.get("coins", DEFAULT_COINS)),
                int(club.get("fifaPoints", 0)),
                str(club.get("squadName") or "Starting XI"),
                str(club.get("formation") or "f442"),
                club.get("chemistry"), club.get("starRating"), club.get("rating"),
            ),
        )
        con.execute("DELETE FROM item")
        for wrapped in document.get("items") or []:
            pile = str(wrapped.get("pile") or "club")
            item = dict(wrapped.get("item") or {})
            item_id = int(item.get("id") or 0)
            resource_id = int(item.get("resourceId") or 0)
            if item_id <= 0 or resource_id <= 0:
                continue
            con.execute("INSERT INTO item(id,resource_id,pile,payload) VALUES(?,?,?,?)",
                        (item_id, resource_id, pile, json.dumps(item, separators=(",", ":"))))
        con.execute("DELETE FROM squad_slot")
        for slot, item_id in enumerate((document.get("squadOrder") or [])[:23]):
            item_id = int(item_id or 0)
            if item_id:
                con.execute("INSERT INTO squad_slot(slot,item_id) VALUES(?,?)", (slot, item_id))
        con.execute("DELETE FROM clientdata")
        for bucket, entries in (document.get("clientData") or {}).items():
            for entry in entries or []:
                con.execute("INSERT INTO clientdata(bucket,key,value) VALUES(?,?,?)",
                            (str(bucket), int(entry.get("key", 0)), int(entry.get("value", 0))))
        next_id = int(document.get("nextItemId") or 20000)
        con.execute("INSERT OR REPLACE INTO meta(key,value) VALUES('next_item_id',?)", (str(next_id),))
        con.commit()


def reset(path: Path) -> None:
    if path.exists():
        path.unlink()
    for suffix in ("-wal", "-shm"):
        p = Path(str(path) + suffix)
        if p.exists():
            p.unlink()
    with connect(path):
        pass


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True, type=Path)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("load")
    snap = sub.add_parser("snapshot")
    snap.add_argument("--input", required=True, type=Path)
    sub.add_parser("reset")
    args = ap.parse_args()
    if args.cmd == "load":
        print(json.dumps(load(args.db), separators=(",", ":")))
    elif args.cmd == "snapshot":
        snapshot(args.db, json.loads(args.input.read_text(encoding="utf-8-sig")))
    elif args.cmd == "reset":
        reset(args.db)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
