import datetime
import hashlib
import json
import logging
import os
import secrets
import time
import uuid
from collections import defaultdict, deque
from typing import Optional

log = logging.getLogger(__name__)

import requests as http_requests
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

INGEST_API_KEY = os.getenv("INGEST_API_KEY", "")


def _require_ingest_key(authorization: str = Header(...)):
    """Validate Bearer token for ingest endpoints."""
    if not INGEST_API_KEY:
        raise HTTPException(status_code=503, detail="INGEST_API_KEY not configured")
    if not secrets.compare_digest(authorization, f"Bearer {INGEST_API_KEY}"):
        raise HTTPException(status_code=401, detail="Invalid API key")


# ── Per-IP rate limiting (in-process; this API runs as a single instance) ──

_RATE_BUCKETS: dict[str, deque] = defaultdict(deque)
_RATE_WINDOW_SECONDS = 60.0
GEMINI_RATE_LIMIT = int(os.getenv("GEMINI_RATE_LIMIT_PER_MIN", "5"))
VOTE_RATE_LIMIT = int(os.getenv("VOTE_RATE_LIMIT_PER_MIN", "30"))


def _client_ip(request: Request) -> str:
    fwd = request.headers.get("x-forwarded-for")
    if fwd:
        return fwd.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def _rate_limit(request: Request, limit: int, scope: str) -> None:
    now = time.monotonic()
    key = f"{scope}:{_client_ip(request)}"
    bucket = _RATE_BUCKETS[key]
    while bucket and now - bucket[0] > _RATE_WINDOW_SECONDS:
        bucket.popleft()
    if len(bucket) >= limit:
        raise HTTPException(status_code=429, detail="Too many requests — please slow down")
    bucket.append(now)
    if len(_RATE_BUCKETS) > 10_000:
        for k in [k for k, b in _RATE_BUCKETS.items() if not b]:
            del _RATE_BUCKETS[k]


def gemini_rate_limit(request: Request) -> None:
    _rate_limit(request, GEMINI_RATE_LIMIT, "gemini")


def vote_rate_limit(request: Request) -> None:
    _rate_limit(request, VOTE_RATE_LIMIT, "vote")


# ── Input size caps, enforced before any Gemini call ──

MAX_TEXT_CHARS = 4_000
MAX_IMAGE_B64_CHARS = 8_000_000  # ~6 MB decoded
ALLOWED_IMAGE_MIMES = {"image/jpeg", "image/png", "image/webp", "image/heic", "image/heif"}


def _check_submission_limits(text: Optional[str], image_base64: Optional[str], image_mime: Optional[str]) -> None:
    if text and len(text) > MAX_TEXT_CHARS:
        raise HTTPException(status_code=413, detail=f"Text too long (max {MAX_TEXT_CHARS} characters)")
    if image_base64 and len(image_base64) > MAX_IMAGE_B64_CHARS:
        raise HTTPException(status_code=413, detail="Image too large")
    if image_base64 and image_mime and image_mime not in ALLOWED_IMAGE_MIMES:
        raise HTTPException(status_code=422, detail=f"Unsupported image type: {image_mime}")


# ── Short-TTL extraction cache so an ambiguity confirm-resubmit doesn't
#    re-run the same Gemini extraction on identical text/image ──

_EXTRACTION_CACHE: dict[str, tuple[float, str]] = {}  # key -> (monotonic ts, raw response)
_EXTRACTION_TTL_SECONDS = 600.0
_EXTRACTION_CACHE_MAX = 200


def _extraction_cache_key(text: Optional[str], image_base64: Optional[str]) -> str:
    h = hashlib.sha256()
    h.update((text or "").encode())
    h.update(b"\x00")
    h.update((image_base64 or "").encode())
    return h.hexdigest()


def _extraction_cache_get(key: str) -> Optional[str]:
    entry = _EXTRACTION_CACHE.get(key)
    if entry and time.monotonic() - entry[0] < _EXTRACTION_TTL_SECONDS:
        return entry[1]
    _EXTRACTION_CACHE.pop(key, None)
    return None


