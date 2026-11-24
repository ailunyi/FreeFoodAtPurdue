"""Tests for database.py: inserts, votes, dedup, updates, and geo lookup."""


def _insert(db, message_id, **overrides):
    kwargs = dict(
        building="Wilmeth Active Learning Center", building_abbr="WALC",
        room=None, food_type="pizza", expires_at=None, confidence=0.9,
        lat=40.4275, lng=-86.9132,
    )
    kwargs.update(overrides)
    return db.insert_event(message_id=message_id, **kwargs)


def test_insert_event_returns_existing_id_on_duplicate(fresh_events_db):
    db = fresh_events_db
    first = _insert(db, "msg-1")
    second = _insert(db, "msg-1")
    assert first == second

    third = _insert(db, "msg-2")
    assert third != first


def test_vote_toggle_add_and_remove(fresh_events_db):
    db = fresh_events_db
    event_id = _insert(db, "msg-vote")

    count, active = db.increment_going(event_id, user_id="user-a")
    assert (count, active) == (1, True)

    # Same user voting again removes their vote.
    count, active = db.increment_going(event_id, user_id="user-a")
    assert (count, active) == (0, False)

    # Anonymous votes still increment.
    count, active = db.increment_going(event_id)
    assert (count, active) == (1, True)


def test_gone_votes_are_independent_of_going(fresh_events_db):
    db = fresh_events_db
    event_id = _insert(db, "msg-gone")
    db.increment_going(event_id, user_id="user-a")
    count, active = db.increment_gone(event_id, user_id="user-a")
    assert (count, active) == (1, True)


def test_is_duplicate_event_matches_same_building_and_name(fresh_events_db):
    db = fresh_events_db
    _insert(db, "msg-dup", name="Free Pizza at IEEE", starts_at=None)

    dup_id = db.is_duplicate_event(
        building_abbr="WALC", food_type="pizza",
        name="IEEE Free Pizza Night", starts_at=None,
    )
    assert dup_id is not None

    # Different building is not a duplicate.
    assert db.is_duplicate_event(
        building_abbr="LWSN", food_type="pizza",
        name="IEEE Free Pizza Night", starts_at=None,
    ) is None

    # Unrelated name is not a duplicate.
    assert db.is_duplicate_event(
        building_abbr="WALC", food_type="donuts",
        name="Completely Different Gathering", starts_at=None,
    ) is None


def test_update_event_ignores_unknown_fields(fresh_events_db):
    db = fresh_events_db
    event_id = _insert(db, "msg-upd")
    db.update_event(event_id, room="1087", message_id="hacked", nonsense="x")
    with db.get_conn() as conn:
        row = conn.execute("SELECT room, message_id FROM events WHERE id = ?", (event_id,)).fetchone()
    assert row["room"] == "1087"
    assert row["message_id"] == "msg-upd"


def test_building_at_point_inside_near_and_far(scratch_dbs):
    db = scratch_dbs
    inside = db.building_at_point(40.4275, -86.9132)
    assert inside and inside["abbr"] == "WALC" and inside["inside"] is True

    # Just north of the polygon's northwest corner (distance is measured to
    # polygon vertices, so the probe point sits near one).
    near = db.building_at_point(40.42815, -86.9140, max_distance_m=50)
    assert near and near["abbr"] == "WALC" and near["inside"] is False

    far = db.building_at_point(40.5, -86.8, max_distance_m=50)
    assert far is None


def test_update_event_logs_changed_fields_only(fresh_events_db):
    db = fresh_events_db
    event_id = _insert(db, "msg-act", room="100")
    db.update_event(event_id, source="groupme", room="200", food_type="pizza", confidence=0.5)
    activity = db.get_event_activity(event_id)
    # food_type is unchanged and confidence is not tracked, so only room is logged.
    assert [(a["kind"], a["field"], a["old_value"], a["new_value"], a["source"]) for a in activity] == [
        ("updated", "room", "100", "200", "groupme"),
    ]


def test_vote_activity_is_removed_on_unvote(fresh_events_db):
    db = fresh_events_db
    event_id = _insert(db, "msg-act-vote")
    db.increment_going(event_id, user_id="user-a")
    assert [a["kind"] for a in db.get_event_activity(event_id)] == ["going"]
    db.increment_going(event_id, user_id="user-a")
    assert db.get_event_activity(event_id) == []


def test_dining_vote_toggle_and_rankings(fresh_events_db):
    db = fresh_events_db
    courts = {"ERHT": "Earhart", "FORD": "Ford"}
    assert db.toggle_dining_vote("user-a", "FORD", "2026-01-01") == (True, 1)
    assert db.toggle_dining_vote("user-b", "FORD", "2026-01-01") == (True, 2)
    assert db.toggle_dining_vote("user-a", "FORD", "2026-01-01") == (False, 1)

    rankings = db.get_dining_rankings(courts, "2026-01-01", "user-b")
    assert [(r["abbr"], r["votes"], r["voted"], r["rank"]) for r in rankings] == [
        ("FORD", 1, True, 1),
        ("ERHT", 0, False, 2),
    ]
    # A new day starts with an empty leaderboard.
    assert all(r["votes"] == 0 for r in db.get_dining_rankings(courts, "2026-01-02", None))
