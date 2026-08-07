#!/usr/bin/env python3
"""
One-time script to generate buildings.json from Purdue's official ArcGIS building dataset.
Computes the centroid of each building polygon for use as a map pin coordinate.

Data source:
  Purdue University Facilities & Construction Management
  Building Shapes dataset via ArcGIS REST API
  https://services1.arcgis.com/mLNdQKiKsj5Z5YMN/arcgis/rest/services/BuildingShapesZip4/FeatureServer
  Accessed: 2026-04-02

Usage:
  python generate_buildings.py
"""

import json
import requests

ARCGIS_URL = (
    "https://services1.arcgis.com/mLNdQKiKsj5Z5YMN/arcgis/rest/services/"
    "BuildingShapesZip4/FeatureServer/0/query?where=1%3D1&outFields=*&f=geojson"
)


def polygon_centroid(coordinates: list) -> tuple[float, float]:
    """Compute the centroid of the first ring of a GeoJSON polygon."""
    ring = coordinates[0]
    lngs = [pt[0] for pt in ring]
    lats = [pt[1] for pt in ring]
    return sum(lats) / len(lats), sum(lngs) / len(lngs)




def main() -> None:
    print("Fetching Purdue building data...", flush=True)
    resp = requests.get(ARCGIS_URL, timeout=30)
    resp.raise_for_status()
    features = resp.json()["features"]
    print(f"Found {len(features)} buildings.")

    output = {}

    for f in features:
        props = f["properties"]
        abbr = (props.get("BLDG_ABBR") or "").strip()
        name = (props.get("BUILDING_N") or "").strip()
        other_abbr = (props.get("OTHER_ABBR") or "").strip()

        if not abbr or not name:
            continue

        geometry = f.get("geometry")
        if not geometry:
            continue

        lat, lng = polygon_centroid(geometry["coordinates"])

        aliases = [abbr.lower()]
        if other_abbr and other_abbr != abbr:
            aliases.append(other_abbr.lower())
        aliases.append(name.lower())

        output[abbr] = {
            "full_name": name,
            "lat": round(lat, 7),
            "lng": round(lng, 7),
            "polygon": geometry["coordinates"],
            "aliases": aliases,
        }

    with open("buildings.json", "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2)

    print(f"Saved {len(output)} buildings to buildings.json")


if __name__ == "__main__":
    main()
