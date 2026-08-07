#!/usr/bin/env python3
"""
Merge Google Places results into buildings.json (point locations → tiny footprint polygons),
then refresh buildings.db from buildings.json so the API serves the same data.

Expects googleplacesv2.json with top-level keys: meta, results (see building locations/).

Usage:
  python merge_google_places.py
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os

from import_buildings import sync_buildings_from_json

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
BUILDINGS_JSON = os.path.join(BASE_DIR, "buildings.json")
GOOGLE_JSON = os.path.join(BASE_DIR, "googleplacesv2.json")

# Prefix for abbreviations from this source (avoid collision with campus BLDG_ABBR codes).
GPL_PREFIX = "GPL"


def _square_around_point(lat: float, lng: float, half_m: float = 14.0) -> list:
    """Single-ring polygon [[lng,lat], ...] in the same format as ArcGIS-derived data."""
    m_per_deg_lat = 111_320.0
    m_per_deg_lng = 111_320.0 * math.cos(math.radians(lat))
    dlat = half_m / m_per_deg_lat
    dlng = half_m / m_per_deg_lng
    ring = [
        [lng - dlng, lat - dlat],
        [lng + dlng, lat - dlat],
        [lng + dlng, lat + dlat],
        [lng - dlng, lat + dlat],
        [lng - dlng, lat - dlat],
    ]
    return [ring]


def _abbr_for_place(name: str, lat: float, lng: float) -> str:
    h = hashlib.sha256(f"{name}|{lat:.7f}|{lng:.7f}".encode()).hexdigest()[:8].upper()
    return f"{GPL_PREFIX}{h}"


def main() -> None:
    parser = argparse.ArgumentParser(description="Merge Google Places into buildings.json and sync buildings.db")
    parser.add_argument(
        "--no-db",
        action="store_true",
        help="Only update buildings.json; do not refresh buildings.db",
    )
    args = parser.parse_args()

    with open(GOOGLE_JSON, encoding="utf-8") as f:
        gp = json.load(f)

    if not isinstance(gp, dict) or "results" not in gp:
        raise SystemExit("googleplacesv2.json must be an object with a 'results' array")

    results = gp["results"]
    if not isinstance(results, list):
        raise SystemExit("'results' must be an array")

    with open(BUILDINGS_JSON, encoding="utf-8") as f:
        buildings: dict = json.load(f)

    added = 0
    already_present = 0
    invalid = 0

    for item in results:
        if not isinstance(item, dict):
            invalid += 1
            continue
        name = (item.get("name") or "").strip()
        geom = item.get("geometry") or {}
        loc = geom.get("location") or {}
        try:
            lat = float(loc["lat"])
            lng = float(loc["lng"])
        except (KeyError, TypeError, ValueError):
            invalid += 1
            continue
        if not name:
            invalid += 1
            continue

        abbr = _abbr_for_place(name, lat, lng)
        if abbr in buildings:
            already_present += 1
            continue

        nm = name.lower()
        aliases = [nm]
        # Also add a shorter alias stripped of location qualifiers (e.g. "Campus Edge on Pierce" → "campus edge")
        for sep in (" on ", " at ", " - ", " – ", " / "):
            if sep in nm:
                short = nm.split(sep)[0].strip()
                if short and short != nm:
                    aliases.append(short)
                break
        buildings[abbr] = {
            "full_name": name,
            "lat": round(lat, 7),
            "lng": round(lng, 7),
            "polygon": _square_around_point(lat, lng),
            "aliases": aliases,
            "source": "google_places",
        }
        added += 1

    if added:
        with open(BUILDINGS_JSON, "w", encoding="utf-8") as f:
            json.dump(buildings, f, indent=2)

    print(
        f"Merged Google Places: added {added} new, "
        f"{already_present} already in buildings.json (no change needed), "
        f"{invalid} invalid rows, "
        f"{len(buildings)} buildings total."
    )

    if not args.no_db:
        ins, skip_poly = sync_buildings_from_json()
        print(f"buildings.db: inserted/replaced {ins} rows, skipped {skip_poly} (no polygon in JSON).")


if __name__ == "__main__":
    main()
