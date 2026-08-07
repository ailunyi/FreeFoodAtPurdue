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


def update_event(event_id: int, **fields) -> None:
    """Merge non-None fields into an existing event row."""
    allowed = {'building', 'building_abbr', 'room', 'food_type', 'expires_at',
               'starts_at', 'confidence', 'lat', 'lng', 'is_free', 'name', 'description',
               'name_confidence', 'dietary_info', 'rsvp_required', 'rsvp_link'}
    updates = {k: v for k, v in fields.items() if k in allowed and v is not None}
    if not updates:
        return
    set_clause = ", ".join(f"{k} = ?" for k in updates)
    with get_conn() as conn:
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
                conn.execute("UPDATE events SET going_count = MAX(going_count - 1, 0) WHERE id = ?", (event_id,))
                row = conn.execute("SELECT going_count FROM events WHERE id = ?", (event_id,)).fetchone()
                return (row["going_count"] if row else 0, False)
            conn.execute(
                "INSERT INTO event_votes (event_id, user_id, vote_type) VALUES (?, ?, 'going')",
                (event_id, user_id),
            )
        conn.execute("UPDATE events SET going_count = going_count + 1 WHERE id = ?", (event_id,))
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
                conn.execute("UPDATE events SET gone_count = MAX(gone_count - 1, 0) WHERE id = ?", (event_id,))
                row = conn.execute("SELECT gone_count FROM events WHERE id = ?", (event_id,)).fetchone()
                return (row["gone_count"] if row else 0, False)
            conn.execute(
                "INSERT INTO event_votes (event_id, user_id, vote_type) VALUES (?, ?, 'gone')",
                (event_id, user_id),
            )
        conn.execute("UPDATE events SET gone_count = gone_count + 1 WHERE id = ?", (event_id,))
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
            _pick(row['name'], name),
            _pick_longer(row['description'], description),
            _pick(row['food_type'], food_type),
            _pick(row['starts_at'], starts_at),
            _pick(row['expires_at'], expires_at),
            _pick(row['building'], building),
            _pick(row['building_abbr'], building_abbr),
            _pick(row['lat'], lat),
            _pick(row['lng'], lng),
            existing_id,
        ))
