// localStorage-backed saved-events set, with cross-tab sync.
import { useEffect, useState } from 'react';

const KEY = 'ffp.saved';

function read() {
  try {
    const raw = localStorage.getItem(KEY);
    return new Set(raw ? JSON.parse(raw) : []);
  } catch {
    return new Set();
  }
}

export function useSaved() {
  const [saved, setSaved] = useState(read);

  useEffect(() => {
    try {
      localStorage.setItem(KEY, JSON.stringify([...saved]));
    } catch {}
  }, [saved]);

  // Pick up changes from other tabs.
  useEffect(() => {
    const onStorage = (e) => {
      if (e.key === KEY) setSaved(read());
    };
    window.addEventListener('storage', onStorage);
    return () => window.removeEventListener('storage', onStorage);
  }, []);

  const toggle = (id) => {
    setSaved(prev => {
      const next = new Set(prev);
      const key = String(id);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  };

  const has = (id) => saved.has(String(id));

  return { saved, has, toggle, count: saved.size };
}
