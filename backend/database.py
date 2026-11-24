import json
import os
import re
import sqlite3
from contextlib import contextmanager
from typing import Optional

_BACKEND_DIR = os.path.dirname(os.path.abspath(__file__))
DB_PATH           = os.getenv("FOOD_EVENTS_DB_PATH", os.path.join(_BACKEND_DIR, "food_events.db"))
BUILDINGS_DB_PATH = os.path.join(_BACKEND_DIR, "buildings.db")
MESSAGES_DB_PATH  = os.getenv("MESSAGES_DB_PATH", os.path.join(_BACKEND_DIR, "messages.db"))


def init_db() -> None:
    with get_conn() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS events (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                message_id      TEXT UNIQUE,
                building        TEXT,
                building_abbr   TEXT,
                room            TEXT,
                food_type       TEXT,
                expires_at      TEXT,
                confidence      REAL,
                lat             REAL,
                lng             REAL,
                is_free         INTEGER NOT NULL DEFAULT 1,
                created_at      TEXT DEFAULT (datetime('now'))
            )
        """)
        cols = {r[1] for r in conn.execute("PRAGMA table_info(events)").fetchall()}
        if "building_abbr" not in cols:
            conn.execute("ALTER TABLE events ADD COLUMN building_abbr TEXT")
        if "is_free" not in cols:
            conn.execute("ALTER TABLE events ADD COLUMN is_free INTEGER NOT NULL DEFAULT 1")
        if "going_count" not in cols:
            conn.execute("ALTER TABLE events ADD COLUMN going_count INTEGER NOT NULL DEFAULT 0")
        if "gone_count" not in cols:
            conn.execute("ALTER TABLE events ADD COLUMN gone_count INTEGER NOT NULL DEFAULT 0")
        if "is_testing" not in cols:
            conn.execute("ALTER TABLE events ADD COLUMN is_testing INTEGER NOT NULL DEFAULT 0")
        if "source" not in cols:
            conn.execute("ALTER TABLE events ADD COLUMN source TEXT NOT NULL DEFAULT 'groupme'")
        if "name" not in cols:
            conn.execute("ALTER TABLE events ADD COLUMN name TEXT")
        if "description" not in cols:
            conn.execute("ALTER TABLE events ADD COLUMN description TEXT")
        if "starts_at" not in cols:
            conn.execute("ALTER TABLE events ADD COLUMN starts_at TEXT")
        if "name_confidence" not in cols:
            conn.execute("ALTER TABLE events ADD COLUMN name_confidence REAL NOT NULL DEFAULT 0.0")
        if "event_categories" not in cols:
            conn.execute("ALTER TABLE events ADD COLUMN event_categories TEXT")
        if "dietary_info" not in cols:
            conn.execute("ALTER TABLE events ADD COLUMN dietary_info TEXT")
        if "sources" not in cols:
            conn.execute("ALTER TABLE events ADD COLUMN sources TEXT")
        if "rsvp_required" not in cols:
            conn.execute("ALTER TABLE events ADD COLUMN rsvp_required INTEGER NOT NULL DEFAULT 0")
        if "rsvp_link" not in cols:
            conn.execute("ALTER TABLE events ADD COLUMN rsvp_link TEXT")

        conn.execute("""
            CREATE TABLE IF NOT EXISTS processed_ids (
                source_id    TEXT PRIMARY KEY,
                source       TEXT NOT NULL,
                result       TEXT NOT NULL,
                processed_at TEXT DEFAULT (datetime('now'))
            )
        """)

        conn.execute("""
            CREATE TABLE IF NOT EXISTS event_votes (
                event_id    INTEGER NOT NULL,
                user_id     TEXT NOT NULL,
                vote_type   TEXT NOT NULL CHECK(vote_type IN ('going', 'gone')),
                created_at  TEXT DEFAULT (datetime('now')),
                PRIMARY KEY (event_id, user_id, vote_type)
            )
        """)

        conn.execute("""
            CREATE TABLE IF NOT EXISTS event_activity (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id    INTEGER NOT NULL,
                kind        TEXT NOT NULL,
                field       TEXT,
                old_value   TEXT,
                new_value   TEXT,
                source      TEXT,
                user_id     TEXT,
                created_at  TEXT DEFAULT (datetime('now'))
            )
        """)
        conn.execute("CREATE INDEX IF NOT EXISTS idx_event_activity_event_id ON event_activity(event_id, id)")
        # Additive migration for installs created before user_id existed.
        act_cols = {r[1] for r in conn.execute("PRAGMA table_info(event_activity)").fetchall()}
        if "user_id" not in act_cols:
            conn.execute("ALTER TABLE event_activity ADD COLUMN user_id TEXT")

        # Per-day, per-court upvotes for the dining-court rankings feature.
        # PRIMARY KEY (user_id, court_abbr, date) means a fast double-click
        # can't double-count, and a fresh `date` value each day implicitly
        # resets the leaderboard at midnight.
        conn.execute("""
            CREATE TABLE IF NOT EXISTS dining_votes (
                user_id     TEXT NOT NULL,
                court_abbr  TEXT NOT NULL,
                date        TEXT NOT NULL,
                created_at  TEXT DEFAULT (datetime('now')),
                PRIMARY KEY (user_id, court_abbr, date)
            )
        """)
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_dining_votes_date_court "
            "ON dining_votes(date, court_abbr)"
        )

    with get_messages_conn() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS messages (
                message_id   TEXT PRIMARY KEY,
                group_id     TEXT,
                sender_id    TEXT,
                sender_name  TEXT,
                text         TEXT,
                image_url    TEXT,
                sent_at      TEXT,
                received_at  TEXT DEFAULT (datetime('now'))
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS gemini_responses (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                message_id    TEXT NOT NULL,
                raw_response  TEXT,
                parsed_result TEXT,
                is_food_event INTEGER NOT NULL DEFAULT 0,
                created_at    TEXT DEFAULT (datetime('now'))
            )
        """)


