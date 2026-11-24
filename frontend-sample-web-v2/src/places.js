// Static "places" data ported verbatim from the original site:
// food pantries (ACE), Boilermaker convenience markets, On-the-GO grab-and-go,
// PMU Atlas Family Marketplace restaurants. Used to render extra map markers
// alongside the live free-food sightings.

export const FOOD_PANTRIES = [
  {
    name: 'ACE Campus Food Pantry (Main)',
    location: 'The Found (Baptist Student Foundation)',
    address: '200 N Russell St, West Lafayette',
    lat: 40.4265, lng: -86.9188,
    hours: 'Tue 12–6 PM, Sun 5–8 PM',
    description: 'Main pantry location for Purdue students, staff & faculty. Bring your PUID.',
  },
  {
    name: 'ACE Pantry Pop-Up — LCC',
    location: 'Latino Cultural Center',
    address: '426 Waldron St',
    lat: 40.4290, lng: -86.9176,
    hours: 'Mon 9 AM–5 PM',
    description: 'Pop-up pantry at the Latino Cultural Center. Bring your PUID.',
  },
  {
    name: 'ACE Pantry Pop-Up — CoRec',
    location: 'Córdova Recreational Sports Center',
    address: '355 N Martin Jischke Dr',
    lat: 40.4283, lng: -86.9223,
    hours: 'Mon–Fri 6 AM–10 PM',
    description: 'Pop-up pantry at the CoRec. Bring your PUID.',
  },
  {
    name: 'ACE Pantry Pop-Up — Vet School',
    location: 'Lynn Hall of Veterinary Medicine',
    address: '625 Harrison St',
    lat: 40.4195, lng: -86.9147,
    hours: 'Tue & Thu 11:30 AM–1:30 PM',
    description: 'Pop-up pantry at the Veterinary School. Bring your PUID.',
  },
  {
    name: 'ACE Pantry Pop-Up — Horizons',
    location: 'Krach Leadership Center',
    address: '1198 Third St',
    lat: 40.4276, lng: -86.9213,
    hours: 'Mon–Fri 9 AM–5 PM',
    description: 'Pop-up pantry at the Horizons office in Krach. Bring your PUID.',
  },
  {
    name: 'ACE Pantry Pop-Up — LGBTQ+ Center',
    location: 'John W. Hicks Undergraduate Library',
    address: 'LGBTQ+ Center, Hicks Undergraduate Library',
    lat: 40.4245478, lng: -86.9126638,
    hours: 'Check ACE website for schedule',
    description: 'Pop-up pantry at the LGBTQ+ Center in Hicks Undergraduate Library. Bring your PUID.',
  },
  {
    name: 'ACE Pantry Pop-Up — AAARCC',
    location: 'Asian American and Asian Resource and Cultural Center',
    address: 'AAARCC',
    lat: 40.4291, lng: -86.9177,
    hours: 'Check ACE website for schedule',
    description: 'Pop-up table at AAARCC. Bring your PUID.',
  },
];

export const BOILER_MARKETS = [
  { name: 'Boilermaker Market @ Winifred Parker Hall', location: 'Winifred Parker Residence Hall (3rd Street)',
    lat: 40.4277, lng: -86.9203, hours: 'Open 24 hours (self-checkout)',
    description: 'Convenience market with snacks, drinks, and essentials.' },
  { name: 'Boilermaker Market @ Harrison Hall', location: 'Benjamin Harrison Residence Hall',
    lat: 40.4251, lng: -86.9269, hours: 'Open 24 hours (self-checkout)',
    description: 'Convenience market with snacks, drinks, and essentials.' },
  { name: 'Boilermaker Market @ Hillenbrand Hall', location: 'Hillenbrand Residence Hall',
    lat: 40.4267, lng: -86.9267, hours: 'Open 24 hours (self-checkout)',
    description: 'Convenience market with snacks, drinks, and essentials.' },
  { name: 'Boilermaker Market @ PMU', location: 'Purdue Memorial Union',
    lat: 40.4248, lng: -86.9108, hours: 'Mon–Fri 8 AM–8 PM',
    description: 'Snacks, drinks, and supplies in the Union. Also offers Holy Bowls (Kosher grab-and-go).' },
  { name: 'Boilermaker Market @ Burton Morgan', location: 'Burton D. Morgan Center for Entrepreneurship',
    lat: 40.4238, lng: -86.9230, hours: 'Mon–Fri 8 AM–5 PM',
    description: 'Mini market with snacks and drinks near the entrepreneurship center.' },
  { name: 'Boilermaker Market @ Chaney-Hale', location: 'Chaney-Hale Hall of Science',
    lat: 40.4285, lng: -86.9155, hours: 'Open 24 hours (self-checkout)',
    description: 'New self-checkout convenience market in the science building.' },
];

export const ON_THE_GO = [
  { abbr: 'EOTG', name: 'Earhart On-the-GO!',  lat: 40.425797, lng: -86.924944, hours: 'Mon–Fri 6:30 AM–5 PM' },
  { abbr: 'FOTG', name: 'Ford On-the-GO!',     lat: 40.432082, lng: -86.919644, hours: 'Mon–Fri 6:30 AM–5 PM' },
  { abbr: 'LWSN', name: 'Lawson On-the-GO!',   lat: 40.427432, lng: -86.916988, hours: 'Mon–Fri 7:30 AM–5 PM' },
  { abbr: 'WOTG', name: 'Windsor On-the-GO!',  lat: 40.4268,   lng: -86.9210,   hours: 'Mon–Fri 6:30 AM–5 PM' },
];

