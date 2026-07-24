# Day 14 — Observability Stack: SRE Dashboard

**Goal:** Add custom Micrometer metrics, Prometheus alerting, and a Grafana dashboard — turning Notes Buddy into a fully observable system with SRE-grade monitoring.

---

## Session Context

Days 1-13 built the application features (ingestion, search, solution cards). The infrastructure for observability was already in place (`pom.xml` had `micrometer-registry-prometheus`, Prometheus and Grafana ran in docker-compose), but the app exposed zero custom metrics. Only JVM defaults (heap, threads, GC) were available.

This day fills that gap — adding business-level metrics that an SRE would care about: ingestion rate, error rate, search latency, category distribution, and solution card activity.

---

## SRE Mindset

The question an SRE asks: **"How do I know when something is wrong before the user tells me?"**

Before Day 14:
- App UP/DOWN → actuator health check (binary, not helpful)
- Errors visible only on the dashboard UI (reactive, pull-based)
- No historical data on performance (can't measure trends)

After Day 14:
- Ingestion rate graph → "Did the log file stop being written?"
- Error rate + alert → "Error spike detected, auto-scaling or fix needed"
- Search latency p95 + alert → "DB query performance degraded"
- Category distribution → "What am I spending most of my terminal time on?"
- JVM memory → "Is there a leak? When should I restart?"

---

## Feature: Custom Micrometer Metrics

### `MetricsService.java`

A centralized service that manages all custom metrics via Micrometer's `MeterRegistry`:

| Metric Name | Type | Tags | What It Measures |
|------------|------|------|-----------------|
| `notesbuddy_commands_ingested_total` | Counter | — | Total commands saved to DB |
| `notesbuddy_commands_skipped_total` | Counter | — | Commands filtered as junk |
| `notesbuddy_commands_failed_total` | Counter | — | Commands with exitCode != 0 |
| `notesbuddy_commands_by_category_total` | Counter | `category` | Commands broken down by type |
| `notesbuddy_search_requests_total` | Counter | — | Search API calls |
| `notesbuddy_search_latency_seconds` | Timer | — | p50/p95/p99 search duration |
| `notesbuddy_tag_requests_total` | Counter | — | Tag assignments via UI |
| `notesbuddy_solutions_shown_total` | Counter | — | Solution cards returned |

**Key patterns:**
- **Counter** for cumulative totals (ingested, failed, searched)
- **Timer** for latency with percentile distributions (p50=median, p95=bad, p99=critical)
- **Tagged counter** for dimensional data (by category) — enables Prometheus `group by category` queries

### Injection Points

```java
// CommandService.ingest()
metrics.recordIngested(cmd.getCategory());  // +1 per category
if (code != 0) metrics.recordFailed();      // +1 on failure

// CommandController.search()
long start = System.currentTimeMillis();
List<Command> results = repo.searchCommands(q.trim());
metrics.recordSearch(System.currentTimeMillis() - start);  // latency recorded

// CommandController.tagCommand()
metrics.recordTag();

// CommandController.solutions()
metrics.recordSolutions(cards.size());
```

---

## Feature: Prometheus Alerting Rules

4 alert rules in `prometheus-alerts.yml`:

| Alert | Expression | Severity | Response |
|-------|-----------|----------|---------|
| **AppDown** | `up{job="notes-buddy"} == 0` for 30s | Critical | Restart container or pod |
| **HighErrorRate** | `rate(failed[5m]) / rate(ingested[5m]) > 0.2` for 2m | Warning | Check what's failing, investigate |
| **IngestionStopped** | `rate(ingested[5m]) == 0` for 10m | Warning | Check log file, HistoryWatcher, disk space |
| **SearchLatencyHigh** | `search_latency_p95 > 2.0` for 2m | Warning | DB index missing, query optimization needed |

**Why these specific alerts?**
- **AppDown** — Binary check. The most basic SRE alert. Already had actuator health, now Prometheus tracks uptime.
- **HighErrorRate** — Ratio-based. Raw count spikes are meaningless (more commands = more errors). Ratio tells you if the error rate changed independently of volume.
- **IngestionStopped** — Silence is dangerous. If the app stopped recording commands, you won't notice until you look at the dashboard. This alerts proactively.
- **SearchLatencyHigh** — User-facing latency. Slow search makes the dashboard feel broken. P95 > 2s means 1 in 20 searches is painful.

---

## Feature: Grafana Dashboard

The dashboard JSON in `grafana-dashboard.json` is importable directly into Grafana:

### Panels

| Panel | Type | Data Source | What It Shows |
|-------|------|-------------|---------------|
| Command Ingestion Rate | Graph (time series) | `rate(ingested[5m])` vs `rate(failed[5m])` | Green line = ingested/sec, red = failed/sec |
| Search Requests | Graph (time series) | `rate(search[5m])` | Search queries per second |
| Commands by Category | Pie Chart | `topk(10, by_category)` | Your terminal activity by tool (git/docker/k8s etc.) |
| Search Latency (p95) | Stat + Thresholds | `search_latency_p95` | Green < 1s, Orange < 2s, Red > 2s |
| Total Commands | Stat | `ingested_total` | Lifetime command count |
| Failed Commands | Stat + Thresholds | `failed_total` | Green < 10, Orange < 50, Red > 50 |
| Tag & Solution Activity | Graph (time series) | `rate(tags[5m])` + `rate(solutions[5m])` | How often you tag and see solutions |
| JVM Memory | Graph (time series) | `jvm_memory_used_bytes` | Heap vs non-heap memory in MB |

### How to Import

```bash
# 1. Open http://localhost:3000 (admin/admin)
# 2. Connections → Data Sources → Add Prometheus → URL: http://prometheus:9090 → Save
# 3. Dashboards → New → Import → Upload grafana-dashboard.json → Select Prometheus
```

### SRE Dashboard Layout

```
┌──────────────────────────────┬──────────────────────────────┐
│   Command Ingestion Rate     │     Search Requests          │
│   (ingested vs failed/sec)   │     (queries/sec)            │
├──────────┬──────────┬────────┴──┬───────────────────────────┤
│ Commands │  Search  │  Total    │    Failed Commands        │
│ by       │ Latency  │ Commands  │    (with thresholds)      │
│ Category │ (p95)    │           │                           │
├──────────┴──────────┴──────────┴───────────────────────────┤
│   Tag & Solution Activity     │     JVM Memory (MB)        │
└──────────────────────────────┴──────────────────────────────┘
```

---

## SRE Runbook Integration

This observability stack feeds directly into the Runbook:

| Scenario | How You'd Detect It Via Metrics |
|----------|--------------------------------|
| App crashed | `AppDown` alert OR Grafana "Command Ingestion Rate" flatlines |
| Log file stopped writing | `IngestionStopped` alert — rate(ingested) = 0 |
| Docker builds keep failing | `HighErrorRate` alert + check failed_total by category |
| Search feels slow | `SearchLatencyHigh` alert + check p95 latency panel |
| Memory leak | JVM memory panel shows steady increase over hours/days |

---

## File Change Log

| File | Lines Changed | What Changed |
|------|--------------|-------------|
| `MetricsService.java` | NEW (67 lines) | All custom Micrometer metrics |
| `CommandService.java` | +6 | Inject MetricsService, record ingested/failed |
| `CommandController.java` | +10 | Inject MetricsService, record search latency/tags/solutions |
| `prometheus-alerts.yml` | NEW (24 lines) | 4 SRE alerting rules |
| `prometheus.yml` | +2 | Added `rule_files:` reference |
| `docker-compose.yml` | +1 | Mount alert rules file into Prometheus |
| `grafana-dashboard.json` | NEW (115 lines) | Importable Grafana dashboard with 8 panels |

## Files Created

| File | Content |
|------|---------|
| `src/main/java/com/notesbuddy/service/MetricsService.java` | Micrometer metrics service |
| `prometheus-alerts.yml` | Prometheus alerting rules |
| `grafana-dashboard.json` | Grafana dashboard definition |
| `docs/day14/day14-notes.md` | This file |
| `docs/day14/README.md` | Day 14 quick reference |

---

## Key Decisions Summary

| Decision | Rationale |
|----------|-----------|
| `Counter.builder()` over `@Timed` annotation | Explicit control over tag values. `@Timed` on controller methods can't dynamically set category tags. |
| Timer with percentiles (p50/p95/p99) not avg | Average latency hides outliers. P95 tells you what most users experience. P99 tells you the worst case. |
| Rate-based alerts (`rate()[5m]`) | Raw counter values always increase. Rate gives you per-second activity, which is what matters for alerting. |
| Ratio alert for error rate | 5 failures in 10 commands = 50% error rate (bad). 5 failures in 1000 commands = 0.5% (fine). Ratio normalizes for volume. |
| Static Grafana dashboard JSON | Importable, version-controllable, reproducible. No manual click-build. Any team member can import the same dashboard. |
| Metrics in a separate service | Single responsibility. If we change metric names or add dimensions, only MetricsService changes. Consumers don't care about metric implementation. |

---

## What This Enables Next

1. **Custom Grafana alerts** — Set up Grafana Alerting (email, Slack, webhook) when error rate spikes or ingestion stops. Real SRE pager duty.

2. **Auto-scaling based on metrics** — In K8s, HPA could scale based on `rate(commands_ingested_total[5m])` — more terminal activity → more pods.

3. **SLI/SLO tracking** — Define Service Level Indicators: ingestion latency p99 < 500ms, search p95 < 1s, uptime > 99.9%. Track against SLOs in Grafana.

4. **Cost monitoring** — Add Prometheus metrics for EBS volume size, ALB request count, data transfer. Track per-command cost.

---

## Testing the Observability Stack

```bash
# 1. Check custom metrics from the app
curl http://localhost:9098/actuator/prometheus | grep notesbuddy_

# 2. Check Prometheus is scraping (targets)
curl http://localhost:9090/api/v1/targets

# 3. Check alert rules are loaded
curl http://localhost:9090/api/v1/rules

# 4. Generate traffic and watch metrics change
for i in 1 2 3; do
  curl -s "http://localhost:9098/commands/search?q=docker" > /dev/null
  curl -s -X POST "http://localhost:9098/ingest" \
    -d "text=git commit -m 'test'" \
    -d "workingDir=/test" -d "repoName=test" \
    -d "exitCode=0" > /dev/null
done
curl http://localhost:9098/actuator/prometheus | grep notesbuddy_

# 5. Open Grafana
# http://localhost:3000 (admin/admin)
# Add Prometheus data source: http://prometheus:9090
# Import grafana-dashboard.json
```