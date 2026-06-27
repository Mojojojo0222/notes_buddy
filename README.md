# ⚡ Notes Buddy

> A personal engineering journal that writes itself.

No more manual note-taking. Notes Buddy runs silently in the background,
captures every terminal command you run, and turns your daily work into
a searchable, organized engineering log — automatically.

---

## What It Does

Every command you type in Git Bash gets recorded with:
- the exact command text
- the folder it was run from
- the time it was run
- the category (git, docker, kubernetes, terraform, etc.)

You get a clean dashboard at `localhost:9098` showing everything
grouped by date, with a daily summary and live search.

```
⚡ Notes Buddy

Today's Summary
Commands Run: 22    Most Used: git status (3x)    Topics: [docker] [git] [files]

Saturday, June 27, 2026
  22:03   git status         📁 /e/Notes_Buddy
  22:01   docker --version   📁 /c/Users/Lenovo
  21:58   ls -la             📁 /e/Notes_Buddy
```

---

## Tech Stack

| Layer      | Technology              |
|------------|-------------------------|
| Backend    | Spring Boot 3.2 (Java 17) |
| Database   | H2 (file-based)         |
| Frontend   | Vanilla HTML/JS         |
| Shell      | Git Bash (Windows)      |

---

## Project Structure

```
notes-buddy/
├── src/main/java/com/notesbuddy/
│   ├── NotesApplication.java          # entry point
│   ├── controller/
│   │   └── CommandController.java     # REST endpoints
│   ├── model/
│   │   ├── Command.java               # command entity
│   │   └── WatcherState.java          # bookmark entity
│   ├── repository/
│   │   ├── CommandRepository.java     # DB access for commands
│   │   └── WatcherStateRepository.java
│   └── service/
│       ├── HistoryWatcher.java        # reads log file every 10s
│       └── SummaryService.java        # builds daily summary
├── src/main/resources/
│   ├── static/index.html              # dashboard UI
│   └── application.properties
├── docs/
│   ├── day1/day1-notes.md
│   ├── day2/day2-notes.md
│   ├── day3/day3-notes.md
│   └── README.md                      # architecture + all flows
├── ROADMAP.md
└── pom.xml
```

---

## Getting Started

### Prerequisites
- Java 17+
- Maven 3.8+
- Git Bash (Windows)

### 1. Clone the repo
```bash
git clone https://github.com/YOUR_USERNAME/notes-buddy.git
cd notes-buddy
```

### 2. Configure Git Bash to log commands

Add this to your `~/.bashrc` (create it if it doesn't exist):

```bash
NOTES_LOG="$HOME/.notes_buddy_log"

log_command() {
    local last_cmd
    last_cmd=$(history 1 | sed 's/^[ ]*[0-9]*[ ]*//')
    echo "$(pwd)|${last_cmd}" >> "$NOTES_LOG"
}

export PROMPT_COMMAND='history -a; log_command'
```

Then make sure `~/.bash_profile` loads it:

```bash
if [ -f ~/.bashrc ]; then
    source ~/.bashrc
fi
```

Then reload:
```bash
source ~/.bashrc
```

### 3. Run the app
```bash
mvn spring-boot:run
```

### 4. Open the dashboard
```
http://localhost:9098
```

Start typing commands in Git Bash — they appear on the dashboard within 10 seconds.

---

## API Endpoints

| Method | Endpoint        | Description                        |
|--------|-----------------|------------------------------------|
| GET    | `/`             | Dashboard UI                       |
| GET    | `/commands/all` | All commands as JSON               |
| GET    | `/summary`      | Today's summary (count, most used, topics) |
| GET    | `/h2-console`   | H2 database browser (debug)        |

### Example Response — `/commands/all`
```json
[
  {
    "id": 1,
    "text": "git status",
    "category": "git",
    "workingDir": "/e/Notes_Buddy",
    "savedAt": "2026-06-27T22:03:15"
  }
]
```

### Example Response — `/summary`
```json
{
  "date": "2026-06-27",
  "totalCommands": 22,
  "topicsTouched": ["docker", "files", "git"],
  "mostUsed": "git status (3 times)"
}
```

---

## How It Works

```
Git Bash (your terminal)
    │
    │  PROMPT_COMMAND runs after every command
    │  writes → ~/.notes_buddy_log
    │  format: /path/to/dir|command text
    ▼
~/.notes_buddy_log
    │
    │  HistoryWatcher reads every 10 seconds
    │  only reads new lines (bookmark in DB)
    ▼
H2 Database
    │
    ├── GET /commands/all  →  full command list
    └── GET /summary       →  daily stats
    ▼
localhost:9098  (your browser)
```

---

## Auto-detected Categories

| Category   | Detected From                          |
|------------|----------------------------------------|
| git        | `git `                                 |
| docker     | `docker `, `docker-compose `           |
| kubernetes | `kubectl `, `helm `                    |
| terraform  | `terraform `, `tf `                    |
| build      | `mvn `, `gradle `                      |
| files      | `ls`, `cd `, `cp `, `mv `, `rm `, `mkdir ` |
| network    | `ssh `, `curl `, `wget `, `ping `      |
| editor     | `cat `, `grep `, `tail `, `vim `       |
| other      | everything else                        |

---

## Roadmap

See [ROADMAP.md](ROADMAP.md) for the full 6-month plan.

**Currently built:**
- ✅ Terminal command logging
- ✅ Working directory tracking
- ✅ Auto category detection
- ✅ Daily summary
- ✅ Live search dashboard
- ✅ Persistent bookmark (no duplicates on restart)

**Coming next:**
- 🔲 Category filter buttons
- 🔲 Session detection
- 🔲 PostgreSQL migration
- 🔲 Weekly summary
- 🔲 File watcher
- 🔲 Semantic search (Qdrant)

---

## Development Docs

Detailed day-by-day notes covering every flow, every line, every decision:

- [Day 1 — Terminal Logger + Core Flow](docs/day1/day1-notes.md)
- [Day 2 — Dashboard + Summary](docs/day2/day2-notes.md)
- [Day 3 — Working Directory Tracking](docs/day3/day3-notes.md)
- [Full Architecture + All Annotations](docs/README.md)

---

## Contributing

This project is in active early development.
If you want to contribute or have ideas, open an issue.

---

## License

MIT License — use it, fork it, build on it.
