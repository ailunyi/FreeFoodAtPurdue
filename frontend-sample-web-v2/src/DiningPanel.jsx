// Dining-courts panel.
//
// Lists the 5 Purdue dining courts. Expand a card to fetch today's real menu
// from the backend (`/dining/{abbr}` — already cached server-side per day).
// By default it shows the "current" meal (or the next/first one when closed)
// and offers tabs to switch between meals plus an "All meals" view.

import { useState, useEffect, useRef, useMemo, useCallback } from 'react';
import { fetchDiningMenu, fetchDiningRankings, voteDiningCourt } from './api.js';
import {
  PMU_RESTAURANTS, BOILER_MARKETS, ON_THE_GO, FOOD_PANTRIES,
  isLocationOpen,
} from './places.js';

// Court id ↔ backend abbr ↔ display name. lat/lng pulled from /buildings so
// expanding a card can pan the map to the court.
const DINING_COURTS = [
  { id: 'wiley',       abbr: 'WDCT', name: 'Wiley',       location: 'South of Memorial Mall',
    lat: 40.4285421, lng: -86.9208612,
    hours: { breakfast: '7:00–10:00', lunch: '11:00–14:00', dinner: '17:00–21:00' },
    note: 'Late lunch until 4 pm Mon–Fri' },
  { id: 'earhart',     abbr: 'ERHT', name: 'Earhart',     location: 'Earhart Hall',
    lat: 40.425716,   lng: -86.9249651,
    hours: { breakfast: '7:00–10:30', lunch: '11:00–14:00', dinner: '17:00–21:00' },
    note: 'Best stir-fry on campus, allegedly' },
  { id: 'ford',        abbr: 'FORD', name: 'Ford',        location: 'Ford Hall',
    lat: 40.4320976,  lng: -86.9196732,
    hours: { breakfast: '7:00–10:00', lunch: '11:00–14:00', dinner: '17:00–21:00' },
    note: 'Closes for clean at 2 pm sharp' },
  { id: 'hillenbrand', abbr: 'HILL', name: 'Hillenbrand', location: 'Hillenbrand Hall',
    lat: 40.426687,   lng: -86.9266818,
    hours: { breakfast: '7:00–10:00', lunch: '11:00–14:00', dinner: '17:00–21:00' },
    note: 'Allergen-friendly station every meal' },
  { id: 'windsor',     abbr: 'WDC',  name: 'Windsor',     location: 'Windsor Halls',
    lat: 40.4267748,  lng: -86.9209875,
    hours: { brunch: '10:00–14:00', dinner: '17:00–20:00' },
    note: 'Smaller — brunch + dinner only' },
];

// Derive ranking display state from the server response. Leader = unique
// court with strictly more votes than #2 AND > 0 votes. Ties or all-zero
// produce no leader, keeping the crown's signal honest.
function deriveRankState(d) {
  const byAbbr = Object.fromEntries((d.rankings || []).map(r => [r.abbr, r]));
  const sorted = [...(d.rankings || [])].sort((a, b) => b.votes - a.votes);
  let leader = null;
  if (sorted.length === 1 && sorted[0].votes > 0) leader = sorted[0].abbr;
  else if (sorted.length >= 2 && sorted[0].votes > 0 && sorted[0].votes > sorted[1].votes) {
    leader = sorted[0].abbr;
  }
  return { date: d.date || '', byAbbr, leader };
}

// Optimistic update for an upvote toggle. Mirrors the server's tie-breaking
// rules so the UI doesn't flicker between local and authoritative state.
function optimisticToggle(prev, abbr) {
  const cur = prev.byAbbr[abbr] || { abbr, votes: 0, voted: false, rank: 99 };
  const nextEntry = {
    ...cur,
    voted: !cur.voted,
    votes: cur.votes + (cur.voted ? -1 : 1),
  };
  const nextByAbbr = { ...prev.byAbbr, [abbr]: nextEntry };
  // Re-derive leader from the optimistic state.
  const arr = Object.values(nextByAbbr).sort((a, b) => b.votes - a.votes);
  let leader = null;
  if (arr.length === 1 && arr[0].votes > 0) leader = arr[0].abbr;
  else if (arr.length >= 2 && arr[0].votes > 0 && arr[0].votes > arr[1].votes) {
    leader = arr[0].abbr;
  }
  return { ...prev, byAbbr: nextByAbbr, leader };
}

