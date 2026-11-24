import { useEffect, useMemo, useState, useCallback, useRef } from 'react';
import * as api from './api.js';
import {
  eventStatus, eventMatchesDiet, parseDate, isExpired, isUpcoming, haversineMeters,
} from './helpers.js';
import { useSaved } from './useSaved.js';
import { useReminders } from './useReminders.js';
import { humanOffset } from './ReminderPopover.jsx';
import { useRoute, navigate } from './router.js';
import { applyHomeSeo, applyEventSeo } from './seo.js';
import Header from './Header.jsx';
import CampusMap from './Map.jsx';
import FilterBar from './FilterBar.jsx';
import SightingCard from './SightingCard.jsx';
import EventDetail from './EventDetail.jsx';
import DiningPanel from './DiningPanel.jsx';
import SubmitModal from './SubmitModal.jsx';
import SpotFab from './SpotFab.jsx';
import BuildingInfo from './BuildingInfo.jsx';
import Toast from './Toast.jsx';

const POLL_MS = 60_000;

export default function App() {
  const [route] = useRoute();
  const [events, setEvents] = useState([]);
  const [loaded, setLoaded] = useState(false);
  const [loadError, setLoadError] = useState(null);
  const [search, setSearch] = useState('');
  const [diets, setDiets] = useState([]);
  const [sort, setSort] = useState('recommended');
  const [hoveredId, setHoveredId] = useState(null);
  const [submitOpen, setSubmitOpen] = useState(false);
  const [submitContext, setSubmitContext] = useState(null); // null | {lat,lng,buildingAbbr,outsideBuilding,hint}
  const [sidebarCollapsed, setSidebarCollapsed] = useState(false);
  const [mobileTab, setMobileTab] = useState('map');
  const [toasts, setToasts] = useState([]);
  const [buildingFilter, setBuildingFilter] = useState(null); // {abbr,name} | null
  const [placeFocus, setPlaceFocus] = useState(null);          // service group | null
  const [feedFilter, setFeedFilter] = useState('today');       // 'today' | 'upcoming'
  const [diningFocusId, setDiningFocusId] = useState(null);    // wiley|earhart|ford|hillenbrand|windsor
  const [showPast, setShowPast] = useState(false);             // Today tab: also show recently-ended events
  const [freeOnly, setFreeOnly] = useState(false);             // hide paid events
  const [userPos, setUserPos] = useState(null);                // {lat,lng} | null — set by Mapbox geolocate
  const { has: hasSaved, toggle: toggleSaved, count: savedCount } = useSaved();
  const reminders = useReminders();
  const toastSeq = useRef(0);
  const mapRef = useRef(null);

  // Toast helper
  const showToast = useCallback((msg) => {
    const id = ++toastSeq.current;
    setToasts(t => [...t, { id, msg }]);
    setTimeout(() => setToasts(t => t.filter(x => x.id !== id)), 2400);
  }, []);

  const fetchEventsNow = useCallback(async () => {
    try {
      const data = await api.fetchEvents();
      setEvents(Array.isArray(data) ? data : []);
      setLoadError(null);
    } catch (err) {
      console.error('[fetchEvents]', err);
      setLoadError(err.message || 'Failed to load events.');
    } finally {
      setLoaded(true);
    }
  }, []);

  useEffect(() => {
    let alive = true;
    const run = async () => { if (alive) await fetchEventsNow(); };
    run();
    const id = setInterval(() => { if (alive) fetchEventsNow(); }, POLL_MS);
    return () => { alive = false; clearInterval(id); };
  }, [fetchEventsNow]);

  // Reminder cleanup — when the event list refreshes, drop reminders for
  // events that have been removed or already started/expired so the user
  // doesn't get stale notifications.
  useEffect(() => {
    if (!events.length) return;
    const byId = new Map(events.map(e => [String(e.id), e]));
    for (const id of reminders.ids()) {
      const ev = byId.get(id);
      // If the event is gone from the active set OR already started, purge.
      if (!ev) { reminders.clear(id); continue; }
      const start = parseDate(ev.starts_at)?.getTime();
      if (!start || start <= Date.now()) reminders.clear(id);
    }
  }, [events, reminders]);

  const view = route.name === 'saved' ? 'saved'
             : route.name === 'dining' ? 'dining'
             : 'all';

  const focused = route.name === 'event'
    ? events.find(e => String(e.id) === String(route.id))
    : null;

  // Update SEO
  useEffect(() => {
    if (route.name === 'event') {
      if (focused) applyEventSeo(focused);
    } else {
      applyHomeSeo();
    }
  }, [route.name, route.id, focused?.id, focused?.name]);

  // When the user focuses an event / building / place, make sure the
  // sidebar is visible — otherwise the click silently triggers content the
  // user can't see. On phones we additionally flip the bottom mobile-tab
  // switcher to the Feed pane.
  useEffect(() => {
    if (!(route.name === 'event' || buildingFilter || placeFocus)) return;
    setSidebarCollapsed(false);
    if (typeof window !== 'undefined' && window.matchMedia('(max-width: 760px)').matches) {
      setMobileTab('feed');
    }
  }, [route.name, route.id, buildingFilter, placeFocus]);

  // (No auto-clear of buildingFilter / placeFocus on route change. The
  // previous version did this in an effect, which raced with onBuildingClick:
  // setBuildingFilter(b) → navigate('/') → effect saw route='home' → cleared
  // the filter we just set. Filters are now explicitly cleared by the Header
  // tab callbacks and onUnfocus instead.)

  // Diet filter — loose semantics: only hides events explicitly marked
  // incompatible (false) for any selected restriction. Null / unknown passes.
  const matchesDiet = useCallback((ev) => eventMatchesDiet(ev, diets), [diets]);

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    return events.filter(ev => {
      if (!matchesDiet(ev)) return false;
      // Free-only: hide events explicitly marked paid. Default-undefined → free.
      if (freeOnly && ev.is_free === 0) return false;
      if (!q) return true;
      const hay = [ev.name, ev.food_type, ev.description, ev.building, ev.building_abbr, ev.room]
        .filter(Boolean).join(' ').toLowerCase();
      return hay.includes(q);
    });
  }, [events, search, matchesDiet, freeOnly]);

  const sorted = useMemo(() => {
    const arr = [...filtered];
    const distOf = (ev) =>
      (userPos && ev.lat != null && ev.lng != null)
        ? haversineMeters(userPos.lat, userPos.lng, Number(ev.lat), Number(ev.lng))
        : Infinity;

    if (sort === 'recent') {
      arr.sort((a, b) => (parseDate(b.created_at)?.getTime() ?? 0) - (parseDate(a.created_at)?.getTime() ?? 0));
    } else if (sort === 'popular') {
      arr.sort((a, b) => (b.going_count || 0) - (a.going_count || 0));
    } else if (sort === 'distance') {
      arr.sort((a, b) => distOf(a) - distOf(b));
    } else if (sort === 'recommended' && userPos) {
      // Blend urgency + distance. Convert time-left to minutes and add a
      // distance penalty in the same units (~80m per minute, roughly walking
      // pace). Expired events are pushed to the bottom; upcoming events go
      // after live ones.
      const now = Date.now();
      const score = (ev) => {
        if (isExpired(ev)) return 1e15;
        const dPenalty = distOf(ev) === Infinity ? 30 : (distOf(ev) / 80);
        if (isUpcoming(ev)) {
          const startMin = ((parseDate(ev.starts_at)?.getTime() || 0) - now) / 60_000;
          return 1e6 + startMin + dPenalty;
        }
        const endMin = ((parseDate(ev.expires_at)?.getTime() || 0) - now) / 60_000;
        return endMin + dPenalty;
      };
      arr.sort((a, b) => score(a) - score(b));
    } else {
      // 'time' sort, also the fallback for 'recommended' when no userPos.
      const now = Date.now();
      const score = (ev) => {
        if (isExpired(ev)) return 1e15;
        if (isUpcoming(ev)) return (parseDate(ev.starts_at)?.getTime() || 0) - now + 1e10;
        return (parseDate(ev.expires_at)?.getTime() || 0) - now;
      };
      arr.sort((a, b) => score(a) - score(b));
    }
    return arr;
  }, [filtered, sort, userPos]);

  // "Today" / "Next 3 Days" partition — mirrors the original site's
  // setPanelFilter logic. Today = active and not flagged gone, with starts_at
  // before now+24h. Next 3 Days = events whose starts_at lies between
  // now+24h and now+72h.
  const ONE_DAY_MS = 24 * 3600_000;
  const todayEvents = useMemo(() => {
    const now = Date.now();
    return sorted.filter(ev => {
      if (!(ev.is_active && (ev.gone_count || 0) < 2)) return false;
      const start = parseDate(ev.starts_at)?.getTime() ?? 0;
      return start <= now + ONE_DAY_MS;
    });
  }, [sorted]);
  const upcomingEvents = useMemo(() => {
    const now = Date.now();
    return sorted.filter(ev => {
      const start = parseDate(ev.starts_at)?.getTime();
      return start && start > now + ONE_DAY_MS && start <= now + 3 * ONE_DAY_MS;
    });
  }, [sorted]);

  // "Past" = recently-finished events shown beneath Today on demand. Mirrors
  // the original site (frontend-sample-web/index.html:1308-1316): a 48-hour
  // window keyed off `starts_at` (or `created_at` as fallback), excluding
  // anything currently active. This is much more inclusive than a strict
  // expires_at-based filter — buildings that hosted an event yesterday still
  // have it visible.
  const pastEvents = useMemo(() => {
    const now = Date.now();
    const past48h = now - 2 * ONE_DAY_MS;
    const isReallyActive = (e) => e.is_active && (e.gone_count || 0) < 2;
    return sorted.filter(ev => {
      if (isReallyActive(ev)) return false;
      const refIso = ev.starts_at || ev.created_at;
      const ref = parseDate(refIso)?.getTime();
      return ref && ref >= past48h && ref <= now;
    });
  }, [sorted]);

  const savedSightings = useMemo(
    () => events.filter(ev => hasSaved(ev.id)),
    [events, hasSaved],
  );

  // Map pins:
  //   - Saved tab → only saved events (regardless of time window)
  //   - All other tabs → respect the active Today / Next 3 Days filter
  // (Dining tab hides food pins entirely — handled separately below.)
  const mapEvents = useMemo(() => {
    if (view === 'saved') return savedSightings;
    return feedFilter === 'today' ? todayEvents : upcomingEvents;
  }, [view, savedSightings, feedFilter, todayEvents, upcomingEvents]);

  const activeCount = useMemo(() => {
    return events.filter(ev => {
      const s = eventStatus(ev);
      return s === 'live' || s === 'expiring';
    }).length;
  }, [events]);

  // Events at a specific building. Three pools mirror the home view —
  // Today, Next 3 Days, and Past — so the building feed has the same
  // structure (active list + Show past events button under Today).
  // Match events to a building. The two data sources disagree on naming —
  // ArcGIS polygons use abbreviations like 'HILL' and full names like
  // 'Hillenbrand Residence Hall', while events often carry Google Places IDs
  // (e.g. 'GPLEF661EED') and shorter names ('Hillenbrand Hall'). To resolve
  // this we rely on the polygon's `aliases` array (curated in the buildings
  // DB) — the polygon click attaches aliases, and we accept any event whose
  // `building` matches the polygon's full_name OR any alias.
  const matchesBuilding = useMemo(() => {
    if (!buildingFilter) return () => false;
    const abbr = buildingFilter.abbr;
    const name = buildingFilter.name;
    const aliasSet = new Set(
      [name, ...(buildingFilter.aliases || [])]
        .filter(Boolean)
        .map(a => String(a).trim().toLowerCase()),
    );
    return (ev) => {
      if (abbr && ev.building_abbr === abbr) return true;
      const evBldg = (ev.building || '').trim().toLowerCase();
      return !!evBldg && aliasSet.has(evBldg);
    };
  }, [buildingFilter]);

  const buildingEvents = useMemo(() => {
    if (!buildingFilter) return [];
    const pool = feedFilter === 'today' ? todayEvents : upcomingEvents;
    return pool.filter(matchesBuilding);
  }, [feedFilter, todayEvents, upcomingEvents, matchesBuilding, buildingFilter]);

  const buildingPastEvents = useMemo(() => {
    if (!buildingFilter) return [];
    return pastEvents.filter(matchesBuilding);
  }, [pastEvents, matchesBuilding, buildingFilter]);

  // Handlers
  const onFocus = useCallback((id) => {
    if (id == null) { navigate('/'); return; }
    setBuildingFilter(null);
    setPlaceFocus(null);
    const ev = events.find(e => String(e.id) === String(id));
    if (ev?.lat != null && ev?.lng != null && mapRef.current) {
      try { mapRef.current.easeTo({ center: [Number(ev.lng), Number(ev.lat)], duration: 600, essential: true }); } catch {}
    }
    navigate(`/event/${encodeURIComponent(id)}`);
  }, [events]);
  const onUnfocus = useCallback(() => {
    if (buildingFilter) { setBuildingFilter(null); navigate('/'); return; }
    if (placeFocus)     { setPlaceFocus(null); navigate('/'); return; }
    navigate(view === 'saved' ? '/saved' : view === 'dining' ? '/dining' : '/');
  }, [view, buildingFilter, placeFocus]);

  const onGoing = useCallback(async (ev) => {
    try {
      const d = await api.voteGoing(ev.id);
      setEvents(prev => prev.map(x => x.id === ev.id ? { ...x, going_count: d.going_count } : x));
      const key = `fap_vote_${ev.id}_going`;
      if (d.active) localStorage.setItem(key, '1'); else localStorage.removeItem(key);
      showToast(d.active
        ? `${d.going_count} ${d.going_count === 1 ? 'person' : 'people'} heading there!`
        : "You're no longer marked as going.");
    } catch { showToast('Could not record your vote — try again.'); }
  }, [showToast]);

  const onGone = useCallback(async (ev) => {
    try {
      const d = await api.voteGone(ev.id);
      setEvents(prev => prev.map(x => x.id === ev.id ? { ...x, gone_count: d.gone_count } : x));
      const key = `fap_vote_${ev.id}_gone`;
      if (d.active) localStorage.setItem(key, '1'); else localStorage.removeItem(key);
      showToast(d.active
        ? (d.gone_count >= 2 ? 'Food marked as gone.' : 'Thanks for the report!')
        : "You've removed your report.");
    } catch { showToast('Could not record your vote — try again.'); }
  }, [showToast]);

  const onSave = useCallback((ev) => {
    const before = hasSaved(ev.id);
    toggleSaved(ev.id);
    showToast(before ? 'Removed from saved' : 'Saved for later');
  }, [hasSaved, toggleSaved, showToast]);

  // "Interested" on upcoming events is a relabelled `/going` vote — same
  // backend, same toggle semantics, same localStorage key. The UI just shows
  // it as "Interested · N" instead of "I'm going · N" while the event is
  // upcoming. See plan: this single counter avoids any double-counting once
  // the event flips to live.
  const onInterested = onGoing;

  const onSetReminder = useCallback((ev, offsetMs) => {
    const start = parseDate(ev.starts_at)?.getTime();
    if (!start || start - offsetMs <= Date.now() + 30_000) {
      showToast('That reminder time has already passed.');
      return;
    }
    reminders.set(ev.id, start - offsetMs, {
      title: `🍽️ ${ev.name || ev.food_type || 'Free food'} starts soon`,
      body: `${ev.building || 'Purdue campus'} · in ${humanOffset(offsetMs)}`,
    });
    showToast(`Reminder set for ${humanOffset(offsetMs)} before`);
  }, [reminders, showToast]);

  const onClearReminder = useCallback((ev) => {
    reminders.clear(ev.id);
    showToast('Reminder cleared');
  }, [reminders, showToast]);

  const hasReminder = reminders.has;

  const onShare = useCallback(async (ev) => {
    const url = `${window.location.origin}/event/${encodeURIComponent(ev.id)}`;
    try {
      await navigator.clipboard.writeText(url);
      showToast('Link copied to clipboard');
    } catch {
      // Last-resort fallback when clipboard API is blocked (rare on http).
      window.prompt('Copy this link:', url);
    }
  }, [showToast]);

  const onSubmitted = useCallback((data) => {
    showToast(`Got it! ${data?.foodType || 'Food event'} added.`);
    fetchEventsNow();
    if (data?.lat && data?.lng && mapRef.current) {
      try {
        mapRef.current.flyTo({ center: [data.lng, data.lat], zoom: 17, speed: 1.2, curve: 1.4, essential: true });
      } catch {}
    }
  }, [fetchEventsNow, showToast]);

  // Map handlers
  const onMapReady = useCallback((map) => { mapRef.current = map; }, []);
  const onBuildingClick = useCallback((b) => {
    setPlaceFocus(null);
    setBuildingFilter(b);
    navigate('/');
  }, []);
  // Map abbr (backend convention) to the DiningPanel's internal court id.
  const ABBR_TO_PANEL_ID = { WDCT: 'wiley', ERHT: 'earhart', FORD: 'ford', HILL: 'hillenbrand', WDC: 'windsor' };

  // Build a stable focus key shared between the marker (Map.jsx) and the
  // matching card in DiningPanel.jsx. Every place type now scrolls to its
  // card in the Dining panel rather than opening a separate detail panel.
  const placeFocusKey = useCallback((svc) => {
    if (!svc) return null;
    if (svc.type === 'dining') return ABBR_TO_PANEL_ID[svc.data?.abbr] || null;
    if (svc.type === 'otg')    return `otg:${svc.data?.abbr}`;
    if (svc.type === 'market') return `market:${svc.data?.name}`;
    if (svc.type === 'pantry') return `pantry:${svc.data?.name}`;
    if (svc.type === 'pmu')    return 'pmu';
    return null;
  }, []);

  const onPlaceClick = useCallback((group) => {
    setBuildingFilter(null);
    setPlaceFocus(null);
    setDiningFocusId(placeFocusKey(group.services?.[0]));
    navigate('/dining');
  }, [placeFocusKey]);

  // FAB: opens modal with a drag-detected location, or null for tap-to-open
  const onFabOpen = useCallback((ctx) => {
    setSubmitContext(ctx); // null or {lat,lng,buildingAbbr,outsideBuilding,hint}
    setSubmitOpen(true);
  }, []);

  const cardCommon = {
    onOpen: onFocus,
    onGoing, onGone, onSave,
    onInterested, onSetReminder, onClearReminder, hasReminder,
    hasSaved,
  };

  return (
    <div className="ffp-app">
      <Header
        view={view}
        liveCount={activeCount}
        savedCount={savedCount}
        sidebarCollapsed={sidebarCollapsed}
        onToggleSidebar={() => setSidebarCollapsed(c => !c)}
        onChangeView={(v) => {
          // Switching top-level tabs always drops any building / place focus.
          setBuildingFilter(null);
          setPlaceFocus(null);
          if (v === 'dining') setDiningFocusId(null);
          navigate(v === 'all' ? '/' : v === 'saved' ? '/saved' : '/dining');
        }}
      />

      <div className={`ffp-main ffp-mobile-${mobileTab}`}>
        <div className="ffp-mapwrap">
          <CampusMap
            events={mapEvents}
            focusedId={focused?.id ?? null}
            focusedBuildingAbbr={buildingFilter?.abbr ?? null}
            onFocus={onFocus}
            hoveredId={hoveredId}
            onHover={setHoveredId}
            onBuildingClick={onBuildingClick}
            onPlaceClick={onPlaceClick}
            onMapReady={onMapReady}
            onUserPos={setUserPos}
            focusedPlaceKey={view === 'dining' ? diningFocusId : null}
            showPlaces={view === 'dining'}
            showEvents={view !== 'dining'}
          />
          <div className="ffp-map-overlay">
            <div className="ffp-legend">
              <div style={{fontWeight:600,fontSize:10.5,letterSpacing:'0.06em',textTransform:'uppercase',color:'var(--muted)'}}>Map key</div>
              <div className="ffp-legend-item"><span className="ffp-legend-dot" style={{background:'var(--accent)',borderColor:'#2e1e0f'}}/> Live now</div>
              <div className="ffp-legend-item"><span className="ffp-legend-dot" style={{background:'#f4c430',borderColor:'#2e1e0f'}}/> Upcoming</div>
            </div>
          </div>
        </div>

        <div className="ffp-mobile-switch">
          <button className={`ffp-mobile-switch-btn ${mobileTab==='map' ? 'on' : ''}`}
                  onClick={() => setMobileTab('map')}
                  style={mobileTab==='map' ? {background:'var(--accent)', borderColor:'var(--accent)'} : {}}>
            <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
              <path d="M5 2 L1 3.5 V12 L5 10.5 L9 12 L13 10.5 V2 L9 3.5 Z M5 2 V10.5 M9 3.5 V12" stroke="currentColor" strokeWidth="1.2" fill="none" strokeLinejoin="round"/>
            </svg>
            Map
          </button>
          <button className={`ffp-mobile-switch-btn ${mobileTab==='feed' ? 'on' : ''}`}
                  onClick={() => setMobileTab('feed')}
                  style={mobileTab==='feed' ? {background:'var(--accent)', borderColor:'var(--accent)'} : {}}>
            <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
              <path d="M2 3 H12 M2 7 H12 M2 11 H12" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round"/>
            </svg>
            Feed
          </button>
        </div>

        <aside className={`ffp-sidebar ${sidebarCollapsed ? 'collapsed' : ''}`}>
          {/* Today / Next 3 Days tabs persist across all-sightings, building,
              and event-detail views. Hidden on Dining (which has its own
              meal-period tabs) and Saved (where the map shows saved events
              regardless of time window). */}
          {!sidebarCollapsed && view !== 'dining' && view !== 'saved' && (
            <div role="tablist" aria-label="Time window"
                 style={{ display:'flex', gap:6, padding:'10px 14px 8px', borderBottom:'1px solid var(--hairline)', flexShrink: 0 }}>
              {[
                { id: 'today',    label: 'Today',       n: todayEvents.length },
                { id: 'upcoming', label: 'Next 3 Days', n: upcomingEvents.length },
              ].map(t => {
                const on = feedFilter === t.id;
                return (
                  <button key={t.id} role="tab" aria-selected={on}
                          onClick={() => setFeedFilter(t.id)}
                          style={{
                            flex: 1, padding: '6px 0', borderRadius: 999,
                            border: '1px solid var(--hairline)',
                            background: on ? 'var(--accent)' : 'var(--surface-light)',
                            color: on ? '#faf6ef' : 'var(--text)',
                            font: 'inherit', fontSize: 12, fontWeight: 600, cursor: 'pointer',
                          }}>
                    {t.label}
                    <span style={{ marginLeft: 6, opacity: 0.7, fontWeight: 500 }}>{t.n}</span>
                  </button>
                );
              })}
            </div>
          )}

          {!sidebarCollapsed && renderSidebarBody({
            view, focused, route,
            loaded, loadError,
            todayEvents, upcomingEvents, pastEvents,
            feedFilter, setFeedFilter,
            showPast, setShowPast,
            savedSightings,
            buildingFilter, buildingEvents, buildingPastEvents,
            placeFocus,
            search, setSearch, diets, setDiets, sort, setSort,
            freeOnly, setFreeOnly,
            diningFocusId,
            cardCommon,
            onUnfocus, onShare,
            onGoing, onGone, onSave, hasSaved,
          })}
        </aside>
      </div>

      <SpotFab getMap={() => mapRef.current} onOpen={onFabOpen} />

      <SubmitModal
        open={submitOpen}
        openContext={submitContext}
        onClose={() => setSubmitOpen(false)}
        onSubmitted={onSubmitted}
      />

      {!loaded && (
        <div className="ffp-loading">
          <div className="ring" />
          <p>Finding free food…</p>
        </div>
      )}

      <Toast toasts={toasts} />
    </div>
  );
}

