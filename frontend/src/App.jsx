import { useState, useEffect, useCallback, useRef } from 'react';
import Header from './components/Header';
import SummaryBox from './components/SummaryBox';
import WeeklySummary from './components/WeeklySummary';
import TimelineBar from './components/TimelineBar';
import SearchBar from './components/SearchBar';
import FilterButtons from './components/FilterButtons';
import SessionCard from './components/SessionCard';
import { fetchSessions, fetchByDate, fetchSearch } from './api';
import { useInterval, useLocalStorage } from './hooks';

export default function App() {
  const [sessions, setSessions] = useState([]);
  const [selectedDate, setSelectedDate] = useState('');
  const [searchQuery, setSearchQuery] = useState('');
  const [activeFilters, setActiveFilters] = useLocalStorage('notesBuddyFilters', []);
  const [refreshKey, setRefreshKey] = useState(0);
  const justTagged = useRef(false);

  const activeSet = new Set(activeFilters);

  const load = useCallback(async () => {
    try {
      let data;
      if (searchQuery) {
        const cmds = await fetchSearch(searchQuery);
        data = groupByDate(cmds);
      } else if (selectedDate) {
        const cmds = await fetchByDate(selectedDate);
        data = cmds.length > 0 ? [{
          startTime: cmds[0].savedAt,
          endTime: cmds[cmds.length - 1].savedAt,
          durationMins: 0,
          commandCount: cmds.length,
          categories: [...new Set(cmds.map(c => c.category).filter(Boolean))],
          commands: cmds,
        }] : [];
      } else {
        data = await fetchSessions();
      }
      setSessions(data);
    } catch { /* ignore */ }
  }, [searchQuery, selectedDate]);

  // initial load + auto refresh
  useEffect(() => { load(); }, [load, refreshKey]);
  useInterval(() => { if (!justTagged.current) setRefreshKey(k => k + 1); }, 15000);

  function handleTagged() {
    justTagged.current = true;
    load().then(() => { justTagged.current = false; });
  }

  function handleSearch(q) { setSearchQuery(q); setSelectedDate(''); }
  function handleClearSearch() { setSearchQuery(''); }

  function toggleFilter(cat) {
    const next = activeSet.has(cat)
      ? activeFilters.filter(c => c !== cat)
      : [...activeFilters, cat];
    setActiveFilters(next);
  }

  function clearFilters() { setActiveFilters([]); }

  // compute available categories from loaded sessions
  const allCats = new Set();
  sessions.forEach(s => (s.categories || []).forEach(c => allCats.add(c)));

  // apply client-side filters
  const filtered = sessions
    .map(s => {
      const cmds = (s.commands || []).filter(c => {
        if (activeSet.size === 0) return true;
        return activeSet.has(c.category);
      });
      return { ...s, commands: cmds };
    })
    .filter(s => s.commands.length > 0);

  return (
    <div className="max-w-[860px] mx-auto px-6 py-8 pb-20">
      <Header />
      <SummaryBox />
      <WeeklySummary />
      <TimelineBar
        selectedDate={selectedDate}
        onDateChange={d => { setSelectedDate(d); handleClearSearch(); }}
        onClearSearch={handleClearSearch}
      />
      <SearchBar onSearch={handleSearch} onClear={handleClearSearch} />
      <FilterButtons
        categories={allCats}
        activeFilters={activeSet}
        onToggle={toggleFilter}
        onClear={clearFilters}
      />
      {filtered.length === 0 ? (
        <div className="text-text-muted text-center py-16 text-sm">no commands found</div>
      ) : (
        filtered.map((s, i) => (
          <SessionCard key={i} session={s} idx={i} autoOpen={i === 0} onCommandTagged={handleTagged} />
        ))
      )}
    </div>
  );
}

function groupByDate(cmds) {
  const byDate = {};
  for (const c of cmds) {
    const d = new Date(c.savedAt).toLocaleDateString('en-CA');
    if (!byDate[d]) byDate[d] = { date: d, commands: [] };
    byDate[d].commands.push(c);
  }
  return Object.values(byDate).map(g => ({
    startTime: g.commands[0].savedAt,
    endTime: g.commands[g.commands.length - 1].savedAt,
    durationMins: 0,
    commandCount: g.commands.length,
    categories: [...new Set(g.commands.map(c => c.category).filter(Boolean))],
    commands: g.commands,
  }));
}
