import { useState, useEffect } from 'react';
import { fetchWeeklySummary } from '../api';
import { StatSection } from './SummaryBox';

export default function WeeklySummary() {
  const [data, setData] = useState(null);
  useEffect(() => {
    fetchWeeklySummary().then(setData).catch(() => {});
  }, []);
  if (!data) return null;
  return <StatSection title="This Week" data={data} />;
}