function renderSidebarBody(props) {
  const {
    view, focused, route,
    loaded, loadError,
    todayEvents, upcomingEvents, pastEvents,
    feedFilter, setFeedFilter,
    showPast, setShowPast,
    savedSightings,
    buildingFilter, buildingEvents, buildingPastEvents,
    placeFocus,
    search, setSearch, diets, setDiets, sort, setSort,
    freeOnly, setFreeOnly,
    diningFocusId,
    cardCommon,
    onUnfocus, onShare,
    onGoing, onGone, onSave, hasSaved,
  } = props;

  if (route.name === 'event') {
    if (focused) {
      return (
        <EventDetail
          ev={focused}
          onBack={onUnfocus}
          onGoing={cardCommon.onGoing}
          onGone={cardCommon.onGone}
          onSave={cardCommon.onSave}
          onShare={onShare}
          isSaved={hasSaved(focused.id)}
          onInterested={cardCommon.onInterested}
          onSetReminder={cardCommon.onSetReminder}
          onClearReminder={cardCommon.onClearReminder}
          hasReminder={cardCommon.hasReminder}
        />
      );
    }
    if (!loaded) return null;
    return (
      <div className="ffp-error">
        <b>Sighting not found</b>
        This sighting may have ended or the link is invalid.
      </div>
    );
  }

  if (buildingFilter) {
    const sectionLabel = feedFilter === 'today' ? 'Today' : 'Coming up next 3 days';
    return (
      <>
        <BuildingInfo
          abbr={buildingFilter.abbr}
          name={buildingFilter.name}
          onBack={onUnfocus}
        />
        <div className="ffp-feed">
          {buildingEvents.length === 0 ? (
            <div className="ffp-empty">
              <div style={{fontSize:32}}>🍽️</div>
              <h3>Nothing matches right now</h3>
              <p style={{fontSize:12.5,maxWidth:280,margin:'0 auto'}}>
                {feedFilter === 'today'
                  ? `No active sightings at ${buildingFilter.name} in the next 24 hours. Try Next 3 Days, or check past events below.`
                  : `No upcoming sightings at ${buildingFilter.name} between 24 and 72 hours from now.`}
              </p>
            </div>
          ) : (
            <>
              <div className="ffp-section-label">
                {sectionLabel} at {buildingFilter.abbr} <span className="ffp-section-rule"/>
                <span style={{color:'var(--muted)',fontWeight:500,letterSpacing:0,textTransform:'none'}}>
                  {buildingEvents.length}
                </span>
              </div>
              {buildingEvents.map(ev => <SightingCard key={ev.id} ev={ev} {...cardCommon}/>)}
            </>
          )}

          {/* Show past events at this building — Today tab only, mirrors home. */}
          {feedFilter === 'today' && buildingPastEvents.length > 0 && (
            <>
              <button
                className="ffp-show-past"
                onClick={() => setShowPast(p => !p)}
                aria-expanded={showPast}>
                {showPast ? 'Hide past events' : `Show past events (${buildingPastEvents.length})`}
              </button>
              {showPast && (
                <>
                  <div className="ffp-past-divider">Earlier today</div>
                  {buildingPastEvents.map(ev => <SightingCard key={ev.id} ev={ev} muted {...cardCommon}/>)}
                </>
              )}
            </>
          )}
        </div>
      </>
    );
  }

  if (loadError) {
    return (
      <div className="ffp-error">
        <b>Couldn't reach the server</b>
        {loadError}
      </div>
    );
  }

  if (view === 'dining') return <DiningPanel dietFilter={diets} focusId={diningFocusId}/>;

  if (view === 'saved') {
    // Split into active (still upcoming or happening) vs. past (expired).
    // Past events stay muted so it's clear they're history, not actionable.
    const savedActive = savedSightings.filter(ev => !isExpired(ev));
    const savedPast   = savedSightings.filter(ev =>  isExpired(ev));
    return (
      <div className="ffp-feed">
        {savedSightings.length === 0 ? (
          <div className="ffp-empty">
            <div style={{fontSize:32}}>🔖</div>
            <h3>No saved sightings yet</h3>
            <p style={{fontSize:12.5,maxWidth:280,margin:'0 auto'}}>
              Tap the bookmark on any sighting to save it for later.
            </p>
          </div>
        ) : (
          <>
            {savedActive.length > 0 && (
              <>
                <div className="ffp-section-label">
                  Saved <span className="ffp-section-rule"/>
                  <span style={{color:'var(--muted)',fontWeight:500,letterSpacing:0,textTransform:'none'}}>
                    {savedActive.length}
                  </span>
                </div>
                {savedActive.map(ev => <SightingCard key={ev.id} ev={ev} {...cardCommon}/>)}
              </>
            )}
            {savedPast.length > 0 && (
              <>
                <div className="ffp-section-label">
                  Past <span className="ffp-section-rule"/>
                  <span style={{color:'var(--muted)',fontWeight:500,letterSpacing:0,textTransform:'none'}}>
                    {savedPast.length}
                  </span>
                </div>
                {savedPast.map(ev => <SightingCard key={ev.id} ev={ev} muted {...cardCommon}/>)}
              </>
            )}
            {savedActive.length === 0 && savedPast.length > 0 && (
              <p style={{ padding: '8px 18px 0', fontSize: 12, color: 'var(--muted)', fontStyle: 'italic' }}>
                None of your saved sightings are happening anymore — they're all in Past.
              </p>
            )}
          </>
        )}
      </div>
    );
  }

  // All-sightings view: Today / Next 3 Days tabs at the top.
  const filteredEvents = feedFilter === 'today' ? todayEvents : upcomingEvents;
  const sectionLabel  = feedFilter === 'today' ? 'Today' : 'Coming up next 3 days';

  return (
    <>
      <FilterBar
        search={search} setSearch={setSearch}
        diets={diets} setDiets={setDiets}
        sort={sort} setSort={setSort}
        freeOnly={freeOnly} setFreeOnly={setFreeOnly}
      />
      <div className="ffp-feed">
        {filteredEvents.length === 0 ? (
          <div className="ffp-empty">
            <div style={{fontSize:32}}>🍽️</div>
            <h3>Nothing matches right now</h3>
            <p style={{fontSize:12.5}}>
              {feedFilter === 'today'
                ? 'No active sightings in the next 24 hours. Try Next 3 Days, or check back soon.'
                : 'No upcoming events between 24 and 72 hours from now.'}
            </p>
          </div>
        ) : (
          <>
            <div className="ffp-section-label">
              {sectionLabel} <span className="ffp-section-rule"/>
              <span style={{color:'var(--muted)',fontWeight:500,letterSpacing:0,textTransform:'none'}}>{filteredEvents.length}</span>
            </div>
            {filteredEvents.map(ev => <SightingCard key={ev.id} ev={ev} {...cardCommon}/>)}
          </>
        )}

        {/* "Show past events" — Today tab only. Reveals events that ended in
            the last 24h beneath the active feed. */}
        {feedFilter === 'today' && pastEvents.length > 0 && (
          <>
            <button
              className="ffp-show-past"
              onClick={() => setShowPast(p => !p)}
              aria-expanded={showPast}>
              {showPast ? 'Hide past events' : `Show past events (${pastEvents.length})`}
            </button>
            {showPast && (
              <>
                <div className="ffp-past-divider">Earlier today</div>
                {pastEvents.map(ev => <SightingCard key={ev.id} ev={ev} muted {...cardCommon}/>)}
              </>
            )}
          </>
        )}
      </div>
    </>
  );
}