@contextmanager
def get_conn():
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


@contextmanager
def get_buildings_conn():
    conn = sqlite3.connect(BUILDINGS_DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


@contextmanager
def get_messages_conn():
    conn = sqlite3.connect(MESSAGES_DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def mark_processed(source_id: str, source: str, result: str) -> None:
    """Record that an external event ID has been processed (food, non_food, or error)."""
    with get_conn() as conn:
        conn.execute(
            "INSERT OR IGNORE INTO processed_ids (source_id, source, result) VALUES (?, ?, ?)",
            (source_id, source, result),
        )


def get_processed_ids(source: str) -> set:
    """Return all processed source_ids for a given source."""
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT source_id FROM processed_ids WHERE source = ?", (source,)
        ).fetchall()
    return {r["source_id"] for r in rows}


def insert_message(
    message_id:  str,
    group_id:    str,
    sender_id:   str,
    sender_name: str,
    text:        Optional[str],
    image_url:   Optional[str],
    sent_at:     Optional[str],
) -> None:
    with get_messages_conn() as conn:
        conn.execute(
            """
            INSERT OR IGNORE INTO messages
                (message_id, group_id, sender_id, sender_name, text, image_url, sent_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (message_id, group_id, sender_id, sender_name, text, image_url, sent_at),
        )


def insert_gemini_response(
    message_id:    str,
    raw_response:  Optional[str],
    parsed_result: Optional[dict],
    is_food_event: bool,
) -> None:
    with get_messages_conn() as conn:
        conn.execute(
            """
            INSERT INTO gemini_responses
                (message_id, raw_response, parsed_result, is_food_event)
            VALUES (?, ?, ?, ?)
            """,
            (
                message_id,
                raw_response,
                json.dumps(parsed_result) if parsed_result is not None else None,
                1 if is_food_event else 0,
            ),
        )


def insert_event(
    message_id:       str,
    building:         Optional[str],
    building_abbr:    Optional[str],
    room:             Optional[str],
    food_type:        Optional[str],
    expires_at:       Optional[str],
    confidence:       float,
    lat:              Optional[float],
    lng:              Optional[float],
    is_free:          bool = True,
    is_testing:       bool = False,
    source:           str = 'groupme',
    name:             Optional[str] = None,
    description:      Optional[str] = None,
    starts_at:        Optional[str] = None,
    name_confidence:  float = 0.0,
    dietary_info:     Optional[dict] = None,
    rsvp_required:    bool = False,
    rsvp_link:        Optional[str] = None,
) -> int:
    """Insert a new event and return its row id."""
    dietary_json = json.dumps(dietary_info) if dietary_info is not None else None
    with get_conn() as conn:
        cur = conn.execute(
            """
            INSERT OR IGNORE INTO events
                (message_id, building, building_abbr, room, food_type, expires_at, confidence,
                 lat, lng, is_free, is_testing, source, name, description, starts_at,
                 name_confidence, dietary_info, rsvp_required, rsvp_link)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (message_id, building, building_abbr, room, food_type, expires_at, confidence,
             lat, lng, 1 if is_free else 0, 1 if is_testing else 0, source,
             name, description, starts_at, name_confidence, dietary_json,
             1 if rsvp_required else 0, rsvp_link),
        )
        if cur.rowcount == 0:
            # INSERT OR IGNORE hit an existing message_id — lastrowid would be
            # stale, so look up the real row id instead.
            row = conn.execute(
                "SELECT id FROM events WHERE message_id = ?", (message_id,)
            ).fetchone()
            return row["id"] if row else 0
        return cur.lastrowid


# Fields whose changes are user-visible in the activity feed. Skipped: confidence,
# name_confidence, lat, lng (noisy/internal), building_abbr (paired with building),
# dietary_info (structured payload — handled elsewhere if needed).
_ACTIVITY_TRACKED_FIELDS = {
    'name', 'food_type', 'building', 'room', 'starts_at', 'expires_at',
    'description', 'is_free', 'rsvp_required', 'rsvp_link',
}


def _activity_value(v) -> Optional[str]:
    if v is None:
        return None
    if isinstance(v, (dict, list)):
        return json.dumps(v)
    return str(v)


def _log_activity(conn, event_id: int, kind: str, *,
                  field: Optional[str] = None,
                  old_value=None, new_value=None,
                  source: Optional[str] = None,
                  user_id: Optional[str] = None) -> None:
    conn.execute(
        "INSERT INTO event_activity (event_id, kind, field, old_value, new_value, source, user_id) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (event_id, kind, field, _activity_value(old_value), _activity_value(new_value), source, user_id),
    )


def get_event_activity(event_id: int) -> list[dict]:
    """Activity log for an event, oldest first."""
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT id, kind, field, old_value, new_value, source, created_at "
            "FROM event_activity WHERE event_id = ? ORDER BY id ASC",
            (event_id,),
        ).fetchall()
    return [dict(r) for r in rows]


