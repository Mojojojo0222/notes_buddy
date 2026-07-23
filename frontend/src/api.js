const BASE = '';

export async function fetchJSON(url) {
  const res = await fetch(BASE + url);
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${res.url}`);
  return res.json();
}

export function fetchSummary() {
  return fetchJSON('/summary');
}

export function fetchWeeklySummary() {
  return fetchJSON('/summary/weekly');
}

export function fetchSessions() {
  return fetchJSON('/sessions');
}

export function fetchByDate(date) {
  return fetchJSON(`/commands/by-date?date=${date}`);
}

export function fetchSearch(query) {
  return fetchJSON(`/commands/search?q=${encodeURIComponent(query)}`);
}

export function saveTag(id, tag) {
  return fetch(`/commands/${id}/tag?tag=${encodeURIComponent(tag)}`, { method: 'POST' });
}
