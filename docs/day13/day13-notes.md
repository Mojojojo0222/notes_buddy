# Day 13 — Solution Cards

**Goal:** Surface previous fixes when the same error reappears — turning repeated failures into searchable knowledge.

---

## Session Context

Day 12 added full-text search across all historical commands. But search is pull-based — you have to know what to search for. Solution cards are push-based: when a command fails repeatedly, the dashboard proactively shows you what you did last time.

This feature makes the error detection (exit codes from Day 11) genuinely useful. Without solutions, exit codes just tell you something failed. With solutions, they tell you "this failed before — here's how you fixed it."

---

## Feature: Solution Cards

### Problem

Before Day 13, the dashboard showed which commands failed (via exit code badges), but offered no help when the same error appeared again:
- "ImagePullBackOff" failed 3 times — but what did I do to fix it last time?
- `docker build` keeps failing — what's the pattern?
- User had to manually search for the error text to find previous occurrences

### Solution: Automatic Error Pattern Detection + Suggested Fixes

#### Backend — `SolutionService.java`

The algorithm:

```
1. Get ALL failed commands (exitCode != null && exitCode != 0)
2. Group them by exact command text
3. For groups with ≥2 occurrences → "repeated error"
4. Find the "fix" for each repeated error:
   a. Check if any occurrence was tagged — use the tag as the fix description
   b. If no tag, look at commands that followed the previous failure:
      - If the same command ran successfully next → "retried successfully"
      - If a meaningful fix command ran (git, docker, kubectl, mvn, etc.) → show that command
5. Sort by most-frequent-first
```

```java
public List<Map<String, Object>> findSolutions() {
    List<Command> failed = repo.findByExitCodeNotNullAndExitCodeNotOrderBySavedAtAsc(0);
    // Group by command text
    Map<String, List<Command>> byText = new LinkedHashMap<>();
    for (Command c : failed) {
        byText.computeIfAbsent(c.getText(), k -> new ArrayList<>()).add(c);
    }

    List<Map<String, Object>> solutions = new ArrayList<>();
    for (Map.Entry<String, List<Command>> entry : byText.entrySet()) {
        List<Command> occurrences = entry.getValue();
        if (occurrences.size() < 2) continue; // only repeated errors

        // Find fix from tag or next commands
        String fix = findFix(occurrences, all);
        // Build solution card
        card.put("errorText", entry.getKey());
        card.put("occurrences", occurrences.size());
        card.put("lastFailed", latest.getSavedAt());
        card.put("fix", fix);
    }
    // Sort most frequent first
}
```

**Key design decisions:**
- Groups by **exact** command text, not error message — assumes the same command failing multiple times has similar root cause
- Tags take priority over heuristic fix detection — user knowledge always wins
- Heuristic fallback scans next commands after the previous failure, looking for a meaningful fix command
- Sorted by frequency — the most painful errors appear first

#### New Repository Method

```java
List<Command> findByExitCodeNotNullAndExitCodeNotOrderBySavedAtAsc(int exitCode);
```

Spring Data JPA derives: `WHERE exit_code IS NOT NULL AND exit_code != 0 ORDER BY saved_at ASC`

#### New Endpoint — `GET /solutions`

Returns JSON array of solution cards:
```json
[
    {
        "errorText": "docker build -t notes-buddy .",
        "occurrences": 3,
        "lastFailed": "2026-07-25T14:30:00",
        "errorCategory": "docker",
        "fix": "docker system prune"
    }
]
```

#### Frontend — Solution Cards UI

Orange-highlighted section between weekly summary and timeline:
```
┌─────────────────────────────────────────┐
│ 🔄 Solution Cards — repeated errors     │
│ ┌─────────────────────────────────────┐ │
│ │ ✗ docker build -t notes-buddy .     │ │
│ │ → docker system prune               │ │
│ │ 3×  docker  last: 2026-07-25        │ │
│ └─────────────────────────────────────┘ │
│ ┌─────────────────────────────────────┐ │
│ │ ✗ kubectl apply -f k8s/            │ │
│ │ → retried successfully             │ │
│ │ 2×  kubernetes  last: 2026-07-24   │ │
│ └─────────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

**CSS:**
- Solution section: orange header (`#f0883e`) to visually distinguish from summary/blue sections
- Error text: red (`#f85149`) — "something is wrong"
- Fix text: green (`#3fb950`) — "here's how to fix it"
- Each card shows: error, fix, occurrence count, category, last failure date

**JS flow:**
```
load() calls loadSolutions() after every refresh
    │
    ▼
fetch('/solutions') → API returns array or empty
    │
    ├── empty → hide solutions section
    └── has data → render cards, show section
```

---

## Challenges Faced

### 1. What Counts as a "Fix"?

**Problem:** The algorithm needs to distinguish between the fix command and just the next random command that happens to follow the failure.

