// Display helpers shared across the v2 frontend.

// Great-circle distance in metres between two lat/lng points.
export function haversineMeters(lat1, lng1, lat2, lng2) {
  const R = 6_371_000;
  const toRad = (d) => d * Math.PI / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2
          + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// Building-name tokenization — used to fuzzy-match event.building strings
// (often from Google Places, e.g. "Hillenbrand Hall") against the ArcGIS
// polygon names (e.g. "Hillenbrand Residence Hall"). We strip punctuation,
// lowercase, drop stop-words and short tokens, and compare the remaining
// significant tokens.
const BLDG_STOP_TOKENS = new Set([
  'hall', 'residence', 'center', 'centre', 'building', 'house',
  'lounge', 'lab', 'laboratory', 'court', 'memorial', 'union',
  'of', 'the', 'and', 'or', 'a', 'an', 'jr', 'sr', 'mr', 'mrs', 'ms', 'dr',
]);

export function buildingTokens(name) {
  if (!name) return new Set();
  return new Set(
    String(name).toLowerCase()
      .replace(/[.,&'’()/\\]+/g, ' ')
      .split(/\s+/)
      .filter(t => t.length >= 4 && !BLDG_STOP_TOKENS.has(t))
  );
}

// True if the two building names share at least one significant token.
// E.g. "Hillenbrand Residence Hall" ↔ "Hillenbrand Hall" → true via "hillenbrand".
export function buildingNameMatches(a, b) {
  const ta = buildingTokens(a);
  if (ta.size === 0) return false;
  const tb = buildingTokens(b);
  if (tb.size === 0) return false;
  for (const t of ta) if (tb.has(t)) return true;
  return false;
}

// BoilerLink event descriptions arrive as raw HTML; strip tags for safe display.
export function stripHtml(s) {
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

// Source labels — turns the API's `source`/`sources` field into "Posted on …" copy.
export const SOURCE_LABELS = {
  groupme:    { label: 'GroupMe',    icon: '💬', cls: 'src-gm' },
  boilerlink: { label: 'BoilerLink', icon: '📋', cls: 'src-bl' },
  user:       { label: 'a user',  icon: '📱', cls: 'src-user' },
  testing:    { label: 'Test',       icon: '🧪', cls: 'src-test' },
};

export function getSources(ev) {
  let sources = [];
  try { sources = ev.sources ? JSON.parse(ev.sources) : []; } catch {}
  if (!sources.length) sources = [ev.source || 'groupme'];
  return sources;
}

// Returns "Posted on BoilerLink" / "Posted on GroupMe" / "Posted by a student" etc.
// Multi-source events ("cross-posted") read like "Posted on BoilerLink and GroupMe".
export function postedOnLabel(ev) {
  const sources = getSources(ev);
  if (!sources.length) return 'Posted';
  const labels = sources.map(s => (SOURCE_LABELS[s] || SOURCE_LABELS.groupme).label);
  if (sources.length === 1 && sources[0] === 'user') return 'Posted by a user';
  if (labels.length === 1) return `Posted on ${labels[0]}`;
  if (labels.length === 2) return `Posted on ${labels[0]} and ${labels[1]}`;
  return `Posted on ${labels.slice(0, -1).join(', ')}, and ${labels.at(-1)}`;
}

// BoilerLink event link if message_id has the boilerlink_ prefix.
export function boilerlinkUrl(ev) {
  if (!ev?.message_id || !ev.message_id.startsWith('boilerlink_')) return null;
  const id = ev.message_id.replace('boilerlink_', '');
  return `https://boilerlink.purdue.edu/event/${encodeURIComponent(id)}`;
}

// ISO → "5m ago" / "2h ago". Goes through parseDate so naïve UTC strings
// are not silently mis-interpreted as local time.
export function timeSince(iso) {
  if (!iso) return '';
  const now = Date.now();
  const t = parseDate(iso)?.getTime();
  if (!Number.isFinite(t)) return '';
  const diffMin = Math.max(0, Math.round((now - t) / 60000));
  if (diffMin < 1) return 'just now';
  if (diffMin < 60) return `${diffMin}m ago`;
  const h = Math.floor(diffMin / 60);
  if (h < 24) return `${h}h ago`;
  const d = Math.floor(h / 24);
  return `${d}d ago`;
}

// Display every event timestamp in Eastern time — events happen at Purdue,
// not in the viewer's tz, so a user looking from Seattle should still see
// the start/end clocks in the campus's local hours.
export const PURDUE_TZ = 'America/New_York';

// Returns a Date or null. The backend emits a mix of naïve datetimes
// ("2026-04-24 18:29:14", intended as UTC) and ISO strings with offsets
// ("2026-04-29T17:30:00+00:00"). When there's no timezone marker, JS would
// interpret the string as the viewer's local time — wrong. Append 'Z' so
// naïve timestamps are read as UTC, matching server intent.
export function parseDate(iso) {
  if (!iso) return null;
  let s = String(iso);
  // Look for a timezone marker (Z, +HH:MM, -HH:MM after the time portion).
  const hasTz = /([Zz]|[+\-]\d{2}:?\d{2})$/.test(s);
  if (!hasTz) {
    // Convert "YYYY-MM-DD HH:MM:SS" → "YYYY-MM-DDTHH:MM:SSZ"
    s = s.replace(' ', 'T') + 'Z';
  }
  const d = new Date(s);
  return Number.isFinite(d.getTime()) ? d : null;
}

export function isUpcoming(ev) {
  const start = parseDate(ev.starts_at);
  return start && start.getTime() > Date.now();
}

export function isExpired(ev) {
  const exp = parseDate(ev.expires_at);
  if (!exp) return !ev.is_active;
  return exp.getTime() < Date.now() || !ev.is_active || (ev.gone_count || 0) >= 2;
}

// LIVE / ENDING / UPCOMING / EXPIRED
export function eventStatus(ev) {
  if (isExpired(ev)) return 'expired';
  if (isUpcoming(ev)) return 'upcoming';
  const exp = parseDate(ev.expires_at);
  if (exp) {
    const minsLeft = (exp.getTime() - Date.now()) / 60000;
    if (minsLeft <= 15) return 'expiring';
  }
  return 'live';
}

// "in 35m" / "in 2h 10m" / "in 1d"
export function fmtUntilStart(ev) {
  const start = parseDate(ev.starts_at);
  if (!start) return '';
  const mins = Math.max(0, Math.round((start.getTime() - Date.now()) / 60000));
  if (mins < 60) return `in ${mins}m`;
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  if (h < 24) return `in ${h}h ${m}m`;
  const d = Math.floor(h / 24);
  return `in ${d}d`;
}

// "35m left" / "1h 5m left" / "ended"
export function fmtTimeLeft(ev) {
  const exp = parseDate(ev.expires_at);
  if (!exp) return '';
  const mins = Math.round((exp.getTime() - Date.now()) / 60000);
  if (mins <= 0) return 'ended';
  if (mins < 60) return `${mins}m left`;
  const h = Math.floor(mins / 60);
  return `${h}h ${mins % 60}m left`;
}

// "5:30 PM" formatted clock — always in Purdue/Eastern time.
export function fmtClock(date) {
  if (!date) return '';
  const d = date instanceof Date ? date : parseDate(date);
  if (!d) return '';
  return d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit', timeZone: PURDUE_TZ });
}

// True when food_type carries actual information. The AI extractor sometimes
// emits "Foods provided not specified" or just "food" — treat those as missing.
export function isFoodSpecified(food) {
  if (food == null) return false;
  const s = String(food).trim().toLowerCase();
  if (!s) return false;
  if (s === 'food' || s === 'foods') return false;
  if (s.includes('not specified') || s.includes('unspecified') || s.includes('unknown')) return false;
  return true;
}

// Food-type → emoji. Priority-ordered: specific dishes win over cuisines,
// cuisines over categories, categories over the generic plate. Each entry is
// matched as a substring against the lower-cased food_type. The first hit
// returns its emoji.
const FOOD_EMOJI_TABLE = [
  // Compound matches that must come before their parts
  ['ice cream',  '🍦'],
  ['ice pop',    '🍡'],
  ['hot dog',    '🌭'],
  ['hot cocoa',  '☕'], ['hot chocolate', '☕'],
  ['baked good', '🥐'],

  // Breakfast / pastries
  ['pancake',  '🥞'], ['waffle',  '🧇'],
  ['bagel',    '🥯'],
  ['donut',    '🍩'], ['doughnut', '🍩'],
  ['croissant','🥐'], ['muffin',   '🧁'],
  ['cinnamon roll', '🥐'], ['pastry', '🥐'], ['toast', '🍞'], ['bread', '🍞'],
  ['cupcake',  '🧁'], ['cake',    '🍰'],
  ['cookie',   '🍪'],
  ['brownie',  '🍫'], ['chocolate', '🍫'],
  ['candy',    '🍬'], ['sweet',     '🍬'], ['treat', '🍬'],
  ['samosa',   '🥟'], ['dumpling',  '🥟'],

  // Main dishes
  ['pizza',    '🍕'],
  ['burger',   '🍔'], ['cheeseburger','🍔'], ['smashburger','🍔'],
  ['hot dog',  '🌭'],
  ['burrito',  '🌯'], ['quesadilla', '🌯'],
  ['taco',     '🌮'],
  ['sushi',    '🍣'],
  ['ramen',    '🍜'], ['noodle', '🍜'],
  ['pasta',    '🍝'], ['spaghetti', '🍝'], ['lasagna', '🍝'],
  ['curry',    '🍛'], ['naan',  '🍛'], ['tikka', '🍛'], ['masala', '🍛'], ['biryani', '🍛'],
  ['rice',     '🍚'], ['fried rice', '🍚'],
  ['sandwich', '🥪'], ['sub ',  '🥪'], ['wrap', '🥪'], ['panini', '🥪'],
  ['fries',    '🍟'], ['fry ', '🍟'],
  ['chicken nugget','🍗'], ['nugget',  '🍗'], ['chicken', '🍗'],
  ['bbq',      '🍖'], ['barbecue', '🍖'], ['ribs',  '🍖'],
  ['salad',    '🥗'], ['greens',   '🥗'],
  ['soup',     '🍲'], ['stew',    '🍲'], ['chili', '🌶️'],
  ['gyro',     '🥙'], ['shawarma', '🥙'], ['kebab', '🥙'], ['falafel', '🥙'],
  ['halal',    '🍱'], ['kosher', '🥨'],
  ['popcorn',  '🍿'],

  // Cuisines / chains (after specific dishes). Chipotle has to come before
  // the generic `chip` keyword so the burrito chain doesn't read as "chips".
  ['chipotle', '🌯'],
  ['indian',   '🍛'],
  ['chinese',  '🥡'], ['asian', '🥡'],
  ['mexican',  '🌮'],
  ['italian',  '🍝'],
  ['thai',     '🍜'],
  ['korean',   '🍱'], ['japanese', '🍣'],
  ['mediterranean','🥙'],

  // Snacks / categories — run BEFORE drinks so "snacks and drinks" reads
  // as snacks (the listed-first item).
  ['snack',    '🥨'], ['chip',     '🥨'], ['pretzel', '🥨'],
  ['fruit',    '🍎'], ['apple',   '🍎'], ['banana', '🍌'], ['berry', '🍓'],
  ['veggie',   '🥕'], ['vegetable','🥕'],
  ['breakfast','🍳'], ['egg',      '🥚'],
  ['goodie',   '🍬'], ['goody',    '🍬'],

  // Drinks
  ['lemonade', '🍋'], ['lemon',   '🍋'],
  ['coffee',   '☕'], ['latte',   '☕'], ['espresso', '☕'], ['cappuccino', '☕'],
  ['tea ',     '🍵'], ['boba',    '🧋'], ['bubble tea','🧋'],
  ['smoothie', '🥤'], ['milkshake','🥤'], ['shake', '🥤'],
  ['soda',     '🥤'], ['coke',    '🥤'], ['cola', '🥤'], ['pepsi', '🥤'], ['fanta', '🥤'],
  ['juice',    '🧃'],
  ['milk',     '🥛'],
  ['water',    '💧'], ['drink',   '🥤'],
];

export function foodEmoji(food) {
  if (!isFoodSpecified(food)) return '🍽️';
  const s = String(food).toLowerCase();
  for (const [needle, emoji] of FOOD_EMOJI_TABLE) {
    if (s.includes(needle)) return emoji;
  }
  return '🍽️';
}

// Pretty diet labels for chips. Keys are the kebab-case "chip ids" used by the
// FilterBar UI; values include the corresponding key on the backend's
// `dietary_info` object (which uses camelCase). The chip set matches the
// original site (5 restrictions + 4 allergies).
export const DIET_LABELS = {
  vegetarian:    { label: 'Vegetarian',  key: 'vegetarian' },
  vegan:         { label: 'Vegan',       key: 'vegan' },
  halal:         { label: 'Halal',       key: 'halal' },
  kosher:        { label: 'Kosher',      key: 'kosher' },
  'gluten-free': { label: 'Gluten-Free', key: 'glutenFree' },
  'nut-free':    { label: 'Nut-Free',    key: 'nutFree' },
  'dairy-free':  { label: 'Dairy-Free',  key: 'dairyFree' },
  'soy-free':    { label: 'Soy-Free',    key: 'soyFree' },
  'egg-free':    { label: 'Egg-Free',    key: 'eggFree' },
};

// Pretty quantity labels (legacy, currently unused by v2)
export const QUANTITY_LABELS = {
  plenty:       'Plenty',
  'some-left':  'Some left',
  'few-left':   'A few left',
  'going-fast': 'Going fast',
};

// Does this event clear the given dietary filters?
// Backend convention: `dietary_info.<key>` is `true | false | null`. We only
// HIDE events that are explicitly incompatible (false). Unknown (null) and
// missing dietary_info pass through — matches the original site so users see
// real results instead of a perpetually-empty feed.
export function eventMatchesDiet(ev, chipIds) {
  if (!chipIds || chipIds.length === 0) return true;
  const di = ev?.dietary_info;
  if (!di) return true;
  for (const id of chipIds) {
    const meta = DIET_LABELS[id];
    if (!meta) continue;
    if (di[meta.key] === false) return false;
  }
  return true;
}

// Chip ids the event explicitly satisfies (used to render the card's tag row).
export function getDietChips(ev) {
  const di = ev?.dietary_info;
  if (!di) return [];
  return Object.entries(DIET_LABELS)
    .filter(([_, meta]) => di[meta.key] === true)
    .map(([chipId]) => chipId);
}
