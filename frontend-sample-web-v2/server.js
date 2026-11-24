// Free Food at Purdue — v2 frontend host with SEO server-side rendering for /event/:id.
//
// What this server does:
//   • Serves the Vite-built static SPA from ./dist
//   • Intercepts /event/:id and injects per-event Schema.org Event JSON-LD,
//     dynamic title/description, OG tags, and a static body preview into the
//     index.html template — so crawlers (and slow connections) see real
//     content immediately.
//   • Serves /sitemap.xml enumerated from the API's active events.
//   • Falls back to dist/index.html for SPA client-side routes.
//
// Hardening:
//   • helmet for default security headers (CSP allows the React bundle, fonts,
//     Mapbox, and the production API; everything else is locked down)
//   • Strict event-id validation (only [A-Za-z0-9_-]{1,64}) before contacting
//     the upstream API or interpolating into HTML
//   • All API-derived strings are HTML-escaped before being interpolated; the
//     Schema.org JSON-LD uses JSON.stringify with a `</script>` guard
//   • Compression for HTML/JS/CSS responses
//   • 5s upstream-fetch timeouts so a slow/failed API never hangs page render

import express from 'express';
import compression from 'compression';
import helmet from 'helmet';
import fetch from 'node-fetch';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DIST = path.join(__dirname, 'dist');
const TEMPLATE_PATH = path.join(DIST, 'index.html');

const PORT = parseInt(process.env.PORT || '3000', 10);
const HOST = process.env.HOST || '0.0.0.0';
const API_BASE = process.env.API_BASE || 'https://api.freefoodatpurdue.com';
const SITE_ORIGIN = process.env.SITE_ORIGIN || 'https://freefoodatpurdue.com';

if (!fs.existsSync(TEMPLATE_PATH)) {
  console.error(`[fatal] missing build at ${TEMPLATE_PATH}. Run \`npm run build\` first.`);
  process.exit(1);
}

const TEMPLATE = fs.readFileSync(TEMPLATE_PATH, 'utf-8');

const app = express();
app.disable('x-powered-by');
app.set('trust proxy', true);

app.use(helmet({
  contentSecurityPolicy: {
    useDefaults: true,
    directives: {
      'default-src': ["'self'"],
      // Mapbox + Google Analytics (gtag.js) — both legitimate. inline kept for
      // gtag bootstrap and a couple of inline-style islands React still emits.
      'script-src': ["'self'", "'unsafe-inline'", 'https://api.mapbox.com', 'https://events.mapbox.com', 'https://www.googletagmanager.com', 'blob:'],
      'worker-src': ["'self'", 'blob:'],
      'connect-src': [
        "'self'", API_BASE, 'https://api.mapbox.com', 'https://events.mapbox.com',
        'https://api.freefoodatpurdue.com',
        // GA4 beacon endpoints
        'https://www.googletagmanager.com',
        'https://www.google-analytics.com',
        'https://*.analytics.google.com',
        'https://*.google-analytics.com',
        'https://stats.g.doubleclick.net',
      ],
      'style-src': ["'self'", "'unsafe-inline'", 'https://fonts.googleapis.com', 'https://api.mapbox.com'],
      'font-src': ["'self'", 'https://fonts.gstatic.com', 'data:'],
      'img-src': ["'self'", 'data:', 'blob:', 'https:'],
      'frame-ancestors': ["'none'"],
    },
  },
  crossOriginEmbedderPolicy: false,
}));

app.use(compression());

// ──────────────────────────────────────────────────────────────────────────
// Helpers

function escHtml(s) {
  return String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// Strip HTML markup (BoilerLink event descriptions arrive as raw HTML).
function stripHtml(s) {
  if (!s) return '';
  return String(s)
    .replace(/<style[\s\S]*?<\/style>/gi, '')
    .replace(/<script[\s\S]*?<\/script>/gi, '')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/\s+/g, ' ')
    .trim();
}

// JSON.stringify but safe to drop directly into a <script> tag.
function safeJson(obj) {
  return JSON.stringify(obj).replace(/</g, '\\u003c');
}

function isValidEventId(id) {
  return typeof id === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(id);
}

async function fetchWithTimeout(url, ms = 5000, opts = {}) {
  const ac = new AbortController();
  const t = setTimeout(() => ac.abort(), ms);
  try {
    const res = await fetch(url, {
      signal: ac.signal,
      headers: { accept: 'application/json', ...(opts.headers || {}) },
      ...opts,
    });
    return res;
  } finally {
    clearTimeout(t);
  }
}

