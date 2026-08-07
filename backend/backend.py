#!/usr/bin/env python3
"""
GroupMe poller with Gemini parsing.

- Polls /groups/{group_id}/messages with after_id (no bot/admin needed).
- Sends each new message (text and/or image) to Gemini 2.5 Flash.
- Extracts structured free food events: building, room, foodType, expiresAt.
- Normalizes building names against buildings.db (same catalog as "building locations/import_buildings.py") and attaches coordinates.
- Writes events to SQLite and serves them via FastAPI on port 8000.

Usage:
  Copy .env.example to .env, fill in your values, then:
  python backend.py

Optional env vars:
  POLL_SECONDS=5
  STATE_FILE=.groupme_last_id.txt
  INCLUDE_SYSTEM=0   (set to 1 to include system messages)
  API_PORT=8000
"""

import base64
import json
import logging
import os
import threading
import time
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urlencode

import google.cloud.logging
import google.generativeai as genai
import requests
import uvicorn
from dotenv import load_dotenv

from building_matcher import BuildingMatcher
from boilerlink_poller import poll_boilerlink
from database import init_db, insert_event, update_event, insert_message, insert_gemini_response, is_duplicate_event, merge_duplicate_event, load_buildings_from_db
from gemini_utils import GeminiQuotaError, is_quota_error

load_dotenv()

log = logging.getLogger(__name__)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

API_BASE = "https://api.groupme.com/v3"

# Messages sent by the app start with this marker so the poller can skip them.
APP_MESSAGE_MARKER = "📍 Food spotted via app!"

# How long to pause Gemini calls after a quota / rate-limit error.
QUOTA_COOLDOWN_SECONDS = float(os.getenv("GEMINI_QUOTA_COOLDOWN_SECONDS", "600"))

EXTRACTION_PROMPT = """
You are a food event extractor for Purdue University campus.
Analyze this message and determine if someone is announcing food currently available for students on campus
(whether free or for purchase).

Rules:
- Only extract REAL, EDIBLE food or drinks (pizza, donuts, coffee, snacks, etc.)
- Ignore non-food items even if described as "free" (e.g., drugs, services, activities)
- Set "isFree" to true if the food costs nothing, false if it costs money or a price is mentioned
- For "building": return the building name, abbreviation, or location exactly as the user wrote it
  (e.g. "WALC", "Lawson", "Campus Edge", "the union"). Our system will resolve it to a known building.
  Only return null if no building or location is mentioned at all.
- "name": a short, catchy event title that a student would use (e.g. "Free Pizza – IEEE Meeting", "Leftover Catering in WALC", "Chick-fil-A at the Union!")
- "description": a 1-2 sentence description written in a fun, casual tone — like a student excitedly telling their friends about it. Keep it short and energetic (e.g. "Someone left a ton of pizza in the WALC lobby — get it before it's gone!" or "IEEE is hooking it up with free Chick-fil-A at their meeting tonight!"). Don't be robotic or formal.
- "startsAt": ISO 8601 datetime if a start time is mentioned, otherwise null
- "expiresAt": ISO 8601 datetime if an end time or expiry is mentioned, otherwise null
- "rsvpRequired": true if the event requires RSVP, registration, sign-up, or ticket purchase to attend. false otherwise.
- "rsvpLink": if an RSVP/registration URL or link is mentioned, include it. Otherwise null.
- "update_previous": set to true ONLY if this message is adding more detail to a food event you already
  extracted earlier in this conversation (e.g. a follow-up message from the same person with an image or
  more info). Set to false if this is a new event or you have no prior extraction in this conversation.

Also classify dietary compatibility. For each category below, return true if the food IS compatible,
false if it is definitely NOT compatible, or null if you cannot determine from the information given.
- "vegetarian": no meat, poultry, or fish
- "vegan": no animal products at all (no meat, dairy, eggs, honey)
- "glutenFree": no wheat, barley, rye, or gluten-containing ingredients
- "halal": prepared according to Islamic dietary laws (no pork, no alcohol)
- "kosher": prepared according to Jewish dietary laws
- "nutFree": no tree nuts or peanuts
- "dairyFree": no milk, cheese, butter, or dairy products
- "soyFree": no soy or soy-derived ingredients
- "eggFree": no eggs or egg-derived ingredients

If it IS about food on campus, respond with ONLY a JSON object (no markdown, no explanation):
{
  "name": "<short event title>",
  "description": "<1-2 sentence summary>",
  "building": "<building name/abbreviation as the user wrote it, or null if none mentioned>",
  "room": "<room number or null>",
  "foodType": "<description of food or null>",
  "startsAt": "<ISO 8601 datetime or null>",
  "expiresAt": "<ISO 8601 datetime or null>",
  "isFree": <true if free, false if costs money>,
  "rsvpRequired": <true or false>,
  "rsvpLink": "<URL or null>",
  "confidence": <0.0 to 1.0>,
  "update_previous": <true or false>,
  "dietary": {
    "vegetarian": <true/false/null>,
    "vegan": <true/false/null>,
    "glutenFree": <true/false/null>,
    "halal": <true/false/null>,
    "kosher": <true/false/null>,
    "nutFree": <true/false/null>,
    "dairyFree": <true/false/null>,
    "soyFree": <true/false/null>,
    "eggFree": <true/false/null>
  }
}

If it is NOT about food on campus, respond with ONLY: null

Message:
""".strip()

