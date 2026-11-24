#!/usr/bin/env python3
"""
Instagram → Food at Purdue ingest script.

Run this on your home PC (daily via cron/Task Scheduler).
It fetches recent posts from watched Instagram accounts using instaloader,
then pushes them to the server's /events/ingest_instagram endpoint.

Setup:
  pip install instaloader requests
  cp .env.example .env   # fill in your values

Usage:
  python fetch_and_push.py

Environment variables (or .env file):
  SERVER_URL        - e.g. https://yourserver.com  (no trailing slash)
  INGEST_API_KEY    - must match the server's INGEST_API_KEY
  INSTAGRAM_USER    - (optional) Instagram username for login
  INSTAGRAM_PASS    - (optional) Instagram password for login
  WATCH_ACCOUNTS    - (optional) comma-separated list of accounts to watch
"""

import base64
import json
import os
import sys
from datetime import datetime, timezone, timedelta

import instaloader
import requests

# Load .env if present
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

SERVER_URL = os.getenv("SERVER_URL", "").rstrip("/")
INGEST_API_KEY = os.getenv("INGEST_API_KEY", "")
INSTAGRAM_USER = os.getenv("INSTAGRAM_USER", "")
INSTAGRAM_PASS = os.getenv("INSTAGRAM_PASS", "")
WATCH_ACCOUNTS = [
    a.strip() for a in os.getenv("WATCH_ACCOUNTS", "purduestudentgovernment,purdueaaarcc").split(",")
    if a.strip()
]

MAX_POSTS_PER_ACCOUNT = 5
PUSH_BATCH_SIZE = 25
LOOKBACK_DAYS = 3
SESSION_FILE = os.path.join(os.path.dirname(__file__), ".instaloader_session")


def main():
    if not SERVER_URL:
        print("ERROR: SERVER_URL not set")
        sys.exit(1)
    if not INGEST_API_KEY:
        print("ERROR: INGEST_API_KEY not set")
        sys.exit(1)

    # Set up instaloader
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

    # Try to load existing session, or login fresh
    if os.path.exists(SESSION_FILE) and INSTAGRAM_USER:
        try:
            loader.load_session_from_file(INSTAGRAM_USER, SESSION_FILE)
            print(f"Loaded session for {INSTAGRAM_USER}")
        except Exception:
            _login(loader)
    elif INSTAGRAM_USER and INSTAGRAM_PASS:
        _login(loader)
    else:
        print("WARNING: No Instagram credentials — may get rate-limited")

    cutoff = datetime.now(timezone.utc) - timedelta(days=LOOKBACK_DAYS)
    all_posts = []

    for account in WATCH_ACCOUNTS:
        print(f"Fetching @{account}...")
        try:
            profile = instaloader.Profile.from_username(loader.context, account)
            count = 0
            for post in profile.get_posts():
                if count >= MAX_POSTS_PER_ACCOUNT:
                    break
                if post.date_utc < cutoff.replace(tzinfo=None):
                    break

                post_data = {
                    "shortcode": post.shortcode,
                    "caption": post.caption or "",
                    "account": account,
                    "posted_at": post.date_utc.isoformat() + "Z",
                }

                # Download image
                if post.typename != "GraphVideo" and post.url:
                    try:
                        resp = requests.get(post.url, timeout=20)
                        resp.raise_for_status()
                        post_data["image_base64"] = base64.b64encode(resp.content).decode()
                        post_data["image_mime"] = resp.headers.get("content-type", "image/jpeg").split(";")[0]
                    except Exception as e:
                        print(f"  Could not download image for {post.shortcode}: {e}")

                all_posts.append(post_data)
                count += 1
                print(f"  Post {post.shortcode}: {(post.caption or '')[:60]}...")

        except instaloader.exceptions.ProfileNotExistsException:
            print(f"  Profile not found: {account}")
        except Exception as e:
            print(f"  Error fetching @{account}: {e}")

    if not all_posts:
        print("No new posts found.")
        return

    # Push to server in batches; the server rejects more than 25 posts per request.
    print(f"\nPushing {len(all_posts)} posts to {SERVER_URL}...")
    for i in range(0, len(all_posts), PUSH_BATCH_SIZE):
        batch = all_posts[i:i + PUSH_BATCH_SIZE]
        try:
            resp = requests.post(
                f"{SERVER_URL}/events/ingest_instagram",
                json={"posts": batch},
                headers={"Authorization": f"Bearer {INGEST_API_KEY}"},
                timeout=120,
            )
            resp.raise_for_status()
            data = resp.json()
            print(f"Server response: {json.dumps(data, indent=2)}")
        except requests.HTTPError as e:
            print(f"Server error {resp.status_code}: {resp.text}")
        except Exception as e:
            print(f"Failed to push: {e}")

def _login(loader):
    if not INSTAGRAM_USER or not INSTAGRAM_PASS:
        return
    try:
        loader.login(INSTAGRAM_USER, INSTAGRAM_PASS)
        loader.save_session_to_file(SESSION_FILE)
        print(f"Logged in as {INSTAGRAM_USER} (session saved)")
    except Exception as e:
        print(f"Login failed: {e}")


if __name__ == "__main__":
    main()
