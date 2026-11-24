# Free Food at Purdue — v2 frontend

A redesigned frontend for the Free Food at Purdue website, built with Vite + React on the client and Express on the server. Express handles per-event SEO (server-rendered HTML for `/event/:id`) and a `/sitemap.xml`; everything else is the SPA.

The original `frontend-sample-web/` and the `backend/` are unchanged.

## Layout

    frontend-sample-web-v2/
    ├── package.json          # Vite + React + Express dependencies
    ├── vite.config.js        # build config (output → dist/)
    ├── index.html            # SPA template with SEO_HEAD / SEO_BODY markers
    ├── server.js             # Express SEO + static host
    ├── public/               # static assets (favicon, robots.txt, images, themes)
    └── src/
        ├── main.jsx          # React entry
        ├── App.jsx           # top-level shell + view state
        ├── Header.jsx        # logo, view tabs, "Report a sighting" button
        ├── Map.jsx           # Mapbox map with event pins
        ├── Sidebar / Feed components
        │   ├── FilterBar.jsx
        │   ├── SightingCard.jsx
        │   └── EventDetail.jsx
        ├── DiningPanel.jsx
        ├── SubmitModal.jsx   # ports the original site's text+image+voice flow
        ├── Toast.jsx
        ├── api.js            # API client (food_events, going/gone, submit)
        ├── helpers.js        # shared formatters; "Posted on …" mapping
        ├── seo.js            # client-side title/meta/JSON-LD updates
        ├── router.js         # tiny path-based router
        ├── useSaved.js       # localStorage hook for saved sightings
        ├── styles.css        # v2 design styles (from draft_design_v2)
        └── theme.css         # ember theme + Mapbox markers + extras

## Local development

    cd frontend-sample-web-v2
    cp .env.example .env   # add your public Mapbox token (pk.…)
    npm install
    npm run dev      # starts the Vite dev server at http://localhost:5173

The dev server only serves the SPA — Express SEO routes are not wired in dev. To exercise the full SEO path, build and run the production server (below).

## Production build & run

    npm install
    npm run build    # produces ./dist
    npm start        # runs server.js → http://localhost:3000

`VITE_MAPBOX_TOKEN` from `.env` is baked into the client bundle at build time, so set it before `npm run build`. It must be a public (`pk.`) token; restrict it to your domain in the Mapbox dashboard.

Environment variables for the server:

| Var          | Default                                | Purpose                                       |
| ------------ | -------------------------------------- | --------------------------------------------- |
| `PORT`       | `3000`                                 | Listen port                                   |
| `HOST`       | `0.0.0.0`                              | Listen host                                   |
| `API_BASE`   | `https://api.freefoodatpurdue.com`     | Upstream backend (used for SEO + sitemap)     |
| `SITE_ORIGIN`| `https://freefoodatpurdue.com`         | Origin used in canonical / OG / sitemap URLs  |

## SEO behavior

* **`/`, `/saved`, `/dining`** — serve the SPA template (default home metadata + Schema.org WebSite/Organization). React applies dynamic title/meta if the user navigates to an event.
* **`/event/:id`** — Express fetches the event from `API_BASE/food_events/:id`, validates the id, then injects:
  * Per-event `<title>`, `<meta description>`, canonical, OpenGraph, Twitter card
  * Schema.org `FoodEvent` JSON-LD with location, geo, organizer, start/end dates
  * A static `<article>` body preview so crawlers and no-JS users see real content
  * A 60-second public cache so heavy crawl traffic doesn't hammer the API
* **`/sitemap.xml`** — Express enumerates currently active/upcoming events and emits a sitemap.
* **`/robots.txt`** — static, references the sitemap.

When users with JS land on `/event/:id`, the SPA boots on top of the SSR'd HTML and behaves normally (path stays `/event/:id`, back button returns to `/`).

## Saved sightings

The Saved view is backed by `localStorage['ffp.saved']` (a JSON array of event ids) and is synchronized across tabs via `storage` events. Nothing is sent to the backend.

## Reporting a sighting

The Report-a-sighting modal mirrors the original site's flow — free-text description, optional photo (auto-resized to ≤1568px JPEG), Web-Speech voice input, and an opportunistic geolocation fix. The backend infers building/time/food via AI from the text. Submits to `POST API_BASE/events/submit`.

## Security notes

* Express uses `helmet` for CSP and standard headers; CSP allow-lists Mapbox, Google Fonts, the production API, and self.
* Event-id input is validated server-side (`[A-Za-z0-9_-]{1,64}`) before any upstream fetch or HTML interpolation.
* All API-derived strings are HTML-escaped before being interpolated; JSON-LD uses a `</script>` guard.
* Upstream API calls use a 5s `AbortController` timeout so a slow API never wedges page render.
* React handles output escaping for SPA-rendered content, so user-provided event names / descriptions can't inject HTML.

## Deployment

Static-only hosting cannot do per-event SEO. Run `node server.js` behind nginx (or any reverse proxy) on the same origin you point users to:

    npm ci
    npm run build            # needs VITE_MAPBOX_TOKEN in .env
    npm prune --omit=dev     # optional: drop build-only deps
    PORT=3000 SITE_ORIGIN=https://freefoodatpurdue.com node server.js

Nginx example:

    location / { proxy_pass http://127.0.0.1:3000; proxy_set_header Host $host; }