def update_event(event_id: int, source: Optional[str] = None, **fields) -> None:
    """Merge non-None fields into an existing event row.

    Logs an `event_activity` row per tracked field whose value actually changes.
    `source` is recorded against each logged change so the UI can attribute it.
    """
    allowed = {'building', 'building_abbr', 'room', 'food_type', 'expires_at',
               'starts_at', 'confidence', 'lat', 'lng', 'is_free', 'name', 'description',
               'name_confidence', 'dietary_info', 'rsvp_required', 'rsvp_link'}
    updates = {k: v for k, v in fields.items() if k in allowed and v is not None}
    if not updates:
        return
    with get_conn() as conn:
        existing = conn.execute(
            "SELECT * FROM events WHERE id = ?", (event_id,),
        ).fetchone()
        if existing is None:
            return
        for field, new_v in updates.items():
            if field not in _ACTIVITY_TRACKED_FIELDS:
                continue
            old_v = existing[field] if field in existing.keys() else None
            if _activity_value(old_v) == _activity_value(new_v):
                continue
            _log_activity(conn, event_id, 'updated',
                          field=field, old_value=old_v, new_value=new_v, source=source)
        set_clause = ", ".join(f"{k} = ?" for k in updates)
        conn.execute(
            f"UPDATE events SET {set_clause} WHERE id = ?",
            (*updates.values(), event_id),
        )


