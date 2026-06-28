# Notes Buddy — Learning Docs

## Day-wise Index
| Day | What We Built | Doc |
|-----|--------------|-----|
| Day 1 | Terminal logger, H2 DB, bash history | [day1/day1-notes.md](day1/day1-notes.md) |
| Day 2 | UI dashboard, daily summary, categories | [day2/day2-notes.md](day2/day2-notes.md) |
| Day 3 | Working directory, clean log file, bash fix | [day3/day3-notes.md](day3/day3-notes.md) |
| Day 4 | Repo name tracking, filter buttons, Docker | [day4/day4-notes.md](day4/day4-notes.md) |

---

## File Importance Ranking

### Tier 1 — Delete these and nothing works at all
| File | Why Critical |
|------|-------------|
| `.bashrc` | Source of all data. No bash config = no log file = no commands ever saved |
| `HistoryWatcher.java` | The only thing that reads the log and writes to DB |
| `NotesApplication.java` | Entry point. Without it the app doesn't start |

### Tier 2 — Delete these and the app breaks at runtime
| File | What breaks |
|------|------------|
| `Command.java` | No entity = no table = save() crashes |
| `CommandRepository.java` | Nothing can query or save commands |
| `WatcherState.java` | No bookmark = duplicates on every restart |
| `WatcherStateRepository.java` | HistoryWatcher can't load/save position |

### Tier 3 — Delete these and features disappear but app still runs
| File | What breaks |
|------|------------|
| `SummaryService.java` | /summary returns 404, summary box shows — |
| `CommandController.java` | All endpoints 404, nothing visible in browser |
| `index.html` | / returns 404, no UI, but /commands/all still returns JSON |

### Tier 4 — Config, wrong values cause subtle bugs
| File | What breaks if wrong |
|------|---------------------|
| `application.properties` | Wrong port, wrong DB path, data lost on restart |
| `pom.xml` | Missing dependency = compile error or feature missing at runtime |

---

## Architecture in One Picture

```
                    YOUR LAPTOP
┌─────────────────────────────────────────────────┐
│                                                 │
│  Git Bash                                       │
│    you type commands                            │
│    PROMPT_COMMAND runs after each               │
│    writes → ~/.notes_buddy_log                  │
│                                                 │
│  Spring Boot App (port 9098)                    │
│  ┌─────────────────────────────────────────┐   │
│  │                                         │   │
│  │  HistoryWatcher (background thread)     │   │
│  │    wakes every 10s                      │   │
│  │    reads .notes_buddy_log               │   │
│  │    saves new commands to DB             │   │
│  │                                         │   │
│  │  CommandController (web layer)          │   │
│  │    GET /commands/all → list             │   │
│  │    GET /summary      → daily stats      │   │
│  │                                         │   │
│  │  SummaryService (business logic)        │   │
│  │    filters today's commands             │   │
│  │    counts frequency                     │   │
│  │    finds most used                      │   │
│  │                                         │   │
│  │  H2 Database (notesbuddy-db.mv.db)      │   │
│  │    COMMAND table                        │   │
│  │    WATCHER_STATE table                  │   │
│  │                                         │   │
│  └─────────────────────────────────────────┘   │
│                                                 │
│  Browser → localhost:9098                       │
│    loads index.html                             │
│    fetches /commands/all every 15s              │
│    fetches /summary on load                     │
│                                                 │
└─────────────────────────────────────────────────┘
```

---

## All Endpoints

| Method | URL | Handler | Returns |
|--------|-----|---------|---------|
| GET | / | static/index.html | HTML page |
| GET | /commands/all | CommandController.all() | JSON array of all commands |
| GET | /summary | CommandController.summary() | JSON object with today's stats |
| GET | /h2-console | H2 built-in | SQL browser for debugging |

---

## All Annotations Used

| Annotation | File | What it does |
|------------|------|-------------|
| `@SpringBootApplication` | NotesApplication | Starts Spring, enables component scan + auto-config |
| `@EnableScheduling` | NotesApplication | Activates @Scheduled background threads |
| `@Service` | HistoryWatcher, SummaryService | Spring manages this as a singleton bean |
| `@RestController` | CommandController | Web controller, auto-converts return to JSON |
| `@GetMapping` | CommandController | Maps GET HTTP requests to a method |
| `@Scheduled` | HistoryWatcher | Runs method on a timer automatically |
| `@Entity` | Command, WatcherState | Creates a DB table for this class |
| `@Id` | Command, WatcherState | Marks the primary key column |
| `@GeneratedValue` | Command | DB auto-increments the id |

---

## Common Questions

**Q: Why not use @Autowired for injection?**
Constructor injection is preferred. Easier to test, fields can be final,
Spring recommends it since 4.x.

**Q: Why H2 and not MySQL or PostgreSQL?**
H2 needs zero installation. For a local laptop tool this is fine.
Month 2 we switch to PostgreSQL when we need more power.

**Q: What is Jackson?**
The library Spring uses to convert Java objects to JSON automatically.
It calls getters (getId, getText etc) to build the JSON fields.
That's why every field needs a getter — without it, Jackson can't see it.

**Q: Why does Command need a no-arg constructor?**
JPA reconstructs objects when reading from DB.
It creates an empty object using no-arg constructor, then sets each field.
Without it: InstantiationException when you call findAll().

**Q: What is a Spring Bean?**
Any object that Spring creates and manages.
@Service, @RestController, @Repository all create beans.
You never write `new SummaryService()` — Spring does it and injects it.
