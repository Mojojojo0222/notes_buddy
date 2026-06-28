# Day 4 — Repo Tracking + Category Filter Buttons + Docker

## What We Built
1. Git repo name tracked per command — bash detects it, Java parses it, UI shows 🔀 label
2. Category filter buttons — clickable, multi-select, combined with live search
3. Dockerized the app — multi-stage Dockerfile, volume mounts for log file and DB

---

## Feature 1 — Git Repo Name Tracking

### The Problem
We knew the directory (`/e/Notes_Buddy`) but not the repo name (`notes-buddy`).
If you work in 10 repos, you want to filter by repo later — directory alone isn't clean enough.

### Where It Was Added

**`.bashrc` — bash side (you update this manually in Git Bash)**

```bash
log_command() {
    local last_cmd
    last_cmd=$(history 1 | sed 's/^[ ]*[0-9]*[ ]*//')
    local repo
    repo=$(git rev-parse --show-toplevel 2>/dev/null | xargs basename 2>/dev/null || echo "none")
    echo "$(pwd)|${repo}|${last_cmd}" >> "$NOTES_LOG"
}
```

**What changed:** one new line — `git rev-parse --show-toplevel` finds the root of the current git repo, `xargs basename` strips the path to just the folder name. If not inside a git repo, `2>/dev/null` silences the error and `|| echo "none"` falls back to `"none"`.

**Log file format changed:**

Before Day 4:
```
/e/Notes_Buddy|git status
```

After Day 4:
```
/e/Notes_Buddy|notes-buddy|git status
```

Three fields now. The pipe `|` is still the separator.

---

**`HistoryWatcher.java` — parsing side**

The line parse changed from 2-part to 3-part split:

```java
// old (Day 3)
int pipe = line.indexOf('|');
String dir     = line.substring(0, pipe);
String command = line.substring(pipe + 1);

// new (Day 4)
String[] parts = line.split("\\|", 3);  // max 3 parts
String dir      = parts[0].trim();
String repoName = parts[1].trim();
String command  = parts[2].trim();
```

**Why `split("\\|", 3)` not `split("\\|")`?**
The `3` is a limit. It means: split into at most 3 parts.
If the command text itself contains a `|` (e.g. `ls | grep java`), without the limit
it would split into 4 parts and `parts[2]` would be wrong.
With limit 3: `/e/Notes_Buddy` | `notes-buddy` | `ls | grep java` — correct.

**Why `\\|` not just `|`?**
`split()` takes a regex. In regex, `|` means OR. To match a literal pipe, escape it: `\\|`.

---

**`Command.java` — model side**

`repoName` field was already added in a prior session.
Constructor takes 4 args: text, category, dir, repoName.
Getter `getRepoName()` is there — Jackson uses it to include `repoName` in JSON.

---

**`index.html` — UI side**

In `render()`, after showing the directory line, we check for repo:

```javascript
const repo = cmd.repoName && cmd.repoName !== 'none'
    ? `<div class="workdir">🔀 ${escapeHtml(cmd.repoName)}</div>`
    : '';
```

Two conditions:
- `cmd.repoName` — truthy check, covers null/undefined for old rows in DB
- `cmd.repoName !== 'none'` — don't show the label if bash said "none" (not a git repo)

---

## Feature 2 — Category Filter Buttons

### The Problem
The dashboard showed all commands. No way to ask "show me only docker commands."
With hundreds of commands this becomes noise.

### Design Decision
Buttons are built from actual data, not hardcoded.
If you've never run a kubernetes command, no kubernetes button appears.

### How It Works — Full Flow

```
load() called (on page load or every 15s)
    │
    ▼
fetch('/commands/all') → allCommands array populated
    │
    ▼
buildFilterButtons()
    │
    ▼
[...new Set(allCommands.map(c => c.category).filter(Boolean))].sort()
    → extracts unique categories from live data
    → filter(Boolean) removes null/undefined
    → sort() alphabetical order
    → renders <button class="filter-btn"> for each
    │
    ▼
applyFilters() called
    │
    ▼
reads search input (may be empty)
reads activeFilters Set (may be empty)
    │
    ▼
allCommands.filter(c => {
    const matchesSearch   = c.text.toLowerCase().includes(query);
    const matchesCategory = activeFilters.size === 0 || activeFilters.has(c.category);
    return matchesSearch && matchesCategory;
})
    │
    ▼
render(filtered) → updates DOM
```

**Key design: `activeFilters` is a `Set`**
A `Set` automatically deduplicates. `activeFilters.has(cat)` is O(1).
If `activeFilters.size === 0` → no filter active → show everything.
Multiple active filters = OR logic (command matches any active filter).

**Why rebuild buttons on every toggle?**
Simplest way to keep active CSS class in sync. We re-render the buttons
with `isActive ? 'active' : ''` class check. Alternative would be
`document.querySelectorAll` + classList toggle — works but more lines.
For this data size (< 20 buttons), rebuilding HTML is fast enough.

**CSS for buttons:**
```css
.filter-btn        { border: 1px solid #444; color: #888; }
.filter-btn.active { border-color: #4ec9b0; color: #4ec9b0; }
```
Active = teal border + teal text. Inactive = grey. Simple, obvious.

---

## Feature 3 — Docker

### Why Docker for a Local Tool?

You don't *need* Docker to run this. But:
1. No Java install required on another machine
2. Reproducible — same environment everywhere
3. Practice for Month 2 when we add PostgreSQL (docker-compose)
4. Real engineers ship containers. Learning the pattern now is right.

### The Dockerfile — Line by Line

