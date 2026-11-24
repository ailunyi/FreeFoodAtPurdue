// Draggable Spot-It FAB. Click it to open the modal with no preset location;
// drag it onto a building polygon to drop a pin and pre-fill the location.
//
// Mirrors the original site's behavior: queryRenderedFeatures on the
// 'buildings-fill' layer to detect "inside X" vs "outside X (within ~50px)".

import { useEffect, useRef } from 'react';

export default function SpotFab({ getMap, onOpen }) {
  const fabRef = useRef(null);
  const ghostRef = useRef(null);

  useEffect(() => {
    const fab = fabRef.current;
    const ghost = ghostRef.current;
    if (!fab || !ghost) return;

    const handleDown = (downEv) => {
      downEv.preventDefault();
      let dragging = false;
      const startX = downEv.clientX, startY = downEv.clientY;

      const onMove = (ev) => {
        const dx = ev.clientX - startX, dy = ev.clientY - startY;
        if (!dragging && Math.hypot(dx, dy) > 6) {
          dragging = true;
          fab.classList.add('dragging');
          ghost.style.display = 'block';
        }
        if (dragging) {
          ghost.style.left = ev.clientX + 'px';
          ghost.style.top  = ev.clientY + 'px';
        }
      };

      const onUp = (ev) => {
        document.removeEventListener('mousemove', onMove);
        document.removeEventListener('mouseup',   onUp);
        fab.classList.remove('dragging');
        ghost.style.display = 'none';

        const map = getMap();
        if (dragging && map) {
          const canvas = map.getCanvas();
          const rect = canvas.getBoundingClientRect();
          const px = ev.clientX - rect.left, py = ev.clientY - rect.top;
          const lnglat = map.unproject([px, py]);
          const bldg = detectBuildingAtPoint(map, ev.clientX, ev.clientY);
          if (bldg) {
            onOpen({
              lat: lnglat.lat, lng: lnglat.lng,
              buildingAbbr: bldg.abbr, outsideBuilding: !bldg.inside,
              hint: bldg.inside ? bldg.name : `Outside ${bldg.name}`,
            });
          } else {
            onOpen({
              lat: lnglat.lat, lng: lnglat.lng,
              buildingAbbr: null, outsideBuilding: false,
              hint: 'Pinned location on map',
            });
          }
        } else {
          onOpen(null); // tap, not drag
        }
      };

      document.addEventListener('mousemove', onMove);
      document.addEventListener('mouseup',   onUp);
    };

    const handleTouchStart = (startEv) => {
      startEv.preventDefault();
      let moved = false;

      const onMove = (ev) => {
        moved = true;
        const t = ev.touches[0];
        ghost.style.display = 'block';
        ghost.style.left = t.clientX + 'px';
        ghost.style.top  = t.clientY + 'px';
      };

      const onEnd = (ev) => {
        fab.removeEventListener('touchmove', onMove);
        fab.removeEventListener('touchend',  onEnd);
        ghost.style.display = 'none';

        const map = getMap();
        if (moved && map) {
          const t = ev.changedTouches[0];
          const canvas = map.getCanvas();
          const rect = canvas.getBoundingClientRect();
          const px = t.clientX - rect.left, py = t.clientY - rect.top;
          const lnglat = map.unproject([px, py]);
          const bldg = detectBuildingAtPoint(map, t.clientX, t.clientY);
          if (bldg) {
            onOpen({
              lat: lnglat.lat, lng: lnglat.lng,
              buildingAbbr: bldg.abbr, outsideBuilding: !bldg.inside,
              hint: bldg.inside ? bldg.name : `Outside ${bldg.name}`,
            });
          } else {
            onOpen({
              lat: lnglat.lat, lng: lnglat.lng,
              buildingAbbr: null, outsideBuilding: false,
              hint: 'Pinned location on map',
            });
          }
        } else {
          onOpen(null);
        }
      };

      fab.addEventListener('touchmove', onMove, { passive: false });
      fab.addEventListener('touchend',  onEnd);
    };

    fab.addEventListener('mousedown', handleDown);
    fab.addEventListener('touchstart', handleTouchStart, { passive: false });
    return () => {
      fab.removeEventListener('mousedown', handleDown);
      fab.removeEventListener('touchstart', handleTouchStart);
    };
  }, [getMap, onOpen]);

  return (
    <>
      <div
        id="spot-fab"
        ref={fabRef}
        title="Drag me onto a building, or click to report a sighting"
        aria-label="Report a sighting">
        <span className="p-logo-icon" style={{ width: 30, height: 30 }} />
      </div>
      <div id="spot-drop-ghost" ref={ghostRef} />
    </>
  );
}

// Hit-test the buildings-fill layer; returns { abbr, name, inside } or null.
function detectBuildingAtPoint(map, screenX, screenY) {
  if (!map || !map.getLayer || !map.getLayer('buildings-fill')) return null;
  const canvas = map.getCanvas();
  const rect = canvas.getBoundingClientRect();
  const point = [screenX - rect.left, screenY - rect.top];
  const hits = map.queryRenderedFeatures(point, { layers: ['buildings-fill'] });
  if (hits.length > 0) {
    const props = hits[0].properties;
    return { abbr: props.abbr, name: props.full_name || props.abbr, inside: true };
  }
  // 50px radius — "outside X"
  const pad = 50;
  const bbox = [[point[0] - pad, point[1] - pad], [point[0] + pad, point[1] + pad]];
  const nearby = map.queryRenderedFeatures(bbox, { layers: ['buildings-fill'] });
  if (nearby.length > 0) {
    const props = nearby[0].properties;
    return { abbr: props.abbr, name: props.full_name || props.abbr, inside: false };
  }
  return null;
}