// "2026-04-28" → "Tue, Apr 28"
function prettyRankDate(iso) {
  if (!iso) return '';
  const d = new Date(iso + 'T12:00:00');
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' });
}

// Pans the live mapbox instance (exposed by Map.jsx via window.__ffp.map).
function panMap(lat, lng) {
  const m = (typeof window !== 'undefined' && window.__ffp && window.__ffp.map) || null;
  if (!m || lat == null || lng == null) return;
  try { m.easeTo({ center: [Number(lng), Number(lat)], duration: 600, essential: true }); } catch {}
}

// Compute the meal that's open right now (or null if closed).
function currentMealPeriod(court, now) {
  const h = now.getHours() + now.getMinutes() / 60;
  if (court.id === 'windsor') {
    if (h >= 10 && h < 14) return 'brunch';
    if (h >= 17 && h < 20) return 'dinner';
    return null;
  }
  if (h >= 7  && h < 10.5) return 'breakfast';
  if (h >= 11 && h < 14)   return 'lunch';
  if (h >= 17 && h < 21)   return 'dinner';
  return null;
}

function nextMealPeriod(court, now) {
  const h = now.getHours() + now.getMinutes() / 60;
  if (court.id === 'windsor') {
    if (h < 10) return { name: 'brunch', at: '10:00' };
    if (h < 17) return { name: 'dinner', at: '17:00' };
    return { name: 'brunch', at: 'tomorrow 10:00' };
  }
  if (h < 7)  return { name: 'breakfast', at: '7:00' };
  if (h < 11) return { name: 'lunch',     at: '11:00' };
  if (h < 17) return { name: 'dinner',    at: '17:00' };
  return { name: 'breakfast', at: 'tomorrow 7:00' };
}

const DIET_BADGE_COLORS = {
  V:  { bg: 'rgba(46,125,50,0.12)', fg: '#2e7d32' },
  Vg: { bg: 'rgba(46,125,50,0.18)', fg: '#1b5e20' },
  GF: { bg: 'rgba(193,68,14,0.10)', fg: '#8a3009' },
  H:  { bg: 'rgba(29,78,216,0.10)', fg: '#1d4ed8' },
};

function DietBadge({ tag }) {
  const c = DIET_BADGE_COLORS[tag] || { bg: 'var(--surface)', fg: 'var(--muted)' };
  return <span className="ffp-diet-badge" style={{ background: c.bg, color: c.fg }}>{tag}</span>;
}

// Items from the backend have { name, is_vegetarian, allergens: string[] }.
// Derive simple V / GF tags client-side so the UI stays consistent with
// the legacy ones used by the original site.
function deriveItemDietTags(item) {
  const tags = [];
  if (item.is_vegetarian) tags.push('V');
  const allergens = (item.allergens || []).map(a => String(a).toLowerCase());
  if (!allergens.some(a => a.includes('gluten') || a.includes('wheat'))) {
    // Only mark GF if no gluten allergen is listed — heuristic only.
  }
  return tags;
}

// Pick which meal to show by default given the API's meal list and now.
function pickInitialMeal(meals, court, now) {
  if (!meals || meals.length === 0) return null;
  const cur = currentMealPeriod(court, now);
  if (cur) {
    const m = meals.find(m => (m.name || '').toLowerCase().startsWith(cur.toLowerCase()));
    if (m) return m.name;
  }
  return meals[0].name;
}

