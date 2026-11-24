// v2 sighting card. Matches the draft's design but pulls real fields
// from the Free Food at Purdue API and uses "Posted on Boilerlink/GroupMe…"
// instead of the draft's "@reporter".

import {
  eventStatus, foodEmoji, parseDate, fmtUntilStart, fmtTimeLeft,
  getSources, SOURCE_LABELS,
  isFoodSpecified,
} from './helpers.js';
import ReminderTrigger from './ReminderPopover.jsx';

const ACCENT = 'var(--accent)';

function StatusDot({ status }) {
  if (status === 'live') {
    return (
      <span className="ffp-dot" style={{ background: ACCENT }}>
        <span className="ffp-dot-pulse" style={{ background: ACCENT }}/>
      </span>
    );
  }
  if (status === 'expiring') return <span className="ffp-dot" style={{ background: '#9a7d62' }}/>;
  if (status === 'upcoming') return <span className="ffp-dot" style={{ background: '#c8a8e8' }}/>;
  return <span className="ffp-dot" style={{ background: '#c2b596' }}/>;
}

function TimeChip({ ev, status }) {
  if (status === 'upcoming') return <span className="ffp-time" style={{ color: '#6b5a3e' }}>{fmtUntilStart(ev)}</span>;
  if (status === 'expired')  return <span className="ffp-time" style={{ color: '#9a7d62' }}>ended</span>;
  const expDate = parseDate(ev.expires_at);
  const minsLeft = expDate ? Math.round((expDate.getTime() - Date.now()) / 60000) : 0;
  const urgent = status === 'expiring' || (minsLeft > 0 && minsLeft <= 15);
  return (
    <span className="ffp-time" style={{ color: urgent ? ACCENT : 'var(--text)', fontWeight: urgent ? 700 : 600 }}>
      {urgent && '⚡ '}{fmtTimeLeft(ev) || 'happening now'}
    </span>
  );
}

export default function SightingCard({
  ev, onOpen, onGoing, onSave, hasSaved, muted = false,
  onInterested, onSetReminder, onClearReminder, hasReminder,
}) {
  const status = eventStatus(ev);
  const saved = hasSaved(ev.id);
  const sources = getSources(ev);
  // Backend serializes is_free as int (1 free, 0 paid) — coerce to bool.
  // Default to true when the field is absent (matches original site convention).
  const isFree = ev.is_free === undefined ? true : !!ev.is_free;

  return (
    <article
      className={`ffp-card ${muted ? 'ffp-card-muted' : ''}`}
      onClick={() => onOpen(ev.id)}
      role="button"
      tabIndex={0}
      onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onOpen(ev.id); } }}
    >
      <div className="ffp-card-head">
        <div className="ffp-emoji">{foodEmoji(ev.food_type)}</div>
        <div className="ffp-card-meta">
          <div className="ffp-card-row">
            <StatusDot status={status}/>
            <span className="ffp-status-label">
              {status === 'live' ? 'LIVE'
                : status === 'expiring' ? 'ENDING'
                : status === 'upcoming' ? 'UPCOMING'
                : 'ENDED'}
            </span>
            <span className="ffp-bullet">·</span>
            <TimeChip ev={ev} status={status}/>
          </div>
          <h3 className="ffp-card-title">
            {ev.name || `${ev.food_type || 'Food'} at ${ev.building || ev.building_abbr || 'Purdue'}`}
          </h3>
          <div className="ffp-card-loc">
            <span className="ffp-bldg">{ev.building || ev.building_abbr || ''}</span>
            {ev.room && (<><span className="ffp-bullet"> · </span><span className="ffp-room">Room {ev.room}</span></>)}
          </div>
        </div>
      </div>

      <div className="ffp-card-tags">
        {isFoodSpecified(ev.food_type)
          ? <span className="ffp-tag ffp-tag-q">{ev.food_type}</span>
          : <span className="ffp-tag" style={{ color: 'var(--muted)', fontStyle: 'italic' }}>Food not specified</span>
        }
        <span className="ffp-tag" style={isFree
          ? { background: '#e8f8d8', color: '#4a8020' }
          : { background: '#e4f0fa', color: '#2060a0' }}>
          {isFree ? 'Free' : '💰 Paid'}
        </span>
        {/* Dietary tags intentionally hidden on cards — they live on the
            event detail page and the FilterBar's dietary dropdown. Card stays
            scannable: food type, price, source. */}
        {sources.map(s => {
          const meta = SOURCE_LABELS[s] || SOURCE_LABELS.groupme;
          return <span key={s} className={`ffp-src ${meta.cls}`}>{meta.icon} {meta.label}</span>;
        })}
      </div>

      <div
        className="ffp-card-actions"
        onClick={(e) => e.stopPropagation()}
        onKeyDown={(e) => e.stopPropagation()}
      >
        {(status === 'live' || status === 'expiring') && (
          <button
            className="ffp-btn"
            onClick={() => onGoing(ev)}
            title="I'm going">
            <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
              <path d="M6 1.5 L10.5 7 H7.5 V10.5 H4.5 V7 H1.5 Z" stroke="#2e1e0f" strokeWidth="1.2" fill="none" strokeLinejoin="round"/>
            </svg>
            {ev.going_count > 0 ? `${ev.going_count} going` : "I'm going"}
          </button>
        )}
        {status === 'upcoming' && (
          <>
            <button
              className="ffp-btn"
              onClick={() => onInterested?.(ev)}
              title="Mark as interested">
              ✦ {ev.going_count > 0 ? `${ev.going_count} interested` : 'Interested'}
            </button>
            <ReminderTrigger
              ev={ev}
              hasReminder={!!hasReminder?.(ev.id)}
              onSet={(off) => onSetReminder?.(ev, off)}
              onClear={() => onClearReminder?.(ev)}
            />
          </>
        )}
        <button
          className={`ffp-btn ffp-bookmark-btn ${saved ? 'on' : ''}`}
          onClick={() => onSave(ev)}
          style={saved ? { color: ACCENT, borderColor: ACCENT } : null}
          title={saved ? 'Remove from saved' : 'Save for later'}
          aria-label={saved ? 'Remove from saved' : 'Save for later'}>
          <svg width="11" height="13" viewBox="0 0 14 16" fill="none">
            <path d="M2 1.5 H12 V14.5 L7 11 L2 14.5 Z"
                  fill={saved ? ACCENT : 'none'}
                  stroke={saved ? ACCENT : '#2e1e0f'} strokeWidth="1.4" strokeLinejoin="round"/>
          </svg>
          {saved ? 'Saved' : 'Save'}
        </button>
        <div className="ffp-confirm-count">
          {(ev.gone_count || 0) >= 1 && (
            <span title="Reports of food being gone" style={{ color: 'var(--accent)' }}>
              ⚠ may be gone
            </span>
          )}
        </div>
      </div>
    </article>
  );
}
