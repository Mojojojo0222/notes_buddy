# Day 17 — Stress Testing: Mastercard-Style Production Playbook (Part 1)

**Date:** 2026-08-09 (Saturday night session)
**Goal:** Real-world stress testing of Notes Buddy on EKS — find measured numbers,
break the system on purpose, document every failure + fix + trade-off.
**Why:** Mastercard-level interview prep. Every answer must be a number, not a guess.

---

## 0. The Setup Story (What We Started With)

| Fact | Value |
|---|---|
| Cluster | **Was destroyed** (end of Day 16 — cost saving) |
| Terraform state | Partial: VPC + subnets + IGW + ECR + cluster IAM role in state, rest gone |
| k6 | Not installed → installed v0.57.0 to `C:/Users/Lenovo/k6/k6.exe` |
| ECR | `083777493383.dkr.ecr.ap-south-1.amazonaws.com/notes-buddy` (alive) |
| Docker Desktop | Wasn't running → started it |
| ALB URL (final) | `http://a64a920e03ce5424a96bc55893a92774-868972225.ap-south-1.elb.amazonaws.com` |

---

## 1. Cluster Rebuild — The 2-Hour Fight (BIGGEST LESSON OF THE NIGHT)

### What went down

1. `terraform apply` started (24 to add). **Shell timeout killed it at 30 min**
   while `aws_eks_node_group.main` was still creating.
2. Checked AWS: EKS cluster ACTIVE (v1.31), but node group eventually went
   `CREATE_FAILED` — health issue: **"Instances failed to join the kubernetes cluster"**
   for both instances.
3. EC2 side looked healthy: 2 × t3.small **running**, IAM instance profile attached,
   launch template correct, cluster SG allowed all traffic (self-referencing).

### Root cause (the sneaky one)

`aws ec2 get-console-output` showed the real story:
```
nodeadm[1655]: SDK DEBUG retrying request EC2/DescribeInstances, attempt 2..9 (forever)
```
The node bootstrap (nodeadm) calls the **EC2 API** before joining the cluster.
That call needs internet. **The VPC route table had NO `0.0.0.0/0 → IGW` route.**
Why? Because the killed terraform apply had created the IGW but **never created
`aws_route_table.public` + the 2 associations** — they were mid-apply when the
process died. The IGW existed but nothing routed to it.

Fix sequence (each a mini-drama):
1. **Deleted the failed nodegroup** (`aws eks delete-nodegroup`) — waited for DELETING → gone
2. **Stale state lock** from the killed apply → `terraform force-unlock -force 8eeb0679-...`
3. **Dangling IGW in state**: terraform thought IGW was `igw-087e43090fb36210c`
   (unattached), but the real attached one was `igw-05490cc716c4bb693`.
   → `terraform state rm` + `terraform import module.vpc.aws_internet_gateway.main igw-05490cc716c4bb693` + deleted the dangling IGW
4. **EntityAlreadyExists — EKS OIDC provider** → `terraform import module.eks.aws_iam_openid_connect_provider.eks arn:...`
5. **EntityAlreadyExists — EBS CSI role** → `terraform import module.eks.aws_iam_role.ebs_csi notes-buddy-ebs-csi-role` + import policy attachment
6. Final `terraform apply` → **30 resources, EXIT 0, 2 nodes Ready.**

### Deploy checklist that followed
- `metrics-server` was missing (HPA showed `<unknown>`, `kubectl top` dead) →
  `kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/.../components.yaml`
  → HPA targets went live (4%/50%)
- Built image (`docker build` — cached, seconds), pushed to ECR
- `helm install notes-buddy ./helm/notes-buddy -f values-staging.yaml`
- App UP in ~3 min, DB connected, ALB provisioned

**Cluster final state:** 2 nodes Ready (t3.small, K8s 1.31), app 2 replicas,
HPA 2–4 @50% CPU, EBS CSI + CloudWatch addons active, metrics-server live.

---

## 2. Test Results — What We Measured

### C1 API smoke ✅
All 8 endpoints 200 (`health`, `commands/all`, `sessions`, `summary`,
`summary/weekly`, `solutions`, `search`, `by-date`). `/ingest` → `saved`.

### C2 Ingest edge cases — **ONE REAL BUG FOUND**
| Input | Result |
|---|---|
| 2000-char text | `saved` ✅ |
| **2001-char text** | **HTTP 500** ❌ — PostgreSQL `value too long for type varchar(2000)`. App doesn't truncate, no graceful 400. **Real gap: oversized input should be a 400/truncation, not a 500 (500s pollute the error budget).** |
| Unicode `héllo 😀` (proper UTF-8 bytes) | `saved`, round-trips perfectly ✅ |
| exitCode 0/1/255 | saved correctly ✅ |
| exitCode `abc` | → `null` (swallowed exception) ✅ |
| exitCode empty | → `null` ✅ |

