# Day 3 — Working Directory Tracking

## What We Built
- Capture which folder every command was run from
- Switched from .bash_history to our own clean log file
- Show directory under each command in the UI
- Fixed .bash_profile so .bashrc loads correctly in Git Bash

---

## Most Important File Today
**`.bashrc`** — the root of everything.
If this file is wrong, no data enters the system at all.
Java code can be perfect but if bash doesn't write the log, nothing works.

Second most important: **`HistoryWatcher.java`** — had to change
how it reads and parses lines completely.

---

## DB Structure After Day 3

### Table: COMMAND (final for now)
| Column      | Type      | Notes                              |
|-------------|-----------|------------------------------------|
| id          | BIGINT    | auto-incremented primary key       |
| text        | VARCHAR   | the actual command                 |
| category    | VARCHAR   | git / docker / kubernetes / etc    |
| working_dir | VARCHAR   | folder the command was run from    |
| saved_at    | TIMESTAMP | when we recorded it                |

### Table: WATCHER_STATE (unchanged)
| Column          | Type    | Notes                            |
|-----------------|---------|----------------------------------|
| id              | BIGINT  | always 1                         |
| last_line_count | INTEGER | bookmark — lines read so far     |

---

## The .notes_buddy_log File Format

One line per command. Pipe separates directory from command.

```
/e/Notes_Buddy|git status
/c/Users/Lenovo|ls -la
/c/Users/Lenovo|docker --version
/e/Notes_Buddy|mvn spring-boot:run
```

This is the contract between bash and Java.
Bash writes it. Java reads it.
The pipe | is the separator we chose because it rarely appears in commands.

---

## Flow — How a Command Gets Into the Log File

```
You type "git status" and press Enter in Git Bash
        │
        ▼
Git Bash executes "git status"
        │
        ▼
Git Bash runs PROMPT_COMMAND (before showing next prompt)
  = 'history -a; log_command'
                        [.bashrc, line 7]
        │
        ├── history -a
        │     → flushes current session history to .bash_history
        │
        └── log_command()
                        [.bashrc, line 3-6]
              │
              ▼
            history 1
              → prints "  42  git status"
              │
              ▼
            sed 's/^[ ]*[0-9]*[ ]*//'
              → strips "  42  " prefix
              → leaves "git status"
              │
              ▼
            echo "$(pwd)|git status" >> ~/.notes_buddy_log
              → appends "/e/Notes_Buddy|git status" to file
```

---

## Flow — HistoryWatcher Reads the Log

```
Every 10 seconds → scan() called
                        [HistoryWatcher.java, line 31]
        │
        ▼
Files.exists(LOG_FILE) → checks ~/.notes_buddy_log exists
  If not: prints warning, returns early
                        [HistoryWatcher.java, line 32-35]
        │
        ▼
stateRepo.findById(1L).orElse(new WatcherState())
  → loads lastLineCount from DB
  → example: lastLineCount = 10
                        [HistoryWatcher.java, line 37]
        │
        ▼
Files.readAllLines(LOG_FILE)
  → reads all lines into List<String>
  → example: 12 lines total
                        [HistoryWatcher.java, line 38]
        │
        ▼
lines.subList(10, 12)
  → only lines 10 and 11 (the 2 new ones)
                        [HistoryWatcher.java, line 39]
        │
        ▼
state.setLastLineCount(12)
stateRepo.save(state)
  → UPDATE watcher_state SET last_line_count=12 WHERE id=1
  → saved BEFORE processing the lines
  → reason: if crash happens mid-loop, we don't reprocess
                        [HistoryWatcher.java, line 41-42]
        │
        ▼
for each new line "/e/Notes_Buddy|git status":
        │
        ▼
  line.indexOf('|') → returns position of pipe, e.g. 14
                        [HistoryWatcher.java, line 46]
        │
        ▼
  dir     = line.substring(0, 14)   → "/e/Notes_Buddy"
  command = line.substring(15)      → "git status"
                        [HistoryWatcher.java, line 47-48]
        │
        ▼
  isJunk("git status") → false, passes all checks
                        [HistoryWatcher.java, line 51]
        │
        ▼
  detectCategory("git status")
    → c.startsWith("git ") → returns "git"
                        [HistoryWatcher.java, line 53]
        │
        ▼
  new Command("git status", "git", "/e/Notes_Buddy")
    → sets text, category, workingDir
    → sets savedAt = LocalDateTime.now()
                        [Command.java, line 19-24]
        │
        ▼
  repo.save(command)
    → INSERT INTO command
      (text, category, working_dir, saved_at)
      VALUES ('git status','git','/e/Notes_Buddy','2026-06-27T22:03')
                        [HistoryWatcher.java, line 53]
```

