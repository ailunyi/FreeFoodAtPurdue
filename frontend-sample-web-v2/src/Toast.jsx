// Stack of toasts at the bottom of the viewport.
export default function Toast({ toasts }) {
  if (!toasts.length) return null;
  return (
    <div style={{ position: 'fixed', left: '50%', bottom: 28, transform: 'translateX(-50%)', zIndex: 200, display: 'flex', flexDirection: 'column', gap: 6, alignItems: 'center', pointerEvents: 'none' }}>
      {toasts.map(t => (
        <div key={t.id} className="ffp-toast" style={{ position: 'static', transform: 'none' }}>{t.msg}</div>
      ))}
    </div>
  );
}
