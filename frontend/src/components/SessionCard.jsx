import { useState } from 'react';
import CommandRow from './CommandRow';
import { CatBadge } from './FilterButtons';

export default function SessionCard({ session, idx, autoOpen, onCommandTagged }) {
  const [open, setOpen] = useState(autoOpen);

  const start = new Date(session.startTime);
  const end = new Date(session.endTime);
  const dateStr = start.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' });
  const startStr = start.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: false });
  const endStr = end.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: false });
  const dur = formatDuration(session.durationMins);
  const isTimeline = !session.commandCount;

  return (
    <div className="bg-surface border border-border-light rounded-lg mb-4 overflow-hidden">
      <div
        className="flex items-center justify-between px-[18px] py-3.5 cursor-pointer select-none border-b border-border-light hover:bg-surface-hover transition-colors"
        onClick={() => setOpen(!open)}
      >
        <div className="flex flex-col gap-1.5">
          <div className="text-text-bright text-sm">
            {dateStr} &nbsp;·&nbsp; {startStr} → {endStr}
            {!isTimeline && <span>&nbsp;·&nbsp; {dur}</span>}
          </div>
          <div className="flex items-center gap-3 flex-wrap">
            <span className="text-text-muted text-[0.72rem]">{session.commandCount || session.commands?.length} commands</span>
            <div className="flex gap-1.5 flex-wrap">
              {(session.categories || []).map(c => <CatBadge key={c} category={c} />)}
            </div>
          </div>
        </div>
        <span className={`text-text-muted text-xs transition-transform duration-200 ${open ? 'rotate-180' : ''}`}>▼</span>
      </div>
      {open && (
        <div>
          {(session.commands || []).map(cmd => (
            <CommandRow key={cmd.id} cmd={cmd} onTagged={onCommandTagged} />
          ))}
        </div>
      )}
    </div>
  );
}

function formatDuration(mins) {
  if (!mins || mins < 1) return '< 1 min';
  if (mins < 60) return `${mins}m`;
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  return m > 0 ? `${h}h ${m}m` : `${h}h`;
}