// ── Purdue Libraries building-info proxy ─────────────────────────────
//
// Queries the public Algolia "buildings" index that powers
// https://collections.lib.purdue.edu/campus/buildings (the Archives & Special
// Collections "Purdue Campus Facilities and Buildings Historic Database").
//
// Both credentials below are PUBLIC search-only Algolia keys — they're served
// directly to the browser by the Library's site and are designed to be
// exposed. We proxy through this server so:
//   - The browser doesn't need algolia.net in its CSP connect-src
//   - We can cache responses and shape the payload to what the UI needs
const ALGOLIA_APP_ID  = '7U9KTNF4U8';
const ALGOLIA_API_KEY = '270a5c6cf85c4505bf6e232fa5243c0b';
const LIB_IMAGE_BASE  = 'https://collections.lib.purdue.edu/campus/images/';

const buildingInfoCache = new Map(); // abbr → { ts, data }
const BUILDING_INFO_TTL_MS = 6 * 60 * 60 * 1000; // 6 h

function isValidBuildingAbbr(s) {
  return typeof s === 'string' && /^[A-Za-z][A-Za-z0-9_-]{0,15}$/.test(s);
}

async function lookupLibraryBuilding(abbr) {
  const upper = abbr.toUpperCase();
  const cached = buildingInfoCache.get(upper);
  if (cached && Date.now() - cached.ts < BUILDING_INFO_TTL_MS) return cached.data;

  // Algolia search-only query. We restrict by abbreviation as a facetFilter
  // for an exact match (case-insensitive on Algolia's side by default).
  const body = JSON.stringify({
    params: `query=${encodeURIComponent(upper)}&hitsPerPage=5&restrictSearchableAttributes=abbreviation,name`,
  });
  const url = `https://${ALGOLIA_APP_ID}-dsn.algolia.net/1/indexes/buildings/query`;
  const res = await fetchWithTimeout(url, 5000, {
    method: 'POST',
    headers: {
      'X-Algolia-API-Key': ALGOLIA_API_KEY,
      'X-Algolia-Application-Id': ALGOLIA_APP_ID,
      'Content-Type': 'application/json',
    },
    body,
  });
  if (!res.ok) throw new Error(`algolia ${res.status}`);
  const data = await res.json();

  // Pick the first hit whose abbreviation matches exactly (the Library's
  // tokenized search will sometimes surface fuzzy names).
  const hits = Array.isArray(data.hits) ? data.hits : [];
  const exact = hits.find(h => (h.abbreviation || '').toUpperCase() === upper) || hits[0] || null;
  if (!exact) {
    buildingInfoCache.set(upper, { ts: Date.now(), data: null });
    return null;
  }

  const description = stripHtml(exact.description || '');
  // "Fun fact" — first sentence-ish chunk. Period only counts as a sentence
  // terminator if preceded by 2+ lowercase letters (so "Thomas S." or
  // "Harvey D." don't get treated as a sentence). Question/exclamation marks
  // always terminate. 240-char ceiling.
  const firstSentence = (() => {
    const m = description.match(/^.+?(?:[a-z]{2,}\.|[!?])(?=\s+[A-Z]|\s*$)/);
    const sentence = (m ? m[0] : description).trim();
    return sentence.length > 240 ? sentence.slice(0, 237).trimEnd() + '…' : sentence;
  })();
  const year = Number.isFinite(exact.from_year) && exact.from_year > 0 ? exact.from_year : null;
  // Library uses 9999 as a sentinel for "still standing" — drop it so the UI
  // doesn't render "1965 — 9999".
  const toYear = Number.isFinite(exact.to_year) && exact.to_year > 0 && exact.to_year < 9000
    ? exact.to_year : null;

  const payload = {
    abbreviation: exact.abbreviation || upper,
    name: exact.name || null,
    image_url: exact.image_url ? LIB_IMAGE_BASE + exact.image_url : null,
    description,
    fun_fact: firstSentence || null,
    from_year: year,
    to_year: toYear,
    source_url: `https://collections.lib.purdue.edu/campus/buildings/${exact.objectID}`,
  };
  buildingInfoCache.set(upper, { ts: Date.now(), data: payload });
  return payload;
}

