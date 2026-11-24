// React-wrapped Mapbox GL map.
//
// Features (matches the original site):
//   • Time-of-day style picker (dawn / day / night) — currently forced to day
//   • Building polygons with hover tooltip; click to show events at that building
//   • Live-event HTML markers (clustered by lat/lng)
//   • Dining-court / Boilermaker Market / On-the-GO / ACE Pantry / PMU markers
//   • Geolocate control + bounded panning
//
// The map exposes its instance via `onMapReady` so the FAB can use
// queryRenderedFeatures() / unproject() for drag-to-drop building detection.

import { useEffect, useRef, useState } from 'react';
import mapboxgl from 'mapbox-gl';
import { foodEmoji, eventStatus, isExpired, isUpcoming } from './helpers.js';
import { API_BASE } from './api.js';
import {
  FOOD_PANTRIES, BOILER_MARKETS, ON_THE_GO, PMU_RESTAURANTS,
  PMU_LAT, PMU_LNG, DINING_COURTS, isLocationOpen, locKey,
} from './places.js';
import { bldgStyle } from './buildingStyles.js';

// Public Mapbox token, read at build time from .env (see .env.example).
const ACCESS_TOKEN = import.meta.env.VITE_MAPBOX_TOKEN;
mapboxgl.accessToken = ACCESS_TOKEN;

// Time-of-day style picker (dawn 06:30–10, day 10–20:30, night otherwise).
// TEMP override: forced to day style for now (matches the original deploy).
function pickMapStyle() {
  return 'mapbox://styles/freefoodatpurdue/cmo2aflgz003401s5e1dsdc4d';
}

const PURDUE_CENTER = [-86.9151, 40.4284];
const MAX_BOUNDS = [
  [PURDUE_CENTER[0] - 0.058, PURDUE_CENTER[1] - 0.043], // SW
  [PURDUE_CENTER[0] + 0.058, PURDUE_CENTER[1] + 0.043], // NE
];

// Group events into building-level clusters (matches the original site).
// Each cluster gets a representative {abbr, name, lat, lng} plus the events.
// Key falls back to building name, then a coarse lat/lng cell.
function clusterByLocation(events) {
  const groups = new Map();
  for (const ev of events) {
    if (ev.lat == null || ev.lng == null) continue;
    if (isExpired(ev) && !isUpcoming(ev)) continue;
    const key =
      ev.building_abbr ||
      ev.building ||
      `${Math.round(ev.lat * 1e4)}_${Math.round(ev.lng * 1e4)}`;
    let g = groups.get(key);
    if (!g) {
      g = {
        key,
        lat: Number(ev.lat),
        lng: Number(ev.lng),
        abbr: ev.building_abbr || null,
        name: ev.building || ev.building_abbr || null,
        events: [],
      };
      groups.set(key, g);
    }
    g.events.push(ev);
  }
  return [...groups.values()];
}

// Group static services (dining/market/pantry/PMU/OTG) by location
function buildPlaceGroups(buildings) {
  const groups = new Map();
  const add = (key, name, lat, lng, svc) => {
    if (!groups.has(key)) groups.set(key, { name, lat, lng, services: [] });
    groups.get(key).services.push(svc);
  };
  // Dining courts (only if a polygon exists at that location)
  for (const b of buildings) {
    if (!DINING_COURTS[b.abbr] || !b.lat || !b.lng) continue;
    add(locKey(b.lat, b.lng), b.full_name || b.abbr, b.lat, b.lng,
      { type: 'dining', data: b, emoji: '🍽', label: `${DINING_COURTS[b.abbr]} Dining Court` });
  }
  for (const otg of ON_THE_GO) {
    add(locKey(otg.lat, otg.lng), otg.name, otg.lat, otg.lng,
      { type: 'otg', data: otg, emoji: '🏪', label: otg.name, open: isLocationOpen(otg.hours) });
  }
  for (const bm of BOILER_MARKETS) {
    add(locKey(bm.lat, bm.lng), bm.name, bm.lat, bm.lng,
      { type: 'market', data: bm, emoji: '🏪', label: bm.name, open: isLocationOpen(bm.hours) });
  }
  for (const p of FOOD_PANTRIES) {
    add(locKey(p.lat, p.lng), p.name, p.lat, p.lng,
      { type: 'pantry', data: p, emoji: '🥫', label: p.name, open: isLocationOpen(p.hours) });
  }
  // PMU
  const pmuOpen = PMU_RESTAURANTS.some(r => isLocationOpen(r.hours));
  add(locKey(PMU_LAT, PMU_LNG), 'Purdue Memorial Union', PMU_LAT, PMU_LNG,
    { type: 'pmu', data: PMU_RESTAURANTS, emoji: '🍴', label: 'Atlas Family Marketplace', open: pmuOpen });
  return [...groups.values()];
}

