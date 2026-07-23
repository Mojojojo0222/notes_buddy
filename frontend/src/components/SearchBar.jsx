import { useState } from 'react';
import { useDebounce } from '../hooks';

export default function SearchBar({ onSearch, onClear }) {
  const [value, setValue] = useState('');
  const debounced = useDebounce(value, 300);

  // notify parent when debounced value settles
  const [lastSent, setLastSent] = useState('');
  if (debounced !== lastSent) {
    setLastSent(debounced);
    if (debounced.length >= 2) {
      onSearch(debounced);
    } else if (debounced.length === 0) {
      onClear();
    }
  }

  return (
    <div className="relative mb-3">
      <span className="absolute left-3 top-1/2 -translate-y-1/2 text-text-muted text-sm pointer-events-none">🔍</span>
      <input
        type="text"
        className="w-full pl-9 pr-3.5 py-2.5 bg-surface border border-border rounded-md text-text font-mono text-sm outline-none focus:border-accent transition-colors"
        placeholder="Search all commands (server-side)..."
        value={value}
        onChange={e => setValue(e.target.value)}
      />
    </div>
  );
}
