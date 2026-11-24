// Faithful React port of the original site's "Food Spotted!" modal.
//
// Flow (matches original):
//   1. User opens via the FAB (drag drops a pin + building hint, or tap = no
//      preset location). The header's "Report a sighting" button also opens
//      the modal with no preset location.
//   2. User describes the food in free text (or speaks via Web Speech, or
//      attaches a resized JPEG).
//   3. On Submit:
//        a) POST /events/validate — the AI extracts {name, location, foodType, time}.
//           Missing time auto-fills "(starting now, …)". Missing location auto-fills
//           "(at <building>)" if a pin is set. Otherwise we highlight what's
//           missing in the placeholder hint and stop.
//        b) POST /events/submit with the (possibly auto-filled) text + image +
//           lat/lng + building_abbr + outside_building.
//        c) If the backend returns ambiguous candidates, show the location picker.
//   4. On success: refresh the events list and pan the map to the new event.

import { useEffect, useRef, useState } from 'react';
import { API_BASE } from './api.js';

const IMAGE_MAX_EDGE = 1568;
const JPEG_QUALITY = 0.85;

function resizeToJpegBase64(file) {
  return new Promise((resolve, reject) => {
    const fr = new FileReader();
    fr.onerror = () => reject(new Error('read failed'));
    fr.onload = (ev) => {
      const img = new Image();
      img.onerror = () => reject(new Error('decode failed'));
      img.onload = () => {
        const scale = Math.min(1, IMAGE_MAX_EDGE / Math.max(img.width, img.height));
        const w = Math.max(1, Math.round(img.width * scale));
        const h = Math.max(1, Math.round(img.height * scale));
        const canvas = document.createElement('canvas');
        canvas.width = w; canvas.height = h;
        const ctx = canvas.getContext('2d');
        ctx.drawImage(img, 0, 0, w, h);
        const dataUrl = canvas.toDataURL('image/jpeg', JPEG_QUALITY);
        resolve({ base64: dataUrl.slice(dataUrl.indexOf(',') + 1), mime: 'image/jpeg' });
      };
      img.src = ev.target.result;
    };
    fr.readAsDataURL(file);
  });
}

function currentTimeString() {
  const now = new Date();
  let h = now.getHours();
  const m = now.getMinutes();
  const ampm = h >= 12 ? 'pm' : 'am';
  h = h % 12 || 12;
  return `${h}:${String(m).padStart(2, '0')}${ampm}`;
}

const FIELD_COLORS = {
  name:     { label: 'Event Name', cls: 'hl-name' },
  location: { label: 'Location',   cls: 'hl-location' },
  foodType: { label: 'Food Type',  cls: 'hl-foodType' },
  time:     { label: 'Time',       cls: 'hl-time' },
};

// Build the highlighted overlay HTML by wrapping each field's matched span
// (case-insensitive, longest-first to avoid overlapping replacements).
function buildHighlighted(text, fields) {
  const spans = [];
  for (const [key, info] of Object.entries(FIELD_COLORS)) {
    const f = fields[key];
    if (f && f.found && f.span) spans.push({ span: f.span, cls: info.cls });
  }
  spans.sort((a, b) => b.span.length - a.span.length);
  let out = text;
  for (const s of spans) {
    const escaped = s.span.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    out = out.replace(new RegExp(escaped, 'i'), m => `<span class="${s.cls}">${m}</span>`);
  }
  return out;
}

