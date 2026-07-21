# Day 8 — Ingestion API: Real-Time Terminal → Cloud Pipeline

## What We Built
A real-time event ingestion pipeline. Every command typed in Git Bash on the laptop
is sent via HTTP POST to the EKS pod running in AWS Mumbai and saved to PostgreSQL.
The dashboard at the EKS public URL now shows live terminal activity.

This is the same pattern used by Datadog agent, Splunk forwarder, Fluentd,
every observability and telemetry tool in production. You built it from scratch.

---

## The Full Pipeline (End to End)

```
Git Bash terminal (Windows laptop)
    │
    │  PROMPT_COMMAND fires after every command
    │  log_command() runs:
    │    1. captures last command from history
    │    2. gets git repo name
    │    3. gets timestamp
    │    4. writes to ~/.notes_buddy_log (local backup)
    │    5. curl POST /ingest to EKS URL (background, non-blocking)
    │
    ▼
AWS EKS LoadBalancer
    a0efb8d5...ap-south-1.elb.amazonaws.com:80
    │
    ▼
notes-buddy pod (Spring Boot)
    POST /ingest
    │  CommandController.ingest()
    │  → CommandService.ingest()
    │      → isJunk() filter
    │      → detectCategory()
    │      → Command entity created
    │      → repo.save() → PostgreSQL
    │
    ▼
PostgreSQL pod (EBS volume, persistent)
    │
    ▼
Dashboard (EKS URL, auto-refreshes every 15s)
    Shows commands grouped by session, live
```

---

## What Changed — Every File

### New: `CommandService.java`
Extracted `isJunk()` and `detectCategory()` out of `HistoryWatcher` into a shared service.
Added `ingest()` method — single entry point for saving any command regardless of source.

