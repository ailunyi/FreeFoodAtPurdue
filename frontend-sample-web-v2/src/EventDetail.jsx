// Detailed view for a single event. Uses real API fields, "Posted on…" for
// the source, BoilerLink and RSVP links when present, and a Share button
// that uses navigator.share or clipboard.

import { useEffect, useState } from 'react';
import {
  eventStatus, foodEmoji, parseDate, fmtUntilStart, fmtTimeLeft, fmtClock,
  postedOnLabel, getDietChips, DIET_LABELS, isExpired, isUpcoming, boilerlinkUrl, getSources, SOURCE_LABELS,
  stripHtml, isFoodSpecified, PURDUE_TZ,
} from './helpers.js';
import { fetchEventActivity } from './api.js';
import ReminderTrigger from './ReminderPopover.jsx';

// Field-name → human label for activity log entries.
const ACTIVITY_FIELD_LABELS = {
  name: 'Name', food_type: 'Food', building: 'Building', room: 'Room',
  starts_at: 'Start time', expires_at: 'End time', description: 'Description',
  is_free: 'Free/paid', rsvp_required: 'RSVP requirement', rsvp_link: 'RSVP link',
};

// Backend stores values as strings; format them per-field for display.
function fmtActivityValue(field, raw) {
  if (raw == null || raw === '') return '—';
  if (field === 'starts_at' || field === 'expires_at') {
    const d = new Date(raw);
    return isNaN(d) ? raw : d.toLocaleString([], { dateStyle: 'short', timeStyle: 'short', timeZone: PURDUE_TZ });
  }
  if (field === 'is_free' || field === 'rsvp_required') {
    return raw === '1' || raw === 1 || raw === 'true' ? 'Yes' : 'No';
  }
  if (field === 'description' && raw.length > 80) return raw.slice(0, 77) + '…';
  return raw;
}

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