---

## Flow — UI Showing the Directory

```
Browser receives command JSON:
{
  "text": "git status",
  "category": "git",
  "workingDir": "/e/Notes_Buddy",
  "savedAt": "2026-06-27T22:03:15"
}
                        [index.html, inside render()]
        │
        ▼
const dir = cmd.workingDir && cmd.workingDir !== 'unknown'
    ? `<div class="workdir">📁 /e/Notes_Buddy</div>`
    : ''
  → only shows directory if it's known
        │
        ▼
HTML built:
<div class="command-row">
  <div class="command-top">
    <span class="time">22:03</span>
    <span class="text">git status</span>
  </div>
  <div class="workdir">📁 /e/Notes_Buddy</div>
</div>
```

---

## Key Concepts Learned

**Why we stopped using .bash_history**
.bash_history is unstructured — just raw command text.
No directory. No clean way to attach metadata.
Every hack we added (like #DIR: markers) caused ordering bugs.
Own log file = we control the format completely.

**`line.indexOf('|')` vs `line.split('|')`**
split('|') would work but creates a String array unnecessarily.
indexOf + substring is more direct.
Also: split has edge cases if command itself contains |.
With indexOf we take everything before first pipe and everything after.
Even if command has | in it, directory is always before the first pipe.

**`substring(0, pipe)` vs `substring(pipe + 1)`**
substring(0, pipe) = characters from 0 up to but NOT including pipe.
substring(pipe + 1) = characters starting from position AFTER pipe.
If pipe is at index 14:
  line = "/e/Notes_Buddy|git status"
  substring(0, 14) = "/e/Notes_Buddy"
  substring(15)    = "git status"

**PROMPT_COMMAND timing**
PROMPT_COMMAND runs AFTER the command completes, BEFORE next prompt.
So when log_command() runs, "history 1" already has the command we just ran.
pwd also reflects current directory after any cd that just ran.
This is why the directory is always correct.

**`.bash_profile` vs `.bashrc`**
.bash_profile = runs once on login shell (when Git Bash opens).
.bashrc = runs on every interactive shell.
Git Bash on Windows reads .bash_profile, NOT .bashrc automatically.
Fix: make .bash_profile source .bashrc.
Without this: PROMPT_COMMAND never gets set, log_command never runs.

---

## Problems We Hit and Fixed

| Problem | Cause | Fix |
|---------|-------|-----|
| Directory showing on wrong command | #DIR: marker written after command, one line off | Switched to single-line #CMD:dir|command format |
| Still wrong after that | Old .bash_history mixing with new markers | Switched to dedicated .notes_buddy_log file entirely |
| PROMPT_COMMAND not persisting | .bash_profile was empty, .bashrc never loaded | Made .bash_profile source .bashrc |
| [200~cat command showing up | Bracketed paste artifact from terminal | Can filter in isJunk() — prefix [200~ |

---

## The Three-Layer Contract

```
BASH LAYER          JAVA LAYER          DATABASE LAYER
-----------         ----------          --------------
.bashrc             HistoryWatcher      COMMAND table
  writes              reads               stores
  dir|command         dir|command         id,text,category
  to                  from                workingDir,savedAt
  .notes_buddy_log    .notes_buddy_log
```

Each layer has one job.
Bash writes. Java reads and parses. Database stores.
If any layer breaks, only that layer needs fixing.
