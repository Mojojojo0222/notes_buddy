# Day 14 — Observability Stack: SRE Dashboard

**Goal:** Custom Micrometer metrics + Prometheus alerting + Grafana dashboard.

## What We Built
| Component | What Changed |
|-----------|-------------|
| `MetricsService.java` | NEW — 8 custom metrics (counters, timer with percentiles, tagged counter) |
| `CommandService.java` | Records ingested + failed + category metrics |
| `CommandController.java` | Records search latency + tags + solutions metrics |
| `prometheus-alerts.yml` | NEW — 4 alerts: AppDown, HighErrorRate, IngestionStopped, SearchLatencyHigh |
| `grafana-dashboard.json` | NEW — 8-panel Grafana dashboard (importable) |

## Summary
- 8 custom Micrometer metrics: ingested, skipped, failed, by_category, search requests, search latency (p50/p95/p99), tags, solutions
- 4 Prometheus alerting rules — ratio-based error detection, ingestion stall, latency spikes
- Grafana dashboard with ingestion rate, category pie chart, latency thresholds, JVM memory
- All existing infrastructure used — no new services, no cluster needed