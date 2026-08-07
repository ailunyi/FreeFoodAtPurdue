#!/usr/bin/env python3
"""
One-time migration: load buildings.json into the SQLite buildings table.

Usage:
  python import_buildings.py
"""

import json
import os
import sqlite3

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(BASE_DIR, "buildings.db")
BUILDINGS_JSON = os.path.join(BASE_DIR, "buildings.json")


def main() -> None:
    with open(BUILDINGS_JSON, encoding="utf-8") as f:
        data = json.load(f)

    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA journal_mode=WAL")

    conn.execute("""
        CREATE TABLE IF NOT EXISTS buildings (
            abbr            TEXT PRIMARY KEY,
            full_name       TEXT NOT NULL,
            lat             REAL NOT NULL,
            lng             REAL NOT NULL,
            polygon         TEXT NOT NULL,
            is_main_campus  INTEGER NOT NULL DEFAULT 0
        )
    """)

    inserted = 0
    skipped = 0
    for abbr, b in data.items():
        if not b.get("polygon"):
            skipped += 1
            continue
        conn.execute(
            """
            INSERT OR REPLACE INTO buildings (abbr, full_name, lat, lng, polygon)
            VALUES (?, ?, ?, ?, ?)
            """,
            (abbr, b["full_name"], b["lat"], b["lng"], json.dumps(b["polygon"])),
        )
        inserted += 1

    conn.commit()
    conn.close()
    print(f"Done. Inserted/replaced {inserted} buildings, skipped {skipped} (no polygon).")


if __name__ == "__main__":
    main()