def increment_going(event_id: int, user_id: Optional[str] = None) -> tuple[int, bool]:
    """Toggle a 'going' vote. Returns (new_count, is_now_going)."""
    with get_conn() as conn:
        if user_id:
            existing = conn.execute(
                "SELECT 1 FROM event_votes WHERE event_id = ? AND user_id = ? AND vote_type = 'going'",
                (event_id, user_id),
            ).fetchone()
            if existing:
                conn.execute(
                    "DELETE FROM event_votes WHERE event_id = ? AND user_id = ? AND vote_type = 'going'",
                    (event_id, user_id),
                )
                conn.execute(
                    "DELETE FROM event_activity WHERE event_id = ? AND kind = 'going' AND user_id = ?",
                    (event_id, user_id),
                )
                conn.execute("UPDATE events SET going_count = MAX(going_count - 1, 0) WHERE id = ?", (event_id,))
                row = conn.execute("SELECT going_count FROM events WHERE id = ?", (event_id,)).fetchone()
                return (row["going_count"] if row else 0, False)
            conn.execute(
                "INSERT INTO event_votes (event_id, user_id, vote_type) VALUES (?, ?, 'going')",
                (event_id, user_id),
            )
        conn.execute("UPDATE events SET going_count = going_count + 1 WHERE id = ?", (event_id,))
        _log_activity(conn, event_id, 'going', user_id=user_id)
        row = conn.execute("SELECT going_count FROM events WHERE id = ?", (event_id,)).fetchone()
    return (row["going_count"] if row else 0, True)


def increment_gone(event_id: int, user_id: Optional[str] = None) -> tuple[int, bool]:
    """Toggle a 'gone' vote. Returns (new_count, is_now_gone)."""
    with get_conn() as conn:
        if user_id:
            existing = conn.execute(
                "SELECT 1 FROM event_votes WHERE event_id = ? AND user_id = ? AND vote_type = 'gone'",
                (event_id, user_id),
            ).fetchone()
            if existing:
                conn.execute(
                    "DELETE FROM event_votes WHERE event_id = ? AND user_id = ? AND vote_type = 'gone'",
                    (event_id, user_id),
                )
                conn.execute(
                    "DELETE FROM event_activity WHERE event_id = ? AND kind = 'gone' AND user_id = ?",
                    (event_id, user_id),
                )
                conn.execute("UPDATE events SET gone_count = MAX(gone_count - 1, 0) WHERE id = ?", (event_id,))
                row = conn.execute("SELECT gone_count FROM events WHERE id = ?", (event_id,)).fetchone()
                return (row["gone_count"] if row else 0, False)
            conn.execute(
                "INSERT INTO event_votes (event_id, user_id, vote_type) VALUES (?, ?, 'gone')",
                (event_id, user_id),
            )
        conn.execute("UPDATE events SET gone_count = gone_count + 1 WHERE id = ?", (event_id,))
        _log_activity(conn, event_id, 'gone', user_id=user_id)
        row = conn.execute("SELECT gone_count FROM events WHERE id = ?", (event_id,)).fetchone()
    return (row["gone_count"] if row else 0, True)


