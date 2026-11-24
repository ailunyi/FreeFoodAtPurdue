// Tiny path-based router. Supports:
//   /                — home (all sightings)
//   /saved           — saved view
//   /dining          — dining courts view
//   /event/:id       — event detail (shareable link)
//
// Path-based (not hash-based) so the Express SEO server can render per-event HTML.
import { useEffect, useState } from 'react';

export function parseRoute(pathname = window.location.pathname) {
  const p = pathname.replace(/\/+$/, '') || '/';
  if (p === '/' || p === '') return { name: 'home' };
  if (p === '/saved') return { name: 'saved' };
  if (p === '/dining') return { name: 'dining' };
  const m = p.match(/^\/event\/([0-9a-zA-Z_-]+)$/);
  if (m) return { name: 'event', id: m[1] };
  return { name: 'home' };
}

export function navigate(to) {
  if (window.location.pathname === to) return;
  window.history.pushState({}, '', to);
  window.dispatchEvent(new PopStateEvent('popstate'));
}

export function useRoute() {
  const [route, setRoute] = useState(() => parseRoute());
  useEffect(() => {
    const onPop = () => setRoute(parseRoute());
    window.addEventListener('popstate', onPop);
    return () => window.removeEventListener('popstate', onPop);
  }, []);
  return [route, navigate];
}
