# Day 11 — Local-First Features

**Goal:** Make the dashboard useful day-to-day without needing a cluster.

---

## Session Context

Previous 10 days were heavy infrastructure: Docker, EKS, Terraform, GitHub Actions CI/CD.
User destroyed the EKS cluster (cost saving). Decided to skip ArgoCD and Karpenter (no
interest/need). Instead, focus on making the local dashboard genuinely useful for daily
engineering work.

We built 5 features in one session — all pure Spring Boot + vanilla JS, zero infra.

---

## Feature 1: Exit Codes

### Problem
Every command returns an exit code (`$?`). 0 = success, non-zero = error. But we were
ignoring this data entirely. Without exit codes, you can't tell which commands failed.
This is the foundation for future error-tracking features (solution cards, error frequency).

### Implementation

#### Step 1: Command.java
```java
private Integer exitCode;  // null for legacy records, 0 = success, non-zero = error
private String tag;        // manually assigned label
```

`Integer` (object) not `int` (primitive) because:
- `null` = command logged before this feature existed
- `0` = command succeeded
- `1-255` = command failed with specific error code

#### Step 2: CommandService.ingest()
```java
public Command ingest(String text, String workingDir, String repoName, String timestamp, String exitCodeStr) {
    ...
    if (exitCodeStr != null && !exitCodeStr.isBlank()) {
        try { cmd.setExitCode(Integer.parseInt(exitCodeStr)); }
        catch (Exception ignored) {}
    }
    ...
}
```

#### Step 3: HistoryWatcher.java — 5-field parser
Old log format: `timestamp|dir|repo|cmd` (4 fields)
New log format: `timestamp|dir|repo|cmd|exitCode` (5 fields)

```java
String[] parts = line.split("\\|", 5);

if (parts.length == 5) {
    timestamp   = parts[0].trim();
    dir         = parts[1].trim();
    repoName    = parts[2].trim();
    command     = parts[3].trim();
    exitCodeStr = parts[4].trim();
} else if (parts.length == 4) {
    // ... no exitCode (legacy)
} else if (parts.length == 3) {
    // ... no timestamp, no exitCode (older format)
}
```

#### Step 4: .bashrc update
```bash
log_command() {
    local exit_code=$?                    # ← NEW: capture exit code FIRST
    local last_cmd
    last_cmd=$(history 1 | sed 's/^[ ]*[0-9]*[ ]*//')
    local repo
    repo=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)
    if [ -z "$repo" ]; then repo="none"; fi
    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S')
    echo "${ts}|$(pwd)|${repo}|${last_cmd}|${exit_code}" >> "$NOTES_LOG"  # ← NEW: 5th field
}
```

**Critical detail:** `local exit_code=$?` must be the **first** line in `log_command()`.
If you put it after `last_cmd=$(history 1 | ...)`, then `$?` captures the exit code
of `history`, not the original command.

#### Step 5: UI — exit code badges
```javascript
const ec = cmd.exitCode !== null && cmd.exitCode !== undefined
    ? `<span class="exit-code ${cmd.exitCode === 0 ? 'ok' : 'fail'}">
         ${cmd.exitCode === 0 ? '✓' : '✗ '+cmd.exitCode}
       </span>`
    : '';
```

Green `✓` for success, red `✗ N` for failure. CSS:
```css
.exit-code.ok   { color: #3fb950; border: 1px solid #2ea04340; }
.exit-code.fail { color: #f85149; border: 1px solid #f8514940; }
```

### Challenges Faced
1. **$? timing** — At first, we tried to capture exit code after computing other variables.
   But `$?` changes after EVERY command runs. Even `local var=$(something)` changes `$?`.
   Fix: capture `$?` as the absolute first line of the function.
2. **Backward compatibility** — Thousands of old log lines with 3 or 4 fields exist.
   The parser falls through from 5 → 4 → 3 fields. Old data never breaks.
3. **DDL auto-update** — Hibernate `ddl-auto=update` adds new columns but never changes
   existing column types (we learned this Day 8). Since we're adding a NEW nullable column,
   no migration needed. Existing rows get `NULL` for exitCode.

---

## Feature 2: Tag Commands from UI

