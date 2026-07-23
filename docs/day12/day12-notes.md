# Day 12 — Full-Text Search

**Goal:** Search every command ever logged — not just the visible ones in the current view. Server-side `ILIKE` search across text, tags, directories, repo names, and categories.

---

## Session Context

Day 11 added exit codes, tags, timeline, weekly summary, and filter persistence. The dashboard was now useful for daily work. But the search box only filtered commands already loaded in memory — you couldn't search "terraform apply" and find the command from 3 weeks ago.

The vision from Day 1 was: "searchable memory of everything you've ever learned and solved." Full-text search is the feature that makes this real.

---

## Feature: Server-Side Full-Text Search

### Problem

Before Day 12, the search box was a client-side filter:

```javascript
// Old: only searches commands already fetched from /sessions
const matchSearch = query === '' ||
    c.text.toLowerCase().includes(query) ||
    (c.tag && c.tag.toLowerCase().includes(query));
```

This worked fine for the current session view — maybe 50-500 commands loaded. But total history could be thousands of commands across months of work. You couldn't reach the past.

### Solution: Server-Side Search API

#### Step 1: CommandRepository — `searchCommands()`

```java
@Query("SELECT c FROM Command c WHERE " +
       "LOWER(c.text) LIKE LOWER(CONCAT('%', :query, '%')) OR " +
       "LOWER(c.tag) LIKE LOWER(CONCAT('%', :query, '%')) OR " +
       "LOWER(c.workingDir) LIKE LOWER(CONCAT('%', :query, '%')) OR " +
       "LOWER(c.repoName) LIKE LOWER(CONCAT('%', :query, '%')) OR " +
       "LOWER(c.category) LIKE LOWER(CONCAT('%', :query, '%')) " +
       "ORDER BY c.savedAt ASC")
List<Command> searchCommands(@Param("query") String query);
```

**Why `@Query` with JPQL, not a derived method name?**
- The method name would be absurd: `findByTextContainingIgnoreCaseOrTagContainingIgnoreCaseOr...`
- `@Query` keeps it readable and lets you see the exact SQL
- `LOWER()` + `LIKE CONCAT('%', :query, '%')` = case-insensitive substring match
- Covers 5 fields: text, tag, workingDir, repoName, category — so typing "docker" finds all docker commands even if auto-categorization failed

**Why not PostgreSQL full-text search (`tsvector`/`tsquery`)?**
- `ILIKE` is simpler and sufficient for this scale (thousands of commands, not millions)
- Full-text search with `tsvector` would need:
  - A new `tsvector` column
  - A database trigger or application-side update
  - A GIN index
  - More complex query syntax
- Trade-off: `ILIKE` is slower on large datasets but zero complexity. Revisit if the DB exceeds 100k rows.

#### Step 2: CommandController — `GET /commands/search`

```java
@GetMapping("/commands/search")
public List<Command> search(@RequestParam String q) {
    if (q == null || q.isBlank()) return List.of();
    return repo.searchCommands(q.trim());
}
```

**Design decisions:**
- Query param is `q` not `query` — shorter URL, common convention (`?q=terraform`)
- Returns `List<Command>` — same DTO as all other endpoints, frontend already knows how to render it
- Empty/null query returns empty list — don't dump the entire database on a blank search

#### Step 3: Frontend — Server-Side Search

**Search mode architecture:**
```javascript
let searchQuery = '';
let searchTimer = null;

function onSearchInput() {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => {
        const val = document.getElementById('search').value.trim();
        if (val.length >= 2) {
            searchQuery = val;
            selectedDate = '';
            load();
        } else if (val.length === 0) {
            searchQuery = '';
            load();
        }
    }, 300);
}
```

**Key patterns:**
1. **Debounce (300ms)** — Don't fire an API call on every keystroke. Wait 300ms after the user stops typing. This prevents 10 API calls while typing "terraform".
2. **Minimum 2 characters** — Single-character searches return too many results and are rarely intentional.
3. **Clears date filter** — When searching, the timeline date selection is cleared. The search is across ALL history, not just one day.
4. **Group by date on frontend** — The API returns a flat list. The frontend groups by date to show day cards instead of an endless flat list.

```javascript
// Group search results by date
const byDate = {};
for (const c of cmds) {
    const d = new Date(c.savedAt).toLocaleDateString('en-CA');
    if (!byDate[d]) byDate[d] = { date: d, commands: [] };
    byDate[d].commands.push(c);
}
allSessions = Object.values(byDate).map(group => ({
    startTime: group.commands[0].savedAt,
    endTime: group.commands[group.commands.length-1].savedAt,
    durationMins: 0,
    commandCount: group.commands.length,
    categories: [...new Set(group.commands.map(c => c.category).filter(Boolean))],
    commands: group.commands
}));
```

**Search lifecycle:**
```
User types "docker build" ──┐
                            ▼
  300ms debounce ──→ fetch('/commands/search?q=docker+build')
                            ▼
                    Server: ILIKE across 5 fields
                            ▼
                    Returns [{id, text, category, ...}, ...]
                            ▼
                    Frontend groups by date
                            ▼
                    Renders day cards with matching commands
                            ▼
                    Client-side filters still apply on top
```