function MealList({ meal, dietFilter }) {
  if (!meal || !meal.stations || meal.stations.length === 0) {
    return <div className="ffp-dcard-closed-note">No menu posted for this meal.</div>;
  }
  return (
    <div className="ffp-menu">
      {meal.stations.map((station, i) => {
        const items = (station.items || []).filter(it => itemMatchesFilter(it, dietFilter));
        if (items.length === 0 && (station.items || []).length > 0) return null;
        return (
          <div key={i} className="ffp-menu-station">
            <div className="ffp-menu-station-name">{station.name || 'Station'}</div>
            <ul>
              {items.length === 0
                ? <li className="ffp-menu-empty">No items match your filters</li>
                : items.map((it, j) => (
                  <li key={j}>
                    <span className="ffp-menu-item-name">{it.name}</span>
                    <span className="ffp-menu-item-diets">
                      {deriveItemDietTags(it).map(t => <DietBadge key={t} tag={t}/>)}
                    </span>
                  </li>
                ))}
            </ul>
          </div>
        );
      })}
    </div>
  );
}

function itemMatchesFilter(item, dietFilter) {
  if (!dietFilter || dietFilter.length === 0) return true;
  const allergens = (item.allergens || []).map(a => String(a).toLowerCase());
  for (const d of dietFilter) {
    if (d === 'vegetarian' || d === 'vegan') {
      if (!item.is_vegetarian) return false;
    } else if (d === 'gluten-free') {
      if (allergens.some(a => a.includes('gluten') || a.includes('wheat'))) return false;
    } else if (d === 'nut-free') {
      if (allergens.some(a => a.includes('nut') || a.includes('peanut'))) return false;
    } else if (d === 'dairy-free') {
      if (allergens.some(a => a.includes('milk') || a.includes('dairy'))) return false;
    } else if (d === 'soy-free') {
      if (allergens.some(a => a.includes('soy'))) return false;
    } else if (d === 'egg-free') {
      if (allergens.some(a => a.includes('egg'))) return false;
    }
    // halal / kosher — backend HFS feed doesn't expose these reliably, so we
    // don't filter on them at the dining-court level.
  }
  return true;
}

// Fetched-menu state per court. The deps deliberately do NOT include any
// state-derived values: when setState changes `loading` or `menu` it would
// re-run the effect, the cleanup (`alive=false`) would kill the in-flight
// fetch, and the resolved data would be silently discarded. A ref tracks
// whether we've already kicked off a fetch for this `abbr`.
function useDiningMenu(abbr, expanded) {
  const [state, setState] = useState({ loading: false, error: null, menu: null });
  const startedRef = useRef(false);

  useEffect(() => {
    if (!expanded || startedRef.current) return;
    startedRef.current = true;
    let alive = true;
    setState({ loading: true, error: null, menu: null });
    fetchDiningMenu(abbr)
      .then(data => { if (alive) setState({ loading: false, error: null, menu: data }); })
      .catch(err => {
        if (!alive) return;
        startedRef.current = false; // allow retry on re-expand
        setState({ loading: false, error: err.message || 'Could not load menu', menu: null });
      });
    return () => { alive = false; };
  }, [expanded, abbr]);

  return state;
}

