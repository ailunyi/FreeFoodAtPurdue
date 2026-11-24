// Search + Free toggle + Dietary dropdown (multi-select) + Sort.
//
// Dietary uses a popover panel anchored to its trigger button so the
// 9 restrictions don't dominate the filter row as chips.

import { useEffect, useRef, useState } from 'react';
import { DIET_LABELS } from './helpers.js';

const DIET_RESTRICTIONS = [
  { id: 'vegetarian', label: 'Vegetarian' },
  { id: 'vegan',      label: 'Vegan' },
  { id: 'halal',      label: 'Halal' },
  { id: 'kosher',     label: 'Kosher' },
  { id: 'gluten-free', label: 'Gluten-Free' },
];
const DIET_ALLERGIES = [
  { id: 'nut-free',   label: 'Nut-Free' },
  { id: 'dairy-free', label: 'Dairy-Free' },
  { id: 'soy-free',   label: 'Soy-Free' },
  { id: 'egg-free',   label: 'Egg-Free' },
];

export default function FilterBar({
  search, setSearch,
  diets, setDiets,
  sort, setSort,
  freeOnly, setFreeOnly,
}) {
  const [dietOpen, setDietOpen] = useState(false);
  const wrapRef = useRef(null);

  // Close the popover on click-outside / Escape
  useEffect(() => {
    if (!dietOpen) return;
    const onDocClick = (e) => {
      if (!wrapRef.current?.contains(e.target)) setDietOpen(false);
    };
    const onKey = (e) => { if (e.key === 'Escape') setDietOpen(false); };
    document.addEventListener('mousedown', onDocClick);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onDocClick);
      document.removeEventListener('keydown', onKey);
    };
  }, [dietOpen]);

  const toggleDiet = (id) =>
    setDiets(prev => prev.includes(id) ? prev.filter(x => x !== id) : [...prev, id]);
  const clearDiets = () => setDiets([]);

  return (
    <div className="ffp-filterbar">
      <div className="ffp-search">
        <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
          <circle cx="6" cy="6" r="4.5" stroke="#9a7d62" strokeWidth="1.4"/>
          <path d="M9.5 9.5 L13 13" stroke="#9a7d62" strokeWidth="1.4" strokeLinecap="round"/>
        </svg>
        <input
          placeholder="Search food, building, host…"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
      </div>

      <div className="ffp-chiprow">
        {/* Free toggle */}
        <button
          className={`ffp-chip ${freeOnly ? 'on' : ''}`}
          onClick={() => setFreeOnly(v => !v)}
          aria-pressed={freeOnly}
          style={freeOnly
            ? { background: 'var(--accent)', borderColor: 'var(--accent)', color: '#faf6ef' }
            : null}>
          Free only
        </button>

        {/* Dietary dropdown trigger + popover */}
        <div className="ffp-diet-wrap" ref={wrapRef}>
          <button
            className={`ffp-chip ffp-diet-trigger ${diets.length ? 'on' : ''}`}
            onClick={() => setDietOpen(o => !o)}
            aria-haspopup="true"
            aria-expanded={dietOpen}
            style={diets.length
              ? { background: 'var(--accent)', borderColor: 'var(--accent)', color: '#faf6ef' }
              : null}>
            🥗 Dietary
            {diets.length > 0 && <span className="ffp-diet-count">{diets.length}</span>}
            <svg width="9" height="9" viewBox="0 0 10 10" fill="none" style={{ marginLeft: 4 }}>
              <path d="M2 4 L5 7 L8 4" stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>
          </button>
          {dietOpen && (
            <div className="ffp-diet-pop" role="dialog" aria-label="Dietary filters">
              <div className="ffp-diet-section">Restrictions</div>
              {DIET_RESTRICTIONS.map(d => (
                <label key={d.id} className="ffp-diet-row">
                  <input
                    type="checkbox"
                    checked={diets.includes(d.id)}
                    onChange={() => toggleDiet(d.id)}
                  />
                  <span>{d.label}</span>
                </label>
              ))}
              <div className="ffp-diet-section">Allergies</div>
              {DIET_ALLERGIES.map(d => (
                <label key={d.id} className="ffp-diet-row">
                  <input
                    type="checkbox"
                    checked={diets.includes(d.id)}
                    onChange={() => toggleDiet(d.id)}
                  />
                  <span>{d.label}</span>
                </label>
              ))}
              <div className="ffp-diet-pop-foot">
                <button className="ffp-diet-clear" onClick={clearDiets} disabled={!diets.length}>
                  Clear
                </button>
                <button className="ffp-diet-apply" onClick={() => setDietOpen(false)}>
                  Done
                </button>
              </div>
            </div>
          )}
        </div>

        <div className="ffp-spacer"/>

        <div className="ffp-sort">
          <span>Sort</span>
          <select value={sort} onChange={(e) => setSort(e.target.value)}>
            <option value="recommended">Recommended</option>
            <option value="distance">Closest to me</option>
            <option value="time">Time left</option>
            <option value="recent">Most recent</option>
            <option value="popular">Most going</option>
          </select>
        </div>
      </div>
    </div>
  );
}