export default function CampusMap({
  events, focusedId, focusedBuildingAbbr, focusedPlaceKey,
  onFocus, hoveredId, onHover,
  onBuildingClick, onPlaceClick, onMapReady, onUserPos,
  showPlaces = true, showEvents = true,
}) {
  const containerRef = useRef(null);
  const mapRef = useRef(null);
  const eventMarkersRef = useRef([]);
  const placeMarkersRef = useRef([]);
  const tipRef = useRef(null);
  const buildingsRef = useRef([]);
  // Bumped whenever the buildings list / data has loaded — drives the
  // place-markers effect below without requiring the full map effect to re-run.
  const [buildingsLoadedTick, setBuildingsLoadedTick] = useState(0);

  // Mount Mapbox once
  useEffect(() => {
    if (!containerRef.current) return;
    const map = new mapboxgl.Map({
      container: containerRef.current,
      style: pickMapStyle(),
      center: PURDUE_CENTER,
      zoom: 15.5,
      maxBounds: MAX_BOUNDS,
      attributionControl: false,
    });
    mapRef.current = map;

    map.addControl(new mapboxgl.AttributionControl({ compact: true }));
    map.addControl(new mapboxgl.NavigationControl({ showCompass: false }), 'bottom-right');
    const geolocate = new mapboxgl.GeolocateControl({
      positionOptions: { enableHighAccuracy: true },
      trackUserLocation: true,
      showUserHeading: true,
      showAccuracyCircle: true,
      fitBoundsOptions: { maxZoom: 15.5 },
    });
    map.addControl(geolocate, 'bottom-right');
    geolocate.on('geolocate', (e) => {
      const pos = { lat: e.coords.latitude, lng: e.coords.longitude };
      window.__ffp ||= {};
      window.__ffp.userPos = pos;
      onUserPos?.(pos);
    });

    // Building tooltip element
    const tip = document.createElement('div');
    tip.id = 'tip';
    tip.innerHTML = `
      <div class="tt-bldg"></div>
      <div class="tt-sub"></div>
      <div class="tt-hint"></div>
      <div class="tt-badge"></div>`;
    document.body.appendChild(tip);
    tipRef.current = tip;

    map.on('load', async () => {
      // Building polygons
      try {
        const res = await fetch(`${API_BASE}/buildings?map_only=true&key_only=false`);
        if (res.ok) {
          const buildings = await res.json();
          buildingsRef.current = buildings;
          const features = buildings
            .filter(b => b.polygon && b.polygon.length && b.polygon[0].length)
            .map(b => {
              const st = bldgStyle(b.abbr);
              return {
                type: 'Feature',
                geometry: { type: 'Polygon', coordinates: b.polygon },
                properties: {
                  abbr: b.abbr,
                  full_name: b.full_name,
                  isDining: !!DINING_COURTS[b.abbr],
                  fillColor: st.f,
                  strokeColor: st.s,
                },
              };
            });
          if (features.length) {
            map.addSource('buildings', { type: 'geojson', data: { type: 'FeatureCollection', features } });
            map.addLayer({
              id: 'buildings-fill', type: 'fill', source: 'buildings',
              paint: {
                'fill-color': ['get', 'fillColor'],
                'fill-opacity': 0.82,
              },
            });
            map.addLayer({
              id: 'buildings-line', type: 'line', source: 'buildings',
              paint: {
                'line-color': ['get', 'strokeColor'],
                'line-width': 0.8,
                'line-opacity': 0.9,
              },
            });
            // Focus glow — soft blurred outline drawn on top, animated by a
            // requestAnimationFrame loop in the focusedBuildingAbbr effect.
            map.addLayer({
              id: 'buildings-focus-glow', type: 'line', source: 'buildings',
              filter: ['==', ['get', 'abbr'], '__none__'],
              paint: {
                'line-color': '#C1440E',
                'line-width': 6,
                'line-blur': 6,
                'line-opacity': 0,
              },
            });

            map.on('mousemove', 'buildings-fill', (e) => {
              const f = e.features?.[0];
              if (!f) return;
              map.getCanvas().style.cursor = 'pointer';
              showTip(tip, e.originalEvent, f.properties);
            });
            map.on('mouseleave', 'buildings-fill', () => {
              map.getCanvas().style.cursor = '';
              tip.classList.remove('show');
            });
            map.on('click', 'buildings-fill', (e) => {
              const f = e.features?.[0];
              if (!f) return;
              tip.classList.remove('show');
              const abbr = f.properties.abbr;
              const name = f.properties.full_name || abbr;
              // Pan to the clicked building (no zoom change).
              const b = buildingsRef.current.find(x => x.abbr === abbr);
              const lat = b?.lat ?? e.lngLat.lat;
              const lng = b?.lng ?? e.lngLat.lng;
              map.easeTo({ center: [lng, lat], duration: 600, essential: true });
              onBuildingClick?.({ abbr, name, aliases: b?.aliases || [] });
            });

            // Place markers (dining/pantry/market/PMU/OTG) are added by a
            // separate effect below so they can be toggled by view.
            setBuildingsLoadedTick(t => t + 1);
          }
        }
      } catch (err) {
        console.warn('[map] buildings fetch failed', err);
      }

      // Close any pin focus when clicking empty map
      map.on('click', (e) => {
        const hit = map.queryRenderedFeatures(e.point, { layers: map.getLayer('buildings-fill') ? ['buildings-fill'] : [] });
        if (!hit.length) onFocus?.(null);
      });

      try { geolocate.trigger(); } catch {}

      // Expose
      window.__ffp ||= {};
      window.__ffp.map = map;
      onMapReady?.(map);
    });

    return () => {
      eventMarkersRef.current.forEach(m => m.remove());
      placeMarkersRef.current.forEach(m => m.remove());
      eventMarkersRef.current = [];
      placeMarkersRef.current = [];
      tip.remove();
      map.remove();
      mapRef.current = null;
      window.__ffp && (window.__ffp.map = null);
    };
  }, []);  // eslint-disable-line react-hooks/exhaustive-deps

  // Place markers (dining / pantry / market / PMU / OTG). Respects `showPlaces`.
  // Re-runs when `focusedPlaceKey` changes so the matching marker gets the
  // .focused class for its pulse animation.
  useEffect(() => {
    const map = mapRef.current;
    if (!map || buildingsLoadedTick === 0) return;
    placeMarkersRef.current.forEach(m => m.remove());
    placeMarkersRef.current = [];
    if (!showPlaces) return;
    renderPlaceMarkers(map, placeMarkersRef, buildPlaceGroups(buildingsRef.current),
                       onPlaceClick, focusedPlaceKey);
    return () => {
      placeMarkersRef.current.forEach(m => m.remove());
      placeMarkersRef.current = [];
    };
  }, [showPlaces, onPlaceClick, buildingsLoadedTick, focusedPlaceKey]);

  // Building focus glow — pulses the buildings-focus-glow layer while a
  // building is selected. 1.4s sine cycle on opacity (0.25 → 0.85).
  useEffect(() => {
    const map = mapRef.current;
    if (!map || buildingsLoadedTick === 0 || !map.getLayer('buildings-focus-glow')) return;
    if (!focusedBuildingAbbr) {
      map.setFilter('buildings-focus-glow', ['==', ['get', 'abbr'], '__none__']);
      map.setPaintProperty('buildings-focus-glow', 'line-opacity', 0);
      return;
    }
    map.setFilter('buildings-focus-glow', ['==', ['get', 'abbr'], focusedBuildingAbbr]);
    const start = performance.now();
    let raf = 0;
    const tick = (t) => {
      const phase = ((t - start) % 1400) / 1400;
      const opacity = 0.25 + 0.30 * (1 + Math.sin(phase * Math.PI * 2 - Math.PI / 2));
      map.setPaintProperty('buildings-focus-glow', 'line-opacity', opacity);
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => {
      cancelAnimationFrame(raf);
      if (map.getLayer('buildings-focus-glow')) {
        map.setPaintProperty('buildings-focus-glow', 'line-opacity', 0);
      }
    };
  }, [focusedBuildingAbbr, buildingsLoadedTick]);

  // Render event pins whenever events / focus / hover change
  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    if (!map.isStyleLoaded()) {
      const onLoad = () => renderEventPins();
      map.once('idle', onLoad);
      return () => map.off('idle', onLoad);
    }
    renderEventPins();

    function renderEventPins() {
      eventMarkersRef.current.forEach(m => m.remove());
      eventMarkersRef.current = [];
      if (!showEvents) return;

      const groups = clusterByLocation(events);
      for (const g of groups) {
        // Pick the most-prominent status to color the marker; fall back through
        // live → expiring → upcoming → first event.
        const primary = g.events.find(e => eventStatus(e) === 'live')
          || g.events.find(e => eventStatus(e) === 'expiring')
          || g.events.find(e => eventStatus(e) === 'upcoming')
          || g.events[0];
        const status = eventStatus(primary);

        // Show up to 3 unique food emojis joined together (matches original).
        const emojis = [...new Set(g.events.map(e => foodEmoji(e.food_type)))]
          .slice(0, 3).join('');

        const el = document.createElement('div');
        el.className = `food-marker ${status === 'upcoming' ? 'upcoming' : status === 'expired' ? 'expired' : ''}`;
        if (focusedId != null && g.events.some(e => String(e.id) === String(focusedId))) {
          el.classList.add('focused');
        }

        const inner = document.createElement('div');
        inner.className = 'm-inner';
        // Pulse ring for live/expiring events (red flash via CSS accent).
        if (status === 'live' || status === 'expiring') {
          const ring = document.createElement('div');
          ring.className = 'm-ring';
          inner.appendChild(ring);
        }
        const dot = document.createElement('div');
        dot.className = 'm-dot';
        const e2 = document.createElement('div');
        e2.className = 'm-emoji';
        e2.textContent = emojis;
        dot.appendChild(e2);
        // Count goes inside the same bubble (no separate background).
        if (g.events.length > 1) {
          const cnt = document.createElement('div');
          cnt.className = 'm-count-inline';
          cnt.textContent = String(g.events.length);
          dot.appendChild(cnt);
        }
        inner.appendChild(dot);
        el.appendChild(inner);

        el.addEventListener('mouseenter', () => onHover(primary.id));
        el.addEventListener('mouseleave', () => onHover(null));
        el.addEventListener('click', (e) => {
          e.stopPropagation();
          // Single event at this location → open the event detail directly.
          // Multiple events → open the building feed.
          if (g.events.length === 1) {
            onFocus(g.events[0].id);
          } else if (g.abbr || g.name) {
            // Try to find the matching ArcGIS polygon by abbr OR by name in
            // its aliases — gives us the polygon's full alias list.
            const lc = (s) => (s || '').toString().trim().toLowerCase();
            const evNameLc = lc(g.name);
            const poly = buildingsRef.current.find(b =>
              b.abbr === g.abbr ||
              lc(b.full_name) === evNameLc ||
              (Array.isArray(b.aliases) && b.aliases.some(a => lc(a) === evNameLc))
            );
            const aliases = poly?.aliases || [];
            // Always include the cluster's own name in aliases too.
            const allAliases = g.name && !aliases.some(a => lc(a) === evNameLc)
              ? [...aliases, g.name]
              : aliases;
            onBuildingClick?.({
              abbr: poly?.abbr || g.abbr || g.name,
              name: poly?.full_name || g.name || g.abbr,
              aliases: allAliases,
            });
            // Pan to the building (keep current zoom).
            map.easeTo({ center: [g.lng, g.lat], duration: 600, essential: true });
          } else {
            onFocus(primary.id);
          }
        });

        const marker = new mapboxgl.Marker({ element: el, anchor: 'center' })
          .setLngLat([g.lng, g.lat])
          .addTo(map);
        eventMarkersRef.current.push(marker);
      }
    }
  }, [events, focusedId, onFocus, onHover, showEvents]);

  return <div ref={containerRef} style={{ width: '100%', height: '100%' }} />;
}