function CourtCard({
  court, isExpanded, onToggle, dietFilter, now, focusEl,
  voteCount = 0, voted = false, isLeader = false, onUpvote,
}) {
  const period = currentMealPeriod(court, now);
  const next = nextMealPeriod(court, now);
  const isOpen = !!period;
  const { loading, error, menu } = useDiningMenu(court.abbr, isExpanded);

  const meals = menu?.meals || [];
  const [selected, setSelected] = useState(null); // meal name

  // When the menu first arrives, pick the current/next meal as default.
  useEffect(() => {
    if (!menu || selected) return;
    const initial = pickInitialMeal(meals, court, now);
    if (initial) setSelected(initial);
  }, [menu]); // eslint-disable-line react-hooks/exhaustive-deps

  const activeMeal = meals.find(m => m.name === selected);

  return (
    <article
      ref={focusEl}
      className={`ffp-dcard ${isExpanded ? 'open' : ''} ${!isOpen ? 'closed' : ''} ${isLeader ? 'has-leader' : ''}`}>
      <button
        className={`ffp-dcard-head ${isLeader ? 'is-leader' : ''}`}
        onClick={() => { panMap(court.lat, court.lng); onToggle(); }}
        aria-expanded={isExpanded}>
        <div className="ffp-dcard-name">
          <div className="ffp-dcard-title-row">
            {isLeader && (
              <span className="ffp-dcard-crown" aria-label="Top-ranked today" title="Top-ranked today">👑</span>
            )}
            <span
              className={`ffp-dcard-status ${isOpen ? 'open' : 'closed'}`}
              style={isOpen ? { background: 'var(--accent)' } : null}>
              {isOpen ? period.toUpperCase() : 'CLOSED'}
            </span>
            <h3>{court.name}</h3>
          </div>
          <div className="ffp-dcard-meta">
            {isOpen
              ? <span>Until {court.hours[period]?.split('–')[1] || '—'}</span>
              : <span>Next: {next.name} at {next.at}</span>
            }
          </div>
        </div>
        <div className="ffp-dcard-actions">
          <span
            role="button"
            tabIndex={0}
            className={`ffp-dcard-upvote ${voted ? 'on' : ''}`}
            title={voted ? 'Remove your vote' : "Upvote this dining court for today"}
            aria-label={voted ? 'Remove your vote' : "Upvote this dining court for today"}
            aria-pressed={voted}
            onClick={(e) => { e.stopPropagation(); onUpvote?.(); }}
            onKeyDown={(e) => {
              if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault(); e.stopPropagation(); onUpvote?.();
              }
            }}>
            <svg width="11" height="11" viewBox="0 0 12 12">
              <path d="M6 1.5 L10.5 7 H7.5 V10.5 H4.5 V7 H1.5 Z"
                    fill={voted ? 'currentColor' : 'none'}
                    stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round"/>
            </svg>
            <span>{voteCount}</span>
          </span>
          <svg
            className="ffp-dcard-chev" width="14" height="14" viewBox="0 0 14 14"
            style={{ transform: isExpanded ? 'rotate(180deg)' : 'rotate(0)' }}>
            <path d="M3 5 L7 9 L11 5" stroke="#9a7d62" strokeWidth="1.5" fill="none" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        </div>
      </button>

      {isExpanded && (
        <div className="ffp-dcard-body">
          {loading && <div className="ffp-dcard-closed-note">Loading menu…</div>}
          {error && <div className="ffp-dcard-closed-note">Menu unavailable right now.</div>}
          {menu && meals.length === 0 && (
            <div className="ffp-dcard-closed-note">
              No menu posted for today. Hours: {Object.entries(court.hours).map(([k,v]) => `${k} ${v}`).join(' · ')}
            </div>
          )}
          {menu && meals.length > 0 && (
            <>
              <div className="ffp-meal-tabs" role="tablist" aria-label="Meals">
                {meals.map(m => {
                  const on = selected === m.name;
                  const isCurrent = period && (m.name || '').toLowerCase().startsWith(period);
                  return (
                    <button key={m.name} role="tab" aria-selected={on}
                            className={`ffp-meal-tab ${on ? 'on' : ''} ${isCurrent ? 'now' : ''}`}
                            onClick={() => setSelected(m.name)}>
                      {m.name}
                    </button>
                  );
                })}
              </div>

              <MealList meal={activeMeal} dietFilter={dietFilter}/>
            </>
          )}

          <div className="ffp-dcard-foot">
            <span className="ffp-muted">{court.note}</span>
            <span className="ffp-muted">·</span>
            <span className="ffp-muted">{court.location}</span>
          </div>
        </div>
      )}
    </article>
  );
}

