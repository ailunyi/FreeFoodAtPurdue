#!/usr/bin/env python3
"""
Load building locations/buildings.json into the SQLite buildings table (buildings.db).

Includes campus footprints from ArcGIS and Google Places rows merged by merge_google_places.py.

Usage:
  python import_buildings.py
"""

import json
import os
import sqlite3
from typing import Optional, Tuple

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(BASE_DIR, "..", "buildings.db")
BUILDINGS_JSON = os.path.join(BASE_DIR, "buildings.json")


def sync_buildings_from_json(
    json_path: Optional[str] = None,
    db_path: Optional[str] = None,
) -> Tuple[int, int]:
    """Insert or replace all buildings from JSON into SQLite. Returns (inserted, skipped_no_polygon)."""
    json_path = json_path or BUILDINGS_JSON
    db_path = db_path or DB_PATH

    with open(json_path, encoding="utf-8") as f:
        data = json.load(f)

    conn = sqlite3.connect(db_path)
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

    cols = {r[1] for r in conn.execute("PRAGMA table_info(buildings)").fetchall()}
    if "aliases" not in cols:
        conn.execute("ALTER TABLE buildings ADD COLUMN aliases TEXT")
        conn.execute("UPDATE buildings SET aliases = '[]' WHERE aliases IS NULL")
    if "show_on_map" not in cols:
        conn.execute("ALTER TABLE buildings ADD COLUMN show_on_map INTEGER NOT NULL DEFAULT 0")

    inserted = 0
    skipped = 0
    for abbr, b in data.items():
        if not b.get("polygon"):
            skipped += 1
            continue
        alias_list = b.get("aliases")
        if not isinstance(alias_list, list):
            alias_list = []
        # Google Places entries are keyed with the "GPL" prefix; everything else is ArcGIS campus data.
        show_on_map = 0 if abbr.startswith("GPL") else 1
        conn.execute(
            """
            INSERT OR REPLACE INTO buildings (abbr, full_name, lat, lng, polygon, aliases, show_on_map)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                abbr,
                b["full_name"],
                b["lat"],
                b["lng"],
                json.dumps(b["polygon"]),
                json.dumps(alias_list),
                show_on_map,
            ),
        )
        inserted += 1

    conn.commit()
    conn.close()
    return inserted, skipped


def main() -> None:
    inserted, skipped = sync_buildings_from_json()
    print(f"Done. Inserted/replaced {inserted} buildings, skipped {skipped} (no polygon).")


if __name__ == "__main__":
    main()