FOLLOWUP_PROMPT_TEMPLATE = """
You are a food event extractor for Purdue University campus.
The following food events were recently extracted (most recent first):

{events_summary}

This new message may be a correction or follow-up to one of these events
(e.g. "wait it's not free", "actually it's in WALC", "it runs until 5pm").

If this message updates any field of a previously extracted event, respond with ONLY a JSON object
containing ONLY the fields that changed, plus "target_event_id": <the id of the event being updated>,
"update_previous": true, and "confidence".
If it is unrelated to the previous events and describes a NEW food event, extract it fully with "update_previous": false.
If it has no food-related information at all, respond with ONLY: null

For the "building" field, return the building name or abbreviation exactly as the user wrote it.
Our system will resolve it to a known building.

Updatable fields (only include what changed):
  building, room, foodType, name, description, startsAt, expiresAt, isFree, rsvpRequired, rsvpLink, target_event_id, update_previous, confidence

Message:
""".strip()


def load_buildings() -> dict:
    """Load building catalog from ``buildings.db``."""
    data = load_buildings_from_db()
    if not data:
        raise RuntimeError(
            "buildings.db is empty or missing buildings; run: python 'building locations/import_buildings.py'"
        )
    return data


def env(name: str, default: Optional[str] = None) -> str:
    v = os.getenv(name, default)
    if v is None or v == "":
        raise SystemExit(f"Missing required environment variable: {name}")
    return v


def load_last_id(path: str) -> Optional[str]:
    try:
        s = open(path, "r", encoding="utf-8").read().strip()
        return s or None
    except FileNotFoundError:
        return None


def save_last_id(path: str, last_id: str) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(last_id)
    os.replace(tmp, path)


def groupme_get(token: str, path: str, params: dict) -> dict:
    params = dict(params)
    params["token"] = token
    url = f"{API_BASE}{path}?{urlencode(params)}"

    headers = {"Cache-Control": "no-cache", "Pragma": "no-cache"}
    r = requests.get(url, timeout=20, headers=headers)

    if r.status_code == 304:
        return {"meta": {"code": 304}, "response": {"count": 0, "messages": []}}

    ctype = (r.headers.get("content-type") or "").lower()
    if "application/json" not in ctype:
        log.error("[http] %s non-JSON content-type=%s", r.status_code, ctype)
        log.error("[http] body (first 300 chars): %r", r.text[:300])
        r.raise_for_status()
        raise RuntimeError("Non-JSON response from GroupMe.")

    data = r.json()
    meta_code = data.get("meta", {}).get("code")
    if r.status_code != 200 or (meta_code is not None and meta_code != 200):
        log.error("[http] http=%s meta=%s body=%s", r.status_code, meta_code, data)
        r.raise_for_status()

    return data


def send_groupme_message(token: str, group_id: str, text: str) -> None:
    url = f"{API_BASE}/groups/{group_id}/messages?token={token}"
    payload = {"message": {"source_guid": str(time.time()), "text": text}}
    r = requests.post(url, json=payload, timeout=20)
    r.raise_for_status()
    log.info("[groupme] sent message to group %s", group_id)


def is_system_message(m: Dict[str, Any]) -> bool:
    return bool(m.get("system")) or m.get("sender_type") == "system" or m.get("sender_id") == "system"