export default function SubmitModal({ open, openContext, onClose, onSubmitted }) {
  // openContext: null when opened from header (no preset location), or
  // { lat, lng, buildingAbbr, outsideBuilding, hint } when dragged from FAB.
  const [text, setText] = useState('');
  const [imageInfo, setImageInfo] = useState(null);
  const [imageData, setImageData] = useState(null); // {base64, mime}
  const [hint, setHint] = useState('');
  const [highlightHtml, setHighlightHtml] = useState(null); // string | null
  const [missing, setMissing] = useState({}); // {name:false, location:true, ...}
  const [suggestion, setSuggestion] = useState('');
  const [busy, setBusy] = useState(false);
  const [submitLabel, setSubmitLabel] = useState('Submit');
  const [voiceOn, setVoiceOn] = useState(false);
  const [voiceStatus, setVoiceStatus] = useState('');
  const [candidates, setCandidates] = useState(null); // null | array

  const fileInputRef = useRef(null);
  const recognitionRef = useRef(null);
  const textRef = useRef(null);

  // Refs that don't trigger re-render (parallel to original module-level state)
  const spotLatRef = useRef(null);
  const spotLngRef = useRef(null);
  const spotAbbrRef = useRef(null);
  const spotOutsideRef = useRef(false);
  const validationCacheRef = useRef(null); // { text, fields, suggestion }

  // Reset state when opened
  useEffect(() => {
    if (!open) return;
    setText('');
    setImageInfo(null); setImageData(null);
    setHighlightHtml(null); setMissing({}); setSuggestion('');
    setBusy(false); setSubmitLabel('Submit');
    setVoiceOn(false); setVoiceStatus('');
    setCandidates(null);
    validationCacheRef.current = null;

    if (openContext) {
      spotLatRef.current = openContext.lat;
      spotLngRef.current = openContext.lng;
      spotAbbrRef.current = openContext.buildingAbbr || null;
      spotOutsideRef.current = !!openContext.outsideBuilding;
      setHint('📍 ' + (openContext.hint || 'Pinned location on map'));
    } else {
      // No preset — reuse a recent geolocation fix if we have one (from window.__ffp).
      const fix = (typeof window !== 'undefined' ? window.__ffp?.userPos : null);
      if (fix) {
        spotLatRef.current = fix.lat;
        spotLngRef.current = fix.lng;
        spotAbbrRef.current = null;
        spotOutsideRef.current = false;
        setHint('📍 Using your current location');
      } else {
        spotLatRef.current = null;
        spotLngRef.current = null;
        spotAbbrRef.current = null;
        spotOutsideRef.current = false;
        setHint('📍 Allow location access, or drag the Spot-It button onto a building to drop a pin.');
      }
    }
    setTimeout(() => textRef.current?.focus(), 200);
  }, [open, openContext]);

  // Esc to close (only when not in the middle of an upstream call)
  useEffect(() => {
    if (!open) return;
    const onKey = (e) => { if (e.key === 'Escape' && !busy) onClose(); };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open, busy, onClose]);

  // Stop voice on unmount
  useEffect(() => () => { try { recognitionRef.current?.stop(); } catch {} }, []);

  // Typing in textarea while highlights are visible clears them (lets the user edit again).
  const onTextChange = (e) => {
    setText(e.target.value);
    if (highlightHtml) {
      setHighlightHtml(null);
      setMissing({});
      setSuggestion('');
    }
  };

  const onPickImage = async (e) => {
    const file = e.target.files?.[0];
    if (!file) return;
    setImageInfo({ name: `📎 ${file.name} (processing…)` });
    try {
      const data = await resizeToJpegBase64(file);
      setImageData(data);
      setImageInfo({ name: `📎 ${file.name}` });
    } catch {
      setImageData(null);
      setImageInfo({ name: '⚠️ Could not read image' });
    }
  };

  const toggleVoice = () => {
    const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SR) { setVoiceStatus('Voice input not supported in this browser'); return; }
    if (voiceOn) { try { recognitionRef.current?.stop(); } catch {} setVoiceOn(false); return; }
    const rec = new SR();
    rec.continuous = true; rec.interimResults = true; rec.lang = 'en-US';
    let baseFinal = text;
    rec.onresult = (e) => {
      let interim = '';
      for (let i = e.resultIndex; i < e.results.length; i++) {
        const r = e.results[i];
        if (r.isFinal) baseFinal += (baseFinal && !baseFinal.endsWith(' ') ? ' ' : '') + r[0].transcript;
        else interim += r[0].transcript;
      }
      setText(baseFinal + (interim ? ' ' + interim : ''));
    };
    rec.onerror = (e) => { setVoiceStatus(`Voice error: ${e.error}`); setVoiceOn(false); };
    rec.onend = () => setVoiceOn(false);
    try { rec.start(); recognitionRef.current = rec; setVoiceOn(true); setVoiceStatus('Listening…'); }
    catch { setVoiceStatus('Could not start voice input'); }
  };

  const submit = async (forceBuildingAbbr = null) => {
    if (busy) return;
    const ta = textRef.current;
    let body = text.trim();
    if (!body && !imageData) {
      setSuggestion('Please describe the food or attach a photo.');
      return;
    }
    setBusy(true);
    setSubmitLabel('Validating…');
    setSuggestion('');
    setCandidates(null);

    try {
      // Step 1: validate
      let val = validationCacheRef.current && validationCacheRef.current.text === body
        ? validationCacheRef.current
        : null;
      if (!val) {
        const r = await fetch(`${API_BASE}/events/validate`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ text: body }),
        });
        const data = await r.json();
        if (!r.ok) {
          setSuggestion(data?.detail || 'Validation failed.');
          setBusy(false); setSubmitLabel('Submit');
          return;
        }
        val = { text: body, fields: data.fields || {}, suggestion: data.suggestion || '' };
        validationCacheRef.current = val;
      }
      let fields = { ...val.fields };
      let autoFilled = false;

      // Auto-fill missing time
      if (!fields.time || !fields.time.found) {
        const ts = currentTimeString();
        const suffix = `(starting now, ${ts})`;
        body = (body.replace(/\s+$/, '')) + ' ' + suffix;
        fields.time = { found: true, value: ts, span: suffix };
        autoFilled = true;
      }
      // Auto-fill missing location from pin
      const hasPin = spotLatRef.current !== null && spotLngRef.current !== null;
      if ((!fields.location || !fields.location.found) && hasPin) {
        const pinLabel = spotAbbrRef.current
          ? (spotOutsideRef.current ? `Outside ${spotAbbrRef.current}` : spotAbbrRef.current)
          : 'pin location';
        const suffix = `(at ${pinLabel})`;
        body = (body.replace(/\s+$/, '')) + ' ' + suffix;
        fields.location = { found: true, value: pinLabel, span: suffix };
        autoFilled = true;
      }
      if (autoFilled) setText(body);

      // Mark missing fields
      const m = {};
      let allFound = true;
      for (const key of Object.keys(FIELD_COLORS)) {
        const f = fields[key];
        const found = !!(f && f.found);
        m[key] = !found;
        if (!found) allFound = false;
      }
      setMissing(m);

      if (!allFound) {
        setSuggestion(val.suggestion || 'Please add the missing details and try again.');
        setHighlightHtml(buildHighlighted(body, fields));
        setBusy(false); setSubmitLabel('Submit');
        return;
      }

      setSuggestion('');
      setHighlightHtml(buildHighlighted(body, fields));

      if (autoFilled) {
        setSubmitLabel('Submitting…');
        await new Promise(r => setTimeout(r, 1500));
      } else {
        setSubmitLabel('Submitting…');
      }

      // Step 2: submit
      const payload = { text: body };
      if (imageData) { payload.image_base64 = imageData.base64; payload.image_mime = imageData.mime; }
      if (spotLatRef.current !== null) { payload.lat = spotLatRef.current; payload.lng = spotLngRef.current; }
      if (spotAbbrRef.current) {
        payload.building_abbr = spotAbbrRef.current;
        payload.outside_building = spotOutsideRef.current;
      }
      if (forceBuildingAbbr) payload.force_building_abbr = forceBuildingAbbr;

      const r = await fetch(`${API_BASE}/events/submit`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      const data = await r.json();
      if (!r.ok) {
        setSuggestion(data?.detail || 'Submission failed — try again.');
        setBusy(false); setSubmitLabel('Submit');
        return;
      }
      if (data.status === 'ambiguous' && Array.isArray(data.candidates)) {
        setCandidates(data.candidates);
        setBusy(false); setSubmitLabel('Submit');
        return;
      }

      onSubmitted?.({ lat: data.lat, lng: data.lng, foodType: data.foodType });
      onClose();
    } catch (err) {
      console.error('[submitSpot]', err);
      setSuggestion('Network error — please try again.');
      setBusy(false); setSubmitLabel('Submit');
    }
  };

  const pickCandidate = async (abbr) => {
    setCandidates(null);
    await submit(abbr);
  };

  if (!open) return null;

  return (
    <div
      id="spot-overlay"
      className="show"
      onClick={(e) => { if (e.target === e.currentTarget && !busy) onClose(); }}>
      <div id="spot-modal">
        <h2>
          <span className="p-logo-icon" style={{ width: '1.1em', height: '1.1em', verticalAlign: -2 }} />
          {' '}Food Spotted!
        </h2>
        <div className="spot-hint">
          Describe what you saw — <span className={`hint-name ${missing.name ? 'hint-missing' : ''}`}>Event Name</span>,{' '}
          <span className={`hint-location ${missing.location ? 'hint-missing' : ''}`}>Location</span>,{' '}
          <span className={`hint-foodType ${missing.foodType ? 'hint-missing' : ''}`}>Food Type</span>,{' '}
          <span className={`hint-time ${missing.time ? 'hint-missing' : ''}`}>Time</span>
        </div>
        <div id="spot-loc-hint">{hint}</div>

        <div id="spot-text-wrap">
          <textarea
            id="spot-text"
            ref={textRef}
            value={text}
            onChange={onTextChange}
            placeholder="e.g. free pizza in the WALC lobby until 4pm"
            disabled={busy}
          />
          {highlightHtml && (
            <div
              id="spot-highlighted"
              onClick={() => { setHighlightHtml(null); setMissing({}); textRef.current?.focus(); }}
              dangerouslySetInnerHTML={{ __html: highlightHtml }}
            />
          )}
        </div>

        <div id="spot-attach-row">
          <label id="spot-image-label" htmlFor="spot-image-input">📷 Attach a photo or flyer (optional)</label>
          <button
            id="spot-mic-btn"
            type="button"
            className={voiceOn ? 'listening' : ''}
            onClick={toggleVoice}
            disabled={busy}
            title="Speak your description">
            🎙 {voiceOn ? 'Stop' : 'Speak'}
          </button>
          <span id="spot-voice-status">{voiceStatus}</span>
        </div>
        <input
          ref={fileInputRef}
          type="file" accept="image/*"
          id="spot-image-input"
          onChange={onPickImage}
        />
        {imageInfo && (
          <div id="spot-image-preview" style={{ display: 'block', marginBottom: 10 }}>
            {imageInfo.name}
          </div>
        )}

        <div id="spot-suggestion">{suggestion}</div>

        {candidates && (
          <div id="spot-loc-picker" style={{ display: 'block' }}>
            <div className="label">Multiple matches — pick the right one:</div>
            <div className="btns">
              {candidates.map(c => (
                <button key={c.abbr} className="loc-pick-btn" onClick={() => pickCandidate(c.abbr)}>
                  🏛 {c.full_name}
                  <span className="loc-pick-score">{Math.round((c.score || 0) * 100)}% match</span>
                </button>
              ))}
              <button className="loc-pick-btn" style={{ color: 'var(--text-muted)' }} onClick={() => pickCandidate(null)}>
                ❓ None of these / Unknown location
              </button>
            </div>
          </div>
        )}

        <div className="spot-actions">
          <button id="spot-cancel" type="button" onClick={onClose} disabled={busy}>Cancel</button>
          <button id="spot-submit" type="button" onClick={() => submit()} disabled={busy}>{submitLabel}</button>
        </div>
      </div>
    </div>
  );
}