def get_active_events() -> list[dict]:
    with get_conn() as conn:
        rows = conn.execute("""
            SELECT *,
                CASE
                    WHEN expires_at IS NOT NULL AND datetime(expires_at) > datetime('now') THEN 1
                    WHEN expires_at IS NULL AND datetime(created_at, '+3 hours') > datetime('now') THEN 1
                    ELSE 0
                END AS is_active
            FROM events
            ORDER BY created_at DESC
        """).fetchall()
    return [dict(r) for r in rows]


def _ensure_buildings_columns(conn: sqlite3.Connection) -> None:
    cols = {r[1] for r in conn.execute("PRAGMA table_info(buildings)").fetchall()}
    if "aliases" not in cols:
        conn.execute("ALTER TABLE buildings ADD COLUMN aliases TEXT")
        conn.execute("UPDATE buildings SET aliases = '[]' WHERE aliases IS NULL")
    if "show_on_map" not in cols:
        conn.execute("ALTER TABLE buildings ADD COLUMN show_on_map INTEGER NOT NULL DEFAULT 0")
    conn.commit()


# Backwards-compatible alias kept so callers that imported the old name still work.
_ensure_buildings_aliases_column = _ensure_buildings_columns


def _row_to_building_dict(r: sqlite3.Row) -> dict:
    d = dict(r)
    d["polygon"] = json.loads(d["polygon"])
    raw_aliases = d.get("aliases")
    if raw_aliases is None or raw_aliases == "":
        d["aliases"] = []
    else:
        try:
            d["aliases"] = json.loads(raw_aliases)
        except json.JSONDecodeError:
            d["aliases"] = []
    return d


def load_buildings_from_db() -> dict:
    """Same shape as building locations/buildings.json: {abbr: {full_name, lat, lng, polygon, aliases, show_on_map}}."""
    out: dict = {}
    with get_buildings_conn() as conn:
        _ensure_buildings_columns(conn)
        try:
            rows = conn.execute(
                "SELECT abbr, full_name, lat, lng, polygon, "
                "COALESCE(aliases, '[]') AS aliases, "
                "COALESCE(show_on_map, 0) AS show_on_map "
                "FROM buildings"
            ).fetchall()
        except sqlite3.OperationalError as e:
            if "no such table" in str(e).lower():
                raise RuntimeError(
                    "buildings.db has no buildings table; run: python 'building locations/import_buildings.py'"
                ) from e
            raise

    for r in rows:
        d = _row_to_building_dict(r)
        abbr = d.pop("abbr", None)
        if not abbr:
            continue
        out[abbr] = d
    return out


def get_campus_buildings(
    key_only: bool = False,
    q: Optional[str] = None,
    map_only: bool = False,
) -> list[dict]:
    """Return campus buildings.

    key_only: restrict to is_main_campus = 1.
    map_only: restrict to show_on_map = 1 (ArcGIS-sourced buildings; excludes Google Places).
    q: filter by abbreviation, full name, or any alias (case-insensitive substring).
    """
    query = (
        "SELECT abbr, full_name, lat, lng, polygon, "
        "COALESCE(aliases, '[]') AS aliases, "
        "COALESCE(show_on_map, 0) AS show_on_map "
        "FROM buildings"
    )
    clauses: list[str] = []
    params: list = []

    if key_only:
        clauses.append("is_main_campus = 1")
    if map_only:
        clauses.append("show_on_map = 1")

    if q is not None and (needle := q.strip()):
        needle_like = f"%{needle.lower()}%"
        clauses.append(
            "("
            "lower(abbr) LIKE ? OR "
            "lower(full_name) LIKE ? OR "
            "EXISTS (SELECT 1 FROM json_each(COALESCE(aliases, '[]')) WHERE lower(value) LIKE ?)"
            ")"
        )
        params.extend([needle_like, needle_like, needle_like])

    if clauses:
        query += " WHERE " + " AND ".join(clauses)

    with get_buildings_conn() as conn:
        _ensure_buildings_columns(conn)
        rows = conn.execute(query, params).fetchall()
    return [_row_to_building_dict(r) for r in rows]


