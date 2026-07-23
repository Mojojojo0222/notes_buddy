import { useState, useEffect } from 'react';
import { fetchSummary } from '../api';

export default function SummaryBox() {
  const [data, setData] = useState({ totalCommands: '—', mostUsed: '—', topicsTouched: [] });
  useEffect(() => {
    fetchSummary().then(setData).catch(() => {});
  }, []);
  return (
    <StatSection title="Today's Summary" data={data} />
  );
}

export function StatSection({ title, data }) {
  const { date, totalCommands, mostUsed, topicsTouched, sessions, errorCount } = data;
  return (
    <div className="bg-surface border border-border rounded-lg p-[18px_22px] mb-6">
      <h2 className="text-accent text-[0.72rem] uppercase tracking-widest mb-4">{title}</h2>
      <div className="grid grid-cols-[repeat(auto-fit,minmax(140px,1fr))] gap-3">
        <Stat label="Commands Run" value={totalCommands ?? '—'} />
        {sessions !== undefined && <Stat label="Sessions" value={sessions ?? '—'} />}
        <Stat label="Most Used" value={mostUsed ?? '—'} />
        {errorCount !== undefined && <Stat label="Errors Found" value={errorCount ?? '—'} />}
        <div className="stat bg-[#0d1117] border border-border-light rounded-md p-3">
          <div className="stat-label text-text-muted text-[0.7rem] uppercase tracking-wider mb-1.5">
            {title.includes('Weekly') ? 'Categories' : 'Topics Touched'}
          </div>
          <div className="flex flex-wrap gap-1.5 mt-0.5">
            {(topicsTouched ?? []).length > 0
              ? topicsTouched.map(t => <span key={t} className="topic-tag">{t}</span>)
              : <span className="text-text-muted">—</span>
            }
          </div>
        </div>
      </div>
    </div>
  );
}

function Stat({ label, value }) {
  return (
    <div className="bg-[#0d1117] border border-border-light rounded-md p-3">
      <div className="text-text-muted text-[0.7rem] uppercase tracking-wider mb-1.5">{label}</div>
      <div className="text-text-bright text-base">{value}</div>
    </div>
  );
}
