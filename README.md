# Free Food at Purdue

Free Food at Purdue finds food events on and around Purdue's campus and puts them on a map. It watches a few sources where free food gets announced, extracts the useful details (what, where, when), and serves them through an API that the iOS app and web demo consume.

## How it works

The backend pulls from three sources:

- A GroupMe group chat where students post about leftover catering and free food. A poller reads new messages and uses Gemini to decide whether a message describes a real food event and to extract its details.
- BoilerLink, Purdue's student organization event listing. Events are pre-filtered with a keyword check, then classified with Gemini so only events where you can actually eat something make it through.
- Instagram accounts of Purdue organizations, parsed the same way.

Extracted events are matched against a catalog of campus buildings (exact name lookup first, then embedding similarity for fuzzy references like "the union"), stored in SQLite, and served by a FastAPI application. Students can also submit sightings directly from the app, vote that they are going, or flag that the food is gone.

## Repository layout

| Directory | What it is |
|---|---|
| `backend/` | FastAPI server, source pollers, Gemini extraction, SQLite storage |
| `frontend-IOS/` | SwiftUI iPhone app (map and event list) |
| `frontend-sample-web/` | Single-page web demo of the map |

Each directory has its own README with setup instructions. The backend README is the place to start if you want to run the whole thing locally.

## Quick start

You need Python 3.12+ and a Google Gemini API key.

```bash
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # fill in your keys
python "building locations/import_buildings.py"
python build_embeddings.py
uvicorn api:app --port 8000
```

See [backend/README.md](backend/README.md) for the full walkthrough, including the pollers and every environment variable.

## Branches

`main` is the source of truth and always holds the whole project. Day-to-day work happens on the long-lived component branches, which are merged into `main` through pull requests:

- `backend` for the API and pollers
- `frontend-ios` for the iOS app
- `frontend-web` for the web demo

For a small fix, a short-lived feature branch off `main` is also fine.

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) for setup, branch conventions, and what we expect in a pull request. Security issues should go through the process in [SECURITY.md](SECURITY.md) rather than a public issue.

## License

This project is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE).