**Approach considered:**
- **Just show the tag** — if user tagged a failed command, that's the authoritative fix. Clean but requires manual effort.
- **Show next successful command** — simple heuristic but could show unrelated commands.
- **Show next command with same text that succeeded** — "retried successfully" is accurate but not always helpful.

**Decision:**
1. Tags are the primary fix source (user knowledge)
2. If no tag, look at the next commands after the previous failure
3. Skip commands that are themselves failures (don't chain errors)
4. If the same command ran successfully right after → "retried successfully"
5. If a meaningful command ran (git, docker, kubectl, terraform, mvn, npm, pip) → show it as the fix
6. If nothing meaningful found → "no fix recorded — tag a failed command to save the fix"

### 2. Grouping by Exact Text vs Fuzzy Match

**Problem:** Should `docker build -t notes-buddy .` and `docker build -t notes-buddy v2 .` be grouped together?

**Decision:** Group by **exact** text for now. Fuzzy/partial matching would require more complex grouping logic and could merge unrelated errors. If a user hits the same error with a slightly different command, they can tag the first occurrence and the fix will apply to future exact matches.

**Future improvement:** Add partial text matching using the existing `searchCommands()` query to find similar errors by category + keyword.

### 3. Performance with Large History

**Problem:** Scanning all failed commands and looking at next commands is O(n²) in worst case.

**Current solution:** The service scans all commands only once (`findByExitCodeNotNullAndExitCodeNotOrderBySavedAtAsc`), groups by text (hash map), and only scans next commands for groups with ≥2 occurrences. For <50k commands, this is sub-millisecond.

**Future optimization:** Add a database view or materialized cache for frequent queries.

### 4. Empty State UX

**Problem:** When no repeated errors exist, the solutions section should not take up space.

**Fix:** The section has `style="display:none"` by default. `loadSolutions()` sets it to `display:block` only when solutions exist. This keeps the dashboard clean for users with zero errors.

**Edge case:** On first use with no exit codes (legacy data), the API returns empty → section stays hidden. When the user accumulates enough commands for patterns to emerge, the section appears automatically.

---

## File Change Log

| File | Lines Changed | What Changed |
|------|--------------|-------------|
| `CommandRepository.java` | +2 | Added `findByExitCodeNotNullAndExitCodeNotOrderBySavedAtAsc` method |
| `SolutionService.java` | NEW (73 lines) | Full service — groups failures, finds fixes, returns solution cards |
| `CommandController.java` | +7 | Added `SolutionService` dependency + `GET /solutions` endpoint |
| `index.html` | +55 | Solution cards CSS, HTML section, `loadSolutions()` JS function |

## Files Created

| File | Content |
|------|---------|
| `src/main/java/com/notesbuddy/service/SolutionService.java` | Solution card detection service |
| `docs/day13/day13-notes.md` | This file |
| `docs/day13/README.md` | Day 13 quick reference |

---

## Key Decisions Summary

| Decision | Rationale |
|----------|-----------|
| Group by exact command text | Simpler than fuzzy matching. Users tag specific failures for fixes. |
| Tags as primary fix source | User knowledge is authoritative. Tag = explicit fix documentation. |
| Next-command heuristic as fallback | Automated. Works without user effort. Only shows meaningful commands. |
| Sort by frequency | Most painful errors first. Fix the biggest problems first. |
| Orange section header | Visually distinct from summary (green) and weekly (green) — solutions are proactive alerts. |
| Hidden when empty | Clean dashboard. Section appears only when there's something to show. |
| Red error + green fix | Intuitive color coding: red = problem, green = solution. |
| `Integer` exitCode (nullable) | Backward compatible. Legacy records before Day 11 have null exit codes. |

---

## What This Enables Next

1. **Smart solution cards** — Fuzzy-match error text using the existing search query to group similar errors (e.g., `docker build -t X` and `docker build -t Y` are probably the same error class).

2. **Click solution to search** — Clicking a solution card auto-fills the search box with the error text to show all occurrences in context.

3. **Solution stats** — "This error used to happen 5×/week, now 0×/week" (measure if the fix is working).

4. **Auto-tagging** — When the heuristic detects a fix command with high confidence, automatically tag the failed command with the fix description — no manual tagging needed.

---

## Testing the Feature

```bash
# Test the API directly
curl "http://localhost:9098/solutions"
# Returns JSON array of solution cards, or [] if none

# Create a repeatable error pattern:
# 1. Run a command that fails (exit code != 0)
# 2. Run the fix command
# 3. Repeat steps 1-2 with the same failing command
# 4. Check /solutions — should now show a solution card

# Tag a failed command with the fix description:
curl -X POST "http://localhost:9098/commands/ID/tag?tag=image%20pull%20backoff%20fix"
# The tag becomes the fix description in the solution card
```