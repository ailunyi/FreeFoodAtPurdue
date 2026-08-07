#!/usr/bin/env python3
"""
Boilerlink event poller.

Periodically fetches upcoming events from the Boilerlink discovery API,
uses Gemini to classify each event into categories (food, club, social, ...),
and stores them in the database.
"""

import json
import logging
import os
import time
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

import google.generativeai as genai
import requests
from dotenv import load_dotenv

from building_matcher import BuildingMatcher
from database import (
    get_conn,
    get_processed_ids,
    init_db,
    insert_event,
    is_duplicate_event,
    mark_processed,
    merge_duplicate_event,
)
from gemini_utils import GeminiQuotaError, is_quota_error

load_dotenv()
log = logging.getLogger(__name__)

BOILERLINK_API = "https://boilerlink.purdue.edu/api/discovery/event/search"

CLASSIFICATION_PROMPT = """
You are an event classifier for Purdue University campus.
Given the following event details, classify it into one or more categories.

Possible categories (pick ALL that apply):
- food (students can EAT food at this event — free meals, snacks, food trucks, restaurant pop-ups, catered events, bake sales where you buy and eat food on-site)
- club (club meeting, org event, recruitment)
- social (social gathering, hangout, mixer, party)
- academic (study session, tutoring, lecture, workshop, academic)
- career (career fair, networking, job/internship related)
- cultural (cultural event, diversity, heritage, performance)
- sports (athletic event, intramural, recreation, fitness)
- service (community service, volunteering, charity, philanthropy)
- religious (religious service, faith-based gathering)
- health (health, wellness, blood drive, mental health)
- arts (art, music, theater, dance, creative)
- other (doesn't fit any above)

IMPORTANT for the "food" category:
- ONLY use "food" if students can physically eat/drink something at the event.
- Do NOT use "food" for: food drives, canned food collections, food donations, fundraisers at restaurants where proceeds go to a cause (e.g. "Panda Express fundraiser — proceeds support our club"), grocery gift card giveaways, or events that just vaguely mention food without it being a real part of the event.
- Food must be EXPLICITLY mentioned in the event name, description, or benefits. Do NOT assume food is available just because of the event type (e.g. don't assume a blood drive has food unless it says so).
- A fundraiser where you BUY and EAT food on-site (like a bake sale) IS food.
- A fundraiser where you buy from a restaurant chain and proceeds go to a club is NOT food (students would go to that restaurant anyway).

Also determine:
- isFree: true if free food/drinks are available at the event, false otherwise
- hasFreeFood: true ONLY if free food/drinks are explicitly mentioned or if "Free Food" is in the benefits
- foodType: a short description of the specific food/drinks available (e.g. "pizza", "Chick-fil-A sandwiches", "coffee and donuts", "catered Indian food", "baked goods"). Extract from the event name, description, or benefits. Return null if the specific food is not mentioned.
- rsvpRequired: true if the event requires RSVP, registration, sign-up, or ticket purchase to attend. false otherwise.

Respond with ONLY a JSON object (no markdown):
{
  "categories": ["food", "social"],
  "isFree": true,
  "hasFreeFood": true,
  "foodType": "pizza and drinks",
  "rsvpRequired": false
}

Event details:
""".strip()


def _build_search_params(starts_after: str, ends_before: Optional[str] = None, take: int = 50) -> dict:
    """Build query parameters for the Boilerlink event search API."""
    params = {
        "orderByField": "startsOn",
        "orderByDirection": "ascending",
        "status": "Approved",
        "take": str(take),
        "startsAfter": starts_after,
        "query": "",
    }
    if ends_before:
        params["startsBefore"] = ends_before
    return params


def fetch_boilerlink_events(starts_after: str, ends_before: Optional[str] = None, take: int = 50) -> List[Dict[str, Any]]:
    """Fetch upcoming events from the Boilerlink API."""
    params = _build_search_params(starts_after, ends_before=ends_before, take=take)
    try:
        resp = requests.get(BOILERLINK_API, params=params, timeout=30)
        resp.raise_for_status()
        data = resp.json()
        return data.get("value", [])
    except Exception as e:
        log.error("[boilerlink] fetch error: %s", e)
        return []