def _extraction_cache_put(key: str, raw: str) -> None:
    now = time.monotonic()
    if len(_EXTRACTION_CACHE) >= _EXTRACTION_CACHE_MAX:
        for k in [k for k, (ts, _) in _EXTRACTION_CACHE.items() if now - ts >= _EXTRACTION_TTL_SECONDS]:
            del _EXTRACTION_CACHE[k]
        while len(_EXTRACTION_CACHE) >= _EXTRACTION_CACHE_MAX:
            _EXTRACTION_CACHE.pop(next(iter(_EXTRACTION_CACHE)))
    _EXTRACTION_CACHE[key] = (now, raw)

from database import init_db, get_active_events, get_campus_buildings, get_buildings_for_events, increment_going, increment_gone, insert_event, insert_message, building_at_point
from boilerlink_poller import fetch_boilerlink_events
from backend import _init_shared_resources, EXTRACTION_PROMPT, _parse_gemini_response, send_groupme_message, APP_MESSAGE_MARKER

app = FastAPI(title="Food at Purdue API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["*"],
    allow_credentials=False,
)
init_db()
_init_shared_resources()

# Map building abbreviation → HFS dining location name
DINING_COURTS = {
    "ERHT": "Earhart",
    "FORD": "Ford",
    "HILL": "Hillenbrand",
    "WDCT": "Wiley",
    "WDC":  "Windsor",
}

ON_THE_GO = {
    "EOTG": "Earhart On-the-GO!",
    "FOTG": "Ford On-the-GO!",
    "LWSN": "Lawson On-the-GO!",
    "WOTG": "Windsor On-the-GO!",
}

# Map OTG abbreviation to HFS API location name
OTG_HFS_NAMES = {
    "EOTG": "Earhart%20On-the-GO!",
    "FOTG": "Ford%20On-the-GO!",
    "LWSN": "Lawson%20On-the-GO!",
    "WOTG": "Windsor%20On-the-GO!",
}

# Simple in-memory cache keyed by "location:date"
_dining_cache: dict = {}


def _dining_cache_put(cache_key: str, result: dict, today: str) -> None:
    """Cache today's menu, evicting entries from previous days so the cache stays bounded."""
    for k in [k for k in _dining_cache if not k.endswith(f":{today}")]:
        del _dining_cache[k]
    _dining_cache[cache_key] = result


@app.get("/food_events")
def food_events(include_expired: bool = Query(default=False), include_testing: bool = Query(default=False)):
    all_events = get_active_events()
    # Parse JSON string columns into objects
    for e in all_events:
        for col in ("dietary_info", "event_categories"):
            raw = e.get(col)
            if isinstance(raw, str):
                try:
                    e[col] = json.loads(raw)
                except (json.JSONDecodeError, TypeError):
                    pass
    if not include_testing:
        all_events = [e for e in all_events if not e.get("is_testing")]
    if include_expired:
        return all_events
    return [e for e in all_events if e["is_active"]]


@app.get("/buildings")
def buildings(
    key_only: bool = Query(default=False),
    map_only: bool = Query(default=False, description="Only return buildings with show_on_map=1 (ArcGIS campus footprints; excludes Google Places)"),
    q: Optional[str] = Query(default=None, description="Filter by abbreviation, name, or any alias (case-insensitive)"),
):
    return get_campus_buildings(key_only=key_only, map_only=map_only, q=q)


@app.get("/buildings/with_events")
def buildings_with_events():
    return get_buildings_for_events()


@app.get("/buildings/at_point")
def buildings_at_point(
    lat: float = Query(...),
    lng: float = Query(...),
    max_distance: float = Query(default=50.0, ge=0, le=500, description="Max distance in metres for 'outside' detection"),
):
    """Return the building at the given lat/lng, or the nearest one within max_distance."""
    result = building_at_point(lat, lng, max_distance_m=max_distance)
    if not result:
        return {"building": None}
    return {
        "building": result["full_name"],
        "abbr": result["abbr"],
        "lat": result["lat"],
        "lng": result["lng"],
        "inside": result["inside"],
    }