export default function DiningPanel({ dietFilter = [], focusId = null }) {
  const now = new Date();
  // Start with all courts collapsed; only auto-open when the user arrived
  // from a dining-court marker click on the map (focusId provided).
  const [openId, setOpenId] = useState(focusId || null);
  const cardRefs = useRef({});

  // Daily rankings — fetched on mount, refreshed after each vote. Optimistic
  // updates make the upvote feel instant; the response then patches with the
  // authoritative count.
  const [rank, setRank] = useState({ date: '', byAbbr: {}, leader: null });
  const refreshRankings = useCallback(() => {
    fetchDiningRankings()
      .then(d => setRank(deriveRankState(d)))
      .catch(() => { /* swallow — dining still works without rankings */ });
  }, []);
  useEffect(() => { refreshRankings(); }, [refreshRankings]);

  // Sort the visible courts by rank (top first). Ties keep their declared
  // order — `Array.prototype.sort` is stable in modern engines.
  const orderedCourts = useMemo(() => {
    const score = (c) => rank.byAbbr[c.abbr]?.rank ?? 999;
    return [...DINING_COURTS].sort((a, b) => score(a) - score(b));
  }, [rank]);

  // Optimistic toggle, then reconcile with the server's authoritative count.
  const onUpvote = useCallback(async (abbr) => {
    setRank(prev => optimisticToggle(prev, abbr));
    try {
      await voteDiningCourt(abbr);
    } finally {
      // Re-derive from the server even on failure, so we don't drift.
      refreshRankings();
    }
  }, [refreshRankings]);

  useEffect(() => {
    if (!focusId) return;
    // Only auto-expand a card when the focus key is a court id; place keys
    // (otg:*, market:*, pmu, pantry:*) just scroll to their card.
    if (DINING_COURTS.some(c => c.id === focusId)) setOpenId(focusId);
    const el = cardRefs.current[focusId];
    if (el) setTimeout(() => el.scrollIntoView({ behavior: 'smooth', block: 'start' }), 30);
  }, [focusId]);

  return (
    <div className="ffp-dining">
      <div className="ffp-dining-header">
        <div>
          <h2 className="ffp-dining-title">Dining</h2>
          <p className="ffp-dining-sub">
            Today · {now.toLocaleDateString([], { weekday:'long', month:'short', day:'numeric' })}
          </p>
        </div>
        <span className="ffp-livecount" style={{ borderRadius: 999 }}>
          <span className="ffp-livecount-dot" style={{ background: 'var(--accent)' }}/>
          {DINING_COURTS.filter(c => currentMealPeriod(c, now)).length} open now
        </span>
      </div>

      <div className="ffp-dining-list">
        {/* Today's-rankings banner — pill on the left, date on the right. */}
        <div className="ffp-rank-banner">
          <span className="ffp-rank-banner-pill">Today's rankings</span>
          <span className="ffp-rank-banner-date">
            {prettyRankDate(rank.date) || now.toLocaleDateString([], { weekday:'short', month:'short', day:'numeric' })}
          </span>
        </div>
        {orderedCourts.map(court => {
          const r = rank.byAbbr[court.abbr];
          return (
            <CourtCard
              key={court.id}
              court={court}
              isExpanded={openId === court.id}
              onToggle={() => setOpenId(id => id === court.id ? null : court.id)}
              dietFilter={dietFilter}
              now={now}
              focusEl={(el) => { cardRefs.current[court.id] = el; }}
              voteCount={r?.votes ?? 0}
              voted={!!r?.voted}
              isLeader={rank.leader === court.abbr}
              onUpvote={() => onUpvote(court.abbr)}
            />
          );
        })}

        <div className="ffp-place-section">On-the-GO!</div>
        {ON_THE_GO.map(p => (
          <PlaceCard key={p.abbr}
                     emoji="🏪"
                     stripe="#8e44ad"
                     name={p.name}
                     hours={p.hours}
                     lat={p.lat} lng={p.lng}
                     focusEl={(el) => { cardRefs.current[`otg:${p.abbr}`] = el; }}
                     highlighted={focusId === `otg:${p.abbr}`}
                     open={isLocationOpen(p.hours, now)}/>
        ))}

        <div className="ffp-place-section">Boilermaker Markets</div>
        {BOILER_MARKETS.map(p => (
          <PlaceCard key={p.name}
                     emoji="🏪"
                     stripe="#e67e22"
                     name={p.name}
                     subtitle={p.location}
                     description={p.description}
                     hours={p.hours}
                     lat={p.lat} lng={p.lng}
                     focusEl={(el) => { cardRefs.current[`market:${p.name}`] = el; }}
                     highlighted={focusId === `market:${p.name}`}
                     open={isLocationOpen(p.hours, now)}/>
        ))}

        <div
          className={`ffp-place-section${focusId === 'pmu' ? ' ffp-place-section-highlighted' : ''}`}
          ref={(el) => { cardRefs.current['pmu'] = el; }}>PMU restaurants</div>
        {PMU_RESTAURANTS.map(r => (
          <PlaceCard key={r.name}
                     emoji="🍴"
                     stripe="#c0392b"
                     name={r.name}
                     subtitle={r.type}
                     hours={r.hours}
                     lat={40.4250} lng={-86.9113}  /* PMU centroid */
                     url={r.url}
                     open={isLocationOpen(r.hours, now)}/>
        ))}

        <div className="ffp-place-section">ACE food pantries</div>
        {FOOD_PANTRIES.map(p => (
          <PlaceCard key={p.name}
                     emoji="🥫"
                     stripe="#6aa84f"
                     name={p.name}
                     subtitle={p.location}
                     description={p.description}
                     hours={p.hours}
                     lat={p.lat} lng={p.lng}
                     extraTag="Free with PUID"
                     focusEl={(el) => { cardRefs.current[`pantry:${p.name}`] = el; }}
                     highlighted={focusId === `pantry:${p.name}`}
                     open={isLocationOpen(p.hours, now)}/>
        ))}
      </div>
    </div>
  );
}