_FOOD_KEYWORDS = {
    "food", "pizza", "donut", "donuts", "snack", "snacks", "lunch", "dinner",
    "breakfast", "catering", "catered", "cookies", "coffee", "tea", "sandwich",
    "taco", "burger", "chicken", "bbq", "barbeque", "grill", "bake sale",
    "potluck", "refreshment", "refreshments", "chick-fil-a", "chipotle",
    "panda express", "free food", "free lunch", "free dinner", "free pizza",
    "ice cream", "cupcake", "cupcakes", "brownie", "brownies", "nachos",
    "hot dog", "hot dogs", "wings", "sushi", "ramen", "noodle", "noodles",
    "waffle", "waffles", "pancake", "pancakes", "bagel", "bagels",
    "fruit", "smoothie", "smoothies", "juice", "lemonade", "popcorn",
    "candy", "chocolate", "treats", "meal", "meals", "dining", "eat",
    "hungry", "chef", "cook", "cooking", "baked goods", "pastry", "pastries",
}

_FOOD_BENEFIT_TAGS = {"free food", "food provided"}


def _might_have_food(event: dict) -> bool:
    """Cheap keyword heuristic: does the event mention food in name, description, or benefits?"""
    text = f"{event.get('name', '')} {event.get('description', '')}".lower()
    benefits = {b.lower() for b in event.get("benefitNames", [])}
    if benefits & _FOOD_BENEFIT_TAGS:
        return True
    return any(kw in text for kw in _FOOD_KEYWORDS)