**Why extract to a service?**
Before this change, the logic lived only in `HistoryWatcher`.
Now we have two sources: file watcher + HTTP endpoint.
If both had their own copy of `isJunk()` and `detectCategory()`, they'd drift apart over time.
One fix in one place, both sources benefit. This is the DRY principle (Don't Repeat Yourself).

**Why `@Service` not `@Component`?**
Both work. `@Service` is a specialization of `@Component` — semantically it says
"this class contains business logic." Spring treats them identically at runtime.
Use `@Service` for business logic, `@Repository` for DB access, `@Controller` for HTTP.

```java
@Service
public class CommandService {

    public Command ingest(String text, String workingDir, String repoName, String timestamp) {
        if (isJunk(text)) return null;  // null = caller knows it was skipped

        Command cmd = new Command(text, detectCategory(text), workingDir, repoName);
        if (timestamp != null && !timestamp.isBlank()) {
            try { cmd.setSavedAt(LocalDateTime.parse(timestamp)); }
            catch (Exception ignored) {}  // bad timestamp = use now(), don't crash
        }
        repo.save(cmd);
        return cmd;
    }
}
```

**Why return null for junk instead of throwing an exception?**
Junk commands are expected — they're not errors. Exceptions are for unexpected failures.
Returning null lets the caller (controller) decide what HTTP response to send back.
Controller returns `200 skipped` for junk, `200 saved` for real commands.
Both are 200 — the client (curl in .bashrc) doesn't need to handle errors.

---

### Updated: `CommandController.java`

Added `POST /ingest` endpoint:

```java
@PostMapping("/ingest")
public ResponseEntity<String> ingest(
        @RequestParam String text,
        @RequestParam(defaultValue = "") String workingDir,
        @RequestParam(defaultValue = "none") String repoName,
        @RequestParam(defaultValue = "") String timestamp) {

    Command saved = commandService.ingest(text, workingDir, repoName, timestamp);
    if (saved == null) return ResponseEntity.ok("skipped");
    return ResponseEntity.ok("saved");
}
```

**Why `@RequestParam` not `@RequestBody`?**
`@RequestBody` expects JSON: `{"text": "git status", ...}`
`@RequestParam` reads from query string OR form-encoded body.
`curl --data-urlencode` sends as `application/x-www-form-urlencoded`.
Spring's `@RequestParam` reads both automatically.
Simpler client — just curl, no JSON serialization needed.

**Why `defaultValue` on optional params?**
If `.bashrc` fails to capture workingDir or repoName, the request still succeeds.
Without defaultValue, Spring throws 400 Bad Request for missing required params.

**Why `ResponseEntity<String>` not just `String`?**
`ResponseEntity` gives control over HTTP status code.
Future: return 400 for bad input, 429 for rate limiting. Easy to add later.

---

### Updated: `HistoryWatcher.java`
Removed `isJunk()` and `detectCategory()` — now delegates to `CommandService.ingest()`.
Cleaner, shorter, single responsibility: just reads the file and calls ingest.

---

### Updated: `Command.java`
Added `@Column(length = 2000)` on `text` and `@Column(length = 1000)` on `workingDir`.

**Why did this fail?**
Default JPA column length = 255 characters (VARCHAR(255)).
Some commands are longer — `docker exec -it postgres psql -U notesbuddy -d notesbuddy -c "DROP TABLE..."` exceeds 255 chars.
PostgreSQL threw: `ERROR: value too long for type character varying(255)`.

**Why not `@Lob` (TEXT type)?**
`@Lob` maps to PostgreSQL `TEXT` — unlimited length.
VARCHAR(2000) is indexed efficiently. TEXT is not indexed by default.
For full-text search later, VARCHAR is better.

**Why `ddl-auto=update` didn't fix it automatically?**
Hibernate's `update` mode adds new columns/tables but never alters existing column types.
Altering a column type risks data loss — Hibernate refuses to do it automatically.
Fix: manually drop tables, let Hibernate recreate with new schema.

---

### Updated: `~/.bashrc`

```bash
NOTES_BUDDY_URL="http://a0efb8d5...ap-south-1.elb.amazonaws.com"

log_command() {
    local last_cmd ts repo

    last_cmd=$(history 1 | sed 's/^[ ]*[0-9]*[ ]*//')
    repo=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)
    [ -z "$repo" ] && repo="none"
    ts=$(date '+%Y-%m-%dT%H:%M:%S')

    # local backup
    echo "${ts}|$(pwd)|${repo}|${last_cmd}" >> "$NOTES_LOG"

    # send to EKS in background
    curl -s -o /dev/null -X POST \
        --data-urlencode "text=${last_cmd}" \
        --data-urlencode "workingDir=$(pwd)" \
        --data-urlencode "repoName=${repo}" \
        --data-urlencode "timestamp=${ts}" \
        "${NOTES_BUDDY_URL}/ingest" &
}
```

**Why `--data-urlencode` instead of query string?**
Query string: `?text=git+status&workingDir=/e/Notes_Buddy`
Problem: special characters in commands break the URL.
`kubectl exec -it pod -- bash` contains `--`, spaces, everything.
`--data-urlencode` tells curl: encode this value properly before sending.
curl handles every special character. Spring's `@RequestParam` reads the body automatically.

**Why `&` at the end of the curl command?**
`&` runs curl as a background process.
Without it: every keypress waits for the HTTP round trip to Mumbai (~200ms).
With `&`: curl fires and forgets. Terminal is instant.

**Why keep writing to the local file too?**
Resilience — if EKS is down, commands are still captured locally.
Local mode — when running `mvn spring-boot:run`, HistoryWatcher reads the file.
Same pattern as Datadog agent buffering locally before shipping to the backend.

---

## Problems Hit and Fixed

### Problem 1 — VARCHAR(255) overflow
```
PSQLException: ERROR: value too long for type character varying(255)
```
**Cause:** Long docker exec command exceeded default JPA column length.
**Fix:** `@Column(length = 2000)` + drop and recreate table.
**Learning:** Always set explicit column lengths for user-input fields.

### Problem 2 — python3 URL encoding not working in Git Bash
`.bashrc` was sending literal `${encoded_cmd}` instead of the encoded value.
**Cause:** python3 subshell wasn't executing properly in PROMPT_COMMAND context.
**Fix:** Replaced with `curl --data-urlencode` — no external tools needed.
**Learning:** Fewer dependencies = fewer failure points.

### Problem 3 — `[1]+ Done` appearing in terminal
Normal bash behavior — when a background job completes, bash prints its status.
Not an error. Suppress with `disown` after `&` if needed:
```bash
curl ... & disown
```

---

## Architecture Decision — HTTP POST vs Message Queue

For SRE interviews: "why not use SQS or Kafka?"

**Direct HTTP (what we built):**
- Simple, no extra infrastructure
- If EKS is down, command is lost (mitigated by local file backup)
- Latency ~200ms to Mumbai, fine for background job

**SQS (production choice):**
- Laptop → SQS → EKS pod polls → saves to DB
- EKS can be down for hours, commands queue up, nothing lost
- At-least-once delivery guarantee
- More infrastructure to manage

**The trade-off:** For a personal tool, direct HTTP is correct.
For a multi-user product with SLA requirements, SQS is correct.
Knowing when NOT to add complexity is a senior engineering skill.

---

## What This Unlocks

**HPA is now fully meaningful** — POST /ingest is stateless.
Multiple pods can handle requests safely. No duplicate problem.
Before today: scaling to 4 pods = 4x duplicate commands.
After today: scaling to 4 pods = 4x throughput, zero duplicates.

**Any device can send commands** — not just this laptop.
Any machine with curl and the EKS URL can ingest.
Future: VS Code extension, CI/CD pipeline events, GitHub webhooks.

**The data gap is closed** — EKS dashboard now shows real data.
Before today: dashboard on EKS was always empty.
After today: every terminal command appears within 15 seconds.

---

## Interview Questions

### "Walk me through the ingestion pipeline you built."

> "Every command I type triggers PROMPT_COMMAND which runs log_command().
> It captures the command, working directory, git repo name, and timestamp.
> Writes to a local backup file, then fires a curl POST to /ingest on our
> EKS LoadBalancer in AWS Mumbai — in the background so it doesn't slow the terminal.
>
> The Spring Boot pod receives it via @PostMapping /ingest.
> CommandService validates — filters junk, detects category — saves to PostgreSQL.
> Dashboard auto-refreshes every 15 seconds and shows commands grouped into sessions.
> Full round trip is ~200ms but backgrounded so the user never feels it."

---

### "Why @RequestParam instead of @RequestBody?"

> "curl --data-urlencode sends form-encoded data, not JSON.
> @RequestParam reads both query string and form-encoded body automatically.
> @RequestBody expects JSON with Content-Type: application/json.
> Using form encoding means the client is just curl — no JSON serialization needed.
> Simpler client, same result."

---

### "How do you handle failures in the ingestion pipeline?"

> "Two layers:
> First, local file backup — every command written to ~/.notes_buddy_log before curl fires.
> If EKS is unreachable, command is still captured locally.
> Second, curl is fire-and-forget — if it fails, terminal is never interrupted.
> For production I'd add SQS between laptop and pod — commands queue up
> even if the pod is restarting, at-least-once delivery guaranteed."

---

### "What is DRY and where did you apply it today?"

> "DRY = Don't Repeat Yourself. If the same logic exists in two places,
> a bug fix in one place doesn't fix the other.
>
> Before today, isJunk() and detectCategory() lived only in HistoryWatcher.
> When we added the HTTP ingest endpoint, we needed the same logic there too.
> Instead of copying it, we extracted both into CommandService.
> Now both HistoryWatcher and the controller call CommandService.ingest().
> One change fixes both paths. That's DRY in practice."

---

### "Why is the curl backgrounded with &?"

> "Without &, every terminal command would wait for the HTTP round trip to complete.
> Mumbai is ~200ms away. That means every git status, every ls, every cd
> would feel 200ms slower. Over a full day of work that's noticeable.
>
> With &, curl runs as a separate background process.
> The terminal returns instantly. The HTTP request completes in the background.
> The user never feels the latency.
>
> The trade-off: if the background curl fails, we don't know immediately.
> That's acceptable here because we have the local file as backup."

---

## Current Architecture (End of Day 8)

```
Git Bash (laptop)
    PROMPT_COMMAND → log_command()
    ├── writes → ~/.notes_buddy_log (local backup)
    └── curl POST /ingest → EKS LoadBalancer (background, non-blocking)

EKS Cluster (ap-south-1)
    notes-buddy pod (1-4 replicas via HPA)
    ├── POST /ingest → CommandService → PostgreSQL  ← NEW TODAY
    ├── GET /commands/all → dashboard data
    ├── GET /sessions → session-grouped data
    └── GET /summary → daily stats

    postgres pod (EBS 1Gi, persistent)

    HPA: minReplicas=1, maxReplicas=4, cpu threshold=50%
    CloudWatch: metrics + logs for all pods

Browser → EKS URL → live dashboard showing real terminal commands
```
