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
- the **git repo name** it was run inside (or `none`)
- the time it was run
- the category (git, docker, kubernetes, terraform, build, files, network, editor)

You get a clean dashboard at `localhost:9098` showing everything
grouped by date, newest first — with a daily summary, live search,
and **category filter buttons**.

```
⚡ Notes Buddy

Today's Summary
Commands Run: 22    Most Used: git status (3x)    Topics: [docker] [git] [files]

[ all ] [ build ] [ docker ] [ files ] [ git ] [ network ]

Saturday, June 28, 2026
  22:03   git status
          📁 /e/Notes_Buddy
          🔀 notes-buddy
  22:01   docker --version
          📁 /c/Users/Lenovo
  21:58   mvn spring-boot:run
          📁 /e/Notes_Buddy
          🔀 notes-buddy
```

---

## Tech Stack

| Layer      | Technology                |
|------------|---------------------------|
| Backend    | Spring Boot 3.2 (Java 17) |
| Database   | H2 (file-based)           |
| Frontend   | Vanilla HTML/JS           |
| Shell      | Git Bash (Windows)        |
| Container  | Docker (multi-stage build)|

---

## Project Structure

```
notes-buddy/
├── src/main/java/com/notesbuddy/
│   ├── NotesApplication.java              # entry point + @EnableScheduling
│   ├── controller/
│   │   └── CommandController.java         # REST endpoints
│   ├── model/
│   │   ├── Command.java                   # command entity (text, category, dir, repo, time)
│   │   └── WatcherState.java              # bookmark entity (last line read)
│   ├── repository/
│   │   ├── CommandRepository.java
│   │   └── WatcherStateRepository.java
│   └── service/
│       ├── HistoryWatcher.java            # reads log file every 10s
│       └── SummaryService.java            # builds daily summary
├── src/main/resources/
│   ├── static/index.html                  # dashboard UI
│   └── application.properties
├── docs/
│   ├── day1/day1-notes.md                 # terminal logger + core flow
│   ├── day2/day2-notes.md                 # dashboard + summary
│   ├── day3/day3-notes.md                 # working directory tracking
│   ├── day4/day4-notes.md                 # repo tracking + filter buttons + Docker
│   └── README.md                          # architecture + all annotations
├── Dockerfile                             # multi-stage Docker build
├── .dockerignore
├── ROADMAP.md
└── pom.xml
```

---

## Getting Started

### Option A — Run with Maven (simplest)

#### Prerequisites
- Java 17+
- Maven 3.8+
- Git Bash (Windows)

#### 1. Clone the repo
```bash
git clone https://github.com/YOUR_USERNAME/notes-buddy.git
cd notes-buddy
```

#### 2. Configure Git Bash to log commands

