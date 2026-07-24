# Day 13 — Solution Cards

**Goal:** Surface previous fixes when the same error reappears.

## What We Built
| Component | What Changed |
|-----------|-------------|
| `CommandRepository.java` | Added `findByExitCodeNotNullAndExitCodeNotOrderBySavedAtAsc` |
| `SolutionService.java` | NEW — groups repeated failures, detects fixes from tags or next commands |
| `CommandController.java` | `GET /solutions` endpoint |
| `index.html` | Solution cards section (orange) with red error + green fix display |

## Summary
- Detects repeated error patterns (same command text, exit code != 0, ≥2 occurrences)
- Fix sources: user tags (primary) → next command heuristic (fallback)
- Sorted by frequency — most painful errors first
- Section hidden when no solutions exist — clean dashboard
- Color-coded: orange section, red error, green fix, gray metadata