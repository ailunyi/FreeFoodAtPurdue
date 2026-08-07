#!/usr/bin/env python3
"""
Instagram watch list poller using instaloader.

Downloads recent posts from watched Instagram accounts and uses Gemini
to extract food/event information from captions and images.
"""

import base64
import json
import logging
import os
import time
from datetime import datetime, timezone, timedelta
from typing import Any, Dict, List, Optional

import google.generativeai as genai
import instaloader
import requests
from dotenv import load_dotenv

from building_matcher import BuildingMatcher
from database import get_conn, get_processed_ids, init_db, insert_event, mark_processed
from gemini_utils import GeminiQuotaError, is_quota_error

load_dotenv()
log = logging.getLogger(__name__)

# Instagram accounts to watch for Purdue events
WATCH_LIST = [
    "purduestudentgovernment",
    "purdueaaarcc",
]

INSTAGRAM_EXTRACTION_PROMPT = """
You are an event extractor for Purdue University campus.
Analyze this Instagram post (caption and/or image) from a Purdue-related account.
Determine if it announces an event with food available for students on campus.

Rules:
- Extract events that involve food (free or paid) on Purdue campus
- Also extract general campus events even without food (meetings, socials, etc.)
- For "building": return the building name or abbreviation exactly as written
- "name": a short, catchy event title
- "description": 1-2 sentence casual description
- "categories": list of applicable categories from [food, club, social, academic, career, cultural, sports, service, religious, health, arts, other]
- "hasFreeFood": true only if free food is explicitly mentioned
- "rsvpRequired": true if the event requires RSVP, registration, or sign-up. false otherwise.
- "rsvpLink": if an RSVP/registration URL is mentioned, include it. Otherwise null.

If it IS about a campus event, respond with ONLY a JSON object (no markdown):
{
  "name": "<short event title>",
  "description": "<1-2 sentence summary>",
  "building": "<building name or null>",
  "room": "<room number or null>",
  "foodType": "<description of food or null>",
  "startsAt": "<ISO 8601 datetime or null>",
  "expiresAt": "<ISO 8601 datetime or null>",
  "isFree": <true or false>,
  "hasFreeFood": <true or false>,
  "rsvpRequired": <true or false>,
  "rsvpLink": "<URL or null>",
  "categories": ["food", "social"],
  "confidence": <0.0 to 1.0>
}

If it is NOT about a campus event, respond with ONLY: null

Instagram account: {account}
Post caption:
""".strip()


def _download_image_as_base64(url: str) -> Optional[str]:
    """Download image and return as base64 string."""
    try:
        resp = requests.get(url, timeout=20)
        resp.raise_for_status()
        return base64.b64encode(resp.content).decode()
    except Exception as e:
        log.warning("[instagram] failed to download image: %s", e)
        return None


def extract_event_from_post(
    gemini_model: Any,
    caption: str,
    image_url: Optional[str],
    account: str,
) -> Optional[Dict[str, Any]]:
    """Use Gemini to extract event info from an Instagram post."""
    prompt = INSTAGRAM_EXTRACTION_PROMPT.format(account=account)
    prompt = f"{prompt}\n\n{caption}"

    try:
        parts = [prompt]
        if image_url:
            image_data = _download_image_as_base64(image_url)
            if image_data:
                parts.append({"mime_type": "image/jpeg", "data": image_data})

        raw = gemini_model.generate_content(parts).text.strip()

        if not raw or raw == "null":
            return None

        cleaned = raw
        if cleaned.startswith("```"):
            cleaned = cleaned.split("```")[1]
            if cleaned.startswith("json"):
                cleaned = cleaned[4:]
            cleaned = cleaned.strip()

        parsed = json.loads(cleaned)
        if parsed.get("confidence", 0) < 0.4:
            return None
        return parsed

    except Exception as e:
        if is_quota_error(e):
            log.error("[instagram] Gemini quota/rate limit hit: %s", e)
            raise GeminiQuotaError(str(e)) from e
        log.error("[instagram] Gemini extraction error: %s", e)
        return None