def extract_image_urls(attachments: List[Dict[str, Any]]) -> List[str]:
    return [
        str(a["url"])
        for a in (attachments or [])
        if a.get("type") == "image" and a.get("url")
    ]


def _format_events_summary(recent_events: Dict[int, Dict[str, Any]]) -> str:
    """Format recent events into a summary string for the follow-up prompt."""
    lines = []
    for eid, info in sorted(recent_events.items(), key=lambda x: x[1].get("time", 0), reverse=True):
        parts = [f"id={eid}"]
        if info.get("building"):
            parts.append(f"building={info['building']}")
        if info.get("food_type"):
            parts.append(f"food={info['food_type']}")
        if info.get("name"):
            parts.append(f"name={info['name']}")
        lines.append("- " + ", ".join(parts))
    return "\n".join(lines) if lines else "(none)"


def parse_message(
    gemini_model: Any,
    m: Dict[str, Any],
    history: List[Dict[str, Any]],
    force: bool = False,
    recent_events: Optional[Dict[int, Dict[str, Any]]] = None,
) -> tuple[Optional[str], Optional[Dict[str, Any]]]:
    text = m.get("text") or ""
    image_urls = extract_image_urls(m.get("attachments") or [])

    if not text and not image_urls:
        return None, None


    raw_response = None
    sender_name = m.get("name") or "Unknown"
    try:
        message_block = f"[From: {sender_name}]\n{text}" if text else f"[From: {sender_name}]"
        if force and recent_events:
            base_prompt = FOLLOWUP_PROMPT_TEMPLATE.format(
                events_summary=_format_events_summary(recent_events)
            )
        else:
            base_prompt = EXTRACTION_PROMPT
        prompt = f"{base_prompt}\n\n{message_block}"
        if image_urls:
            image_resp = requests.get(image_urls[0], timeout=20)
            image_resp.raise_for_status()
            mime = image_resp.headers.get("content-type", "image/jpeg").split(";")[0]
            image_data = base64.b64encode(image_resp.content).decode()
            user_parts = [prompt, {"mime_type": mime, "data": image_data}]
        else:
            user_parts = [prompt]

        contents = history + [{"role": "user", "parts": user_parts}]
        raw_response = gemini_model.generate_content(contents).text.strip()

        # Update rolling history (max 10 entries = 5 user/model pairs).
        # Store only the plain message text — never the extraction prompt or
        # image bytes, which would otherwise be re-sent on every future call.
        history_block = message_block + ("\n[image attached]" if image_urls else "")
        history.append({"role": "user",  "parts": [history_block]})
        history.append({"role": "model", "parts": [raw_response]})
        while len(history) > 10:
            history.pop(0)
            history.pop(0)

        if not raw_response or raw_response == "null":
            return raw_response, None

        return raw_response, _parse_gemini_response(raw_response)

    except Exception as e:
        if is_quota_error(e):
            raise GeminiQuotaError(str(e)) from e
        log.error("[gemini] error: %s", e)
        return raw_response, None


def _parse_gemini_response(raw: str) -> Optional[Dict[str, Any]]:
    """Strip markdown, parse JSON, check confidence. Returns dict or None."""
    cleaned = raw
    if cleaned.startswith("```"):
        cleaned = cleaned.split("```")[1]
        if cleaned.startswith("json"):
            cleaned = cleaned[4:]
        cleaned = cleaned.strip()
    try:
        parsed = json.loads(cleaned)
    except json.JSONDecodeError:
        return None
    if parsed.get("confidence", 0) < 0.5:
        return None
    return parsed


# ── Module-level shared resources (used by both poller and API) ──
_gemini_model: Any = None
_buildings: dict = {}
_matcher: Optional[BuildingMatcher] = None


def _init_shared_resources() -> None:
    """Initialize Gemini model, buildings, and embedding matcher."""
    global _gemini_model, _buildings, _matcher
    api_key = os.getenv("GEMINI_API_KEY", "")
    if api_key:
        genai.configure(api_key=api_key)
        _gemini_model = genai.GenerativeModel("gemini-2.5-flash")
    _buildings = load_buildings()
    _matcher = BuildingMatcher(_buildings)
    try:
        _matcher.load_index()
    except Exception as e:
        log.error("[init] Building matcher index failed: %s. "
                  "Vector-based matching disabled; exact match still works.", e)