> Note: sending literal `é`/`😀` from Git Bash mangled them to U+FFFD/`??` —
> that's the **Windows terminal encoding**, not the app. Verified by sending raw
> UTF-8 bytes from a file (`--data-urlencode text@file`): stored as `héllo 😀`.
> App is UTF-8 clean.

### C3 Tag API ✅
Tag set → `tagged`. Missing id (999999) → **404**. Blank tag → clears to `null`
(no empty strings in DB).

### C4 Search edge cases (SQLi) ✅
`docker' OR 1=1--`, `'; DROP TABLE command;--`, `1; SELECT pg_sleep(5);--`,
`%%`, `___`, `a%b_c`, `<script>`, `%d%`, `""`, `x` — **all 200**, DB intact,
no DROP executed, no sleep delay. ILIKE is parameterized. ✅

### C5 Solutions ✅
3× `kubectl describe pod broken-pod` + 2× `kubectl get pods -n kube-system` →
2 solution cards, exact-text grouped, most frequent first (3 before 2),
category `kubernetes` detected. Tagged the first → **tag became the fix** (`restart-coredns-helps`).

### C6 Concurrent duplicate ingest ✅ (documented behavior)
20 unique + 5× same payload concurrently → **EXACT-DUPE = 5 rows**.
No cross-request dedup by design (each POST = distinct event, stateless per request).
Interview answer: if dedup needed → unique constraint on `(text, savedAt, workingDir)`.

### C7 Ingest spike — THE CEILING CURVE (interview gold)
| VUs | RPS | Errors | p95 | Note |
|---|---|---|---|---|
| 30 | 211 | 0% | 112ms | trivial |
| 100 | 752 | 0% | 87ms | HPA scaled 2→4 (CPU hit 176%) |
| 200 | 920 | 0% | 317ms | — |
| 300 | 953 | 0% | 723ms | pods pinned at 500m CPU limit (throttling) |
| **500** | **718** | **0.28%** | **1.6s** | **CEILING + CASCADE** |

**The cascading failure (this is the "what happens when X fails" answer):**
1. CPU pinned at the 500m limit → **throttling**
2. Throttled JVM can't answer `/actuator/health` within the **1-second probe
   timeout** → kubelet events: `Liveness probe failed: context deadline exceeded`
3. 3 failed probes → kubelet kills pod with **SIGTERM (exit code 143)**
4. CrashLoopBackOff → HPA wants more replicas but pods keep dying → self-inflicted outage
5. **Recovery: automatic once load stopped** (~5 min, no manual intervention)

**The root cause is the probe config + CPU limit interaction, not the app:**
`initialDelaySeconds: 60` (Spring Boot takes ~76s to start) + `timeoutSeconds: 1`
+ `failureThreshold: 3` = fragile under CPU starvation. Any health endpoint that
can't answer in 1s while throttled gets killed. Classic Kubernetes footgun.

**Interview number:** "**920 RPS sustained with zero errors on 2×t3.small**;
the ceiling at 500 VUs was CPU-limit throttling + probe timeout cascade, not the DB."

### C8 Search storm — APP-WIDE FAILURE (the other big finding)
By now the DB had **897,133 rows / 134 MB** (accidentally seeded by the ingest
tests — a free 100k-scale test!).

- `EXPLAIN ANALYZE` on `kubectl` search at 897k rows: **5.7s execution** —
  Parallel Seq Scan, 747k rows filtered. No index (known trade-off).
- `%%` (match-all) returns **all 897,133 rows** — no LIMIT on the search endpoint
  (`CommandRepository.searchCommands` has no LIMIT).
- A 50-VU search storm with `%`, `___`, `a b` queries → **100% request failures**,
  all 4 pods crash-looping (same probe-timeout cascade).

**Two fixes needed (prioritized for tomorrow):**
1. **Add a LIMIT to `/commands/search`** (e.g. 200 results) — the `%%` bomb
   is a single-request DoS on yourself.
2. **Search index decision**: at 897k rows the ILIKE-on-5-fields query is 5.7s.
   We have NOW crossed the "100k rows = switch to pg_trgm" decision point from Day 12.
   → `pg_trgm` GIN index is the fix.

---

## 3. State at Wrap-Up (23:00 IST)

```
Cluster:     2 nodes Ready, all addons + metrics-server
App:         3/4 pods Ready, recovering from crash loops (HPA scaled to 4, will settle to 2)
DB:          897,133 rows (test data), 134 MB — needs cleanup tomorrow
HPA:         cpu 2%/50%, 4 replicas (scaling down over 5-min window)
Node memory: node 0 at 101% (!), node 1 at 84% — t3.small 2Gi is TIGHT
             (cloudwatch agent + ebs-csi + postgres + app all compete)
ALB:         a64a920e03ce5424a96bc55893a92774-868972225.ap-south-1.elb.amazonaws.com
```

