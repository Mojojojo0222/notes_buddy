# Notes Buddy — Roadmap

> A personal engineering journal that writes itself.
> Built in Spring Boot. Runs locally. Zero manual note-taking.

---

## ✅ Month 1 — Foundation (Done)

### Day 1 — Terminal Command Logger
- [x] Read `.bash_history` every 10 seconds
- [x] Save commands to H2 database with timestamp
- [x] Persist watcher position so restarts don't cause duplicates
- [x] Filter junk lines (comments, variable assignments)
- [x] Fix PROMPT_COMMAND so Git Bash writes commands immediately

### Day 2 — UI + Summary
- [x] Dark theme HTML dashboard at localhost:9098
- [x] Commands grouped by date, newest first
- [x] Live search (no page reload)
- [x] Auto-refresh every 15 seconds
- [x] Daily summary — total commands, most used, topics touched
- [x] Auto category detection (git, docker, kubernetes, terraform, files, etc.)

### Day 3 — Working Directory Tracking
- [x] Capture which folder each command was run from
- [x] Show directory under each command in the UI
- [x] `.bashrc` updated to write `#DIR:` marker into history

---

## ✅ Month 1 Remaining (Done)

- [x] Category filter buttons on dashboard (click [git] to show only git commands)
- [x] Git repo name tracked per command (🔀 label in UI)
- [x] Docker support — multi-stage Dockerfile, volume mounts for log + DB
- [x] Spring Boot Actuator — /actuator/health for K8s liveness + readiness probes
- [x] Externalized config via env vars — PORT, DB_PATH, H2_CONSOLE
- [x] "All" button to clear all active category filters
- [x] PostgreSQL migration (docker-compose with Spring Boot + Postgres containers)
- [x] Session detection — group commands by 30-min idle gap (SessionService)
- [x] Session view on dashboard — collapsible session cards with duration + categories
- [x] Timestamp in log format — exact real time per command, no more same-time bug

---

## ✅ Month 2 — All Done

- [x] Store exit codes (requires bash change: `echo $?` after command)
- [x] Tag commands manually from the UI

---

## ✅ Month 3 — All Done

- [x] Weekly summary endpoint + UI section
- [x] Timeline view — pick any date and see full activity
- [x] Filter persistence (localStorage)

---

## 🔲 Month 3 Remaining

- [ ] Per-category drill down page
- [ ] File watcher — detect when Dockerfile, pom.xml, *.yaml change

---

## 🔲 Month 4 — Search + Solution Cards

- [ ] Full text search across all commands and notes
- [ ] Manual tags on commands
- [ ] Solution cards — when same error reappears, link to previous fix
- [ ] Export today's session as Markdown

---

## 🔲 Month 5 — Vector Memory

- [ ] Add Qdrant vector database
- [ ] Embed commands and sessions
- [ ] Semantic search — "when did I fix ImagePullBackOff"
- [ ] Related commands suggestion

---

## 🔲 Month 6 — Polish + Demo Ready

- [ ] Clean up UI for demo
- [ ] Export full history as Markdown report
- [ ] ROADMAP.md fully ticked
- [ ] Demo script: "This laptop has been running for 180 days, ask me anything about my work"

---

## Tech Stack

| Layer | Technology |
|---|---|
| Backend | Spring Boot 3.2 |
| Database (now) | H2 (file-based) |
| Database (Month 2) | PostgreSQL |
| Vector DB (Month 5) | Qdrant |
| Frontend | Vanilla HTML/JS |
| Shell | Git Bash (Windows) |

---

## Architecture

```
Git Bash
   │  writes to .bash_history every command
   ▼
HistoryWatcher (runs every 10s)
   │  reads new lines, detects category + directory
   ▼
H2 Database
   │
   ├── CommandController  →  /commands/all  →  UI list
   └── SummaryService     →  /summary       →  UI summary box
```