**Clearing search:**
```
User deletes search text ──→ searchQuery = ''
                            ▼
                    load() sees empty searchQuery
                            ▼
                    Fetches /sessions (normal view)
                            ▼
                    Timeline/Today/All buttons work again
```

---

## Challenges Faced

### 1. Search vs Session View Conflict

**Problem:** The search box and timeline date picker are independent controls. If user had a date selected and then searched, should the search be scoped to that day? Or across all history?

**Decision:** Search is always across **all** history. If you type "kubectl", you want every kubectl command ever run, not just today's. The search clears the date filter.

**Why not scope search to the current view?**
- The timeline's purpose is "what did I do on this day"
- The search's purpose is "find this in my entire history"
- Mixing them creates confusion: "why didn't that old command show up?"
- If users want to search within a day, they can use the date picker + client-side filter

### 2. Debounce Timing

**Problem:** No debounce → every keystroke fires an API call. User types "terraform" → 9 API calls → server load, UI flicker from rapid re-renders.

**Why 300ms?**
- Too short (100ms): fires before user finishes typing common words
- Too long (500ms+): feels sluggish, user wonders if search is broken
- 300ms is the standard for search-as-you-type UX

### 3. Search While Auto-Refresh Is Running

**Problem:** `setInterval(load, 15000)` fires every 15 seconds. If user is viewing search results, the auto-refresh calls `load()` which re-fetches the search query. This is actually correct — it re-runs the search with new data. But the search box value must persist.

**Fix:** `searchQuery` global variable. Auto-refresh preserves it. When new commands arrive (via HistoryWatcher), they appear in search results automatically.

### 4. Empty Search Results

**Problem:** When a search returns zero results, the dashboard shows "no commands found" — which is correct but could confuse the user about whether the search is broken.

**Solution:** The empty state message is clear. Users can tell the search is working because:
- The search box has their query text
- The page shows "no commands found" instead of the session view
- Clearing the search box restores normal view

---

## File Change Log

| File | Lines Changed | What Changed |
|------|--------------|-------------|
| `CommandRepository.java` | +8 | Added `@Query searchCommands()` — ILIKE across 5 fields |
| `CommandController.java` | +7 | Added `GET /commands/search?q=` endpoint |
| `index.html` | +50 | Search debounce, `onSearchInput()`, date grouping, search mode in `load()` |

## Files Created

| File | Content |
|------|---------|
| `docs/day12/day12-notes.md` | This file |

---

## Key Decisions Summary

| Decision | Rationale |
|----------|-----------|
| `@Query` with JPQL, not derived method name | 5-field OR search would have an absurd method name. `@Query` is readable. |
| `ILIKE` not PostgreSQL `tsvector` | Simpler, zero setup, sufficient for <100k rows. Revisit at scale. |
| `LOWER()` + `CONCAT('%', :q, '%')` | Case-insensitive substring match. Standard JPQL approach. |
| Search across 5 fields (text, tag, dir, repo, category) | Maximizes findability. "notes-buddy" finds commands even if text doesn't contain the word. |
| Minimum 2 characters | Prevents massive result sets from single-char searches. |
| 300ms debounce | Standard UX. Prevents API spam, feels responsive. |
| Group results by date on frontend | Flat list is overwhelming. Day cards give context. |
| Search clears date filter | Search = global, timeline = per-day. Mixing scopes is confusing. |
| Same `render()` function for search results | Zero duplication. Search results are just sessions grouped by date. |
| `List.of()` for empty query | Don't dump entire DB on accidental blank search. |

---

## What This Enables Next

1. **Solution cards** — Now that you can search any command, next step: detect repeated errors and surface the previous fix. "This error appeared 3 times. Here's what you did."

2. **Semantic search (Month 5)** — The full-text search is keyword-based. With Qdrant vector DB in Month 5, you can search by meaning: "when did I fix the port conflict" finds the right session even without exact keywords.

3. **Search result improvements** — Add highlighting of matched terms, result count badge, sort by relevance (most frequent commands first).

4. **Search from the URL** — `?q=terraform` on page load auto-searches. Makes it bookmarkable and shareable.

---

## Testing the Feature

```bash
# Test the API directly
curl "http://localhost:9098/commands/search?q=docker"
# Returns JSON array of matching commands

curl "http://localhost:9098/commands/search?q=git%20push"
# URL-encoded query, returns matching git push commands

curl "http://localhost:9098/commands/search?q="
# Empty query → []
```

**Search types that work:**
- By command: `?q=mvn`, `?q=kubectl get pods`
- By tag: `?q=fix`, `?q=ImagePullBackOff`
- By directory: `?q=Notes_Buddy`, `?q=terraform`
- By repo: `?q=notes-buddy`, `?q=my-other-repo`
- By category: `?q=kubernetes`, `?q=docker`
- Partial: `?q=doc` (finds "docker", "document", "docker-compose")