// ── Tooltip helper ────────────────────────────────────────────────────────
function showTip(tip, mouseEvt, props) {
  if (!props) return;
  tip.querySelector('.tt-bldg').textContent = props.full_name || props.abbr || '';
  tip.querySelector('.tt-sub').textContent  = props.abbr || '';
  tip.querySelector('.tt-hint').textContent = props.isDining ? 'Click for dining info' : 'Click to see events here';
  const badge = tip.querySelector('.tt-badge');
  badge.style.display = 'none';
  tip.classList.add('show');
  // Position
  tip.style.left = `${Math.min(window.innerWidth - 230, mouseEvt.clientX + 12)}px`;
  tip.style.top  = `${Math.max(12, mouseEvt.clientY - 36)}px`;
}

// ── Place markers ─────────────────────────────────────────────────────────
// Same key scheme as App.jsx:placeFocusKey — must stay in sync so a marker
// can recognise itself as the focused one.
const ABBR_TO_PANEL_ID = { WDCT: 'wiley', ERHT: 'earhart', FORD: 'ford', HILL: 'hillenbrand', WDC: 'windsor' };
function placeMarkerKey(svc) {
  if (!svc) return null;
  if (svc.type === 'dining') return ABBR_TO_PANEL_ID[svc.data?.abbr] || null;
  if (svc.type === 'otg')    return `otg:${svc.data?.abbr}`;
  if (svc.type === 'market') return `market:${svc.data?.name}`;
  if (svc.type === 'pantry') return `pantry:${svc.data?.name}`;
  if (svc.type === 'pmu')    return 'pmu';
  return null;
}