Add this to `~/.bashrc` (create it if it doesn't exist):

```bash
NOTES_LOG="$HOME/.notes_buddy_log"

log_command() {
    local last_cmd
    last_cmd=$(history 1 | sed 's/^[ ]*[0-9]*[ ]*//')
    local repo
    repo=$(git rev-parse --show-toplevel 2>/dev/null | xargs basename 2>/dev/null || echo "none")
    echo "$(pwd)|${repo}|${last_cmd}" >> "$NOTES_LOG"
}

export PROMPT_COMMAND='history -a; log_command'
```

Make sure `~/.bash_profile` loads it:
```bash
if [ -f ~/.bashrc ]; then
    source ~/.bashrc
fi
```

Reload:
```bash
source ~/.bashrc
```

#### 3. Run the app
```bash
mvn spring-boot:run
```

#### 4. Open the dashboard
```
http://localhost:9098
```

---

### Option B — Run with Docker

#### Prerequisites
- Docker Desktop installed and running
- Git Bash configured (same `.bashrc` setup as above)

#### 1. Build the image
```bash
docker build -t notes-buddy .
```

#### 2. Run the container

**Windows Git Bash:**
```bash
docker run -d \
  -p 9098:9098 \
  -v "$HOME/.notes_buddy_log:/root/.notes_buddy_log" \
  -v "$PWD/notesbuddy-db:/app/notesbuddy-db" \
  --name notes-buddy \
  notes-buddy
```

> `-v "$HOME/.notes_buddy_log:/root/.notes_buddy_log"` — mounts your log file into the container so HistoryWatcher can read it.
> `-v "$PWD/notesbuddy-db:/app/notesbuddy-db"` — persists the H2 database outside the container so data survives restarts.

#### 3. Open the dashboard
```
http://localhost:9098
```

#### Stop / restart
```bash
docker stop notes-buddy
docker start notes-buddy
```

---

## API Endpoints

| Method | Endpoint                 | Description                                      |
|--------|--------------------------|--------------------------------------------------|
| GET    | `/`                      | Dashboard UI                                     |
| GET    | `/commands/all`          | All commands as JSON, sorted by time             |
| GET    | `/commands/by-date`      | Commands for a specific date (`?date=YYYY-MM-DD`)|
| POST   | `/commands/{id}/tag`     | Tag a command (`?tag=myLabel`)                   |
| GET    | `/summary`               | Today's summary (count, most used, topics)       |
| GET    | `/summary/weekly`        | Weekly summary (last 7 days, includes error count)|
| POST   | `/ingest`                | Ingestion endpoint (called by .bashrc curl)      |
| GET    | `/sessions`              | Sessions grouped by 30-min idle gap              |
| GET    | `/h2-console`            | H2 database browser (debug, non-Docker only)     |

### Example — `/commands/all`
```json
[
  {
    "id": 1,
    "text": "git status",
    "category": "git",
    "workingDir": "/e/Notes_Buddy",
    "repoName": "notes-buddy",
    "savedAt": "2026-06-28T22:03:15"
  }
]
```

### Example — `/summary`
```json
{
  "date": "2026-06-28",
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
    │  detects git repo name via: git rev-parse --show-toplevel
    │  writes → ~/.notes_buddy_log
    │  format: /path/to/dir|repo-name|command text
    ▼
~/.notes_buddy_log
    │
    │  HistoryWatcher reads every 10 seconds
    │  only reads new lines (bookmark stored in DB)
    │  parses: dir | repo | command
    │  detects category, filters junk
    ▼
H2 Database  (notesbuddy-db.mv.db)
    │
    ├── GET /commands/all  →  full command list (JSON)
    └── GET /summary       →  daily stats (JSON)
    ▼
localhost:9098  (your browser)
    │
    ├── Summary box     — total, most used, topics
    ├── Filter buttons  — click [git] to show only git commands
    ├── Live search     — type to filter instantly
    └── Command list    — grouped by date, newest first
                          shows time, command, 📁 dir, 🔀 repo
```

---

## Auto-detected Categories

| Category   | Detected From                                    |
|------------|--------------------------------------------------|
| git        | `git `                                           |
| docker     | `docker `, `docker-compose `                     |
| kubernetes | `kubectl `, `helm `                              |
| terraform  | `terraform `, `tf `                              |
| build      | `mvn `, `gradle `                                |
| files      | `ls`, `cd `, `cp `, `mv `, `rm `, `mkdir `       |
| network    | `ssh `, `scp `, `curl `, `wget `, `ping `        |
| editor     | `cat `, `grep `, `tail `, `head `, `nano `, `vim `|
| other      | everything else                                  |

---

## Dashboard Features

| Feature             | How It Works                                                    |
|---------------------|-----------------------------------------------------------------|
| Summary box         | Fetches `/summary` on load — total count, most used, topics     |
| Category filters    | Buttons built from actual data — click to toggle, multi-select  |
| Live search         | Filters `allCommands` array in-browser, no server round trip    |
| Repo tracking       | 🔀 label under each command showing which git repo it came from |
| Directory tracking  | 📁 label under each command showing the working folder          |
| Auto-refresh        | Fetches new data every 15 seconds silently                      |
| XSS protection      | All command text run through `escapeHtml()` before rendering    |

---

## Roadmap

See [ROADMAP.md](ROADMAP.md) for the full 6-month plan.

**Currently built:**
- ✅ Terminal command logging (Git Bash)
- ✅ Working directory tracking
- ✅ Git repo name per command
- ✅ Auto category detection
- ✅ Daily summary
- ✅ Live search
- ✅ Category filter buttons
- ✅ Persistent bookmark (no duplicates on restart)
- ✅ Docker support (multi-stage build)

**Coming next:**
- 🔲 PostgreSQL migration
- 🔲 Session detection (30-min idle gap)
- 🔲 Weekly summary
- 🔲 Timeline view (pick any date)
- 🔲 File watcher (Dockerfile, pom.xml, *.yaml changes)
- 🔲 Solution cards (link repeated errors to previous fixes)
- 🔲 Semantic search (Qdrant vector DB)

---

## Development Docs

Detailed day-by-day notes covering every flow, every line, every decision:

| Day | What Was Built |
|-----|---------------|
| [Day 1](docs/day1/day1-notes.md) | Terminal logger, H2 DB, bash history watcher |
| [Day 2](docs/day2/day2-notes.md) | Dashboard UI, daily summary, category detection |
| [Day 3](docs/day3/day3-notes.md) | Working directory tracking, clean log format |
| [Day 4](docs/day4/day4-notes.md) | Repo name tracking, category filter buttons, Docker |
| [Architecture](docs/README.md) | Full architecture diagram, all annotations explained |

---

## Contributing

This project is in active early development.
If you want to contribute or have ideas, open an issue.

---

## License

MIT License — use it, fork it, build on it.