def poll_group(
    token: str,
    group_id: str,
    is_testing: bool,
    gemini_model: Any,
    matcher: BuildingMatcher,
    poll_seconds: float,
    state_file: str,
    include_system: bool,
) -> None:
    """Poll a single GroupMe group indefinitely."""
    label = "[test]" if is_testing else "[prod]"
    gemini_history: List[Dict[str, Any]] = []  # rolling 10-entry conversation window
    recent_events: Dict[int, Dict[str, Any]] = {}  # event_id -> {building, food_type, name, time}
    EVENT_WINDOW = 600  # seconds to keep events in the buffer

    last_id = load_last_id(state_file)
    if last_id is None:
        resp = groupme_get(token, f"/groups/{group_id}/messages", {"limit": 1})
        msgs = resp.get("response", {}).get("messages", []) or []
        if msgs:
            last_id = str(msgs[0]["id"])
            save_last_id(state_file, last_id)
            log.info("%s starting at latest message id=%s", label, last_id)
        else:
            log.info("%s group has no messages; starting with last_id=None", label)

    log.info("%s watching group_id=%s poll=%ss", label, group_id, poll_seconds)
    backoff = poll_seconds

    while True:
        try:
            params: Dict[str, Any] = {"limit": 100}
            if last_id:
                params["after_id"] = last_id

            resp = groupme_get(token, f"/groups/{group_id}/messages", params)
            msgs = resp.get("response", {}).get("messages", []) or []
            quota_hit = False

            for m in msgs:
                mid = str(m.get("id", ""))
                if not mid:
                    continue

                if (not include_system) and is_system_message(m):
                    last_id = mid
                    save_last_id(state_file, last_id)
                    continue

                name = m.get("name") or "Unknown"
                text = m.get("text")

                if text and text.startswith(APP_MESSAGE_MARKER):
                    log.debug("%s [skip] app-sent message, ignoring", label)
                    last_id = mid
                    save_last_id(state_file, last_id)
                    continue

                if text:
                    log.info("%s [message][%s] %s", label, name, text)

                image_urls = extract_image_urls(m.get("attachments") or [])
                insert_message(
                    message_id=mid,
                    group_id=group_id,
                    sender_id=m.get("sender_id", ""),
                    sender_name=name,
                    text=m.get("text"),
                    image_url=image_urls[0] if image_urls else None,
                    sent_at=str(m.get("created_at", "")),
                )

                # Prune expired events from the buffer
                now = time.time()
                recent_events = {eid: info for eid, info in recent_events.items()
                                 if now - info["time"] < EVENT_WINDOW}

                in_followup = bool(recent_events)
                try:
                    raw_response, event = parse_message(gemini_model, m, gemini_history,
                                                        force=in_followup, recent_events=recent_events)
                except GeminiQuotaError as e:
                    # Don't advance last_id — retry this message after the cooldown.
                    log.error("%s [gemini] quota/rate limit hit, cooling down %ss: %s",
                              label, QUOTA_COOLDOWN_SECONDS, e)
                    quota_hit = True
                    break
                if raw_response is not None:
                    insert_gemini_response(mid, raw_response, event, event is not None)

                if event:
                    full_name, abbr, lat, lng, name_conf = matcher.match(event.get("building"))
                    is_free     = bool(event.get("isFree", True))
                    food_type   = event.get("foodType")
                    name        = event.get("name")
                    description = event.get("description")
                    starts_at   = event.get("startsAt")
                    expires_at  = event.get("expiresAt")
                    confidence  = event.get("confidence", 0)
                    dietary     = event.get("dietary")
                    rsvp_required = bool(event.get("rsvpRequired", False))
                    rsvp_link   = event.get("rsvpLink")

                    target_id = event.get("target_event_id")
                    if event.get("update_previous") and target_id is not None and target_id in recent_events:
                        dietary_json = json.dumps(dietary) if dietary else None
                        update_event(
                            target_id,
                            building=full_name, building_abbr=abbr,
                            room=event.get("room"), food_type=food_type,
                            name=name, description=description,
                            starts_at=starts_at, expires_at=expires_at,
                            confidence=confidence, lat=lat, lng=lng,
                            is_free=1 if is_free else 0,
                            name_confidence=name_conf,
                            dietary_info=dietary_json,
                            rsvp_required=1 if rsvp_required else 0,
                            rsvp_link=rsvp_link,
                        )
                        log.info("%s [updated] event id=%s | %s (name_conf=%.2f) | %s", label, target_id, full_name, name_conf, food_type)
                    elif (dup_id := is_duplicate_event(building_abbr=abbr, food_type=food_type, name=name, starts_at=starts_at)):
                        source = 'testing' if is_testing else 'groupme'
                        merge_duplicate_event(
                            dup_id, new_source=source,
                            name=name, description=description, food_type=food_type,
                            starts_at=starts_at, expires_at=expires_at,
                            building=full_name, building_abbr=abbr, lat=lat, lng=lng,
                        )
                        log.info("%s [duplicate] merged into id=%s | %s (%s) | %s", label, dup_id, full_name, abbr, food_type)
                    else:
                        new_id = insert_event(
                            message_id=mid,
                            building=full_name, building_abbr=abbr,
                            room=event.get("room"), food_type=food_type,
                            name=name, description=description,
                            starts_at=starts_at, expires_at=expires_at,
                            confidence=confidence, lat=lat, lng=lng,
                            is_free=is_free, is_testing=is_testing,
                            name_confidence=name_conf,
                            dietary_info=dietary,
                            rsvp_required=rsvp_required,
                            rsvp_link=rsvp_link,
                        )
                        recent_events[new_id] = {
                            "building": full_name,
                            "food_type": food_type,
                            "name": name,
                            "time": time.time(),
                        }
                        log.info("%s [food event] id=%s %s (%s) name_conf=%.2f | %s | free=%s",
                                 label, new_id, full_name, abbr, name_conf, food_type, is_free)

                last_id = mid
                save_last_id(state_file, last_id)

            backoff = poll_seconds
            time.sleep(QUOTA_COOLDOWN_SECONDS if quota_hit else poll_seconds)

        except KeyboardInterrupt:
            return
        except Exception as e:
            log.error("%s [error] %s", label, e)
            time.sleep(backoff)
            backoff = min(backoff * 2, 60)


