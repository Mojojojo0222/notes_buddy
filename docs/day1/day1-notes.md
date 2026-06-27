# Day 1 — Terminal Command Logger

## What We Built
A Spring Boot app that reads Git Bash command history every 10 seconds
and saves each command to an H2 database with a timestamp.

---

## Most Important File Today
**`HistoryWatcher.java`** — this is the brain.
Everything else (model, repo, controller) just supports it.
If this file didn't exist, nothing would ever get saved.

---

## DB Structure After Day 1

### Table: COMMAND
| Column    | Type          | Notes                        |
|-----------|---------------|------------------------------|
| id        | BIGINT        | auto-incremented primary key |
| text      | VARCHAR       | the actual command           |
| saved_at  | TIMESTAMP     | when we recorded it          |

### Table: WATCHER_STATE
| Column          | Type    | Notes                              |
|-----------------|---------|------------------------------------|
| id              | BIGINT  | always 1, only ever one row        |
| last_line_count | INTEGER | how many lines we've read so far   |

---

## Flow — Saving a Command (Background Thread)

```
Every 10 seconds → Spring calls HistoryWatcher.scan()
                              [HistoryWatcher.java, line 31]
        │
        ▼
Files.exists(LOG_FILE) check
                              [HistoryWatcher.java, line 32]
        │
        ▼
stateRepo.findById(1L).orElse(new WatcherState())
  → SELECT * FROM watcher_state WHERE id = 1
  → if no row: new WatcherState() with lastLineCount = 0
                              [HistoryWatcher.java, line 37]
        │
        ▼
Files.readAllLines(LOG_FILE)
  → reads entire ~/.notes_buddy_log into List<String>
                              [HistoryWatcher.java, line 38]
        │
        ▼
lines.subList(state.getLastLineCount(), lines.size())
  → if lastLineCount=10, file has 12 lines → subList(10,12)
  → only the 2 new lines
                              [HistoryWatcher.java, line 39]
        │
        ▼
state.setLastLineCount(lines.size())
stateRepo.save(state)
  → UPDATE watcher_state SET last_line_count=12 WHERE id=1
  → saved BEFORE processing so crash mid-loop doesn't reprocess
                              [HistoryWatcher.java, line 41-42]
        │
        ▼
for each new line:
  line.indexOf('|') → finds the pipe character position
  dir     = line.substring(0, pipe)   → "/e/Notes_Buddy"
  command = line.substring(pipe + 1)  → "git status"
                              [HistoryWatcher.java, line 46-49]
        │
        ▼
isJunk(command) check
  → empty? skip
  → starts with #? skip
  → has = but no space? skip (variable assignment)
  → length < 2? skip
                              [HistoryWatcher.java, line 51]
        │
        ▼
detectCategory(command)
  → checks prefix of command
  → returns "git", "docker", "files", etc.
                              [HistoryWatcher.java, line 53]
        │
        ▼
repo.save(new Command(command, category, dir))
  → INSERT INTO command (text, category, working_dir, saved_at)
    VALUES ('git status', 'git', '/e/Notes_Buddy', NOW())
                              [HistoryWatcher.java, line 53]
```

---

## Flow — Viewing Commands (Web Request)

```
Browser: GET /commands/all
        │
        ▼
Tomcat receives request
        │
        ▼
CommandController.all()
                              [CommandController.java, line 22]
        │
        ▼
repo.findAll(Sort.by(ASC, "savedAt"))
  → SELECT * FROM command ORDER BY saved_at ASC
                              [CommandController.java, line 23]
        │
        ▼
JPA maps each DB row → Command Java object
  → id, text, category, workingDir, savedAt all populated
        │
        ▼
@RestController auto-converts List<Command> → JSON array
        │
        ▼
Browser receives:
[
  {"id":1, "text":"git status", "category":"git",
   "workingDir":"/e/Notes_Buddy", "savedAt":"2026-06-27T22:03"}
]
```

---

## Key Concepts Learned

**`@Scheduled(fixedDelay = 10000)`**
Runs a method every 10 seconds in a background thread.
fixedDelay = wait 10s AFTER previous run finishes.
fixedRate = run every 10s regardless of how long previous took.
We use fixedDelay to avoid overlap.

**`subList(from, to)`**
Returns a view of a List between two indexes.
We use it as a bookmark — only read lines we haven't seen.

**`Optional.orElse()`**
findById returns Optional because the row might not exist yet.
.orElse(new WatcherState()) handles first run gracefully.

**`@Entity` + `@Id` + `@GeneratedValue`**
@Entity = make a table for this class.
@Id = this field is the primary key.
@GeneratedValue(IDENTITY) = database auto-increments it.

---

## Why We Didn't Use .bash_history Directly
.bash_history is written only when terminal closes by default.
We added PROMPT_COMMAND="history -a" to write after every command.
But .bash_history has no structure — just raw command text.
No directory, no timestamp beyond what bash adds.
We moved to our own .notes_buddy_log in Day 3.

---

## Problems We Hit and Fixed

| Problem | Cause | Fix |
|---------|-------|-----|
| Duplicates on restart | lastLineCount was in memory, reset to 0 | Moved lastLineCount to WatcherState in DB |
| Junk lines saved | .bash_history had script content | Added isJunk() filter |
| New commands not appearing | .bash_history only flushed on terminal close | Added PROMPT_COMMAND="history -a" |
| .bashrc not loading | .bash_profile was empty | Made .bash_profile source .bashrc |