class SpotSubmission(BaseModel):
    text:                Optional[str]   = None
    image_base64:        Optional[str]   = None
    image_mime:          Optional[str]   = None
    lat:                 Optional[float] = None
    lng:                 Optional[float] = None
    building_abbr:       Optional[str]   = None
    outside_building:    bool            = False
    force_building_abbr: Optional[str]   = None  # user-confirmed building after ambiguity prompt
    is_testing:          bool            = False  # true when submitted from frontend dev mode


@app.post("/events/submit")
def submit_event(body: SpotSubmission, _rl: None = Depends(gemini_rate_limit)):
    import backend as _backend_module
    model = _backend_module._gemini_model
    matcher = _backend_module._matcher

    if not model:
        raise HTTPException(status_code=503, detail="Gemini model not configured")
    if not matcher:
        raise HTTPException(status_code=503, detail="Building matcher not initialized")
    if not body.text and not body.image_base64:
        raise HTTPException(status_code=400, detail="Provide text or image_base64")
    _check_submission_limits(body.text, body.image_base64, body.image_mime)

    # Reuse a recent extraction of the exact same text/image (e.g. the
    # confirm-resubmit after an ambiguous building prompt) instead of paying
    # for a second Gemini call.
    cache_key = _extraction_cache_key(body.text, body.image_base64)
    raw_response = _extraction_cache_get(cache_key)
    if raw_response is None:
        try:
            if body.image_base64:
                mime = body.image_mime or "image/jpeg"
                prompt = f"{EXTRACTION_PROMPT}\n\n{body.text}" if body.text else EXTRACTION_PROMPT
                contents = [prompt, {"mime_type": mime, "data": body.image_base64}]
                raw_response = model.generate_content(contents).text.strip()
            else:
                raw_response = model.generate_content(
                    f"{EXTRACTION_PROMPT}\n\n{body.text}"
                ).text.strip()
        except Exception as e:
            raise HTTPException(status_code=502, detail=f"Gemini error: {e}")
        _extraction_cache_put(cache_key, raw_response)

    if not raw_response or raw_response == "null":
        raise HTTPException(status_code=422, detail="Could not detect a food event in the submission")

    event = _parse_gemini_response(raw_response)
    if not event:
        raise HTTPException(status_code=422, detail="Could not detect a food event in the submission")

    # Priority: 1) force_building_abbr (user confirmed after ambiguity), 2) Gemini extraction,
    #           3) pin-detected building, 4) geo-lookup from coords
    if body.force_building_abbr:
        from database import load_buildings_from_db
        all_bldgs = load_buildings_from_db()
        bldg = all_bldgs.get(body.force_building_abbr.upper())
        if bldg:
            full_name = bldg["full_name"]
            abbr = body.force_building_abbr.upper()
            blat, blng = bldg["lat"], bldg["lng"]
            name_conf = 1.0
        else:
            raise HTTPException(status_code=422, detail=f"Unknown building abbreviation: {body.force_building_abbr}")
    else:
        best_result, candidates, is_ambiguous = matcher.match_candidates(event.get("building"))
        full_name, abbr, blat, blng, name_conf = best_result

        # If ambiguous, return candidates for the user to pick — do not insert yet
        if is_ambiguous:
            return {
                "status": "ambiguous",
                "candidates": candidates,
            }

    if not abbr and body.building_abbr:
        # Text didn't mention a building — fall back to the pin-detected one
        from database import load_buildings_from_db
        all_bldgs = load_buildings_from_db()
        bldg = all_bldgs.get(body.building_abbr)
        if bldg:
            full_name = bldg["full_name"]
            if body.outside_building:
                full_name = f"Outside {full_name}"
                # Use the actual drop point, not the building centroid
                blat, blng = body.lat, body.lng
            else:
                blat, blng = bldg["lat"], bldg["lng"]
            abbr = body.building_abbr
            name_conf = 1.0

    if not abbr and body.lat is not None and body.lng is not None:
        geo_result = building_at_point(body.lat, body.lng)
        if geo_result:
            full_name = geo_result["full_name"]
            if not geo_result["inside"]:
                full_name = f"Outside {full_name}"
                # Use the actual drop point, not the building centroid
                blat, blng = body.lat, body.lng
            else:
                blat, blng = geo_result["lat"], geo_result["lng"]
            abbr = geo_result["abbr"]
            name_conf = 0.9

    final_lat = blat if blat is not None else body.lat
    final_lng = blng if blng is not None else body.lng

    message_id = f"user_{uuid.uuid4().hex}"
    insert_event(
        message_id       = message_id,
        building         = full_name,
        building_abbr    = abbr,
        room             = event.get("room"),
        food_type        = event.get("foodType"),
        name             = event.get("name"),
        description      = event.get("description"),
        starts_at        = event.get("startsAt"),
        expires_at       = event.get("expiresAt"),
        confidence       = event.get("confidence", 0),
        lat              = final_lat,
        lng              = final_lng,
        is_free          = bool(event.get("isFree", True)),
        is_testing       = body.is_testing,
        source           = "user",
        name_confidence  = name_conf,
        dietary_info     = event.get("dietary"),
    )

    # Notify the test GroupMe group
    test_group_id = os.getenv("TEST_GROUP_ID", "").strip()
    groupme_token = os.getenv("GROUPME_TOKEN", "").strip()
    if test_group_id and groupme_token:
        lines = [APP_MESSAGE_MARKER]
        if event.get("name"):
            lines.append(f"📌 {event['name']}")
        if full_name:
            loc = full_name
            if event.get("room"):
                loc += f", Room {event['room']}"
            lines.append(f"🏛 {loc}")
        if event.get("foodType"):
            lines.append(f"🍽 {event['foodType']}")
        if event.get("description"):
            lines.append(f"📝 {event['description']}")
        if event.get("startsAt"):
            lines.append(f"🕐 Starts: {event['startsAt']}")
        if event.get("expiresAt"):
            lines.append(f"⏰ Until: {event['expiresAt']}")
        lines.append("🆓 Free" if event.get("isFree") else "💰 Paid")
        try:
            msg_text = "\n".join(lines)
            send_groupme_message(groupme_token, test_group_id, msg_text)
            insert_message(
                message_id=f"app_{message_id}",
                group_id=test_group_id,
                sender_id="app",
                sender_name="Food at Purdue App",
                text=msg_text,
                image_url=None,
                sent_at=datetime.datetime.utcnow().isoformat(),
            )
        except Exception as e:
            log.warning("Failed to send GroupMe notification: %s", e)

    return {
        "status":          "ok",
        "building":        full_name,
        "abbr":            abbr,
        "lat":             final_lat,
        "lng":             final_lng,
        "name":            event.get("name"),
        "description":     event.get("description"),
        "foodType":        event.get("foodType"),
        "startsAt":        event.get("startsAt"),
        "isFree":          event.get("isFree"),
        "expiresAt":       event.get("expiresAt"),
        "confidence":      event.get("confidence"),
        "name_confidence": name_conf,
    }


