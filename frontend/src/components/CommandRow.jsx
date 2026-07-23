import { useState } from 'react';
import { CatBadge } from './FilterButtons';
import { saveTag } from '../api';

export default function CommandRow({ cmd, onTagged }) {
  const [editing, setEditing] = useState(false);
  const [tagVal, setTagVal] = useState(cmd.tag || '');

  const t = new Date(cmd.savedAt).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: false });
  const ec = cmd.exitCode !== null && cmd.exitCode !== undefined;
  const dirPart = cmd.workingDir && cmd.workingDir !== 'unknown' ? cmd.workingDir : null;
  const repoPart = cmd.repoName && cmd.repoName !== 'none' ? cmd.repoName : null;

  function finish() {
    setEditing(false);
    const trimmed = tagVal.trim();
    saveTag(cmd.id, trimmed).then(() => { if (onTagged) onTagged(); });
  }

  function cancel() {
    setEditing(false);
    setTagVal(cmd.tag || '');
  }

  return (
    <div className="grid grid-cols-[52px_1fr] gap-0 gap-x-4 px-[18px] py-2.5 border-b border-[#0d1117] last:border-b-0 hover:bg-surface-hover transition-colors">
      <span className="text-text-muted text-[0.78rem] pt-0.5 whitespace-nowrap">{t}</span>
      <div className="flex flex-col gap-1 min-w-0">
        <div className="flex items-center gap-2.5 flex-wrap">
          <span className="text-text-link text-sm break-all">{escapeHtml(cmd.text)}</span>
          <CatBadge category={cmd.category} />
          {ec && (
            <span className={`text-[0.72rem] px-[6px] py-[1px] rounded font-bold border
              ${cmd.exitCode === 0
                ? 'text-[#3fb950] border-[#2ea04340]'
                : 'text-[#f85149] border-[#f8514940]'}`}>
              {cmd.exitCode === 0 ? '✓' : '✗ ' + cmd.exitCode}
            </span>
          )}
        </div>
        {(dirPart || repoPart || true) && (
          <div className="flex gap-3.5 flex-wrap items-center">
            {dirPart && <MetaItem icon="📁" value={dirPart} />}
            {repoPart && <MetaItem icon="🔀" value={repoPart} />}
            <span className="tag-wrap inline-flex items-center gap-1">
              {editing ? (
                <input
                  type="text"
                  className="tag-input"
                  value={tagVal}
                  onChange={e => setTagVal(e.target.value)}
                  onBlur={finish}
                  onKeyDown={e => { if (e.key === 'Enter') finish(); if (e.key === 'Escape') cancel(); }}
                  autoFocus
                />
              ) : (
                <span
                  className="tag-badge"
                  onClick={() => { setEditing(true); setTagVal(cmd.tag || ''); }}
                >{cmd.tag ? escapeHtml(cmd.tag) : '+'}</span>
              )}
            </span>
          </div>
        )}
      </div>
    </div>
  );
}

function MetaItem({ icon, value }) {
  return (
    <span className="text-text-muted text-[0.72rem] flex items-center gap-1">
      {icon} <span className="text-[#6e7681]">{escapeHtml(value)}</span>
    </span>
  );
}

function escapeHtml(text) {
  return String(text).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
