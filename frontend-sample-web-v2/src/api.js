// Lightweight API client for the Free Food at Purdue backend.
// Backend endpoints are unchanged from the original site.

export const API_BASE = 'https://api.freefoodatpurdue.com';

export function getUserId() {
  let uid = localStorage.getItem('fap_user_id');
  if (!uid) {
    uid = (typeof crypto !== 'undefined' && crypto.randomUUID)
      ? crypto.randomUUID()
      : 'u_' + Math.random().toString(36).slice(2) + Date.now().toString(36);
    localStorage.setItem('fap_user_id', uid);
  }
  return uid;
}

const USER_ID = getUserId();

export async function fetchEvents({ includeExpired = true, includeTesting = false } = {}) {
  const url = `${API_BASE}/food_events?include_expired=${includeExpired}&include_testing=${includeTesting}`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`food_events ${res.status}`);
  return res.json();
}

export async function fetchEventById(id) {
  const url = `${API_BASE}/food_events/${encodeURIComponent(id)}`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`food_events/${id} ${res.status}`);
  return res.json();
}

export async function fetchBuildings() {
  const res = await fetch(`${API_BASE}/buildings`);
  if (!res.ok) throw new Error(`buildings ${res.status}`);
  return res.json();
}

// Today's dining-court menu. abbr ∈ {WDCT, ERHT, FORD, HILL, WDC}.
// Backend already caches per-day, so this is cheap to hit on expand.
export async function fetchDiningMenu(abbr) {
  const res = await fetch(`${API_BASE}/dining/${encodeURIComponent(abbr)}`);
  if (!res.ok) throw new Error(`dining/${abbr} ${res.status}`);
  return res.json();
}

// Today's dining-court ranking — { date, rankings: [{abbr,name,votes,voted,rank}] }
export async function fetchDiningRankings() {
  const res = await fetch(`${API_BASE}/dining/rankings?user_id=${encodeURIComponent(USER_ID)}`);
  if (!res.ok) throw new Error(`dining/rankings ${res.status}`);
  return res.json();
}

// Toggle the user's vote for a dining court today. Returns
// { abbr, voted, votes, date }.
export async function voteDiningCourt(abbr) {
  const res = await fetch(`${API_BASE}/dining/${encodeURIComponent(abbr)}/vote`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ user_id: USER_ID }),
  });
  if (!res.ok) throw new Error(`dining/${abbr}/vote ${res.status}`);
  return res.json();
}

// Library building info — proxied by our Express server, sourced from
// Purdue Archives & Special Collections.
// Returns { name, abbreviation, image_url, description, fun_fact, from_year, to_year, source_url } or null on 404.
export async function fetchLibraryBuilding(abbr) {
  if (!abbr) return null;
  const res = await fetch(`/lib/building/${encodeURIComponent(abbr)}`);
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`lib/building/${abbr} ${res.status}`);
  return res.json();
}

export async function fetchEventActivity(eventId) {
  const res = await fetch(`${API_BASE}/events/${encodeURIComponent(eventId)}/activity`);
  if (!res.ok) throw new Error(`activity ${res.status}`);
  return res.json();
}

export async function voteGoing(eventId) {
  const res = await fetch(`${API_BASE}/events/${eventId}/going`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ user_id: USER_ID }),
  });
  if (!res.ok) throw new Error(`going ${res.status}`);
  return res.json();
}

export async function voteGone(eventId) {
  const res = await fetch(`${API_BASE}/events/${eventId}/gone`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ user_id: USER_ID }),
  });
  if (!res.ok) throw new Error(`gone ${res.status}`);
  return res.json();
}

export async function submitSpot(payload) {
  const res = await fetch(`${API_BASE}/events/submit`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
  if (!res.ok) throw new Error(`submit ${res.status}`);
  return res.json();
}
