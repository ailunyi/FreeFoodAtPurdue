# Backend

FastAPI server and source pollers. This is where events get collected, parsed, stored, and served.

## Requirements

- Python 3.12 or newer
- A Google Gemini API key (used for event extraction, classification, and building-name embeddings)
- A GroupMe access token, if you want to run the GroupMe poller

## Setup

```bash
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

Fill in `.env`:

| Variable | Required | Purpose |
|---|---|---|
| `GEMINI_API_KEY` | yes | Gemini API key for extraction and embeddings |
| `GROUPME_TOKEN` | for the poller | GroupMe user API token |
| `GROUPME_GROUP_ID` | for the poller | The group to watch |
| `TEST_GROUP_ID` | no | Optional second group treated as test data |
| `INGEST_API_KEY` | for ingest | Shared secret for `POST /events/ingest_instagram` |
| `POLL_SECONDS` | no | GroupMe poll interval, default 5 |
| `BOILERLINK_POLL_SECONDS` | no | BoilerLink poll interval, default 300 |
| `GEMINI_QUOTA_COOLDOWN_SECONDS` | no | Pause after a Gemini quota error, default 600 |
| `GEMINI_RATE_LIMIT_PER_MIN` | no | Per-IP limit on Gemini-backed endpoints, default 5 |
| `VOTE_RATE_LIMIT_PER_MIN` | no | Per-IP limit on vote endpoints, default 30 |
| `FOOD_EVENTS_DB_PATH` | no | Override the events database location |
| `MESSAGES_DB_PATH` | no | Override the messages database location |

## One-time data bootstrap

The server needs a catalog of campus buildings before it will start.

```bash
python "building locations/import_buildings.py"   # builds buildings.db from the JSON data
python build_embeddings.py                        # embeds building names for fuzzy matching
```

The embeddings file (`building_embeddings.npz`) is generated locally and not checked in. If you change the building catalog, run `build_embeddings.py` again; it only re-embeds what changed.

## Running

The API on its own:

```bash
uvicorn api:app --host 0.0.0.0 --port 8000
```

The GroupMe poller (also starts the BoilerLink poller in a background thread):

```bash
python backend.py
```

The Instagram poller is separate and optional: `python instagram_poller.py`.

## API overview

| Endpoint | Method | Description |
|---|---|---|
| `/food_events` | GET | Active events; `include_expired` and `include_testing` flags |
| `/buildings` | GET | Campus building catalog; supports `q`, `key_only`, `map_only` |
| `/buildings/with_events` | GET | Only buildings that currently have events |
| `/buildings/at_point` | GET | Which building a coordinate falls in or near |
| `/events/submit` | POST | User-submitted sighting; text and/or photo, parsed by Gemini |
| `/events/validate` | POST | Pre-submit check that required fields are present |
| `/events/{id}/going` | POST | Toggle an "I'm going" vote |
| `/events/{id}/gone` | POST | Toggle a "food's gone" flag |
| `/events/ingest_instagram` | POST | Bulk ingest, requires the `INGEST_API_KEY` bearer token |
| `/dining/{abbr}` | GET | Dining court menu for today, proxied from Purdue's menu API |
| `/otg/{abbr}` | GET | On-the-GO location menu for today |

Endpoints that call Gemini are rate limited per IP and enforce size limits on text and images, so a public deployment does not turn into an open Gemini proxy.

## Tests

```bash
pip install -r requirements-dev.txt
pytest tests
```

The tests create their own throwaway SQLite databases and stub out Gemini, so they run without any keys or network access.