// Compact place card used for non-dining-court rows in the Dining tab.
// Clicking the card pans the map to the place.
function PlaceCard({ emoji, stripe, name, subtitle, description, hours, open, extraTag,
                    lat, lng, url, focusEl, highlighted }) {
  const onClick = () => panMap(lat, lng);
  return (
    <article
      ref={focusEl}
      className={`ffp-place-card${highlighted ? ' ffp-place-card-highlighted' : ''}`}
      style={{ borderLeft: `3px solid ${stripe}`, cursor: lat != null ? 'pointer' : 'default' }}
      role={lat != null ? 'button' : undefined}
      tabIndex={lat != null ? 0 : undefined}
      onClick={onClick}
      onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onClick(); } }}>
      <div className="ffp-place-head">
        <div className="ffp-place-emoji">{emoji}</div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div className="ffp-place-name">
            {url ? (
              <a href={url} target="_blank" rel="noopener"
                 onClick={(e) => e.stopPropagation()}
                 style={{ color: 'inherit', textDecoration: 'none', borderBottom: '1px dotted var(--muted)' }}>
                {name} ↗
              </a>
            ) : name}
          </div>
          {subtitle && <div className="ffp-place-sub">{subtitle}</div>}
        </div>
        {open !== undefined && (
          <span className="ffp-place-status" style={open
            ? { background: 'rgba(46,125,50,.12)', color: '#2e7d32' }
            : { background: 'rgba(154,125,98,.12)', color: '#9a7d62' }}>
            {open ? 'Open' : 'Closed'}
          </span>
        )}
      </div>
      {description && <div className="ffp-place-desc">{description}</div>}
      <div className="ffp-place-tags">
        {hours && <span className="ffp-tag">🕐 {hours}</span>}
        {extraTag && <span className="ffp-tag">{extraTag}</span>}
      </div>
    </article>
  );
}