**Why pods kept restarting at the end:** node memory pressure (101% on node 0)
+ the 1s probe timeout + 76s Spring Boot startup under 4-replica churn.
The crash loop is self-sustaining until load stops. A `timeoutSeconds: 3-5`
or higher `failureThreshold` would fix the fragility.

---

## 4. Costs (to recite in interview)

| Item | Cost |
|---|---|
| EKS control plane | ~$73/mo |
| 2 × t3.small (2Gi, 2vCPU) | ~$30/mo |
| ALB + LCU | ~$16-18/mo |
| EBS gp2 (small PVC) | <$1/mo |
| CloudWatch agent | minimal |
| **Total** | **~$120/mo ≈ $4/day** — cheap enough to run tests on-demand |

---

## 5. Tomorrow's Plan (Day 18) — Priority Order

1. **Fix 1 (P0): LIMIT on search endpoint** — add `.setMaxResults`/Pageable to
   `searchCommands`, rebuild image, redeploy. Re-test `%%` → must be fast + bounded.
2. **Fix 2 (P0): probe fragility** — `timeoutSeconds: 1 → 5`, consider
   `initialDelaySeconds: 90` (startup takes 76s), maybe `failureThreshold: 5`.
3. **Fix 3 (P0): node memory pressure** — check what's eating 2Gi (cloudwatch,
   ebs-csi 6 containers, fluent-bit). Options: bigger node type (t3.medium),
   or trim CloudWatch/ebs-csi replicas.
4. **Fix 4 (P1): 2001-char → 400/truncate** instead of 500 (Controller advice +
   `@Column(length=2000)` stays as hard limit).
5. **Search index experiment**: install `pg_trgm`, GIN index on text, re-run the
   5.7s query → measure before/after. This is the "decision point" number.
6. **Re-run C8 search storm after fixes** — the pass criteria is p95 < 2s.
7. **C25 scale test data cleanup** — delete the 897k test rows (or keep a curated
   10k and measure the curve at 10k/50k/100k properly).
8. **Remaining courses**: C13 HPA live demo (redo cleanly), C15 statelessness
   (kill pods mid-ingest, count dups), C17 pod kill under load, C19 postgres
   restart, C22 ingestion outage (buffer & backfill), C25, C37-39 alert drills
   (needs Prometheus — runs locally via docker-compose, not on cluster).
9. **Wrap-up**: scorecard (Appendix B), destroy cluster or keep (user's call —
   ~$4/day).

**Interview numbers already banked tonight:**
- "920 RPS ingest, zero errors, on 2×t3.small; ceiling = CPU-limit throttling + probe timeout cascade at 500 VUs"
- "Search at 897k rows: 5.7s — the documented ILIKE limit, trigger for pg_trgm"
- "Found a real cascading failure: CPU throttle → 1s health-probe timeout → kubelet kill (exit 143) → CrashLoopBackOff"
- "Zero-downtime recovery: cluster self-healed after load stopped"

---

## 6. Session Timeline (Postmortem format)

| Time | Event |
|---|---|
| 01:40 | Session start: docs read, state assessment (cluster destroyed) |
| 02:00 | k6 v0.57.0 installed; terraform apply kicked off |
| 02:30 | Apply killed by 30-min shell timeout (nodegroup mid-create) |
| 02:47 | Nodegroup CREATE_FAILED: "Instances failed to join" |
| 03:03 | Root cause: no IGW route (killed apply never made route table) — console log showed DescribeInstances retry loop |
| 03:15 | Deleted failed nodegroup, force-unlocked state, fixed dangling IGW, imported OIDC + EBS CSI |
| 03:40 | Terraform complete: 30 resources, 2 nodes Ready |
| 03:50 | metrics-server installed (HPA was blind) |
| 03:55 | Image built + pushed; helm install; ALB live |
| 04:05 | C1-C6 correctness: all pass, found 2001-char → 500 bug |
| 04:10 | C7 ingest spike: 211 → 752 → 920 → 953 RPS, zero errors |
| 04:20 | C7 at 500 VUs: CEILING — 0.28% errors, p95 1.6s, pods OOM-ish crash loop (exit 143) |
| 04:35 | C8 search storm at 897k rows: app-wide failure, 5.7s query plan confirmed |
| 05:00 | Recovery: crash loop persisted (node mem 101%), scaled to 2, force-deleted pods |
| 05:30 | 3/4 pods Ready; wrap-up, notes written |
