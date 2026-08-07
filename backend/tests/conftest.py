"""Shared fixtures for the backend test suite.

The API module runs initialization at import time (database setup, building
matcher), so the environment and the buildings database must be prepared
before `api` is imported. Everything runs against throwaway SQLite files.
"""

import json
import os
import sqlite3
import sys

import pytest

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, BACKEND_DIR)

# A square roughly 100 m on each side around the WALC centroid.
WALC_POLYGON = [[
    [-86.9140, 40.4270],
    [-86.9125, 40.4270],
    [-86.9125, 40.4280],
    [-86.9140, 40.4280],
]]


@pytest.fixture(scope="session")
def scratch_dbs(tmp_path_factory):
    """Create scratch event/message/building databases and point the app at them."""
    root = tmp_path_factory.mktemp("dbs")
    os.environ["FOOD_EVENTS_DB_PATH"] = str(root / "food_events.db")
    os.environ["MESSAGES_DB_PATH"] = str(root / "messages.db")
    os.environ.pop("GEMINI_API_KEY", None)
    os.environ["INGEST_API_KEY"] = "test-ingest-key"

    import database

    buildings_db = str(root / "buildings.db")
    database.BUILDINGS_DB_PATH = buildings_db
    conn = sqlite3.connect(buildings_db)
    conn.execute(
        """CREATE TABLE buildings (
            abbr TEXT PRIMARY KEY, full_name TEXT, lat REAL, lng REAL,
            polygon TEXT, is_main_campus INTEGER DEFAULT 1,
            aliases TEXT, show_on_map INTEGER DEFAULT 1)"""
    )
    conn.execute(
        "INSERT INTO buildings VALUES (?,?,?,?,?,?,?,?)",
        ("WALC", "Wilmeth Active Learning Center", 40.4275, -86.9132,
         json.dumps(WALC_POLYGON), 1, json.dumps(["the walc", "active learning center"]), 1),
    )
    conn.execute(
        "INSERT INTO buildings VALUES (?,?,?,?,?,?,?,?)",
        ("LWSN", "Lawson Computer Science Building", 40.4249, -86.9130,
         json.dumps([[[-86.914, 40.424], [-86.912, 40.424], [-86.912, 40.4255], [-86.914, 40.4255]]]),
         1, "[]", 1),
    )
    conn.commit()
    conn.close()

    database.init_db()
    return database


@pytest.fixture(scope="session")
def api_module(scratch_dbs):
    import api
    return api


@pytest.fixture()
def client(api_module):
    """A TestClient with rate limiter and caches reset around each test."""
    from fastapi.testclient import TestClient

    api_module._RATE_BUCKETS.clear()
    api_module._EXTRACTION_CACHE.clear()
    api_module._dining_cache.clear()
    yield TestClient(api_module.app)
    api_module._RATE_BUCKETS.clear()


@pytest.fixture()
def fresh_events_db(scratch_dbs):
    """Wipe the events tables so a test starts from an empty database."""
    with scratch_dbs.get_conn() as conn:
        conn.execute("DELETE FROM events")
        conn.execute("DELETE FROM event_votes")
        conn.execute("DELETE FROM processed_ids")
    return scratch_dbs
