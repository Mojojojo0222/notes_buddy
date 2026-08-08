# Day 17 — Stress Testing (Mastercard Interview Prep)

**Date:** 2026-08-09 | **Goal:** real-world load/failure testing, every answer a measured number

## Session Summary
- Rebuilt the EKS cluster (destroyed end of Day 16) — a 2-hour terraform fight
- Deployed app via Helm, installed k6 + metrics-server
- Ran correctness courses C1-C6 (all pass, one real bug found)
- Ran load courses C7 (ingest ceiling: **920 RPS zero errors**) + C8 (search storm: **app-wide failure at 897k rows**)
- Found a real cascading failure: CPU throttle → 1s probe timeout → kubelet kill → CrashLoopBackOff

## Key Numbers
| Metric | Value |
|---|---|
| Ingest ceiling | 920 RPS @ 0% errors (200 VUs), 953 RPS @ 0% (300 VUs) |
| Failure point | 500 VUs → 718 RPS, 0.28% errors, p95 1.6s |
| Search @ 897k rows | 5.7s per query (no index, no LIMIT) |
| DB size | 897,133 rows / 134 MB |
| Cluster cost | ~$120/mo (~$4/day) |

## Bugs Found
1. **2001-char command → HTTP 500** (varchar(2000) overflow, no truncation)
2. **Search has no LIMIT** — `%%` returns all 897k rows (~100MB JSON)
3. **Probe fragility** — 1s timeout kills pods under CPU throttling (exit 143)

## Full Details
→ [day17-notes.md](./day17-notes.md) — timeline, root causes, fixes, tomorrow's plan
