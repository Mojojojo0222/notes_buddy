import { useLocalStorage } from '../hooks';

const CAT_COLORS = {
  git:        'bg-[#1a2e1a] text-[#56d364] border-[#2ea04326]',
  docker:     'bg-[#0d2137] text-[#58a6ff] border-[#1f6feb26]',
  kubernetes: 'bg-[#1a1a2e] text-[#a5a0ff] border-[#6e40c926]',
  terraform:  'bg-[#2e1a2e] text-[#d2a8ff] border-[#8957e526]',
  build:      'bg-[#2e2a0d] text-[#e3b341] border-[#9e6a0326]',
  files:      'bg-[#1a1a1a] text-[#8b949e] border-[#30363d]',
  network:    'bg-[#2e1a1a] text-[#ffa198] border-[#da363326]',
  editor:     'bg-[#1a2a2e] text-[#76e3ea] border-[#1b7c8326]',
  other:      'bg-[#1a1a1a] text-[#6e7681] border-[#21262d]',
};

export default function FilterButtons({ categories, activeFilters, onToggle, onClear }) {
  return (
    <div className="flex flex-wrap gap-1.5 mb-7">
      <button
        className={`filter-btn ${activeFilters.size === 0 ? 'active' : ''}`}
        onClick={onClear}
      >all</button>
      {[...categories].sort().map(cat => (
        <button
          key={cat}
          className={`filter-btn ${activeFilters.has(cat) ? 'active' : ''}`}
          onClick={() => onToggle(cat)}
        >{cat}</button>
      ))}
    </div>
  );
}

export function CatBadge({ category }) {
  const c = category || 'other';
  const colors = CAT_COLORS[c] || CAT_COLORS.other;
  return (
    <span className={`text-[0.65rem] px-[7px] py-[1px] rounded-[10px] whitespace-nowrap border ${colors}`}>
      {c}
    </span>
  );
}
