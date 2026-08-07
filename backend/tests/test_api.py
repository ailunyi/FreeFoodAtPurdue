"""Tests for api.py: endpoints, rate limiting, input caps, auth, and caches."""

import pytest
from fastapi import HTTPException


def test_read_endpoints_respond(client):
    assert client.get("/food_events").status_code == 200
    assert client.get("/buildings").status_code == 200
    assert client.get("/buildings/with_events").status_code == 200


def test_buildings_query_filter(client):
    names = [b["full_name"] for b in client.get("/buildings", params={"q": "wilmeth"}).json()]
    assert names == ["Wilmeth Active Learning Center"]


def test_at_point_clamps_max_distance(client):
    r = client.get("/buildings/at_point", params={"lat": 40.4275, "lng": -86.9132, "max_distance": 99999})
    assert r.status_code == 422

    r = client.get("/buildings/at_point", params={"lat": 40.4275, "lng": -86.9132})
    assert r.status_code == 200
    assert r.json()["abbr"] == "WALC"


def test_gemini_endpoints_503_without_model(client):
    assert client.post("/events/submit", json={"text": "free pizza"}).status_code == 503
    assert client.post("/events/validate", json={"text": "free pizza"}).status_code == 503


def test_gemini_rate_limit(client, api_module):
    codes = [
        client.post("/events/validate", json={"text": "pizza"}).status_code
        for _ in range(api_module.GEMINI_RATE_LIMIT + 2)
    ]
    assert codes.count(429) >= 2
    # Everything before the limit was let through to the (unconfigured) model check.
    assert codes[0] == 503


def test_vote_rate_limit(client, api_module, fresh_events_db):
    event_id = fresh_events_db.insert_event(
        message_id="rate-vote", building=None, building_abbr=None, room=None,
        food_type=None, expires_at=None, confidence=0.9, lat=None, lng=None,
    )
    codes = [
        client.post(f"/events/{event_id}/gone", json={}).status_code
        for _ in range(api_module.VOTE_RATE_LIMIT + 2)
    ]
    assert codes[0] == 200
    assert 429 in codes


def test_submission_size_caps(api_module):
    with pytest.raises(HTTPException) as e:
        api_module._check_submission_limits("x" * (api_module.MAX_TEXT_CHARS + 1), None, None)
    assert e.value.status_code == 413

    with pytest.raises(HTTPException) as e:
        api_module._check_submission_limits(None, "A" * (api_module.MAX_IMAGE_B64_CHARS + 1), "image/jpeg")
    assert e.value.status_code == 413

    with pytest.raises(HTTPException) as e:
        api_module._check_submission_limits(None, "AAAA", "application/pdf")
    assert e.value.status_code == 422

    # Within limits passes silently.
    api_module._check_submission_limits("short", "AAAA", "image/png")


def test_ingest_requires_valid_key(client):
    r = client.post(
        "/events/ingest_instagram",
        json={"posts": []},
        headers={"Authorization": "Bearer wrong-key"},
    )
    assert r.status_code == 401


def test_ingest_batch_cap(client, api_module):
    posts = [{"shortcode": f"s{i}", "account": "acct"} for i in range(api_module.MAX_INGEST_POSTS + 1)]
    r = client.post(
        "/events/ingest_instagram",
        json={"posts": posts},
        headers={"Authorization": "Bearer test-ingest-key"},
    )
    assert r.status_code == 422


def test_extraction_cache_roundtrip_and_expiry(api_module, monkeypatch):
    key = api_module._extraction_cache_key("some text", None)
    api_module._extraction_cache_put(key, "raw-response")
    assert api_module._extraction_cache_get(key) == "raw-response"

    # Different content yields a different key.
    assert api_module._extraction_cache_key("other text", None) != key

    # Entries expire after the TTL.
    import time as time_module
    real_monotonic = time_module.monotonic
    monkeypatch.setattr(
        api_module.time, "monotonic",
        lambda: real_monotonic() + api_module._EXTRACTION_TTL_SECONDS + 1,
    )
    assert api_module._extraction_cache_get(key) is None


def test_dining_cache_evicts_previous_days(api_module):
    api_module._dining_cache.clear()
    api_module._dining_cache["Earhart:2026-01-01"] = {"stale": True}
    api_module._dining_cache_put("Earhart:2026-01-02", {"fresh": True}, "2026-01-02")
    assert list(api_module._dining_cache) == ["Earhart:2026-01-02"]


def test_dining_unknown_abbr_404(client):
    assert client.get("/dining/NOPE").status_code == 404
    assert client.get("/otg/NOPE").status_code == 404