def classify_event(gemini_model: Any, event: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Use Gemini to classify an event into categories.

    Raises _GeminiQuotaError on 429/quota/spending cap errors so the caller
    can break the loop immediately.
    """
    details = (
        f"Name: {event.get('name', '')}\n"
        f"Description: {event.get('description', '')}\n"
        f"Organization: {event.get('organizationName', '')}\n"
        f"Location: {event.get('location', '')}\n"
        f"Theme: {event.get('theme', '')}\n"
        f"Boilerlink Categories: {', '.join(event.get('categoryNames', []))}\n"
        f"Benefits: {', '.join(event.get('benefitNames', []))}\n"
    )
    try:
        raw = gemini_model.generate_content(
            f"{CLASSIFICATION_PROMPT}\n\n{details}"
        ).text.strip()
        cleaned = raw
        if cleaned.startswith("```"):
            cleaned = cleaned.split("```")[1]
            if cleaned.startswith("json"):
                cleaned = cleaned[4:]
            cleaned = cleaned.strip()
        return json.loads(cleaned)
    except Exception as e:
        if is_quota_error(e):
            log.error("[boilerlink] Gemini quota/rate limit hit: %s", e)
            raise GeminiQuotaError(str(e)) from e
        log.error("[boilerlink] classify error for '%s': %s", event.get("name"), e)
        return None


_MAX_GEMINI_ERRORS_PER_CYCLE = 3


def poll_boilerlink(
    gemini_model: Any,
    matcher: BuildingMatcher,
    poll_seconds: float = 300,
) -> None:
    """Poll Boilerlink for new events indefinitely."""
    log.info("[boilerlink] starting poller, interval=%ss", poll_seconds)
    backoff = poll_seconds

    while True:
        try:
            now_dt = datetime.now(timezone.utc)
            now = now_dt.strftime("%Y-%m-%dT%H:%M:%S+00:00")
            cutoff = (now_dt + timedelta(days=3)).strftime("%Y-%m-%dT%H:%M:%S+00:00")
            events = fetch_boilerlink_events(starts_after=now, ends_before=cutoff, take=600)
            seen = get_processed_ids("boilerlink")

            gemini_errors = 0

            for ev in events:
                bl_id = f"boilerlink_{ev.get('id', '')}"
                if bl_id in seen:
                    continue

                # Keyword pre-filter: skip events that obviously aren't food-related
                if not _might_have_food(ev):
                    mark_processed(bl_id, "boilerlink", "non_food")
                    log.debug("[boilerlink] keyword pre-filter skipped: %s", ev.get("name"))
                    continue

                # Classify with Gemini
                try:
                    classification = classify_event(gemini_model, ev)
                except GeminiQuotaError:
                    # Deliberately NOT marked processed — the quota failure wasn't
                    # the event's fault, so it retries next cycle.
                    log.error("[boilerlink] quota hit, stopping this cycle")
                    break

                if not classification:
                    mark_processed(bl_id, "boilerlink", "error")
                    gemini_errors += 1
                    if gemini_errors >= _MAX_GEMINI_ERRORS_PER_CYCLE:
                        log.warning("[boilerlink] %d consecutive Gemini errors, stopping this cycle", gemini_errors)
                        break
                    continue

                # Reset error counter on success
                gemini_errors = 0

                categories = classification.get("categories", ["other"])
                has_free_food = classification.get("hasFreeFood", False)

                # Also check Boilerlink's own benefit tags
                benefits = [b.lower() for b in ev.get("benefitNames", [])]
                if "free food" in benefits:
                    has_free_food = True
                    if "food" not in categories:
                        categories.append("food")

                # Only insert events that involve food
                if "food" not in categories:
                    mark_processed(bl_id, "boilerlink", "non_food")
                    log.debug("[boilerlink] skipping non-food event: %s", ev.get("name"))
                    continue

                # Reject food drives / donation events that Gemini misclassified
                _name_lower = (ev.get("name") or "").lower()
                _desc_lower = (ev.get("description") or "").lower()
                _reject_phrases = ["food drive", "canned food", "food donation", "food collection"]
                if any(p in _name_lower or p in _desc_lower for p in _reject_phrases):
                    mark_processed(bl_id, "boilerlink", "non_food")
                    log.info("[boilerlink] skipping food drive/donation event: %s", ev.get("name"))
                    continue

                # Resolve building from location text
                location_text = ev.get("location") or ""
                full_name, abbr, lat, lng, name_conf = matcher.match(location_text)

                # Use Boilerlink's own coordinates if available and matcher didn't find any
                if lat is None and ev.get("latitude"):
                    try:
                        lat = float(ev["latitude"])
                        lng = float(ev["longitude"])
                    except (ValueError, TypeError):
                        pass

                # Build a description from the event data
                org = ev.get("organizationName", "")
                desc = ev.get("description", "")
                if len(desc) > 200:
                    desc = desc[:197] + "..."

                food_type = classification.get("foodType")
                if not food_type and has_free_food:
                    food_type = "Foods provided not specified"

                rsvp_required = bool(classification.get("rsvpRequired", False))
                bl_event_id = ev.get("id", "")
                rsvp_link = f"https://boilerlink.purdue.edu/event/{bl_event_id}" if rsvp_required and bl_event_id else None

                event_name = ev.get("name")
                starts_on = ev.get("startsOn")

                # Cross-source dedup: merge into existing if duplicate
                desc_full = f"{desc} (by {org})" if org else desc
                dup_id = is_duplicate_event(building_abbr=abbr, food_type=food_type, name=event_name, starts_at=starts_on)
                if dup_id:
                    merge_duplicate_event(
                        dup_id, new_source='boilerlink',
                        name=event_name, description=desc_full, food_type=food_type,
                        starts_at=starts_on, expires_at=ev.get("endsOn"),
                        building=full_name, building_abbr=abbr, lat=lat, lng=lng,
                    )
                    mark_processed(bl_id, "boilerlink", "food")
                    log.info("[boilerlink] duplicate, merged into id=%s: %s", dup_id, event_name)
                    continue

                insert_event(
                    message_id=bl_id,
                    building=full_name,
                    building_abbr=abbr,
                    room=None,
                    food_type=food_type,
                    name=ev.get("name"),
                    description=f"{desc} (by {org})" if org else desc,
                    starts_at=ev.get("startsOn"),
                    expires_at=ev.get("endsOn"),
                    confidence=0.9,
                    lat=lat,
                    lng=lng,
                    is_free=has_free_food,
                    is_testing=False,
                    source="boilerlink",
                    name_confidence=name_conf,
                    rsvp_required=rsvp_required,
                    rsvp_link=rsvp_link,
                )

                mark_processed(bl_id, "boilerlink", "food")
                categories_str = ", ".join(categories)
                log.info(
                    "[boilerlink] new event: %s | %s | categories=[%s] | free_food=%s",
                    ev.get("name"), location_text, categories_str, has_free_food,
                )

                # Store categories in the database
                _store_event_categories(bl_id, categories)

            # Reset backoff on successful cycle
            backoff = poll_seconds
            time.sleep(poll_seconds)

        except KeyboardInterrupt:
            return
        except Exception as e:
            log.error("[boilerlink] poll error: %s", e)
            backoff = min(backoff * 2, 1800)
            time.sleep(backoff)


def _store_event_categories(message_id: str, categories: List[str]) -> None:
    """Store event categories as a JSON array in the event_categories column."""
    with get_conn() as conn:
        conn.execute(
            "UPDATE events SET event_categories = ? WHERE message_id = ?",
            (json.dumps(categories), message_id),
        )