def get_buildings_for_events() -> list[dict]:
    """Return only buildings that have any food event, with polygon data (for iOS app)."""
    with get_conn() as conn:
        abbrs = [r[0] for r in conn.execute(
            "SELECT DISTINCT building_abbr FROM events WHERE building_abbr IS NOT NULL"
        ).fetchall()]

    if not abbrs:
        return []

    placeholders = ",".join("?" * len(abbrs))
    with get_buildings_conn() as conn:
        _ensure_buildings_columns(conn)
        rows = conn.execute(
            f"SELECT abbr, full_name, lat, lng, polygon, "
            f"COALESCE(aliases, '[]') AS aliases, "
            f"COALESCE(show_on_map, 0) AS show_on_map "
            f"FROM buildings WHERE abbr IN ({placeholders}) AND show_on_map = 1",
            abbrs,
        ).fetchall()

    return [_row_to_building_dict(r) for r in rows]


import math

def _point_in_polygon(lat: float, lng: float, ring: list[list[float]]) -> bool:
    """Ray-casting point-in-polygon test. Ring is [[lng, lat], ...]."""
    n = len(ring)
    inside = False
    j = n - 1
    for i in range(n):
        yi, xi = ring[i][1], ring[i][0]
        yj, xj = ring[j][1], ring[j][0]
        if ((yi > lat) != (yj > lat)) and (lng < (xj - xi) * (lat - yi) / (yj - yi) + xi):
            inside = not inside
        j = i
    return inside


def _haversine_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    """Return distance in metres between two lat/lng points."""
    R = 6_371_000
    dlat = math.radians(lat2 - lat1)
    dlng = math.radians(lng2 - lng1)
    a = math.sin(dlat / 2) ** 2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlng / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def _min_distance_to_polygon(lat: float, lng: float, ring: list[list[float]]) -> float:
    """Approximate minimum distance (metres) from point to polygon boundary."""
    return min(_haversine_m(lat, lng, pt[1], pt[0]) for pt in ring)


def building_at_point(lat: float, lng: float, max_distance_m: float = 50.0) -> Optional[dict]:
    """Find which building a lat/lng falls inside, or the nearest one within max_distance_m.

    Returns dict with keys: abbr, full_name, lat, lng, inside (bool)
    or None if no building is close enough.
    """
    buildings = get_campus_buildings(map_only=True)

    # Phase 1: check if point is inside any polygon
    for b in buildings:
        polygon = b.get("polygon")
        if not polygon or not polygon[0]:
            continue
        if _point_in_polygon(lat, lng, polygon[0]):
            return {
                "abbr": b["abbr"],
                "full_name": b["full_name"],
                "lat": b["lat"],
                "lng": b["lng"],
                "inside": True,
            }

    # Phase 2: find nearest building within threshold
    best = None
    best_dist = max_distance_m
    for b in buildings:
        polygon = b.get("polygon")
        if not polygon or not polygon[0]:
            continue
        dist = _min_distance_to_polygon(lat, lng, polygon[0])
        if dist < best_dist:
            best_dist = dist
            best = b

    if best:
        return {
            "abbr": best["abbr"],
            "full_name": best["full_name"],
            "lat": best["lat"],
            "lng": best["lng"],
            "inside": False,
        }
    return None


_STOP_WORDS = {'the', 'a', 'an', 'and', 'or', 'with', 'in', 'at', 'of', 'for', 'some', 'free'}

def _text_words(text: str) -> set:
    return {w for w in re.sub(r'[^a-z0-9 ]', '', text.lower()).split()
            if w not in _STOP_WORDS}


