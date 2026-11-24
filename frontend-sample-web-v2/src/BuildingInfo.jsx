// Header card shown above the building feed. This is the single canonical
// header for a building — back arrow, hero image (when available), full
// name, abbreviation, year, and a dismissable "fun fact" pulled from
// Purdue Libraries' Archives & Special Collections.
//
// The fun-fact section is dismissable globally; the user's choice persists
// in localStorage and is mirrored across tabs via the `storage` event.

import { useEffect, useState } from 'react';
import { fetchLibraryBuilding } from './api.js';

const FACT_HIDDEN_KEY = 'ffp.bldgFunFactHidden';

function readFactHidden() {
  try { return localStorage.getItem(FACT_HIDDEN_KEY) === '1'; }
  catch { return false; }
}

// Custom hook: persisted boolean for whether the user has dismissed the
// building fun-fact section globally.
function useFactHidden() {
  const [hidden, setHiddenState] = useState(readFactHidden);
  useEffect(() => {
    const onStorage = (e) => { if (e.key === FACT_HIDDEN_KEY) setHiddenState(readFactHidden()); };
    window.addEventListener('storage', onStorage);
    return () => window.removeEventListener('storage', onStorage);
  }, []);
  const setHidden = (v) => {
    setHiddenState(v);
    try {
      if (v) localStorage.setItem(FACT_HIDDEN_KEY, '1');
      else localStorage.removeItem(FACT_HIDDEN_KEY);
    } catch {}
  };
  return [hidden, setHidden];
}

function BackButton({ onBack, floating = false }) {
  return (
    <button
      type="button"
      className={floating ? 'ffp-bldg-back ffp-bldg-back-floating' : 'ffp-bldg-back'}
      onClick={onBack}
      aria-label="Back">
      <svg width="14" height="14" viewBox="0 0 14 14">
        <path d="M9 2 L4 7 L9 12" stroke="currentColor" strokeWidth="1.6" fill="none" strokeLinecap="round" strokeLinejoin="round"/>
      </svg>
    </button>
  );
}

export default function BuildingInfo({ abbr, name, onBack }) {
  const [state, setState] = useState({ loading: true, info: null, error: null });
  const [factHidden, setFactHidden] = useFactHidden();

  useEffect(() => {
    if (!abbr) { setState({ loading: false, info: null, error: null }); return; }
    let alive = true;
    setState({ loading: true, info: null, error: null });
    fetchLibraryBuilding(abbr)
      .then(info => { if (alive) setState({ loading: false, info, error: null }); })
      .catch(err => { if (alive) setState({ loading: false, info: null, error: err.message || 'fetch failed' }); });
    return () => { alive = false; };
  }, [abbr]);

  const info = state.info;
  const hasImage = !!info?.image_url;
  // Prefer the library's full name when available; fall back to whatever
  // the click handler captured (event.building or building polygon name).
  const displayName = info?.name || name || abbr || 'Building';

  return (
    <div className={`ffp-bldg-card ${hasImage ? 'has-image' : ''}`}>
      {state.loading ? (
        <div className="ffp-bldg-skel-image">
          <BackButton onBack={onBack} floating/>
        </div>
      ) : hasImage ? (
        <div className="ffp-bldg-image-wrap">
          <BackButton onBack={onBack} floating/>
          <img
            className="ffp-bldg-image"
            src={info.image_url}
            alt={info.name || abbr}
            loading="lazy"
            onError={(e) => { e.currentTarget.style.display = 'none'; }}
          />
        </div>
      ) : (
        <div className="ffp-bldg-noimage-row">
          <BackButton onBack={onBack}/>
          <div className="ffp-bldg-icon">🏛</div>
        </div>
      )}

      <div className="ffp-bldg-meta">
        <div className="ffp-bldg-fullname">{displayName}</div>
        <div className="ffp-bldg-year-row">
          <span className="ffp-bldg-year">
            {abbr}
            {info?.from_year ? ` · Built in ${info.from_year}` : ''}
            {info?.to_year && info.to_year !== info.from_year ? ` — ${info.to_year}` : ''}
          </span>
          {info?.fun_fact && factHidden && (
            <button
              type="button"
              className="ffp-bldg-fact-show"
              onClick={() => setFactHidden(false)}>
              See fun fact
            </button>
          )}
        </div>
      </div>

      {info?.fun_fact && !factHidden && (
        <div className="ffp-bldg-fact">
          <button
            type="button"
            className="ffp-bldg-fact-close"
            onClick={() => setFactHidden(true)}
            aria-label="Hide fun facts (applies to all buildings)"
            title="Hide fun facts (applies to all buildings)">
            ×
          </button>
          <span className="ffp-bldg-fact-label">Did you know?</span>
          {info.fun_fact}
        </div>
      )}

      {info?.source_url && (
        <a
          className="ffp-bldg-source"
          href={info.source_url}
          target="_blank"
          rel="noopener noreferrer">
          More on Purdue Libraries ↗
        </a>
      )}
    </div>
  );
}
