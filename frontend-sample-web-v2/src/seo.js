// Dynamic SEO updates: <title>, <meta description>, OpenGraph, canonical, Schema.org Event JSON-LD.
// Express renders the same data server-side for /event/:id so crawlers index it without JS.
// On client navigation we keep document head in sync.

import { fmtClock, parseDate, postedOnLabel, foodEmoji, stripHtml } from './helpers.js';

const HOME = {
  title: 'Free Food at Purdue — live sightings of free food on campus',
  description: "A live map of free food on Purdue's campus. Spot pizza, bagels, catered events, and dining-court openings — posted by students, BoilerLink, and GroupMe in real time.",
  url: 'https://freefoodatpurdue.com/',
};

function setMeta(selector, attr, value) {
  let el = document.head.querySelector(selector);
  if (!el) {
    el = document.createElement('meta');
    const [, name] = selector.match(/\[(?:name|property)="([^"]+)"\]/) || [];
    if (selector.includes('property=')) el.setAttribute('property', name || '');
    else el.setAttribute('name', name || '');
    document.head.appendChild(el);
  }
  el.setAttribute(attr, value);
}

function setCanonical(url) {
  let el = document.head.querySelector('link[rel="canonical"]');
  if (!el) {
    el = document.createElement('link');
    el.setAttribute('rel', 'canonical');
    document.head.appendChild(el);
  }
  el.setAttribute('href', url);
}

function clearLD() {
  document.head
    .querySelectorAll('script[data-seo-event="1"]')
    .forEach(n => n.remove());
}

function injectLD(obj) {
  clearLD();
  const s = document.createElement('script');
  s.type = 'application/ld+json';
  s.setAttribute('data-seo-event', '1');
  s.textContent = JSON.stringify(obj);
  document.head.appendChild(s);
}

export function applyHomeSeo() {
  document.title = HOME.title;
  setMeta('meta[name="description"]', 'content', HOME.description);
  setMeta('meta[property="og:title"]', 'content', HOME.title);
  setMeta('meta[property="og:description"]', 'content', HOME.description);
  setMeta('meta[property="og:url"]', 'content', HOME.url);
  setMeta('meta[name="twitter:title"]', 'content', HOME.title);
  setMeta('meta[name="twitter:description"]', 'content', HOME.description);
  setCanonical(HOME.url);
  clearLD();
}

export function applyEventSeo(ev) {
  if (!ev) return;
  const url = `https://freefoodatpurdue.com/event/${encodeURIComponent(ev.id)}`;
  const food = ev.food_type || 'Free food';
  const where = ev.building || ev.building_abbr || 'Purdue campus';
  const startTxt = ev.starts_at ? fmtClock(parseDate(ev.starts_at)) : '';
  const headline = ev.name
    ? `${ev.name} — free food at Purdue`
    : `${foodEmoji(food)} ${food} at ${where} — free food at Purdue`;
  const desc = (stripHtml(ev.description) || `${food} at ${where}${startTxt ? ` starting ${startTxt}` : ''}. ${postedOnLabel(ev)}.`).slice(0, 280);

  document.title = headline;
  setMeta('meta[name="description"]', 'content', desc);
  setMeta('meta[property="og:title"]', 'content', headline);
  setMeta('meta[property="og:description"]', 'content', desc);
  setMeta('meta[property="og:url"]', 'content', url);
  setMeta('meta[name="twitter:title"]', 'content', headline);
  setMeta('meta[name="twitter:description"]', 'content', desc);
  setCanonical(url);

  injectLD(buildEventSchema(ev));
}

// Builds a Schema.org/Event object from an API event. Used both client-side
// (here) and server-side (Express) — keep this pure and JSON-safe.
export function buildEventSchema(ev) {
  if (!ev) return null;
  const url = `https://freefoodatpurdue.com/event/${encodeURIComponent(ev.id)}`;
  const obj = {
    '@context': 'https://schema.org',
    '@type': 'FoodEvent',
    name: ev.name || `Free food at ${ev.building || 'Purdue'}`,
    description: stripHtml(ev.description) || `${ev.food_type || 'Free food'} at ${ev.building || 'Purdue'}.`,
    url,
    eventStatus: 'https://schema.org/EventScheduled',
    eventAttendanceMode: 'https://schema.org/OfflineEventAttendanceMode',
    isAccessibleForFree: ev.is_free !== false,
  };
  if (ev.starts_at) obj.startDate = ev.starts_at;
  if (ev.expires_at) obj.endDate = ev.expires_at;
  // Location
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
  if (ev.lat && ev.lng) {
    place.geo = {
      '@type': 'GeoCoordinates',
      latitude: Number(ev.lat),
      longitude: Number(ev.lng),
    };
  }
  obj.location = place;
  // Organizer
  obj.organizer = {
    '@type': 'Organization',
    name: 'Free Food at Purdue',
    url: 'https://freefoodatpurdue.com/',
  };
  return obj;
}