export default function EventDetail({
  ev, onBack, onGoing, onGone, onSave, onShare, isSaved,
  onInterested, onSetReminder, onClearReminder, hasReminder,
}) {
  const [activity, setActivity] = useState([]);
  useEffect(() => {
    if (!ev?.id) { setActivity([]); return; }
    let alive = true;
    fetchEventActivity(ev.id)
      .then(data => { if (alive) setActivity(Array.isArray(data) ? data : []); })
      .catch(() => { if (alive) setActivity([]); });
    return () => { alive = false; };
  }, [ev?.id, ev?.going_count, ev?.gone_count]);
  if (!ev) return null;
  const status = eventStatus(ev);
  const live = status === 'live' || status === 'expiring';
  const upcoming = isUpcoming(ev);
  const expired = isExpired(ev);
  const dietChips = getDietChips(ev);
  const sources = getSources(ev);
  const blUrl = boilerlinkUrl(ev);
  // Backend serializes is_free as int 1/0; default to free when absent.
  const isFree = ev.is_free === undefined ? true : !!ev.is_free;
  const startD = parseDate(ev.starts_at);
  const expD = parseDate(ev.expires_at);

  const headlineTime = upcoming ? fmtUntilStart(ev) : fmtTimeLeft(ev) || (expired ? 'ended' : 'happening now');
  const goingActive = (typeof window !== 'undefined') && localStorage.getItem(`fap_vote_${ev.id}_going`) === '1';
  const goneActive  = (typeof window !== 'undefined') && localStorage.getItem(`fap_vote_${ev.id}_gone`) === '1';

  return (
    <div className="ffp-detail">
      <button className="ffp-back" onClick={onBack}>
        <svg width="14" height="14" viewBox="0 0 14 14"><path d="M9 2 L4 7 L9 12" stroke="#2e1e0f" strokeWidth="1.5" fill="none" strokeLinecap="round" strokeLinejoin="round"/></svg>
        Back to feed
      </button>

      <div className="ffp-detail-hero">
        <div className="ffp-detail-emoji">{foodEmoji(ev.food_type)}</div>
        <div>
          <div className="ffp-card-row">
            <StatusDot status={status}/>
            <span className="ffp-status-label">
              {status === 'live' ? 'LIVE NOW'
                : status === 'expiring' ? 'ENDING SOON'
                : status === 'upcoming' ? 'UPCOMING'
                : 'ENDED'}
            </span>
          </div>
          <h2 className="ffp-detail-title">
            {ev.name || `${isFoodSpecified(ev.food_type) ? ev.food_type : 'Food'} at ${ev.building || 'Purdue'}`}
          </h2>
          <span className="ffp-time" style={{ color: live && !expired ? ACCENT : 'var(--muted)', fontWeight: 600 }}>
            {headlineTime}
          </span>
        </div>
      </div>

      <dl className="ffp-deflist">
        <div>
          <dt>Where</dt>
          <dd>
            <strong>{ev.building || ev.building_abbr || 'Purdue campus'}</strong>
            {ev.room && (<><br/><span className="ffp-muted">Room {ev.room}</span></>)}
          </dd>
        </div>
        <div>
          <dt>{upcoming ? 'Starts' : 'Available until'}</dt>
          <dd>
            <strong>
              {fmtClock(upcoming ? startD : expD) || '—'}
            </strong>
            <br/>
            <span className="ffp-muted">{postedOnLabel(ev)}</span>
          </dd>
        </div>
        <div>
          <dt>Food</dt>
          <dd>
            {isFoodSpecified(ev.food_type)
              ? <strong>{ev.food_type}</strong>
              : <span className="ffp-muted" style={{ fontStyle: 'italic' }}>Not specified</span>}
          </dd>
        </div>
        <div>
          <dt>Cost</dt>
          <dd>
            <span className="ffp-tag" style={isFree
              ? { background: '#e8f8d8', color: '#4a8020' }
              : { background: '#e4f0fa', color: '#2060a0' }}>
              {isFree ? 'Free' : '💰 Paid'}
            </span>
          </dd>
        </div>
        {dietChips.length > 0 && (
          <div>
            <dt>Dietary</dt>
            <dd>
              {dietChips.map(chip => (
                <span key={chip} className="ffp-tag" style={{ marginRight: 4 }}>{DIET_LABELS[chip].label}</span>
              ))}
            </dd>
          </div>
        )}
      </dl>

      {stripHtml(ev.description) && (
        <div className="ffp-notes">
          <div className="ffp-note-label">Description</div>
          <p>{stripHtml(ev.description)}</p>
        </div>
      )}

      <div className="ffp-share-row">
        {blUrl && (
          <a className="ffp-btn" href={blUrl} target="_blank" rel="noopener">
            View on BoilerLink ↗
          </a>
        )}
        {ev.rsvp_required && ev.rsvp_link ? (
          <a className="ffp-btn" href={ev.rsvp_link} target="_blank" rel="noopener">
            📋 RSVP ↗
          </a>
        ) : null}
        <button className="ffp-btn" onClick={() => onShare(ev)}>
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
            <path d="M6 1 V8 M3 4 L6 1 L9 4 M2 7 V10 H10 V7" stroke="#2e1e0f" strokeWidth="1.2" fill="none" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
          Share
        </button>
      </div>

      <div className="ffp-detail-actions">
        {(status === 'live' || status === 'expiring') && (
          <button
            className={`ffp-btn ffp-btn-lg ffp-btn-primary ${goingActive ? 'on' : ''}`}
            onClick={() => onGoing(ev)}
            style={{ background: ACCENT, borderColor: ACCENT }}>
            {goingActive ? '✓ Going' : "I'm going"}
            {ev.going_count > 0 && ` · ${ev.going_count}`}
          </button>
        )}
        {upcoming && (
          <>
            <button
              className={`ffp-btn ffp-btn-lg ffp-btn-primary ${goingActive ? 'on' : ''}`}
              onClick={() => onInterested?.(ev)}
              style={{ background: ACCENT, borderColor: ACCENT }}
              title="Mark as interested">
              ✦ {goingActive ? '✓ Interested' : 'Interested'}{ev.going_count > 0 ? ` · ${ev.going_count}` : ''}
            </button>
            <ReminderTrigger
              size="lg"
              ev={ev}
              hasReminder={!!hasReminder?.(ev.id)}
              onSet={(off) => onSetReminder?.(ev, off)}
              onClear={() => onClearReminder?.(ev)}
            />
          </>
        )}
        <button
          className={`ffp-btn ffp-btn-lg ${isSaved ? 'on' : ''}`}
          onClick={() => onSave(ev)}
          style={isSaved ? { color: ACCENT, borderColor: ACCENT } : null}
          title={isSaved ? 'Remove from saved' : 'Save for later'}>
          <svg width="14" height="16" viewBox="0 0 14 16" fill="none">
            <path d="M2 1.5 H12 V14.5 L7 11 L2 14.5 Z"
                  fill={isSaved ? ACCENT : 'none'}
                  stroke={isSaved ? ACCENT : '#2e1e0f'} strokeWidth="1.3" strokeLinejoin="round"/>
          </svg>
          {isSaved ? 'Saved' : 'Save'}
        </button>
        {(status === 'live' || status === 'expiring') && (
          <button
            className={`ffp-btn ffp-btn-lg ffp-btn-danger ${goneActive ? 'on' : ''}`}
            onClick={() => onGone(ev)}
            title="Report that the food is gone">
            {goneActive ? '✓ Reported' : "Food's gone"}
          </button>
        )}
      </div>

      <div className="ffp-confirm-feed">
        <div className="ffp-note-label">Recent activity</div>
        <ul>
          {[...activity].reverse().map(item => {
            const when = item.created_at
              ? new Date(item.created_at + 'Z').toLocaleString([], { dateStyle: 'short', timeStyle: 'short', timeZone: PURDUE_TZ })
              : '';
            const sourceLabel = item.source && (SOURCE_LABELS[item.source]?.label || item.source);
            if (item.kind === 'going') {
              return (
                <li key={item.id}>
                  <span className="ffp-mini-dot" style={{ background: ACCENT }}/>
                  <span>
                    Someone {upcoming ? 'marked interested' : "said they're going"}
                    {when && ` · ${when}`}
                  </span>
                </li>
              );
            }
            if (item.kind === 'gone') {
              return (
                <li key={item.id}>
                  <span className="ffp-mini-dot" style={{ background: 'var(--accent)' }}/>
                  <span>
                    Someone reported the food is gone
                    {when && ` · ${when}`}
                  </span>
                </li>
              );
            }
            if (item.kind === 'merged') {
              return (
                <li key={item.id}>
                  <span className="ffp-mini-dot"/>
                  <span>
                    Also reported{sourceLabel ? ` by ${sourceLabel}` : ''}
                    {when && ` · ${when}`}
                  </span>
                </li>
              );
            }
            // 'updated'
            const fieldLabel = ACTIVITY_FIELD_LABELS[item.field] || item.field;
            const newV = fmtActivityValue(item.field, item.new_value);
            const oldV = fmtActivityValue(item.field, item.old_value);
            const changeText = (item.old_value == null || item.old_value === '')
              ? <>{fieldLabel} set to <strong>{newV}</strong></>
              : <>{fieldLabel} changed: <span className="ffp-muted">{oldV}</span> → <strong>{newV}</strong></>;
            return (
              <li key={item.id}>
                <span className="ffp-mini-dot"/>
                <span>
                  {changeText}
                  {sourceLabel && ` · via ${sourceLabel}`}
                  {when && ` · ${when}`}
                </span>
              </li>
            );
          })}
          <li>
            <span className="ffp-mini-dot"/>
            <span>
              {postedOnLabel(ev)}
              {ev.created_at && ` · ${parseDate(ev.created_at)?.toLocaleString([], { dateStyle: 'short', timeStyle: 'short', timeZone: PURDUE_TZ })}`}
            </span>
          </li>
        </ul>
      </div>
    </div>
  );
}