def main() -> None:
    try:
        _log_client = google.cloud.logging.Client()
        _log_client.setup_logging()
    except Exception as e:
        logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
        log.warning("GCP Cloud Logging unavailable, falling back to stdout: %s", e)

    token          = env("GROUPME_TOKEN")
    group_id       = env("GROUPME_GROUP_ID")
    test_group_id  = os.getenv("TEST_GROUP_ID", "").strip()
    gemini_api_key = env("GEMINI_API_KEY")
    poll_seconds   = float(os.getenv("POLL_SECONDS", "5"))
    state_file     = os.getenv("STATE_FILE", ".groupme_last_id.txt")
    include_system = os.getenv("INCLUDE_SYSTEM", "0") == "1"

    init_db()
    _init_shared_resources()
    gemini_model = _gemini_model
    matcher      = _matcher

    common = dict(
        token=token,
        gemini_model=gemini_model,
        matcher=matcher,
        poll_seconds=poll_seconds,
        include_system=include_system,
    )

    threads = [
        threading.Thread(
            target=poll_group,
            kwargs=dict(**common, group_id=group_id, is_testing=False, state_file=state_file),
            daemon=True,
            name="poller-prod",
        )
    ]

    if test_group_id:
        test_state_file = state_file.replace(".txt", "_test.txt")
        threads.append(threading.Thread(
            target=poll_group,
            kwargs=dict(**common, group_id=test_group_id, is_testing=True, state_file=test_state_file),
            daemon=True,
            name="poller-test",
        ))
        log.info("[init] test group enabled: %s", test_group_id)
    else:
        log.info("[init] TEST_GROUP_ID not set — skipping test group poller")

    # Boilerlink poller (checks every 5 minutes by default)
    boilerlink_poll_seconds = float(os.getenv("BOILERLINK_POLL_SECONDS", "300"))
    threads.append(threading.Thread(
        target=poll_boilerlink,
        kwargs=dict(
            gemini_model=gemini_model,
            matcher=matcher,
            poll_seconds=boilerlink_poll_seconds,
        ),
        daemon=True,
        name="poller-boilerlink",
    ))
    log.info("[init] Boilerlink poller enabled, interval=%ss", boilerlink_poll_seconds)

    for t in threads:
        t.start()

    try:
        for t in threads:
            t.join()
    except KeyboardInterrupt:
        log.info("[stopped]")


if __name__ == "__main__":
    main()