def poll_instagram(
    gemini_model: Any,
    matcher: BuildingMatcher,
    poll_seconds: float = 3600,
    max_posts: int = 10,
) -> None:
    """Poll Instagram watch list for new posts indefinitely."""
    log.info("[instagram] starting poller, interval=%ss, accounts=%s", poll_seconds, WATCH_LIST)

    loader = instaloader.Instaloader(
        download_pictures=False,
        download_videos=False,
        download_video_thumbnails=False,
        download_geotags=False,
        download_comments=False,
        save_metadata=False,
        compress_json=False,
        quiet=True,
    )

    # Optionally log in for better rate limits
    ig_user = os.getenv("INSTAGRAM_USER", "").strip()
    ig_pass = os.getenv("INSTAGRAM_PASS", "").strip()
    if ig_user and ig_pass:
        try:
            loader.login(ig_user, ig_pass)
            log.info("[instagram] logged in as %s", ig_user)
        except Exception as e:
            log.warning("[instagram] login failed, continuing anonymously: %s", e)

    _MAX_GEMINI_ERRORS = 3
    backoff = poll_seconds

    while True:
        try:
            seen = get_processed_ids("instagram")
            cutoff = datetime.now(timezone.utc) - timedelta(days=7)
            quota_hit = False

            for account in WATCH_LIST:
                if quota_hit:
                    break
                try:
                    profile = instaloader.Profile.from_username(loader.context, account)
                    post_count = 0
                    gemini_errors = 0

                    for post in profile.get_posts():
                        if post_count >= max_posts:
                            break

                        if post.date_utc < cutoff.replace(tzinfo=None):
                            break

                        post_id = f"instagram_{post.shortcode}"
                        if post_id in seen:
                            post_count += 1
                            continue

                        caption = post.caption or ""
                        image_url = post.url if post.typename != "GraphVideo" else None

                        try:
                            event = extract_event_from_post(
                                gemini_model, caption, image_url, account
                            )
                        except GeminiQuotaError:
                            # Deliberately NOT marked processed — the quota failure
                            # wasn't the post's fault, so it retries next cycle.
                            log.error("[instagram] quota hit, stopping this cycle")
                            quota_hit = True
                            break

                        if event:
                            gemini_errors = 0

                            # Resolve building
                            full_name, abbr, lat, lng, name_conf = matcher.match(
                                event.get("building")
                            )

                            categories = event.get("categories", ["other"])
                            has_free_food = event.get("hasFreeFood", False)

                            food_type = event.get("foodType")
                            if not food_type and has_free_food:
                                food_type = "Foods provided not specified"

                            insert_event(
                                message_id=post_id,
                                building=full_name,
                                building_abbr=abbr,
                                room=event.get("room"),
                                food_type=food_type,
                                name=event.get("name"),
                                description=event.get("description"),
                                starts_at=event.get("startsAt"),
                                expires_at=event.get("expiresAt"),
                                confidence=event.get("confidence", 0),
                                lat=lat,
                                lng=lng,
                                is_free=has_free_food,
                                is_testing=False,
                                source="instagram",
                                name_confidence=name_conf,
                                rsvp_required=bool(event.get("rsvpRequired", False)),
                                rsvp_link=event.get("rsvpLink"),
                            )

                            # Store categories
                            _store_event_categories(post_id, categories)

                            mark_processed(post_id, "instagram", "food")
                            log.info(
                                "[instagram] new event from @%s: %s | categories=%s",
                                account, event.get("name"), categories,
                            )
                        else:
                            mark_processed(post_id, "instagram", "non_food")
                            gemini_errors += 1
                            if gemini_errors >= _MAX_GEMINI_ERRORS:
                                log.warning("[instagram] %d consecutive Gemini errors for @%s, skipping", gemini_errors, account)
                                break

                        post_count += 1

                except instaloader.exceptions.ProfileNotExistsException:
                    log.error("[instagram] profile not found: %s", account)
                except instaloader.exceptions.ConnectionException as e:
                    log.warning("[instagram] connection error for @%s: %s", account, e)
                except Exception as e:
                    log.error("[instagram] error polling @%s: %s", account, e)

            backoff = poll_seconds
            time.sleep(poll_seconds)

        except KeyboardInterrupt:
            return
        except Exception as e:
            log.error("[instagram] poll error: %s", e)
            backoff = min(backoff * 2, 1800)
            time.sleep(backoff)


def _store_event_categories(message_id: str, categories: List[str]) -> None:
    """Store event categories as a JSON array."""
    with get_conn() as conn:
        conn.execute(
            "UPDATE events SET event_categories = ? WHERE message_id = ?",
            (json.dumps(categories), message_id),
        )