def _parse_event_dt(s: str):
    """Parse various datetime formats from events."""
    from datetime import datetime
    for fmt in ('%Y-%m-%dT%H:%M:%S+00:00', '%Y-%m-%dT%H:%M:%S%z', '%Y-%m-%d %H:%M:%S'):
        try:
            return datetime.strptime(s.split('.')[0].replace('Z', '+00:00'), fmt)
        except ValueError:
            continue
    return None


def is_duplicate_event(
    building_abbr: Optional[str] = None,
    food_type: Optional[str] = None,
    name: Optional[str] = None,
    starts_at: Optional[str] = None,
) -> Optional[int]:
    """Return the ID of the matching active event, or None if no duplicate found.

    All three checks must pass simultaneously:
      1. Same building (by abbr)
      2. Overlapping time window (starts within 2 hours)
      3. Similar event name (>50% word overlap)

    If a field is missing on BOTH sides, that check is skipped (not failed),
    so two events with no building set won't auto-pass the building check.
    """
    if not name and not building_abbr and not starts_at:
        return None

    with get_conn() as conn:
        rows = conn.execute("""
            SELECT id, building_abbr, food_type, name, starts_at FROM events
            WHERE (
                (expires_at IS NOT NULL AND datetime(expires_at) > datetime('now'))
                OR
                (expires_at IS NULL AND datetime(created_at, '+3 hours') > datetime('now'))
            )
        """).fetchall()

    for row in rows:
        # --- Check 1: same building ---
        if building_abbr and row['building_abbr']:
            if building_abbr != row['building_abbr']:
                continue
        elif building_abbr or row['building_abbr']:
            continue

        # --- Check 2: overlapping time (within 2 hours) ---
        if starts_at and row['starts_at']:
            t1 = _parse_event_dt(starts_at)
            t2 = _parse_event_dt(row['starts_at'])
            if t1 and t2 and abs((t1 - t2).total_seconds()) >= 7200:
                continue
        elif starts_at or row['starts_at']:
            continue

        # --- Check 3: similar name (>50% word overlap) ---
        if name and row['name']:
            name_words = _text_words(name)
            row_words = _text_words(row['name'])
            if name_words and row_words:
                overlap = len(name_words & row_words)
                smaller = min(len(name_words), len(row_words))
                if smaller == 0 or overlap / smaller <= 0.5:
                    continue
            else:
                continue
        elif name or row['name']:
            continue

        return row['id']

    return None


def merge_duplicate_event(
    existing_id: int,
    new_source: str,
    name: Optional[str] = None,
    description: Optional[str] = None,
    food_type: Optional[str] = None,
    starts_at: Optional[str] = None,
    expires_at: Optional[str] = None,
    building: Optional[str] = None,
    building_abbr: Optional[str] = None,
    lat: Optional[float] = None,
    lng: Optional[float] = None,
) -> None:
    """Merge a duplicate event into the existing one.

    - Appends new_source to the sources list
    - Updates fields with newer/better data (non-null values overwrite nulls,
      longer descriptions replace shorter ones)
    """
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM events WHERE id = ?", (existing_id,)).fetchone()
        if not row:
            return

        # Build sources list
        existing_sources = []
        if row['sources']:
            try:
                existing_sources = json.loads(row['sources'])
            except (json.JSONDecodeError, TypeError):
                existing_sources = [row['source']] if row['source'] else []
        elif row['source']:
            existing_sources = [row['source']]
        if new_source not in existing_sources:
            existing_sources.append(new_source)

        # Pick the better value for each field: prefer non-null, prefer longer descriptions
        def _pick(old, new):
            if new is None:
                return old
            if old is None:
                return new
            return new  # newer wins

        def _pick_longer(old, new):
            if new is None:
                return old
            if old is None:
                return new
            return new if len(str(new)) > len(str(old)) else old

        new_values = {
            'name':          _pick(row['name'], name),
            'description':   _pick_longer(row['description'], description),
            'food_type':     _pick(row['food_type'], food_type),
            'starts_at':     _pick(row['starts_at'], starts_at),
            'expires_at':    _pick(row['expires_at'], expires_at),
            'building':      _pick(row['building'], building),
            'building_abbr': _pick(row['building_abbr'], building_abbr),
            'lat':           _pick(row['lat'], lat),
            'lng':           _pick(row['lng'], lng),
        }

        # 'merged' marker — even when no fields change, we want the UI to show
        # that an additional source corroborated this event.
        _log_activity(conn, existing_id, 'merged', source=new_source)
        for field, new_v in new_values.items():
            if field not in _ACTIVITY_TRACKED_FIELDS:
                continue
            old_v = row[field]
            if _activity_value(old_v) == _activity_value(new_v):
                continue
            _log_activity(conn, existing_id, 'updated',
                          field=field, old_value=old_v, new_value=new_v, source=new_source)

        conn.execute("""
            UPDATE events SET
                sources = ?,
                name = ?,
                description = ?,
                food_type = ?,
                starts_at = ?,
                expires_at = ?,
                building = ?,
                building_abbr = ?,
                lat = ?,
                lng = ?
            WHERE id = ?
        """, (
            json.dumps(existing_sources),
            new_values['name'],
            new_values['description'],
            new_values['food_type'],
            new_values['starts_at'],
            new_values['expires_at'],
            new_values['building'],
            new_values['building_abbr'],
            new_values['lat'],
            new_values['lng'],
            existing_id,
        ))


