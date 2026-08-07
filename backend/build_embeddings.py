#!/usr/bin/env python3
"""
Build or update the building embedding cache.

By default, performs an incremental update (only embeds new/changed buildings).
Use --full to force a complete rebuild.

    python build_embeddings.py          # incremental (default)
    python build_embeddings.py --full   # full rebuild
"""

import logging
import os
import sys

import google.generativeai as genai
from dotenv import load_dotenv

from building_matcher import BuildingMatcher
from database import load_buildings_from_db

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger(__name__)

load_dotenv()
api_key = os.getenv("GEMINI_API_KEY", "")
if not api_key:
    raise SystemExit("GEMINI_API_KEY not set in .env")

genai.configure(api_key=api_key)

force_full = "--full" in sys.argv

log.info("Loading buildings from database...")
buildings = load_buildings_from_db()
log.info("Loaded %d buildings", len(buildings))

matcher = BuildingMatcher(buildings)
matcher.build_index(force_full=force_full)
log.info("Done. Cache saved to building_embeddings.npz")
