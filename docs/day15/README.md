# Day 15 — Helm Charts

**Goal:** Production-grade Helm chart replacing raw `k8s/` YAML.

## What We Built
| Component | What Changed |
|-----------|-------------|
| `helm/notes-buddy/Chart.yaml` | Chart metadata (v0.1.0, app v1.0.0) |
| `helm/notes-buddy/values.yaml` | 100+ configurable values |
| `helm/notes-buddy/values-dev.yaml` | DEV: 8 resources, ClusterIP, minimal |
| `helm/notes-buddy/values-staging.yaml` | STAGING: 11 resources, LoadBalancer, HPA |
| `helm/notes-buddy/values-production.yaml` | PROD: 13 resources, full HA, Ingress, PDB |
| `helm/notes-buddy/templates/_helpers.tpl` | 6 reusable named templates |
| `helm/notes-buddy/templates/*.yaml` | 13 template files (namespace → ingress → rbac) |
| `k8s/` (unchanged) | Original raw YAML kept for reference |

## Summary
- **Before:** 7 separate `kubectl apply -f k8s/` commands, manual edits per env
- **After:** `helm install notes-buddy ./helm/notes-buddy -f values-prod.yaml`
- 3 environment profiles, same templates
- Production patterns: HPA, PDB, Ingress, rolling updates, checksum annotations
- Component labels on every resource for fine-grained queries
- Security: `b64enc` at render time, supports External Secrets Operator pattern