// Source of truth: https://www.union.purdue.edu/dine/index.html
// Each `url` links to the venue's CampusDish page (menu + hours).
export const PMU_RESTAURANTS = [
  { name: "Walk-On's Sports Bistreaux",
    type: 'Louisiana-inspired sports bar', hours: 'Mon–Sat 11 AM–9 PM',
    url: 'https://purdue.campusdish.com/LocationsAndMenus/AtlasFamilyMarketplace/WalkOnsSportsBistreaux' },
  { name: 'Starbucks',
    type: 'Coffee & drinks', hours: 'Mon–Fri 7 AM–12 AM, Sat–Sun 8 AM–12 AM',
    url: 'https://purdue.campusdish.com/LocationsAndMenus/AtlasFamilyMarketplace/Starbucks' },
  { name: 'Burgers + Fries',
    type: 'Build-your-own burgers', hours: 'Mon–Fri 10:30 AM–8 PM',
    url: 'https://purdue.campusdish.com/LocationsAndMenus/AtlasFamilyMarketplace/BurgersandFries' },
  { name: 'Choolaah Indian BBQ',
    type: 'Fast-casual Indian BBQ', hours: 'Mon–Fri 10:30 AM–8 PM',
    url: 'https://purdue.campusdish.com/LocationsAndMenus/AtlasFamilyMarketplace/Choolaah' },
  { name: 'DSJ Asian Grill',
    type: 'Scratch-made Asian', hours: 'Mon–Fri 10:30 AM–8 PM',
    url: 'https://purdue.campusdish.com/LocationsAndMenus/AtlasFamilyMarketplace/DSJAsianGrill' },
  { name: 'FoodLab',
    type: 'Rotating concept · currently Scoops + Sweets', hours: 'Mon–Fri 10:30 AM–8 PM',
    url: 'https://purdue.campusdish.com/LocationsAndMenus/AtlasFamilyMarketplace/FoodLab' },
  { name: 'KNOW Eatery',
    type: 'Allergen-safe · vegan & vegetarian', hours: 'Mon–Fri 10:30 AM–8 PM',
    url: 'https://purdue.campusdish.com/LocationsAndMenus/KNOWEatery' },
  { name: 'Sushi Boss',
    type: 'Fresh custom sushi', hours: 'Mon–Fri 10:30 AM–8 PM',
    url: 'https://purdue.campusdish.com/LocationsAndMenus/AtlasFamilyMarketplace/SushiBoss' },
  { name: 'Tenders, Love & Chicken',
    type: 'Premium chicken tenders', hours: 'Mon–Fri 10:30 AM–8 PM',
    url: 'https://purdue.campusdish.com/LocationsAndMenus/AtlasFamilyMarketplace/Tenders-Love-and-Chicken' },
  { name: 'Zen',
    type: 'Sushi bowls, salads & boba', hours: 'Mon–Fri 10:30 AM–8 PM',
    url: 'https://purdue.campusdish.com/LocationsAndMenus/AtlasFamilyMarketplace/Zen' },
];

export const PMU_LAT = 40.4250;
export const PMU_LNG = -86.9113;

// Building-abbr → display name for Purdue dining courts (used to recognize them
// among the building polygons and render dining markers on top).
export const DINING_COURTS = {
  ERHT: 'Earhart',
  FORD: 'Ford',
  HILL: 'Hillenbrand',
  WDCT: 'Wiley',
  WDC:  'Windsor',
};

// Best-effort "is this place open right now?" — accepts free-form hour
// strings like "Mon–Fri 7 AM–5 PM" / "10:30 AM–8 PM" / "Open 24 hours".
// Returns boolean (defaults true for "always open" / unrecognized).
export function isLocationOpen(hours, now = new Date()) {
  if (!hours) return true;
  const h = String(hours).toLowerCase();
  if (h.includes('24 hours') || h.includes('check ')) return true;

  const dayMap = { sun:0, mon:1, tue:2, wed:3, thu:4, fri:5, sat:6 };
  const day = now.getDay();

  // Day-of-week filter
  let allowed = null;
  const range = h.match(/(sun|mon|tue|wed|thu|fri|sat)\s*[–-]\s*(sun|mon|tue|wed|thu|fri|sat)/);
  if (range) {
    const a = dayMap[range[1]], b = dayMap[range[2]];
    allowed = new Set();
    for (let i = a; ; i = (i + 1) % 7) { allowed.add(i); if (i === b) break; }
  } else {
    const single = h.match(/(sun|mon|tue|wed|thu|fri|sat)/g);
    if (single) allowed = new Set(single.map(d => dayMap[d]));
  }
  if (allowed && !allowed.has(day)) return false;

  // Time window — find first "X(:MM)?(am|pm) – Y(:MM)?(am|pm)"
  const t = h.match(/(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*[–-]\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)/);
  if (!t) return true;
  let [_, sH, sM, sP, eH, eM, eP] = t;
  sH = parseInt(sH, 10); sM = parseInt(sM || '0', 10);
  eH = parseInt(eH, 10); eM = parseInt(eM || '0', 10);
  if (sP === 'pm' && sH !== 12) sH += 12;
  if (sP === 'am' && sH === 12) sH = 0;
  if (eP === 'pm' && eH !== 12) eH += 12;
  if (eP === 'am' && eH === 12) eH = 0;
  const cur = now.getHours() * 60 + now.getMinutes();
  const open = sH * 60 + sM, close = eH * 60 + eM;
  if (close <= open) {
    // wraps midnight
    return cur >= open || cur < close;
  }
  return cur >= open && cur < close;
}

// Round lat/lng to a coarse cluster key so co-located services share a marker.
export function locKey(lat, lng) {
  return `${Math.round(lat * 1e4)}_${Math.round(lng * 1e4)}`;
}
