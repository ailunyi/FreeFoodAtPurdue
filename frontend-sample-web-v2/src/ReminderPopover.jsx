// Anchored popover with three "before-the-event" offset chips.
//
// The trigger button is provided by the caller via `<ReminderTrigger>`. This
// file exports both the trigger and the popover. The popover positions itself
// directly below its trigger, closes on outside-click / Escape, and disables
// chips whose computed fireAt is in the past.

import { useEffect, useRef, useState } from 'react';
import { ensureNotificationPermission } from './useReminders.js';
import { parseDate } from './helpers.js';

const OFFSETS = [
  { id: '15m', label: '15 min before', ms: 15 * 60_000 },
  { id: '1h',  label: '1 hour before', ms: 60 * 60_000 },
  { id: '1d',  label: '1 day before',  ms: 24 * 60 * 60_000 },
];

export function humanOffset(ms) {
  if (ms >= 24 * 60 * 60_000) return `${Math.round(ms / (24 * 60 * 60_000))} day`;
  if (ms >= 60 * 60_000)      return `${Math.round(ms / (60 * 60_000))} hour`;
  return `${Math.round(ms / 60_000)} min`;
}

export default function ReminderTrigger({ ev, hasReminder, onSet, onClear, size = 'sm' }) {
  const [open, setOpen] = useState(false);
  const wrapRef = useRef(null);

  useEffect(() => {
    if (!open) return;
    const onDocClick = (e) => { if (!wrapRef.current?.contains(e.target)) setOpen(false); };
    const onKey = (e) => { if (e.key === 'Escape') setOpen(false); };
    document.addEventListener('mousedown', onDocClick);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onDocClick);
      document.removeEventListener('keydown', onKey);
    };
  }, [open]);

  const btnClass = size === 'lg'
    ? `ffp-btn ffp-btn-lg ffp-reminder ${hasReminder ? 'on' : ''}`
    : `ffp-btn ffp-reminder ${hasReminder ? 'on' : ''}`;

  const onClick = () => {
    if (hasReminder) onClear();
    else setOpen(o => !o);
  };

  return (
    <div className="ffp-reminder-wrap" ref={wrapRef}>
      <button type="button" className={btnClass} onClick={onClick}
              aria-expanded={open} aria-haspopup="dialog"
              title={hasReminder ? 'Clear reminder' : 'Set reminder'}>
        🔔 {hasReminder ? 'Set ✕' : (size === 'lg' ? 'Remind' : 'Remind me')}
      </button>
      {open && !hasReminder && (
        <ReminderPopover
          ev={ev}
          onPick={(offsetMs) => { onSet(offsetMs); setOpen(false); }}
          onClose={() => setOpen(false)}
        />
      )}
    </div>
  );
}

function ReminderPopover({ ev, onPick, onClose }) {
  const [permState, setPermState] = useState(
    typeof Notification !== 'undefined' ? Notification.permission : 'unsupported'
  );
  const start = parseDate(ev.starts_at)?.getTime() ?? 0;
  const now = Date.now();

  const choose = async (ms) => {
    const perm = await ensureNotificationPermission();
    setPermState(perm);
    if (perm !== 'granted') return; // popover stays open with the inline note
    onPick(ms);
  };

  const allTooSoon = OFFSETS.every(o => start - o.ms <= now + 30_000);

  return (
    <div className="ffp-reminder-popover" role="dialog" aria-label="Set reminder">
      <div className="ffp-reminder-pop-label">Notify me</div>
      {allTooSoon ? (
        <div className="ffp-reminder-pop-note">Event is too soon to set a reminder.</div>
      ) : (
        <div className="ffp-reminder-pop-list">
          {OFFSETS.map(o => {
            const tooSoon = start - o.ms <= now + 30_000;
            return (
              <button
                key={o.id}
                type="button"
                className="ffp-reminder-pop-chip"
                disabled={tooSoon}
                onClick={() => choose(o.ms)}>
                {o.label}
              </button>
            );
          })}
        </div>
      )}
      {permState === 'denied' && (
        <div className="ffp-reminder-pop-note ffp-reminder-pop-denied">
          Notifications are blocked in your browser. Reminders won't fire until you allow them in site settings.
        </div>
      )}
      {permState === 'unsupported' && (
        <div className="ffp-reminder-pop-note">
          This browser doesn't support notifications.
        </div>
      )}
      {(permState === 'granted' || permState === 'default') && !allTooSoon && (
        <div className="ffp-reminder-pop-hint">
          You'll be reminded as long as this tab is open or you reopen it before then.
        </div>
      )}
    </div>
  );
}