class VoteBody(BaseModel):
    user_id: Optional[str] = None


@app.post("/events/{event_id}/going")
def event_going(event_id: int, body: VoteBody = VoteBody(), _rl: None = Depends(vote_rate_limit)):
    new_count, is_active = increment_going(event_id, body.user_id)
    return {"going_count": new_count, "active": is_active}


@app.post("/events/{event_id}/gone")
def event_gone(event_id: int, body: VoteBody = VoteBody(), _rl: None = Depends(vote_rate_limit)):
    new_count, is_active = increment_gone(event_id, body.user_id)
    return {"gone_count": new_count, "active": is_active}


VALIDATION_PROMPT = """
You are a food event validator for Purdue University campus.
Analyze this event description and determine which required fields are present or missing.

Required fields:
- name: An event name or title (e.g. "Free Pizza at IEEE Meeting")
- location: A building, room, or place on campus (e.g. "WALC 1087", "Lawson lobby")
- foodType: What food is available (e.g. "pizza", "donuts and coffee")
- time: When it's happening - start time, end time, or duration (e.g. "until 4pm", "from 5-7pm")

Respond with ONLY a JSON object (no markdown):
{
  "fields": {
    "name": {"found": true, "value": "Free Pizza at IEEE", "span": "Free Pizza at IEEE"},
    "location": {"found": true, "value": "WALC 1087", "span": "WALC 1087"},
    "foodType": {"found": true, "value": "pizza", "span": "pizza"},
    "time": {"found": false, "value": null, "span": null}
  },
  "isFree": true,
  "confidence": 0.85,
  "suggestion": "Add when the food will be available or when the event ends."
}

"span" should be the exact substring from the original text that corresponds to each field.
"suggestion" should be a brief tip about what's missing, or null if everything is present.

Event description:
""".strip()