```dockerfile
# Stage 1: Build
FROM maven:3.9-eclipse-temurin-17 AS build
```
Multi-stage build. Stage 1 has Maven + JDK. We name it `build`.
Everything in this stage is temporary — only what we `COPY --from=build` survives.

```dockerfile
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline -q
```
Copy `pom.xml` first, download dependencies, then copy source.
**Why this order?** Docker caches each instruction as a layer.
If you change only Java code (not pom.xml), the `dependency:go-offline` layer
is cached — Docker skips re-downloading 50MB of JARs. Saves minutes per build.

```dockerfile
COPY src ./src
RUN mvn package -DskipTests -q
```
`-DskipTests` — don't run tests during Docker build (they'd need a running system).
`-q` — quiet output, cleaner logs.
Result: `target/notes-buddy-0.0.1.jar` — a fat JAR with everything inside.

```dockerfile
# Stage 2: Run
FROM eclipse-temurin:17-jre-alpine
```
JRE only (not JDK). No Maven. Alpine Linux = 5MB base instead of 200MB.
Final image is ~180MB instead of ~600MB if we used the build stage directly.

```dockerfile
COPY --from=build /app/target/notes-buddy-0.0.1.jar app.jar
EXPOSE 9098
VOLUME /root
ENTRYPOINT ["java", "-jar", "app.jar"]
```
`COPY --from=build` — pulls only the JAR from stage 1.
`EXPOSE 9098` — documents the port (doesn't publish it, `-p` does that).
`VOLUME /root` — declares /root as a mount point. This is where the log file lives
(`/root/.notes_buddy_log`) because the JVM runs as root in the container.
`ENTRYPOINT` — what runs when the container starts.

### The Volume Mounts

```bash
docker run -d \
  -p 9098:9098 \
  -v "$HOME/.notes_buddy_log:/root/.notes_buddy_log" \
  -v "$PWD/notesbuddy-db:/app/notesbuddy-db" \
  --name notes-buddy \
  notes-buddy
```

`-p 9098:9098` — host port 9098 → container port 9098. Browser at localhost:9098 works.

`-v "$HOME/.notes_buddy_log:/root/.notes_buddy_log"`
Host file Git Bash writes to ← → the path Java reads from inside container.
Without this mount: container has no log file, HistoryWatcher prints "Waiting..." forever.

`-v "$PWD/notesbuddy-db:/app/notesbuddy-db"`
H2 creates `notesbuddy-db.mv.db` at `./notesbuddy-db` relative to where Java runs.
Inside container that's `/app/notesbuddy-db`.
Without this mount: every `docker stop` + `docker start` loses all data.
With it: data file lives on your host, survives container restarts.

### Trade-off: H2 in Docker
H2 file-based DB with a volume mount works fine for local use.
The real limitation: you can't run two containers reading the same H2 file simultaneously
(H2 file locking). This is fine — we only run one container.
Month 2 migration to PostgreSQL solves this properly (PostgreSQL is designed for concurrent access).

---

## DB Structure — Unchanged from Day 3

### Table: COMMAND
| Column      | Type      | Notes                          |
|-------------|-----------|--------------------------------|
| id          | BIGINT    | auto-incremented primary key   |
| text        | VARCHAR   | the actual command             |
| category    | VARCHAR   | git / docker / etc             |
| working_dir | VARCHAR   | folder the command ran from    |
| repo_name   | VARCHAR   | git repo name or "none"        |
| saved_at    | TIMESTAMP | when recorded                  |

### Table: WATCHER_STATE
| Column          | Type    | Notes                        |
|-----------------|---------|------------------------------|
| id              | BIGINT  | always 1                     |
| last_line_count | INTEGER | lines read from log so far   |

---

## Files Changed Today

| File | What Changed |
|------|-------------|
| `.bashrc` | Added `git rev-parse` line to capture repo name |
| `HistoryWatcher.java` | Changed parse from 2-part to 3-part `split("\\|", 3)` |
| `index.html` | Added 🔀 repo label in `render()`, filter button logic was already present |
| `Dockerfile` | New file — multi-stage build |
| `.dockerignore` | New file — keeps build context clean |
| `README.md` | Full rewrite with Docker docs, repo tracking, filter docs |
| `ROADMAP.md` | Ticked off completed items |
| `docs/day4/day4-notes.md` | This file |

---

## What Could Be Better (Future Months)

| Current Limitation | Better Approach | When |
|--------------------|----------------|------|
| H2 can't be accessed by multiple processes | PostgreSQL | Month 2 |
| Repo detection runs `git rev-parse` every command | Fine for now, but slow in large repos | Month 3 |
| Filter is OR logic only (cat1 OR cat2) | Could add AND/NOT later | Month 4 |
| H2 volume mount is fragile (path must match) | PostgreSQL in docker-compose network | Month 2 |
| `activeFilters` lost on page reload | Could persist to `localStorage` | Month 3 |
| No "All" button to clear all active filters | Easy to add — `activeFilters.clear()` | Next session |

---

## Problems We Hit and Fixed

| Problem | Cause | Fix |
|---------|-------|-----|
| Old log lines (2-part) break with 3-part parser | `parts.length < 3` check | `if (parts.length < 3) continue;` in HistoryWatcher |
| H2 data lost on `docker stop` | Container filesystem is ephemeral | Volume mount for DB directory |
| Log file not visible inside container | Container has its own filesystem | Volume mount for `.notes_buddy_log` |
| Docker build slow on every code change | Dependencies re-downloaded | Copy pom.xml first, then source — layer cache |