### Problem
Category detection is automatic (git, docker, k8s, etc.), but sometimes you need to
manually label a command. "This was the fix for ImagePullBackOff." Tags let you
categorize commands after the fact.

### Implementation

#### API: POST /commands/{id}/tag?tag=myLabel
```java
@PostMapping("/commands/{id}/tag")
public ResponseEntity<String> tagCommand(@PathVariable Long id, @RequestParam String tag) {
    Command cmd = repo.findById(id).orElse(null);
    if (cmd == null) return ResponseEntity.notFound().build();
    cmd.setTag(tag.isBlank() ? null : tag);
    repo.save(cmd);
    return ResponseEntity.ok("tagged");
}
```

#### UI: Inline Editing Pattern
```javascript
function startTagEdit(cmdId) {
    const span = document.getElementById(`tag-${cmdId}`);
    const current = span.textContent === '+' ? '' : span.textContent;
    const input = document.createElement('input');
    input.type = 'text';
    input.className = 'tag-input';
    input.value = current;
    input.placeholder = 'add tag...';
    input.onblur = () => saveTag(cmdId, input.value);
    input.onkeydown = (e) => {
        if (e.key === 'Enter') input.blur();      // save on Enter
        if (e.key === 'Escape') {                  // cancel on Esc
            span.style.display = '';
            input.remove();
        }
    };
    span.style.display = 'none';
    span.parentNode.insertBefore(input, span.nextSibling);
    input.focus();
}
```

**Flow:**
1. User sees `+` button next to each command
2. Click `+` → input field appears, `+` hidden
3. Type tag name → Enter saves via API → reloads → tag shown as pill badge
4. Esc cancels → restores `+`

### Challenges Faced
- **None.** This was straightforward. The inline edit pattern is well-known from
  todo-list apps. The API is a simple POST with one parameter.
- One design decision: `tag.isBlank()` → `null` (saves null instead of empty string).
  This keeps the database clean — no meaningless empty strings.

---

## Feature 3: Timeline View

### Problem
Before Day 11, the dashboard only showed today's activity (via `/summary` and session
grouping). You couldn't look back at what you did on a specific day.

### Implementation

#### Repository method
```java
List<Command> findBySavedAtBetweenOrderBySavedAtAsc(LocalDateTime start, LocalDateTime end);
```
Spring Data JPA derives the SQL query from the method name:
```sql
SELECT * FROM command WHERE saved_at BETWEEN ? AND ? ORDER BY saved_at ASC
```

#### API endpoint
```java
@GetMapping("/commands/by-date")
public List<Command> byDate(@RequestParam String date) {
    java.time.LocalDate day = java.time.LocalDate.parse(date);
    java.time.LocalDateTime start = day.atStartOfDay();
    java.time.LocalDateTime end = day.plusDays(1).atStartOfDay();
    return repo.findBySavedAtBetweenOrderBySavedAtAsc(start, end);
}
```

#### UI: Date picker + navigation
```html
<div class="timeline-bar">
    <label>📅 Timeline</label>
    <button class="nav-btn" onclick="shiftDay(-1)">‹ Prev</button>
    <input type="date" id="datePicker" onchange="loadDate()" />
    <button class="nav-btn" onclick="shiftDay(1)">Next ›</button>
    <button class="nav-btn" onclick="selectedDate=today; load();">Today</button>
    <button class="nav-btn" onclick="selectedDate=''; load();">All</button>
</div>
```

#### JavaScript date helpers
```javascript
function shiftDay(delta) {
    const picker = document.getElementById('datePicker');
    const d = picker.valueAsDate || new Date();
    d.setDate(d.getDate() + delta);
    picker.valueAsDate = d;
    loadDate();
}
```

#### Key pattern: selectedDate global
```javascript
let selectedDate = '';

async function load() {
    if (selectedDate) {
        // fetch /commands/by-date?date=selectedDate
        // show single day
    } else {
        // fetch /sessions
        // show all sessions
    }
    buildFilterButtons();
    applyFilters();
}
```

The `selectedDate` variable persists across auto-refreshes (15s interval).
This means picking a date keeps showing that date — the auto-refresh doesn't
reset the view.