// Tiny in-memory cache so repeated /event/:id and /sitemap hits within ~30s
// don't all hammer the upstream list endpoint.
const eventListCache = { at: 0, events: [], inflight: null };
async function getEvents() {
  const now = Date.now();
  if (now - eventListCache.at < 30_000 && eventListCache.events.length) {
    return eventListCache.events;
  }
  if (eventListCache.inflight) return eventListCache.inflight;
  eventListCache.inflight = (async () => {
    try {
      const res = await fetchWithTimeout(`${API_BASE}/food_events?include_expired=true&include_testing=false`, 5000);
      if (!res.ok) throw new Error(`food_events ${res.status}`);
      const events = await res.json();
      eventListCache.events = Array.isArray(events) ? events : [];
      eventListCache.at = Date.now();
      return eventListCache.events;
    } finally {
      eventListCache.inflight = null;
    }
  })();
  return eventListCache.inflight;
}

async function findEventById(id) {
  const events = await getEvents();
  return events.find(ev => String(ev.id) === String(id)) || null;
}

// Server-side mirror of the client's isFoodSpecified — keeps "Foods provided
// not specified" / "food" out of titles and SSR markup.
function isFoodSpecified(food) {
  if (food == null) return false;
  const s = String(food).trim().toLowerCase();
  if (!s) return false;
  if (s === 'food' || s === 'foods') return false;
  if (s.includes('not specified') || s.includes('unspecified') || s.includes('unknown')) return false;
  return true;
}

// Render times in Purdue/Eastern so SSR matches what the SPA shows.
const PURDUE_TZ = 'America/New_York';
function fmtClock(iso) {
  if (!iso) return '';
  // Coerce naïve datetimes ("YYYY-MM-DD HH:MM:SS") to UTC so we display the
  // correct local hour rather than the host process's local interpretation.
  let s = String(iso);
  if (!/([Zz]|[+\-]\d{2}:?\d{2})$/.test(s)) s = s.replace(' ', 'T') + 'Z';
  const d = new Date(s);
  if (!Number.isFinite(d.getTime())) return '';
  return d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', timeZone: PURDUE_TZ });
}

function parseSources(ev) {
  let sources = [];
  try { sources = ev.sources ? JSON.parse(ev.sources) : []; } catch {}
  if (!sources.length) sources = [ev.source || 'groupme'];
  return sources;
}

function postedOnLabel(ev) {
  const labels = parseSources(ev).map(s => {
    if (s === 'boilerlink') return 'BoilerLink';
    if (s === 'groupme') return 'GroupMe';
    if (s === 'user') return 'a user';
    if (s === 'testing') return 'Test';
    return s;
  });
  if (!labels.length) return 'Posted';
  if (labels.length === 1 && parseSources(ev)[0] === 'user') return 'Posted by a user';
  if (labels.length === 1) return `Posted on ${labels[0]}`;
  if (labels.length === 2) return `Posted on ${labels[0]} and ${labels[1]}`;
  return `Posted on ${labels.slice(0, -1).join(', ')}, and ${labels.at(-1)}`;
}

function buildEventSchema(ev) {
  const url = `${SITE_ORIGIN}/event/${encodeURIComponent(ev.id)}`;
  const obj = {
    '@context': 'https://schema.org',
    '@type': 'FoodEvent',
    name: ev.name || `Free food at ${ev.building || 'Purdue'}`,
    description: stripHtml(ev.description) || `${isFoodSpecified(ev.food_type) ? ev.food_type : 'Free food'} at ${ev.building || 'Purdue'}.`,
    url,
    eventStatus: 'https://schema.org/EventScheduled',
    eventAttendanceMode: 'https://schema.org/OfflineEventAttendanceMode',
    isAccessibleForFree: ev.is_free === undefined ? true : !!ev.is_free,
  };
  if (ev.starts_at) obj.startDate = ev.starts_at;
  if (ev.expires_at) obj.endDate = ev.expires_at;
  const placeName = ev.building || ev.building_abbr || 'Purdue University';
  const place = {
    '@type': 'Place',
    name: ev.room ? `${placeName} — Room ${ev.room}` : placeName,
    address: {
      '@type': 'PostalAddress',
      addressLocality: 'West Lafayette',
      addressRegion: 'IN',
      addressCountry: 'US',
    },
  };
  if (ev.lat != null && ev.lng != null) {
    place.geo = { '@type': 'GeoCoordinates', latitude: Number(ev.lat), longitude: Number(ev.lng) };
  }
  obj.location = place;
  obj.organizer = { '@type': 'Organization', name: 'Free Food at Purdue', url: SITE_ORIGIN + '/' };
  return obj;
}