@app.post("/events/validate")
def validate_event(body: SpotSubmission, _rl: None = Depends(gemini_rate_limit)):
    import backend as _backend_module
    model = _backend_module._gemini_model
    if not model:
        raise HTTPException(status_code=503, detail="Gemini model not configured")
    if not body.text:
        raise HTTPException(status_code=400, detail="Provide text to validate")
    _check_submission_limits(body.text, None, None)

    try:
        raw = model.generate_content(f"{VALIDATION_PROMPT}\n\n{body.text}").text.strip()
        cleaned = raw
        if cleaned.startswith("```"):
            cleaned = cleaned.split("```")[1]
            if cleaned.startswith("json"):
                cleaned = cleaned[4:]
            cleaned = cleaned.strip()
        result = json.loads(cleaned)
        return result
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Validation error: {e}")


@app.get("/boilerlink/events")
def boilerlink_events(food_only: bool = Query(default=False)):
    """Return Boilerlink-sourced events from the database."""
    all_events = get_active_events()
    bl_events = [e for e in all_events if e.get("source") == "boilerlink"]
    if food_only:
        bl_events = [
            e for e in bl_events
            if e.get("event_categories") and "food" in (e["event_categories"] if isinstance(e["event_categories"], list) else json.loads(e.get("event_categories") or "[]"))
        ]
    return bl_events


class InstagramPost(BaseModel):
    shortcode:   str
    caption:     Optional[str] = None
    image_base64: Optional[str] = None
    image_mime:  Optional[str] = None
    account:     str
    posted_at:   Optional[str] = None


class InstagramIngest(BaseModel):
    posts: list[InstagramPost]


MAX_INGEST_POSTS = 25


@app.post("/events/ingest_instagram")
def ingest_instagram(body: InstagramIngest, authorization: str = Header(...)):
    _require_ingest_key(authorization)

    if len(body.posts) > MAX_INGEST_POSTS:
        raise HTTPException(status_code=422, detail=f"Too many posts (max {MAX_INGEST_POSTS} per request)")
    for post in body.posts:
        _check_submission_limits(post.caption, post.image_base64, post.image_mime)

    import backend as _backend_module
    model = _backend_module._gemini_model
    matcher = _backend_module._matcher
    if not model or not matcher:
        raise HTTPException(status_code=503, detail="Gemini/matcher not ready")

    from database import get_conn

    # Get already-seen post IDs
    with get_conn() as conn:
        seen = {r[0] for r in conn.execute(
            "SELECT message_id FROM events WHERE source = 'instagram'"
        ).fetchall()}

    results = []
    for post in body.posts:
        post_id = f"instagram_{post.shortcode}"
        if post_id in seen:
            results.append({"shortcode": post.shortcode, "status": "skipped", "reason": "already exists"})
            continue

        # Build Gemini prompt
        prompt = (
            f"{EXTRACTION_PROMPT}\n\n"
            f"[Instagram post from @{post.account}]\n"
            f"{post.caption or '(no caption)'}"
        )
        try:
            if post.image_base64:
                mime = post.image_mime or "image/jpeg"
                contents = [prompt, {"mime_type": mime, "data": post.image_base64}]
                raw = model.generate_content(contents).text.strip()
            else:
                raw = model.generate_content(prompt).text.strip()
        except Exception as e:
            results.append({"shortcode": post.shortcode, "status": "error", "reason": str(e)})
            continue

        if not raw or raw == "null":
            results.append({"shortcode": post.shortcode, "status": "skipped", "reason": "not a food event"})
            continue

        event = _parse_gemini_response(raw)
        if not event:
            results.append({"shortcode": post.shortcode, "status": "skipped", "reason": "low confidence"})
            continue

        full_name, abbr, lat, lng, name_conf = matcher.match(event.get("building"))

        insert_event(
            message_id=post_id,
            building=full_name,
            building_abbr=abbr,
            room=event.get("room"),
            food_type=event.get("foodType"),
            name=event.get("name"),
            description=event.get("description"),
            starts_at=event.get("startsAt"),
            expires_at=event.get("expiresAt"),
            confidence=event.get("confidence", 0),
            lat=lat,
            lng=lng,
            is_free=bool(event.get("isFree", False)),
            is_testing=False,
            source="instagram",
            name_confidence=name_conf,
            dietary_info=event.get("dietary"),
        )

        results.append({"shortcode": post.shortcode, "status": "created", "name": event.get("name")})
        seen.add(post_id)

    return {"processed": len(body.posts), "results": results}