# ── Dining-court daily rankings ────────────────────────────────────────────
# Toggleable, anonymous upvotes keyed by (user_id, court_abbr, date) so the
# leaderboard self-resets at midnight Indianapolis time.

def toggle_dining_vote(user_id: str, court_abbr: str, date: str) -> tuple[bool, int]:
    """Add or remove a vote. Returns (now_voted, total_votes_for_court_today)."""
    with get_conn() as conn:
        existing = conn.execute(
            "SELECT 1 FROM dining_votes WHERE user_id=? AND court_abbr=? AND date=?",
            (user_id, court_abbr, date),
        ).fetchone()
        if existing:
            conn.execute(
                "DELETE FROM dining_votes WHERE user_id=? AND court_abbr=? AND date=?",
                (user_id, court_abbr, date),
            )
            voted = False
        else:
            conn.execute(
                "INSERT INTO dining_votes (user_id, court_abbr, date) VALUES (?, ?, ?)",
                (user_id, court_abbr, date),
            )
            voted = True
        count = conn.execute(
            "SELECT COUNT(*) FROM dining_votes WHERE court_abbr=? AND date=?",
            (court_abbr, date),
        ).fetchone()[0]
        conn.commit()
        return voted, count


def get_dining_rankings(courts: dict, date: str, user_id: Optional[str]) -> list[dict]:
    """Return one entry per court with vote count + per-user `voted` flag.

    `courts` is the {abbr: name} mapping (lives in api.DINING_COURTS) — passed in
    rather than imported to avoid a circular import.
    """
    with get_conn() as conn:
        counts = {row[0]: row[1] for row in conn.execute(
            "SELECT court_abbr, COUNT(*) FROM dining_votes "
            "WHERE date=? GROUP BY court_abbr",
            (date,),
        ).fetchall()}
        my_votes: set[str] = set()
        if user_id:
            my_votes = {row[0] for row in conn.execute(
                "SELECT court_abbr FROM dining_votes WHERE user_id=? AND date=?",
                (user_id, date),
            ).fetchall()}

    rows = [
        {
            "abbr": abbr,
            "name": name,
            "votes": int(counts.get(abbr, 0)),
            "voted": abbr in my_votes,
        }
        for abbr, name in courts.items()
    ]
    rows.sort(key=lambda r: (-r["votes"], r["name"]))
    for i, r in enumerate(rows):
        r["rank"] = i + 1
    return rows
