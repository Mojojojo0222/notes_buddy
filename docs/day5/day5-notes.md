# Day 5 — Actuator + Externalized Config + Clear Filters

## What We Built
1. Spring Boot Actuator — `/actuator/health` endpoint for K8s probes
2. Externalized config via environment variables — app config no longer hardcoded
3. "All" button — clears all active category filters in one click

## Why These Three Today
All three are required before EKS deployment this weekend.
Kubernetes needs a health URL to ping (Actuator).
Kubernetes needs to inject config at runtime (env vars).
Clear filters was a Day 4 leftover — 10 minutes, clean it up.

---

## Feature 1 — Spring Boot Actuator

### What Is Actuator
A Spring Boot library that adds operational endpoints to your app automatically.
You add one dependency. Spring wires up the endpoints. You configure which to expose.

The one we care about right now: `/actuator/health`

### Why K8s Needs It

Kubernetes manages pods. It needs to know two things:
- **Liveness probe**: is this pod alive? (if not → kill it and restart)
- **Readiness probe**: is this pod ready to serve traffic? (if not → don't send requests to it)

Without a health endpoint, K8s has no way to answer these questions.
It would just send traffic to a pod that's still booting, or keep a broken pod running forever.

`/actuator/health` returns:
```json
{
  "status": "UP",
  "components": {
    "db": { "status": "UP" },
    "diskSpace": { "status": "UP" }
  }
}
```
Status `UP` = healthy. Status `DOWN` = something is wrong.
Spring checks the DB connection, disk space automatically. We get this for free.

### What Was Added

**`pom.xml`**
```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
```
No version needed — Spring Boot parent manages it.

**`application.properties`**
```properties
management.endpoints.web.exposure.include=health
management.endpoint.health.show-details=always
```

`exposure.include=health` — by default Actuator exposes nothing over HTTP.
This line explicitly says: expose the `health` endpoint.
You could write `include=*` to expose all endpoints (metrics, env, beans...) but
that's a security risk in production. We expose only what K8s needs.

`show-details=always` — by default `/actuator/health` just returns `{"status":"UP"}`.
`always` makes it return the full breakdown (DB status, disk space etc).
For a local tool this is fine. In production you'd set `show-details=when-authorized`.

### Trade-off
By default Spring Boot Actuator also exposes `/actuator/info`, `/actuator/metrics` etc via JMX.
We're only enabling HTTP exposure of `health`. Everything else stays JMX-only (internal, not web-accessible).
Month 2 when we add PostgreSQL, the DB component in the health response becomes more meaningful —
it'll show whether the Postgres connection is alive, not just H2.

---

## Feature 2 — Externalized Config via Environment Variables

### The Problem
Before today `application.properties` had:
```properties
server.port=9098
spring.datasource.url=jdbc:h2:file:./notesbuddy-db
```
These are baked into the JAR. In a Docker container or K8s pod, you can't change them
without rebuilding the image. That's wrong — config should be separate from code.

### The 12-Factor App Rule
"Store config in the environment."
Code stays the same. Config changes per environment (local / Docker / K8s / prod).
This is standard practice. K8s ConfigMaps and Secrets exist to inject exactly this.

### How Spring Boot Handles It
Spring Boot has a property resolution order. From highest to lowest priority:
1. Environment variables
2. `application.properties`
3. Default values in code

The syntax `${VAR_NAME:defaultValue}` means:
- Look for env var `VAR_NAME`
- If found → use it
- If not found → use `defaultValue`

### What Changed

```properties
server.port=${PORT:9098}
```
Locally: no `PORT` env var → defaults to `9098`. Nothing breaks.
In Docker: `docker run -e PORT=9098` → uses 9098.
In K8s ConfigMap: `PORT: "9098"` → uses 9098.
Tomorrow if you want port 8080: `docker run -e PORT=8080` → no rebuild needed.

```properties
spring.datasource.url=jdbc:h2:file:${DB_PATH:./notesbuddy-db}
```
Locally: defaults to `./notesbuddy-db` → H2 file in project root. Same as before.
In Docker: `-e DB_PATH=/app/notesbuddy-db` → H2 file at the volume mount path.
In K8s: ConfigMap sets `DB_PATH` to wherever the PersistentVolume is mounted.

```properties
spring.h2.console.enabled=${H2_CONSOLE:true}
```
Locally: H2 console stays enabled (useful for debugging).
In K8s: ConfigMap sets `H2_CONSOLE=false` → console disabled in production.

### Trade-off
H2 is still the database. Even with env var config, H2 has file locking issues in K8s
(can't have two pods reading the same file). This means:
- For EKS this weekend: run with 1 replica only (replicas: 1 in Deployment YAML)
- Month 2: migrate to PostgreSQL which is built for concurrent access and fits K8s properly

---

## Feature 3 — "All" Button (Clear Filters)

### What Changed in `index.html`

```javascript
// new clearFilters function
function clearFilters() {
    activeFilters.clear();  // empties the Set completely
    buildFilterButtons();
    applyFilters();
}
```

`activeFilters.clear()` — built-in Set method. Removes all entries. Size becomes 0.
`applyFilters()` then sees `activeFilters.size === 0` → shows everything.

```javascript
// "all" button added at the start of buildFilterButtons()
const clearBtn = `<button class="filter-btn ${activeFilters.size === 0 ? 'active' : ''}"
                    onclick="clearFilters()">all</button>`;
filtersEl.innerHTML = clearBtn + catBtns;
```

The `all` button is active (teal) when no category filters are selected — i.e. when you're seeing everything.
As soon as you click a category, `all` goes grey and the category goes teal.
Click `all` again → everything clears → `all` goes teal again.

### Why `activeFilters.size === 0` for the active check
When no filters are active, the "all" state is active by definition.
`size === 0` is exactly that condition. Same logic already used in `applyFilters()`.
One consistent rule in two places.

---

## DB Structure — Unchanged

No DB changes today. All three features are config/UI/infrastructure only.

---

## Files Changed Today

| File | What Changed |
|------|-------------|
| `pom.xml` | Added `spring-boot-starter-actuator` dependency |
| `application.properties` | Full rewrite — env var syntax, Actuator config |
| `src/main/resources/static/index.html` | `clearFilters()` function + "all" button in `buildFilterButtons()` |
| `docs/day5/day5-notes.md` | This file |

---

## Testing Checklist

### Local (Maven)
```bash
mvn spring-boot:run
```
- [ ] `localhost:9098` loads dashboard
- [ ] `localhost:9098/actuator/health` returns `{"status":"UP"}`
- [ ] Filter buttons show "all" at the start
- [ ] Click a category → "all" goes grey, category goes teal
- [ ] Click "all" → everything clears, "all" goes teal

### Docker
```bash
docker build -t notes-buddy .
docker run -d \
  -p 9098:9098 \
  -e PORT=9098 \
  -e DB_PATH=/app/notesbuddy-db \
  -e H2_CONSOLE=false \
  -v "$HOME/.notes_buddy_log:/root/.notes_buddy_log" \
  -v "$PWD/notesbuddy-db:/app/notesbuddy-db" \
  --name notes-buddy \
  notes-buddy
```
- [ ] `localhost:9098` loads dashboard
- [ ] `localhost:9098/actuator/health` returns `{"status":"UP"}`
- [ ] `localhost:9098/h2-console` returns 404 (H2_CONSOLE=false worked)
- [ ] Commands from Git Bash appear within 10 seconds
- [ ] Stop + start container → data still there (volume mount working)

---

## What's Next — EKS Weekend

Now that Actuator is live and config is externalized, the app is EKS-ready.

Weekend checklist:
1. Push Docker image to ECR
2. `eksctl create cluster`
3. Write `deployment.yaml` — uses the ECR image, sets env vars via ConfigMap
4. Write `service.yaml` — LoadBalancer to expose port 9098
5. Write `pvc.yaml` — PersistentVolumeClaim for H2 DB storage
6. Deploy and hit the dashboard from a public AWS URL
7. Add liveness + readiness probe pointing at `/actuator/health`

The H2 + single replica constraint means no auto-scaling yet.
That's fine — the goal this weekend is to understand K8s primitives
using an app we know inside out.
PostgreSQL + StatefulSet in Month 2 unlocks proper multi-replica deployment.

---

## Problems We Hit and Fixed

| Problem | Cause | Fix |
|---------|-------|-----|
| Docker Desktop not running | Not started | Start Docker Desktop, rebuild |