### Challenges Faced

#### Bug 1: Timeline resets on auto-refresh
**Problem:** User picks a date, sees that day's commands. After 15 seconds,
`setInterval(load, 15000)` fires and reloads `/sessions` — which shows ALL days.
The timeline was wiped.

**Fix:**
- Added `selectedDate` global variable
- `load()` checks: if `selectedDate` is set, fetch `/commands/by-date` instead
- Auto-refresh now preserves the selected date
- "All" button sets `selectedDate = ''` and reloads all sessions

#### Bug 2: "Today" button showed all sessions
**Problem:** Originally "Today" set `selectedDate = ''; load()` which showed
all sessions, not today's commands. Users expected "Today" to show today only.

**Fix:**
- Changed "Today" to set `selectedDate = today` (today's date string)
- Added separate "All" button for "show everything"
- Clear distinction: "Today" = filter to today, "All" = no filter

#### Bug 3: CSS specificity for date input
**Problem:** Global `* { box-sizing: border-box; }` and monospace font on body
affected the date picker. The calendar icon and layout looked inconsistent.

**Fix:** Added explicit styling for `.timeline-bar input[type=date]` to override
defaults. Narrow scope prevents leaks.

##### Key learnings about `<input type="date">`:
- `picker.valueAsDate = new Date()` — sets the display to today
- `.toLocaleDateString('en-CA')` — gives ISO format `2026-07-23` (Canadian locale)
- `onchange` fires only when user picks a date, not on programmatic `.value` changes
- **Important:** `.toLocaleDateString('en-CA')` is the reliable way to get YYYY-MM-DD
  without manual padding. Other locales can return different formats.

---

## Feature 4: Weekly Summary

### Problem
Today's summary is useful but short-sighted. You can't see weekly trends.
"How many commands did I run this week? Which tools did I use most?"

### Implementation

#### SummaryService.getWeeklySummary()
```java
public Map<String, Object> getWeeklySummary() {
    LocalDate today = LocalDate.now();
    LocalDate weekAgo = today.minusDays(7);
    List<Command> weekCommands = repo.findBySavedAtBetweenOrderBySavedAtAsc(
        weekAgo.atStartOfDay(), today.plusDays(1).atStartOfDay());

    Map<String, Object> summary = buildSummary(weekAgo + " — " + today, weekCommands);
    long errorCount = weekCommands.stream()
        .filter(c -> c.getExitCode() != null && c.getExitCode() != 0)
        .count();
    summary.put("errorCount", errorCount);
    return summary;
}
```

#### Shared buildSummary() refactor
Previously `getDailySummary()` had inline logic for counting frequency, most used,
topics. Refactored into a shared `buildSummary(label, commands)` method.
DRY principle — both daily and weekly use the same logic.

#### API
```java
@GetMapping("/summary/weekly")
public Map<String, Object> weeklySummary() {
    return summaryService.getWeeklySummary();
}
```

#### UI
```html
<div class="weekly-section">
    <h2>This Week</h2>
    <div class="summary-grid">
        <div class="stat">
            <div class="stat-label">Commands Run</div>
            <div class="stat-value" id="weeklyTotal">—</div>
        </div>
        <div class="stat">
            <div class="stat-label">Most Used</div>
            <div class="stat-value" id="weeklyMostUsed">—</div>
        </div>
        <div class="stat">
            <div class="stat-label">Errors Found</div>
            <div class="stat-value" id="weeklyErrors">—</div>
        </div>
        <div class="stat">
            <div class="stat-label">Categories</div>
            <div class="topics" id="weeklyTopics"></div>
        </div>
    </div>
</div>
```

### Challenges Faced
- **None.** Straightforward. The endpoint is just a wider date range on the same query.
- The `errorCount` stat is the first feature that uses exit code data meaningfully.
  It shows how many failed commands this week.

---

## Feature 5: Filter Persistence (localStorage)

### Problem
Every time the user refreshes the page, all filter selections are lost.
If you're focused on "kubernetes" commands, you have to re-click the button
after every page load. This is a subtle but daily annoyance.

### Implementation
```javascript
function saveFilters() {
    localStorage.setItem('notesBuddyFilters', JSON.stringify([...activeFilters]));
}

function loadFilters() {
    try {
        const saved = JSON.parse(localStorage.getItem('notesBuddyFilters'));
        if (saved && Array.isArray(saved)) activeFilters = new Set(saved);
    } catch(e) {}
}
```

**The Set → Array → Set pattern:**
- `Set` objects can't be serialized directly (`JSON.stringify` produces `{}`)
- `[...activeFilters]` spreads Set items into an Array
- `JSON.stringify(array)` saves as `["git","docker"]`
- On load: `JSON.parse(...)` returns Array, `new Set(array)` reconstructs

### Challenges Faced
- **None.** localStorage is synchronous, zero server changes, instant.
- One consideration: `try/catch` around `JSON.parse` in case localStorage has
  corrupted data (manually edited, different app, old format).

---

## Bug Fixes During the Session

### Bug 1: Tag search not working
**Problem:** User asked "can we search from tags?" — search only matched
command text, not tags.

**Fix:** Added tag text to the search filter:
```javascript
const matchSearch = query === '' ||
    c.text.toLowerCase().includes(query) ||
    (c.tag && c.tag.toLowerCase().includes(query));
```
Now typing a tag name in the search box finds command with that tag.

### Bug 2: Auto-refresh wiping timeline
**Problem:** 15-second auto-refresh calls `load()` which fetches `/sessions`
and shows all commands. If user was viewing a specific date, the view resets.

**Fix:** `selectedDate` global variable. `load()` checks it: if set, fetch
`/commands/by-date` instead. The variable persists across refreshes.

### Bug 3: "Today" button ambiguity
**Problem:** "Today" was clearing the date filter (showing all sessions),
but users expected it to show today's commands only.

**Fix:** Separate buttons for "Today" (show today) and "All" (show everything).

---

## Full File Change Log

| File | Lines Changed | What Changed |
|------|--------------|-------------|
| `Command.java` | +4 | Added `exitCode` (Integer) + `tag` (String) fields with getters/setters |
| `CommandRepository.java` | +1 | Added `findBySavedAtBetweenOrderBySavedAtAsc` query method |
| `CommandService.java` | +3 | `ingest()` now accepts `exitCodeStr`, parses to Integer |
| `HistoryWatcher.java` | +8 | 5-field parser with 4 → 3 fallthrough |
| `CommandController.java` | +15 | `/commands/by-date`, `/commands/{id}/tag`, `/summary/weekly` |
| `SummaryService.java` | +30 | `getWeeklySummary()` + `buildSummary()` refactor |
| `index.html` | +176 | Exit code badges, tag editing, timeline, weekly section, localStorage, all bug fixes |
| `.bashrc` (user's home) | +1 | `local exit_code=$?` + `|${exit_code}` in log write |

## Files Created
| File | Content |
|------|---------|
| `docs/day11/day11-notes.md` | This file |

## Key Decisions Summary

| Decision | Rationale |
|----------|-----------|
| `Integer` not `int` for exitCode | `null` = legacy, 0 = success, non-zero = error |
| `split("\\|", 5)` | Backward compatible with 4 and 3 field old lines |
| `$?` captured first in bash | Any command changes `$?`, even assignment |
| Inline tag editing vs modal | Simpler UX, fewer round trips, no modal CSS needed |
| `selectedDate` global | Persists across auto-refresh, easy to clear |
| localStorage for filters | Zero server changes, synchronous, instant |
| `en-CA` locale for date | Guarantees `YYYY-MM-DD` format iso standard |
| Shared `buildSummary()` | DRY principle, both daily + weekly use same logic |
| Tag search in `applyFilters()` | Single pass, no extra API call |

## What This Enables Next

1. **Solution cards** — Now that we have exit codes, we can detect repeated errors
   and link them to previous fixes. "This error appeared 3 times before. Here's
   what you did to fix it last time."

2. **Full-text search** — Tags give users a way to manually annotate commands.
   Combined with full-text search across all fields, the dashboard becomes a
   genuine personal knowledge base.

3. **Error dashboard** — A separate view that shows only failed commands,
   grouped by frequency. "You've run `kubectl get pods` and got an error 15 times."