@app.get("/dining/{abbr}")
def dining_menu(abbr: str):
    location = DINING_COURTS.get(abbr.upper())
    if not location:
        raise HTTPException(status_code=404, detail="Not a dining court")

    today = datetime.date.today().isoformat()
    cache_key = f"{location}:{today}"
    if cache_key in _dining_cache:
        return _dining_cache[cache_key]

    url = f"https://api.hfs.purdue.edu/menus/v2/locations/{location}/{today}"
    try:
        resp = http_requests.get(url, headers={"Accept": "application/json"}, timeout=10)
        resp.raise_for_status()
        data = resp.json()
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Dining API unavailable: {e}")

    result = {
        "location": location,
        "date": data.get("Date"),
        "meals": [],
    }
    for meal in (data.get("Meals") or []):
        hours = meal.get("Hours") or {}
        meal_data = {
            "name": meal.get("Name"),
            "start": hours.get("StartTime"),
            "end": hours.get("EndTime"),
            "stations": [],
        }
        for station in (meal.get("Stations") or []):
            meal_data["stations"].append({
                "name": station.get("Name"),
                "items": [
                    {
                        "name": item.get("Name"),
                        "is_vegetarian": item.get("IsVegetarian", False),
                        "allergens": [
                            a["Name"] for a in (item.get("Allergens") or []) if a.get("Value")
                        ],
                    }
                    for item in (station.get("Items") or [])
                ],
            })
        result["meals"].append(meal_data)

    _dining_cache_put(cache_key, result, today)
    return result


@app.get("/otg/{abbr}")
def otg_menu(abbr: str):
    """Fetch On-the-GO! menu for a given location abbreviation."""
    hfs_name = OTG_HFS_NAMES.get(abbr.upper())
    if not hfs_name:
        raise HTTPException(status_code=404, detail="Not an On-the-GO! location")

    today = datetime.date.today().isoformat()
    cache_key = f"otg_{abbr}:{today}"
    if cache_key in _dining_cache:
        return _dining_cache[cache_key]

    url = f"https://api.hfs.purdue.edu/menus/v2/locations/{hfs_name}/{today}"
    try:
        resp = http_requests.get(url, headers={"Accept": "application/json"}, timeout=10)
        resp.raise_for_status()
        data = resp.json()
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Dining API unavailable: {e}")

    result = {
        "location": ON_THE_GO.get(abbr.upper(), abbr),
        "date": data.get("Date"),
        "meals": [],
    }
    for meal in (data.get("Meals") or []):
        hours = meal.get("Hours") or {}
        meal_data = {
            "name": meal.get("Name"),
            "start": hours.get("StartTime"),
            "end": hours.get("EndTime"),
            "stations": [],
        }
        for station in (meal.get("Stations") or []):
            meal_data["stations"].append({
                "name": station.get("Name"),
                "items": [
                    {
                        "name": item.get("Name"),
                        "is_vegetarian": item.get("IsVegetarian", False),
                        "allergens": [
                            a["Name"] for a in (item.get("Allergens") or []) if a.get("Value")
                        ],
                    }
                    for item in (station.get("Items") or [])
                ],
            })
        result["meals"].append(meal_data)

    _dining_cache_put(cache_key, result, today)
    return result