// Renders the per-event head and SSR body preview into the dist template.
function renderEventTemplate(ev) {
  const url = `${SITE_ORIGIN}/event/${encodeURIComponent(ev.id)}`;
  const headline = ev.name
    ? `${ev.name} — free food at Purdue`
    : `${isFoodSpecified(ev.food_type) ? ev.food_type : 'Free food'} at ${ev.building || 'Purdue'} — free food at Purdue`;
  const desc = (stripHtml(ev.description)
    || `${isFoodSpecified(ev.food_type) ? ev.food_type : 'Free food'} at ${ev.building || 'Purdue'}${ev.starts_at ? ` starting ${fmtClock(ev.starts_at)}` : ''}. ${postedOnLabel(ev)}.`
  ).slice(0, 280);

  // Build SEO_HEAD replacement
  const head = `<title>${escHtml(headline)}</title>
<meta name="description" content="${escHtml(desc)}"/>
<link rel="canonical" href="${escHtml(url)}"/>
<meta name="robots" content="index, follow, max-image-preview:large"/>
<meta property="og:type" content="article"/>
<meta property="og:site_name" content="Free Food at Purdue"/>
<meta property="og:title" content="${escHtml(headline)}"/>
<meta property="og:description" content="${escHtml(desc)}"/>
<meta property="og:url" content="${escHtml(url)}"/>
<meta property="og:image" content="${escHtml(SITE_ORIGIN)}/images/logo-p.png"/>
<meta name="twitter:card" content="summary_large_image"/>
<meta name="twitter:title" content="${escHtml(headline)}"/>
<meta name="twitter:description" content="${escHtml(desc)}"/>
<meta name="twitter:image" content="${escHtml(SITE_ORIGIN)}/images/logo-p.png"/>
<script type="application/ld+json">${safeJson(buildEventSchema(ev))}</script>`;

  // Static body preview for crawlers / no-JS users
  const body = `<article style="padding:24px 22px;font-family:'Inter',system-ui,sans-serif;max-width:720px;margin:0 auto">
  <a href="/" style="color:#9a7d62;font-size:13px;text-decoration:none">← All sightings</a>
  <h1 style="font-family:'Fraunces',serif;font-weight:500;margin:14px 0 6px;font-size:30px;line-height:1.15">${escHtml(ev.name || `Free food at ${ev.building || 'Purdue'}`)}</h1>
  <p style="color:#9a7d62;font-size:13px;margin:0 0 14px">
    ${escHtml(postedOnLabel(ev))}
    ${ev.starts_at ? ` · Starts ${escHtml(fmtClock(ev.starts_at))}` : ''}
    ${ev.expires_at ? ` · Until ${escHtml(fmtClock(ev.expires_at))}` : ''}
  </p>
  <dl style="display:grid;grid-template-columns:1fr 1fr;gap:12px 18px;background:#f0e9da;border-radius:12px;padding:14px 16px;margin:0 0 18px">
    ${ev.building || ev.building_abbr ? `<div><dt style="font-size:10.5px;font-weight:600;color:#9a7d62;letter-spacing:0.08em;text-transform:uppercase">Where</dt><dd style="margin:3px 0 0;font-size:13px"><strong>${escHtml(ev.building || ev.building_abbr)}</strong>${ev.room ? `<br/><span style="color:#9a7d62">Room ${escHtml(ev.room)}</span>` : ''}</dd></div>` : ''}
    ${isFoodSpecified(ev.food_type) ? `<div><dt style="font-size:10.5px;font-weight:600;color:#9a7d62;letter-spacing:0.08em;text-transform:uppercase">Food</dt><dd style="margin:3px 0 0;font-size:13px"><strong>${escHtml(ev.food_type)}</strong></dd></div>` : ''}
  </dl>
  ${ev.description ? `<p style="font-family:'Fraunces',serif;font-size:15px;line-height:1.45">${escHtml(stripHtml(ev.description))}</p>` : ''}
  <p style="margin-top:24px;font-size:12px;color:#9a7d62">
    For real-time updates, dietary filters, and other free-food sightings on Purdue's campus, visit the <a href="/" style="color:#C1440E">live map</a>.
  </p>
</article>`;

  return TEMPLATE
    .replace(/<!--# SEO_HEAD #-->[\s\S]*?<!--# \/SEO_HEAD #-->/, () => head)
    .replace(/<!--# SEO_BODY #-->[\s\S]*?<!--# \/SEO_BODY #-->/, () => body);
}

// ──────────────────────────────────────────────────────────────────────────
// Routes

// Static assets (built by Vite). Long-lived for hashed assets, short for index.html.
app.use('/assets', express.static(path.join(DIST, 'assets'), {
  immutable: true, maxAge: '30d', fallthrough: true,
}));

// Public/static files (favicon, robots, images, themes)
app.use(express.static(DIST, {
  index: false,
  maxAge: '1d',
  fallthrough: true,
}));

// Per-event SEO render
app.get('/event/:id', async (req, res) => {
  const id = req.params.id;
  if (!isValidEventId(id)) return res.status(400).send('Invalid event id.');
  try {
    const ev = await findEventById(id);
    if (!ev) {
      return res.status(404).type('html').send(renderNotFound(id));
    }
    const html = renderEventTemplate(ev);
    res.set('Cache-Control', 'public, max-age=60, s-maxage=120');
    res.type('html').send(html);
  } catch (err) {
    console.warn('[event ssr] failed:', err.message);
    res.set('Cache-Control', 'no-store').type('html').send(TEMPLATE);
  }
});

function renderNotFound(id) {
  const head = `<title>Sighting not found — Free Food at Purdue</title>
<meta name="description" content="This sighting may have ended or the link is invalid. See live free-food sightings at Purdue."/>
<meta name="robots" content="noindex, follow"/>
<link rel="canonical" href="${escHtml(SITE_ORIGIN)}/"/>`;
  const body = `<main style="padding:48px 22px;font-family:'Inter',system-ui,sans-serif;max-width:560px;margin:0 auto;text-align:center">
  <h1 style="font-family:'Fraunces',serif;font-weight:500">Sighting not found</h1>
  <p style="color:#9a7d62">This sighting may have ended or the link is invalid (id: ${escHtml(id)}).</p>
  <p><a href="/" style="color:#C1440E">See live free-food sightings →</a></p>
</main>`;
  return TEMPLATE
    .replace(/<!--# SEO_HEAD #-->[\s\S]*?<!--# \/SEO_HEAD #-->/, () => head)
    .replace(/<!--# SEO_BODY #-->[\s\S]*?<!--# \/SEO_BODY #-->/, () => body);
}

// Building info (image + fun fact) sourced from Purdue Libraries.
app.get('/lib/building/:abbr', async (req, res) => {
  const abbr = req.params.abbr;
  if (!isValidBuildingAbbr(abbr)) return res.status(400).json({ error: 'invalid abbr' });
  try {
    const data = await lookupLibraryBuilding(abbr);
    if (!data) return res.status(404).json({ error: 'not found' });
    res.set('Cache-Control', 'public, max-age=3600, s-maxage=21600');
    res.json(data);
  } catch (err) {
    console.warn('[lib building]', abbr, err.message);
    res.set('Cache-Control', 'no-store').status(502).json({ error: 'upstream' });
  }
});

// Sitemap — enumerated from cached event list
app.get('/sitemap.xml', async (_req, res) => {
  let urls = [`${SITE_ORIGIN}/`, `${SITE_ORIGIN}/dining`];
  try {
    const events = await getEvents();
    for (const ev of events) {
      if (isValidEventId(String(ev.id))) {
        urls.push(`${SITE_ORIGIN}/event/${encodeURIComponent(ev.id)}`);
      }
    }
  } catch (err) {
    console.warn('[sitemap] api fetch failed:', err.message);
  }
  const body = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${urls.map(u => `  <url><loc>${escHtml(u)}</loc></url>`).join('\n')}
</urlset>`;
  res.set('Cache-Control', 'public, max-age=600').type('application/xml').send(body);
});

// SPA routes — serve the bare template for everything else (saved, dining, etc.)
app.get('*', (req, res) => {
  // Avoid serving HTML for asset-like paths that fell through (returns 404)
  if (req.path.startsWith('/api/') || /\.[a-zA-Z0-9]{1,5}$/.test(req.path)) {
    return res.status(404).end();
  }
  res.set('Cache-Control', 'no-store').type('html').send(TEMPLATE);
});

app.listen(PORT, HOST, () => {
  console.log(`[ffp v2] listening on http://${HOST}:${PORT}`);
});
