# Day 11 — Local-First Features

**Goal:** Make the dashboard useful day-to-day without needing a cluster.

## What We Built

### 1. Exit Codes
- `Command.java` — added `exitCode` (Integer, nullable)
- `.bashrc` — `local exit_code=$?;` captured after every command
- Log format: `timestamp|dir|repo|cmd|exitCode` (5 fields, backward compatible)
- UI shows ✓ (green) or ✗ N (red) badge per command
- Weekly summary shows error count

### 2. Tag Commands
- `Command.java` — added `tag` (String, nullable)
- `POST /commands/{id}/tag?tag=myLabel`
- UI: inline editing — click `+` → type → Enter saves, Esc cancels

### 3. Timeline View
- `GET /commands/by-date?date=YYYY-MM-DD`
- Date picker with Prev/Next/Today navigation
- Loads any date's commands in a single session card

### 4. Weekly Summary
- `GET /summary/weekly` — last 7 days stats + error count
- "This Week" section below Today's Summary

### 5. Filter Persistence
- `localStorage('notesBuddyFilters')` saves active category filters
- Survives page refresh

## Files Changed

| File | Change |
|------|--------|
| `Command.java` | Added `exitCode` + `tag` fields |
| `CommandRepository.java` | Added `findBySavedAtBetweenOrderBySavedAtAsc` |
| `CommandService.java` | Updated `ingest()` to accept `exitCodeStr` |
| `HistoryWatcher.java` | 5-field line parser with fallback |
| `CommandController.java` | Added `/commands/by-date`, `/commands/{id}/tag`, `/summary/weekly` |
| `SummaryService.java` | Added `getWeeklySummary()` + shared `buildSummary()` |
| `index.html` | Exit code badges, tag editing, date picker, weekly section, localStorage |
| `ROADMAP.md` | Month 2 + Month 3 items ticked |
| `docs/README.md` | New endpoints added |
| `docs/CONCEPTS_MASTER.md` | Day 11 concepts section |
| `docs/INTERVIEW_STORY.md` | Phase 9 added |
| `docs/AI_CONTEXT.md` | Day 11 section added |

## Key Decisions

- `Integer` not `int` for exitCode — null means legacy, 0 = success, non-zero = error
- `split("\\|", 5)` — falls through to 4 then 3 field parser. All old log lines still work
- Inline tag editing — simpler than a modal. Click, type, enter. Done.
- Single session card for timeline view — reuses existing render function
- localStorage for filters — zero server changes, instant load