function renderPlaceMarkers(map, markersRef, groups, onPlaceClick, focusedPlaceKey) {
  for (const g of groups) {
    const primary = g.services[0];
    const allClosed = g.services.every(s => s.open === false);
    const emojis = [...new Set(g.services.map(s => s.emoji))].join('');
    const el = document.createElement('div');
    let cls, pinCls, stemCls;
    if (primary.type === 'dining')  { cls = 'dining-marker'; pinCls = 'dm-pin';  stemCls = 'dm-stem'; }
    else if (primary.type === 'pantry') { cls = 'pantry-marker'; pinCls = 'pm-pin';  stemCls = 'pm-stem'; }
    else if (primary.type === 'pmu')    { cls = 'pmu-marker';    pinCls = 'pmu-pin'; stemCls = 'pmu-stem'; }
    else if (primary.type === 'otg')    { cls = 'otg-marker';    pinCls = 'otg-pin'; stemCls = 'otg-stem'; }
    else                                { cls = 'market-marker'; pinCls = 'mk-pin';  stemCls = 'mk-stem'; }
    const isFocused = focusedPlaceKey && placeMarkerKey(primary) === focusedPlaceKey;
    el.className = cls + (allClosed ? ' all-closed' : '') + (isFocused ? ' focused' : '');
    el.innerHTML = `<div class="${pinCls}">${emojis}</div><div class="${stemCls}"></div>`;

    el.addEventListener('mouseenter', (ev) => {
      // tiny inline tooltip via the same #tip element
      const tip = document.getElementById('tip');
      if (!tip) return;
      const labels = g.services.map(s => s.label).join(' · ');
      tip.querySelector('.tt-bldg').textContent = g.name;
      tip.querySelector('.tt-sub').textContent  = labels.length > 60 ? labels.slice(0, 57) + '…' : labels;
      tip.querySelector('.tt-hint').textContent = allClosed ? 'Closed now' : 'Click for details';
      tip.classList.add('show');
      tip.style.left = `${Math.min(window.innerWidth - 230, ev.clientX + 12)}px`;
      tip.style.top  = `${Math.max(12, ev.clientY - 36)}px`;
    });
    el.addEventListener('mouseleave', () => {
      const tip = document.getElementById('tip');
      tip?.classList.remove('show');
    });
    el.addEventListener('click', (e) => {
      e.stopPropagation();
      // For dining markers we pan the camera to the court — App.jsx
      // also navigates to the Dining tab and pre-expands the matching card.
      if (primary.type === 'dining') {
        map.easeTo({ center: [g.lng, g.lat], duration: 600, essential: true });
      }
      onPlaceClick?.(g);
    });

    const m = new mapboxgl.Marker({ element: el, anchor: 'bottom' })
      .setLngLat([g.lng, g.lat])
      .addTo(map);
    markersRef.current.push(m);
  }
}
