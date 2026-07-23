export default function TimelineBar({ selectedDate, onDateChange, onClearSearch }) {
  const today = () => new Date().toLocaleDateString('en-CA');

  function shiftDay(delta) {
    const d = selectedDate ? new Date(selectedDate + 'T00:00:00') : new Date();
    d.setDate(d.getDate() + delta);
    onDateChange(d.toLocaleDateString('en-CA'));
  }

  function handlePick(e) {
    if (e.target.value) onDateChange(e.target.value);
  }

  return (
    <div className="flex items-center gap-3 bg-surface border border-border rounded-lg px-[18px] py-3 mb-4">
      <label className="text-text-muted text-[0.75rem] uppercase tracking-wider whitespace-nowrap">
        📅 Timeline
      </label>
      <button className="nav-btn" onClick={() => shiftDay(-1)}>‹ Prev</button>
      <input
        type="date"
        className="timeline-input"
        value={selectedDate || today()}
        onChange={handlePick}
      />
      <button className="nav-btn" onClick={() => shiftDay(1)}>Next ›</button>
      <button className="nav-btn" onClick={() => { onClearSearch(); onDateChange(today()); }}>
        Today
      </button>
      <button className="nav-btn" onClick={() => { onClearSearch(); onDateChange(''); }}>
        All
      </button>
    </div>
  );
}
