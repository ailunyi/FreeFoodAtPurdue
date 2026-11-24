// v2 header — sidebar toggle + logo + view tabs + active-events chip.
const ACCENT = 'var(--accent)';

export default function Header({ view, liveCount, savedCount, onChangeView, sidebarCollapsed, onToggleSidebar }) {
  return (
    <header className="ffp-header">
      <button
        className="ffp-panel-open-btn"
        onClick={onToggleSidebar}
        title={sidebarCollapsed ? 'Show feed' : 'Hide feed'}
        aria-label={sidebarCollapsed ? 'Show feed' : 'Hide feed'}>
        {sidebarCollapsed ? (
          <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
            <path d="M2 3.5 H12 M2 7 H12 M2 10.5 H12" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round"/>
          </svg>
        ) : (
          <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
            <path d="M9 2 L4 7 L9 12" stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        )}
      </button>
      <a href="/" className="ffp-logo" onClick={(e) => { e.preventDefault(); onChangeView('all'); }}>
        <img src="/images/logo-p.png" alt="Free Food at Purdue logo"/>
        <div>
          <div className="ffp-wordmark">Free Food <em>at</em> Purdue</div>
        </div>
      </a>
      <div className="ffp-header-spacer"/>

      <div className="ffp-viewtabs">
        <button
          className={`ffp-viewtab ${view==='all' ? 'on' : ''}`}
          onClick={() => onChangeView('all')}
          style={view==='all' ? { color: ACCENT, borderBottomColor: ACCENT } : null}>
          All sightings
          <span className="ffp-viewtab-count">{liveCount} live</span>
        </button>
        <button
          className={`ffp-viewtab ${view==='saved' ? 'on' : ''}`}
          onClick={() => onChangeView('saved')}
          style={view==='saved' ? { color: ACCENT, borderBottomColor: ACCENT } : null}>
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" style={{marginRight:5}}>
            <path d="M3 1.5 H9 V10.5 L6 8 L3 10.5 Z"
                  fill={view==='saved' ? ACCENT : 'none'}
                  stroke={view==='saved' ? ACCENT : '#2e1e0f'} strokeWidth="1.2" strokeLinejoin="round"/>
          </svg>
          Saved
          {savedCount > 0 && (
            <span className="ffp-viewtab-badge"
                  style={{ background: view==='saved' ? ACCENT : '#2e1e0f' }}>
              {savedCount}
            </span>
          )}
        </button>
        <button
          className={`ffp-viewtab ${view==='dining' ? 'on' : ''}`}
          onClick={() => onChangeView('dining')}
          style={view==='dining' ? { color: ACCENT, borderBottomColor: ACCENT } : null}>
          <svg width="12" height="12" viewBox="0 0 14 14" fill="none" style={{marginRight:5}}>
            <path d="M2 2 V6 a2 2 0 0 0 4 0 V2 M4 6 V12 M9 2 C8 4 8 6 9 7 V12"
                  stroke={view==='dining' ? ACCENT : '#2e1e0f'} strokeWidth="1.3" fill="none"
                  strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
          Dining
        </button>
      </div>

      <span className="ffp-livecount large" title="Sightings active right now">
        <span className="ffp-livecount-dot" style={{ background: ACCENT }}/>
        <strong>{liveCount}</strong>
        <span className="ffp-muted">active</span>
      </span>
    </header>
  );
}
