// Reminder hook — localStorage-backed map of {eventId → {fireAt, title, body}}.
// On mount and on map changes, schedules setTimeout for each future reminder
// and fires past-due ones immediately. Cross-tab sync via the `storage` event.
//
// Delivery is via the browser Notifications API. This works while the tab is
// open OR re-opened before the fire time. A future iteration can layer a
// service worker / Web Push on top using the same localStorage shape — the
// data model doesn't change.

import { useEffect, useRef, useState, useCallback } from 'react';

const KEY = 'ffp.reminders';
const ONE_DAY_MS = 24 * 3600_000;

function read() {
  try {
    const raw = localStorage.getItem(KEY);
    return raw ? JSON.parse(raw) : {};
  } catch {
    return {};
  }
}

function write(map) {
  try { localStorage.setItem(KEY, JSON.stringify(map)); } catch {}
}

// Re-entrancy guard so the popstate dispatch doesn't loop in tests.
function fireNotification({ title, body, eventId }) {
  if (typeof window === 'undefined') return;
  if (!('Notification' in window) || Notification.permission !== 'granted') return;
  try {
    const n = new Notification(title || 'Free Food at Purdue', {
      body: body || 'Your saved event is starting soon.',
      icon: '/images/logo-p.png',
      tag: `ffp-reminder-${eventId}`,
    });
    n.onclick = () => {
      try { window.focus(); } catch {}
      try {
        window.history.pushState({}, '', `/event/${encodeURIComponent(eventId)}`);
        window.dispatchEvent(new PopStateEvent('popstate'));
      } catch {}
      n.close();
    };
  } catch {}
}

export async function ensureNotificationPermission() {
  if (typeof window === 'undefined' || !('Notification' in window)) return 'unsupported';
  if (Notification.permission === 'granted') return 'granted';
  if (Notification.permission === 'denied') return 'denied';
  try { return await Notification.requestPermission(); }
  catch { return 'denied'; }
}

export function useReminders() {
  const [map, setMap] = useState(read);
  const timersRef = useRef(new Map()); // eventId → setTimeout id

  // Persist on every change
  useEffect(() => { write(map); }, [map]);

  // Cross-tab sync
  useEffect(() => {
    const onStorage = (e) => {
      if (e.key === KEY) setMap(read());
    };
    window.addEventListener('storage', onStorage);
    return () => window.removeEventListener('storage', onStorage);
  }, []);

  // Schedule timers for the current map; fire & purge any past-due entries.
  useEffect(() => {
    // Clear any previously-scheduled timers (some entries may have been removed).
    for (const t of timersRef.current.values()) clearTimeout(t);
    timersRef.current.clear();

    const now = Date.now();
    let pastDue = null;
    for (const [id, r] of Object.entries(map)) {
      if (!r || typeof r.fireAt !== 'number') continue;
      const delay = r.fireAt - now;
      if (delay <= 0) {
        // Fire-now path — collect for batched removal below to avoid
        // mutating state mid-iteration.
        fireNotification(r);
        if (!pastDue) pastDue = new Set();
        pastDue.add(id);
      } else if (delay < ONE_DAY_MS) {
        // setTimeout reliably fires under ~24 h; longer ones get rescheduled
        // on a future render when their fireAt is closer.
        const tid = setTimeout(() => {
          fireNotification(r);
          setMap(prev => {
            if (!(id in prev)) return prev;
            const next = { ...prev };
            delete next[id];
            return next;
          });
        }, delay);
        timersRef.current.set(id, tid);
      }
    }
    if (pastDue) {
      setMap(prev => {
        const next = { ...prev };
        for (const id of pastDue) delete next[id];
        return next;
      });
    }
    return () => {
      for (const t of timersRef.current.values()) clearTimeout(t);
      timersRef.current.clear();
    };
  }, [map]);

  const has = useCallback((id) => !!map[String(id)], [map]);
  const fireAt = useCallback((id) => map[String(id)]?.fireAt, [map]);

  const set = useCallback((eventId, fireAtMs, payload) => {
    setMap(prev => ({
      ...prev,
      [String(eventId)]: { eventId: String(eventId), fireAt: fireAtMs, ...payload },
    }));
  }, []);

  const clear = useCallback((eventId) => {
    setMap(prev => {
      if (!(String(eventId) in prev)) return prev;
      const next = { ...prev };
      delete next[String(eventId)];
      return next;
    });
  }, []);

  // For App.jsx cleanup-on-poll — give it a snapshot of the current keys.
  const ids = useCallback(() => Object.keys(map), [map]);

  return { has, fireAt, set, clear, ids };
}
