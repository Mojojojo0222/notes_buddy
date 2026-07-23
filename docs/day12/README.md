# Day 12 — Full-Text Search

**Goal:** Search every command ever logged — server-side ILIKE across 5 fields.

## What We Built
| Component | What Changed |
|-----------|-------------|
| `CommandRepository.java` | `@Query` with `LOWER() LIKE CONCAT('%', :q, '%')` across text, tag, workingDir, repoName, category |
| `CommandController.java` | `GET /commands/search?q=` endpoint |
| `index.html` | Search debounce, date grouping, search mode in `load()` |

## Summary
- Server-side `ILIKE` search — not just client-side filtering of visible commands
- 300ms debounce to prevent API spam on every keystroke
- Results grouped by date into day cards
- Clears date filter when searching (search = global, timeline = per-day)
- Works with auto-refresh — new commands appear in search results