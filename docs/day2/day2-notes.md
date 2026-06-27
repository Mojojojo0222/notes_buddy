# Day 2 — UI Dashboard + Daily Summary

## What We Built
- Dark theme HTML dashboard at localhost:9098
- Commands grouped by date, newest first
- Live search (filters without page reload)
- Auto-refresh every 15 seconds
- Daily summary box — total commands, most used, topics touched
- Auto category detection per command

---

## Most Important File Today
**`SummaryService.java`** — introduces Java Streams properly.
**`index.html`** — teaches how Spring serves static files and how
the frontend talks to the backend using fetch().

---

## DB Structure After Day 2

### Table: COMMAND (updated)
| Column      | Type      | Notes                              |
|-------------|-----------|------------------------------------|
| id          | BIGINT    | auto-incremented primary key       |
| text        | VARCHAR   | the actual command                 |
| category    | VARCHAR   | git / docker / kubernetes / etc    |
| saved_at    | TIMESTAMP | when we recorded it                |

category column added. Populated by detectCategory() in HistoryWatcher.

---

## Flow — GET /commands/all (Full Detail)

```
Browser JS: fetch('/commands/all')   ← called on load + every 15s
                        [index.html, inside load()]
        │
        ▼
CommandController.all()
                        [CommandController.java, line 22]
        │
        ▼
repo.findAll(Sort.by(Sort.Direction.ASC, "savedAt"))
  → Spring Data generates:
    SELECT * FROM command ORDER BY saved_at ASC
                        [CommandController.java, line 23]
        │
        ▼
Returns List<Command> (Java objects)
        │
        ▼
@RestController converts to JSON via Jackson library
  → calls getId(), getText(), getCategory(), getSavedAt()
    on each Command object to build JSON
        │
        ▼
JSON array sent to browser
        │
        ▼
JS render(commands) in index.html
                        [index.html, inside render()]
        │
        ▼
Groups commands by date:
  cmd.savedAt.split('T')[0]
  "2026-06-27T22:03" → "2026-06-27"
  builds groups = { "2026-06-27": [cmd1, cmd2, ...] }
        │
        ▼
Object.keys(groups).sort().reverse()
  → newest date first
        │
        ▼
For each command:
  cmd.savedAt.split('T')[1].substring(0,5)
  "2026-06-27T22:03:45" → "22:03"
        │
        ▼
Builds HTML string, sets output.innerHTML
  → page shows the list
```

---

## Flow — GET /summary (Full Detail)

```
Browser JS: fetch('/summary')    ← called inside load() after render()
                        [index.html, inside loadSummary()]
        │
        ▼
CommandController.summary()
                        [CommandController.java, line 27]
        │
        ▼
summaryService.getDailySummary()
                        [SummaryService.java, line 20]
        │
        ▼
LocalDate today = LocalDate.now()
  → "2026-06-27"
                        [SummaryService.java, line 22]
        │
        ▼
repo.findAll(Sort.by(ASC, "savedAt"))
  → all commands from DB
                        [SummaryService.java, line 23]
        │
        ▼
.stream().filter(c -> c.getSavedAt().toLocalDate().equals(today))
  → keeps only today's commands
                        [SummaryService.java, line 25]
        │
        ▼
Collectors.groupingBy(Command::getText, Collectors.counting())
  → { "git status": 3, "ls": 5, "docker ps": 1 }
                        [SummaryService.java, line 30]
        │
        ▼
.max(Map.Entry.comparingByValue())
  → finds entry with highest count → "ls": 5
  .map(e -> e.getKey() + " (" + e.getValue() + " times)")
  → "ls (5 times)"
                        [SummaryService.java, line 34]
        │
        ▼
.map(Command::getCategory).distinct().sorted().toList()
  → ["docker", "files", "git", "kubernetes"]
                        [SummaryService.java, line 39]
        │
        ▼
LinkedHashMap built with all results
  → returned as Map<String, Object>
  → @RestController converts to JSON
                        [SummaryService.java, line 42-48]
        │
        ▼
Browser loadSummary() receives JSON:
{
  "date": "2026-06-27",
  "totalCommands": 22,
  "topicsTouched": ["docker","files","git"],
  "mostUsed": "ls (5 times)"
}
        │
        ▼
document.getElementById('totalCommands').textContent = data.totalCommands
document.getElementById('mostUsed').textContent = data.mostUsed
topics rendered as <span class="topic-tag"> elements
```

---

## Key Concepts Learned

**Java Streams**
A pipeline for processing collections.
.stream() → convert list to stream
.filter() → keep only matching items
.map() → transform each item
.collect() → gather results back into a collection
.distinct() → remove duplicates
.sorted() → alphabetical order
.toList() → back to List

**`Collectors.groupingBy()`**
Groups items by a key function.
groupingBy(Command::getText) groups by command text.
groupingBy(Command::getText, counting()) also counts each group.

**`LinkedHashMap` vs `HashMap`**
HashMap has no guaranteed order.
LinkedHashMap preserves insertion order.
We use LinkedHashMap so JSON fields appear in a predictable order.

**How Spring serves static files**
Any file in src/main/resources/static/ is served automatically.
index.html at that path → accessible at localhost:9098/
No controller needed for static files.

**`fetch()` in JavaScript**
fetch('/commands/all') makes an HTTP GET request.
Returns a Promise. async/await makes it look synchronous.
.json() parses the response body as JSON.

**XSS Prevention — escapeHtml()**
If command text contains <script>alert(1)</script>
and we put it directly in innerHTML, browser executes it.
escapeHtml() converts < to &lt; so browser treats it as text.
Always escape user-generated content before putting in innerHTML.

---

## Why LinkedHashMap for Summary Response
We could have used a plain HashMap.
But HashMap randomizes field order in JSON output.
One run: {"date":..., "totalCommands":...}
Next run: {"totalCommands":..., "date":...}
LinkedHashMap preserves the order we insert keys.
Makes the API response predictable and easier to debug.

---

## Problems We Hit and Fixed

| Problem | Cause | Fix |
|---------|-------|-----|
| Summary showed old data | DB had junk from Day 1 experiments | Deleted DB files, restarted |
| topic-tag CSS not showing | Style was missing from HTML | Added .topic-tag CSS class |
