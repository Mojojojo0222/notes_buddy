# Notes Buddy — The Full Interview Story

## The Problem That Started Everything

> "I keep forgetting what I built 2 months ago."

Every engineer has been here: you fixed a Docker issue, ran a specific kubectl command, debugged a PostgreSQL error — and 2 months later you can't remember any of it. You Google the same fix again, waste 30 minutes, repeat.

**Notes Buddy** is a personal searchable memory system built from your own terminal history. It's not a notes app — it's a **searchable memory of everything you've ever learned and solved**, built from your own engineering history, not generic tutorials.

The vision: "This laptop has been running for 180 days. Ask me anything about my work."

---

## The Architecture Evolution (10 Days of Building)

### Phase 1: Data Collection (Days 1-4)
**Goal:** Capture every terminal command with context.

**How:** A `PROMPT_COMMAND` hook in `.bashrc` runs after every command, writing to `~/.notes_buddy_log` in this format:
```
timestamp|working_directory|repo_name|command_text
```

A Spring Boot app with a `HistoryWatcher` (@Scheduled, fixedDelay=10s) reads new lines from the log file, parses them, detects categories (git, docker, k8s, maven, etc.), and saves to a database.

**Key decisions:**
- Own log file, not `.bash_history` — `.bash_history` writes on shell close, not on command execution. We needed real-time capture.
- `PROMPT_COMMAND` runs AFTER command, BEFORE next prompt — perfect timing because `pwd` is already updated.
- `split("\\|", 3)` with limit 3 — commands can contain `|` themselves, so limiting the split prevents incorrect parsing.
- H2 database — zero-install for MVP. PostgreSQL was always Month 2.

### Phase 2: Dashboard UI (Days 2-4)
**Goal:** See what you did today.

Built with vanilla JS + HTML + CSS (no framework — learning-focused, no build step). Features:
- Summary box: today's command count, most-used tool, topics touched
- Category filter buttons (pill-shaped, color-coded)
- Live search
- Auto-refresh every 15s
- Git repo name per command

**Key decisions:**
- Vanilla JS over React — no build step, readable, learning-focused. Revisit Month 3 if needed.
- Constructor injection over @Autowired — Spring recommended since 4.x, testable, fields can be final.
- No Lombok — see every field and getter explicitly while learning.

### Phase 3: Docker + Deployment (Day 4)
**Goal:** Package the app for deployment.

Multi-stage Docker build: `maven:3.9-eclipse-temurin-17` for build, `eclipse-temurin:17-jre-alpine` for runtime. Final image ~180MB instead of ~600MB.

**Key decision:** Copy `pom.xml` before `src` so Maven dependency layer is cached separately. Docker layer caching makes rebuilds fast when only code changes.

### Phase 4: Kubernetes on EKS (Days 5-6)
**Goal:** Deploy to production-grade Kubernetes on AWS.

**What was built:**
- EKS cluster with 2 t3.small nodes
- ECR repository for Docker images
- K8s manifests: Namespace, ConfigMap, Secret, Deployment, Service (LoadBalancer), HPA
- CloudWatch Container Insights for observability
- Stress testing: 500 requests, 500 concurrent → 500/500 success

**Problems hit (6 major issues):**
1. `eksctl` not on PATH → moved to `/c/Users/Lenovo/eksctl/`
2. PVC Pending → EBS CSI driver not installed → installed `aws-ebs-csi-driver` addon
3. EBS CSI CrashLoopBackOff → OIDC disabled → enabled OIDC + IAM service account
4. Postgres CrashLoopBackOff → `lost+found` in EBS root → `subPath: pgdata` fix
5. Postgres permission denied → EBS owned by root → `securityContext.fsGroup: 999`
6. kubectl no context → `aws eks update-kubeconfig`

### Phase 5: PostgreSQL Migration + Sessions (Day 7)
**Goal:** Swap H2 for a real database and add session detection.

**Changes:**
- `pom.xml`: replaced H2 driver with PostgreSQL driver
- `application.properties`: switched to environment variables (`${DB_HOST}`, `${DB_NAME}`, `${DB_USER}`, `${DB_PASS}`)
- `docker-compose.yml`: Postgres + Notes Buddy with `depends_on: condition: service_healthy`
- `Session.java`, `SessionRepository.java`, `SessionService.java`: detect sessions by walking commands sorted by time, splitting on 30-min idle gaps. O(n), one pass.
- Dashboard UI: full rewrite with session cards, collapsible, date/time range, duration, category badges

**Key learning:** `docker service name = DNS hostname` — `DB_HOST=postgres` resolves because Docker Compose creates an internal network.

### Phase 6: Ingestion API (Day 8)
**Goal:** Send commands from laptop to EKS pod without shared filesystem.

**Changes:**
- `CommandService.java` — centralized `isJunk()`, `detectCategory()`, `ingest()`. DRY — HistoryWatcher and HTTP endpoint share same logic.
- `POST /ingest` endpoint — uses `@RequestParam` for form-encoded body from curl
- `.bashrc`: added curl POST to EKS URL in background (`&`) with `--data-urlencode`
- Local file write retained as backup — fire-and-forget with resilience

**Problems hit:**
1. VARCHAR(255) overflow on long docker exec commands → `@Column(length=2000)`
2. python3 URL encoding not working in Git Bash → replaced with `curl --data-urlencode`
3. `[1]+ Done` in terminal → normal bash background job notification, not an error

### Phase 7: Terraform Infrastructure as Code (Day 9)
**Goal:** Replace all manual `eksctl` + `aws cli` commands with reusable Terraform code.

**What was built:**
```
terraform/
├── main.tf              # Root — calls all modules
├── variables.tf         # All inputs (region, instance type, node counts)
├── outputs.tf           # Cluster endpoint, ECR URL, kubeconfig command
├── versions.tf          # Provider versions + S3 backend config
└── modules/
    ├── vpc/             # VPC + 2 public subnets + IGW + route table
    ├── eks/             # IAM roles + cluster + node group + OIDC + addons + IRSA
    └── ecr/             # ECR repo + lifecycle policy
```

**28 resources managed by Terraform:**
- VPC module (6): VPC, IGW, 2 subnets, route table, 2 route table assoc
- EKS module (16): 2 IAM roles (cluster + node), 7 policy attachments, cluster, node group, OIDC provider, EBS CSI IRSA role + policy, 2 addons
- ECR module (2): Repository + lifecycle policy
- GitHub Actions (4): OIDC provider, IAM role, 2 inline policies

**Key Terraform concepts learned:**
- `terraform init / plan / apply / import / state list` — the 5 essential commands
- Modules = infrastructure functions. Same principle: reusable, testable, single responsibility.
- `depends_on` on IAM policy attachments — without this, Terraform races against itself.
- State locking with DynamoDB prevents concurrent applies.
- Remote state in S3 — single source of truth shared across machines.
- `terraform import` — bring existing resources under management. Needed when resources exist outside Terraform.

**Problems hit:**
1. **Apply timeout (15 min)** — EBS CSI addon slow. Fixed with `terraform import`.
2. **State lock contention** — two processes can't write state simultaneously. Used `-lock=false` on second import.
3. **EBS CSI CrashLoopBackOff × 2** — First: no IRSA. Second: IAM policy propagation delay (15-30s).
4. **Windows `/tmp` unavailable** — must inline trust policy JSON in aws CLI command instead of file:// path.

### Phase 8: GitHub Actions CI/CD (Day 10)
**Goal:** Every git push → build Docker image → push to ECR → deploy to EKS automatically.

**How OIDC authentication works (no stored AWS keys):**
1. GitHub Actions requests an identity token (JWT) from GitHub's OIDC provider
2. Token contains claims: `sub: repo:owner/name:ref:refs/heads/main`, `aud: sts.amazonaws.com`
3. `aws-actions/configure-aws-credentials` exchanges this token for AWS credentials via STS AssumeRoleWithWebIdentity
4. AWS verifies the token against the OIDC provider (token.actions.githubusercontent.com)
5. The trust policy on `notes-buddy-github-actions-role` must match the token claims
6. Workflow gets temporary AWS credentials (valid for ~1 hour)

**CI/CD Pipeline (8 steps):**
1. Checkout code
2. Configure AWS credentials via OIDC
3. Login to Amazon ECR
4. Build Docker image (tagged with commit SHA + latest)
5. Push both tags to ECR
6. Update kubeconfig (`aws eks update-kubeconfig`)
7. Deploy: `kubectl set image deployment/notes-buddy ...`
8. Verify: `kubectl rollout status --timeout=120s`

---

## The Complete Infrastructure Stack

```
Your Terminal
    │ PROMPT_COMMAND → ~/.notes_buddy_log
    │ curl POST → /ingest (background)
    ▼
┌─────────────────────────────────────────────┐
│            AWS EKS (ap-south-1)              │
│                                              │
│  ┌─────────┐    ┌─────────────────────────┐  │
│  │  ALB     │───▶│  Notes Buddy (Spring)   │  │
│  │ :80      │    │  :9098                  │  │
│  └─────────┘    │  /actuator/health        │  │
│                 │  /commands/all            │  │
│                 │  /summary                 │  │
│                 │  /sessions                │  │
│                 │  POST /ingest             │  │
│                 └──────────┬────────────────┘  │
│                            │                    │
│                 ┌──────────▼────────────────┐  │
│                 │  PostgreSQL 16 (K8s Pod)   │  │
│                 │  EBS Volume (gp2, 1Gi)     │  │
│                 └───────────────────────────┘  │
│                                              │
│  ┌────────────────────────────────────────┐   │
│  │  EBS CSI (IRSA)  │  CloudWatch Agent   │   │
│  │  HPA (CPU 50%)   │  fluent-bit         │   │
│  └────────────────────────────────────────┘   │
└─────────────────────────────────────────────┘
              ▲
              │ OIDC
┌─────────────────────────────────────────────┐
│            GitHub Actions                    │
│  Push → Build → Push ECR → Deploy EKS       │
│  No static keys — OIDC IAM role             │
└─────────────────────────────────────────────┘
              ▲
              │ Terraform apply
┌─────────────────────────────────────────────┐
│            Terraform (S3 state)              │
│  modules/vpc/  modules/eks/  modules/ecr/   │
│  28 resources managed                       │
└─────────────────────────────────────────────┘
```

---

## Every Problem We Fought (And Won)

This is the most important section for interviews. Real engineering is about problems, not solutions.

### 1. H2 File Locking (Day 4)
**Problem:** Two JVMs can't share the same H2 database file. Docker container + local dev = conflict.
**Fix:** Volume mount ensures only one JVM accesses the file. H2 → PostgreSQL migration (Day 7) fixes it permanently.
**Lesson:** File-based databases don't scale beyond single-process. PostgreSQL from day 1 for anything shared.

### 2. Log Format Breaking on Pipe (Day 3-4)
**Problem:** Commands like `cat file | grep foo` contain `|` which broke `line.split("\\|")`.
**Fix:** `split("\\|", 3)` — the limit parameter (3) means "split into at most 3 parts". The command text can contain any number of `|` without breaking.
**Lesson:** Always consider what user input can contain. `split` without a limit is dangerous when the delimiter can appear in values.

### 3. Duplicate Commands on Restart (Day 1)
**Problem:** Every time the app restarted, it re-read the entire log file from the beginning.
**Fix:** `WatcherState` table in the database stores `lastLineCount` as a bookmark. Reads only new lines since last bookmark. Bookmark is saved BEFORE processing (at-most-once delivery).
**Lesson:** Stateful bookmarks = idempotent processing. Save position before processing so a crash doesn't cause reprocessing.

### 4. EBS CSI CrashLoopBackOff on EKS (Day 6, Fixed Day 9)
**Problem:** EBS CSI driver couldn't create volumes. Error: "no EC2 IMDS role found".
**Root cause:** The driver runs as a pod and needs IAM permissions to call EC2 APIs. Two approaches:
- **Instance profile (old way):** Attach permissions to the node's IAM role — but then every pod on the node inherits those permissions (too broad).
- **IRSA (correct way):** Create a dedicated IAM role scoped to a specific service account in a specific namespace.
**Fix:** Created IAM role `notes-buddy-ebs-csi-role` with `AmazonEBSCSIDriverPolicy` (includes `ec2:DescribeAvailabilityZones`, `CreateVolume`, `AttachVolume`, etc.). Annotated `ebs-csi-controller-sa` with `eks.amazonaws.com/role-arn`. Added to Terraform permanently.
**Secondary issue:** After IRSA was working, error changed to "not authorized for ec2:DescribeAvailabilityZones" — IAM policy propagation delay (~30s). Just waited and restarted.
**Lesson:** Error messages tell you exactly what's wrong if you read them carefully. "no IMDS role" = can't find credentials. "not authorized" = found credentials but missing permissions.

### 5. Postgres PVC: lost+found and EBS Permissions (Day 6)
**Problem:** PostgreSQL container crashed on startup. Two separate issues:
1. **lost+found:** EBS volumes are formatted with ext4, which creates a `lost+found` directory in the root. Postgres tries to initialize its data directory at the mount root, but `lost+found` blocks it.
   - **Fix:** `subPath: pgdata` on the volume mount + `PGDATA` env var pointing to `/var/lib/postgresql/data/pgdata`.
2. **Permission denied:** EBS volumes are owned by root by default. Postgres runs as UID 999 and can't write.
   - **Fix:** `securityContext.fsGroup: 999` in the pod spec — K8s chowns the volume to GID 999 before the container starts.
**Lesson:** Stateful workloads on EBS require `subPath` + `fsGroup`. This is a known pattern, not a bug.

### 6. VARCHAR(255) Overflow on Long Commands (Day 8)
**Problem:** `docker exec` commands with long arguments (connection strings, queries) exceeded 255 characters.
**Fix:** `@Column(length=2000)` on the `text` field in `Command.java`. Also increased `workingDir` to 1000. Had to drop and recreate the table — `ddl-auto=update` never alters existing column types.
**Lesson:** JPA `ddl-auto=update` only adds new columns/tables. It never changes existing column types. You must drop the table or write a migration.

### 7. URL Encoding in Shell Scripts (Day 8)
**Problem:** Commands with special characters (`|`, `"`, `$`, backticks) broke when sent via curl.
**Attempted fix (failed):** `python3 -c "import urllib.parse; print(urllib.parse.quote('$cmd'))"` — python3 not available in Git Bash.
**Final fix:** `curl --data-urlencode "text=${last_cmd}"` — curl's built-in encoding handles every special character correctly.
**Lesson:** Use the tool's native encoding support (`--data-urlencode`) rather than trying to pre-encode in shell.

### 8. Terraform State Lock Contention (Day 9)
**Problem:** Two `terraform import` commands ran in parallel. First one locked the state file, second one failed.
**Fix:** Used `-lock=false` on the second import.
**Production solution:** DynamoDB table for state locking. We created `notes-buddy-terraform-locks` table with `PAY_PER_REQUEST` billing. This prevents concurrent `terraform apply` from conflicting.
**Lesson:** Terraform state is a single source of truth. It must be protected from concurrent writes. Always use a locking mechanism (DynamoDB for S3 backend).

### 9. GitHub Actions OIDC — Missing id-token Permission (Day 10)
**Problem:** OIDC authentication failed with "unable to get ID token".
**Fix:** Added `permissions: id-token: write` at the job level in the workflow file. GitHub defaults to `read` for security — OIDC requires explicit `write`.
**Lesson:** GitHub's permission model is restrictive by default. `id-token: write` must be explicitly set. This is a deliberate security decision — prevents workflows from getting tokens unless they explicitly ask.

### 10. OIDC Trust Policy — StringEquals vs StringLike (Day 10)
**Problem:** Initial trust policy used `StringEquals` which only matched exact branch names.
**Fix:** Changed to `StringLike` with `repo:owner/name:*` — the `*` matches any branch, tag, or PR.
**Lesson:** OIDC token `sub` claim format: `repo:owner/name:ref:refs/heads/main`. In development, `StringLike` with wildcard is fine. Production should restrict to `ref:refs/heads/main` specifically.

---

## Trade-offs and Design Decisions

| Decision | Why | When to Revisit |
|----------|-----|----------------|
| H2 not PostgreSQL | Zero install for MVP | Done — migrated Day 7 |
| `split("\\|", 3)` with limit | Commands can contain `\|` | Never — this is correct |
| `fixedDelay` not `fixedRate` | Prevents overlap if scan takes long | Never change |
| Bookmark saved BEFORE processing | Crash won't reprocess | Month 2: consider at-least-once |
| Vanilla JS no framework | No build step, readable | Month 3: consider React if UI grows |
| Multi-stage Docker | Final image ~180MB not ~600MB | Keep forever |
| No Lombok | See every field and getter explicitly | Reconsider Month 3 |
| Constructor injection not @Autowired | Spring recommended, testable, final fields | Keep forever |
| Public subnets (not private) | Simpler for learning, no NAT gateway cost | Production: private subnets + NAT ($32/mo) |
| Local Terraform state → S3 | Team access, versioning, disaster recovery | Already migrated Day 9 |
| OIDC over static keys | Zero rotation, shorter-lived tokens, audit trail | Keep forever |

---

## Interview Answers — Full Stories

### "Walk me through your infrastructure."

"I built a full production-grade platform on AWS EKS. The infrastructure is provisioned entirely with Terraform — three reusable modules for VPC, EKS, and ECR. The state is stored in S3 with DynamoDB locking so the team can collaborate safely.

The app is a Spring Boot Java service with PostgreSQL, deployed as Docker containers on Kubernetes. Every push to main triggers a GitHub Actions pipeline that builds the image, pushes to Amazon ECR, and does a rolling deployment to EKS. Authentication uses OIDC — no hardcoded AWS keys anywhere.

Observability is handled by CloudWatch Container Insights — we get CPU/memory metrics, container logs with Kubernetes metadata, and we've verified zero container restarts and sub-10% resource utilization under load.

Pod autoscaling is handled by HPA (targeting 50% CPU), and we've tested it scales from 1 to 4 replicas under load. Node autoscaling with Karpenter is the next implementation.

The whole thing started as a personal tool to remember what I built — it grew into a full-stack infrastructure project covering monitoring, CI/CD, IaC, and container orchestration."

### "How do you handle secrets and credentials?"

"No hardcoded credentials anywhere. Three layers:

1. **Kubernetes Secrets:** Database passwords are stored as K8s Secrets and injected as environment variables. `base64` encoded in the YAML, not true encryption — for production we'd use AWS Secrets Manager or Sealed Secrets.

2. **IRSA (IAM Roles for Service Accounts):** Pods that need AWS API access assume IAM roles directly. The EBS CSI driver assumes `notes-buddy-ebs-csi-role` scoped to `kube-system:ebs-csi-controller-sa`. No AWS keys in the pod at all.

3. **OIDC for CI/CD:** GitHub Actions assumes an IAM role via OIDC — GitHub issues a short-lived token, AWS verifies it against the OIDC provider, and the role's trust policy restricts which repo and branch can assume it. Zero static keys stored anywhere."

### "Tell me about a time you debugged a difficult infrastructure issue."

"The EBS CSI driver on EKS was crashing on startup — `CrashLoopBackOff`. The error said 'no EC2 IMDS role found.' The pod couldn't get AWS credentials.

First fix attempt: I checked if the node instance profile had the right permissions. It did. But the pod wasn't using the instance profile — it was trying IMDS first, failing, and falling back to IRSA.

Second fix: I set up IRSA — created an IAM role with a trust policy scoped to exactly `system:serviceaccount:kube-system:ebs-csi-controller-sa`, attached the EBS CSI policy, and annotated the service account. Restarted the pods.

New error: 'not authorized for ec2:DescribeAvailabilityZones.' This was actually progress — IRSA was working (the pod assumed the correct role), but the policy hadn't propagated yet. I waited 30 seconds and restarted again. It worked.

The takeaway: error messages tell you where you are in the debugging process. 'No IMDS role' = authentication problem. 'Not authorized' = authorization problem but authentication is working. Watch for the shift in error messages — it tells you which layer you fixed."

### "How would you handle a production EKS upgrade?"

"In Terraform, I'd change the `version` field in `aws_eks_cluster` from `1.31` to `1.32` and run `terraform apply`. Terraform triggers the control plane upgrade first — this is managed by AWS, takes 20-30 minutes, no downtime.

Then the node group needs upgrading. With `update_config.max_unavailable = 1`, nodes are replaced one at a time — each old node is cordoned and drained, a new node joins, and pods reschedule. Zero downtime if the app has multiple replicas and proper pod disruption budgets.

Before the upgrade: check the Kubernetes release notes for API deprecations. Run `kubectl convert` on existing manifests. Test in a non-production environment first. Have a rollback plan: if something breaks, `terraform apply` the old version and wait for the control plane to roll back."

### "How do you manage Terraform state?"

"Our state is stored in an S3 bucket with versioning enabled — we can recover any previous state version if something goes wrong. DynamoDB table `notes-buddy-terraform-locks` prevents concurrent `terraform apply` from conflicting.

The backend configuration in `versions.tf`:
```hcl
backend "s3" {
  bucket         = "notes-buddy-terraform-state-ACCOUNT_ID"
  key            = "notes-buddy/terraform.tfstate"
  region         = "ap-south-1"
  dynamodb_table = "notes-buddy-terraform-locks"
  encrypt        = true
}
```

For team workflows: `terraform plan` runs in CI/CD for review, `terraform apply` runs after approval. State never lives on a developer's laptop."

### "What's your CI/CD pipeline look like?"

Eight steps, fully automated:
1. **Checkout** — pull the code
2. **OIDC auth** — assume IAM role via GitHub's OIDC provider (no keys)
3. **ECR login** — authenticate with the registry
4. **Build** — Docker build with commit SHA + latest tags
5. **Push** — both tags to ECR
6. **kubeconfig** — `aws eks update-kubeconfig`
7. **Deploy** — `kubectl set image` triggers rolling update
8. **Verify** — `kubectl rollout status --timeout=120s` confirms pods are healthy

If verification fails (pods don't start within 2 minutes), the pipeline fails. Rollback is `kubectl rollout undo` or `kubectl set image` to a known-good SHA.

The pipeline takes ~3-4 minutes from push to production."

---

## Key Technical Concepts Mastered

### Kubernetes
- Pods, Deployments, Services (ClusterIP, LoadBalancer), Namespaces, ConfigMaps, Secrets
- PersistentVolumeClaims + EBS storage + fsGroup + subPath
- Liveness/Readiness probes (Spring Boot Actuator health endpoint)
- HPA (CPU-based, 50% target, 1-4 replicas)
- Rolling updates (maxUnavailable=1)
- IRSA (IAM Roles for Service Accounts) — per-pod IAM permissions
- EKS addons (EBS CSI, CloudWatch)
- OIDC provider for IRSA

### Terraform
- Modules: VPC, EKS, ECR — reusable, testable, single responsibility
- `terraform init / plan / apply / import / state list`
- Remote state in S3 + DynamoDB locking
- IAM: roles, policies, trust policies, OIDC providers
- `depends_on` for resource ordering
- Resource import for existing infrastructure

### CI/CD (GitHub Actions)
- OIDC authentication — no hardcoded keys
- Workflow triggers: push to main + workflow_dispatch
- Docker build/push pipeline
- kubectl deployment + verification
- `permissions: id-token: write` requirement

### AWS
- EKS (Elastic Kubernetes Service)
- ECR (Elastic Container Registry)
- IAM: roles, policies, OIDC identity providers
- EBS: persistent storage, fsGroup, subPath
- CloudWatch Container Insights
- Application Load Balancer (via K8s Service type LoadBalancer)
- S3 (Terraform state)
- DynamoDB (Terraform locks)
- STS (AssumeRoleWithWebIdentity)

---

## What's Next

| Day | Topic | Key Learning |
|-----|-------|-------------|
| 11 | **ArgoCD** | GitOps — Git as source of truth. K8s manifests in repo, ArgoCD syncs cluster |
| 12 | **Karpenter** | Node autoscaling — provision nodes in 30s, spot instances (70% cheaper), consolidation |

---

## Quick Reference: Portfolio Talking Points

| Topic | One-Liner |
|-------|-----------|
| Terraform | "28 resources across 3 modules, S3 remote state, DynamoDB locking" |
| EKS | "2 t3.small nodes, K8s 1.31, HPA, CloudWatch, IRSA, EBS CSI" |
| CI/CD | "GitHub Actions + OIDC — no stored keys, 8-step pipeline, 3-4 min deploy" |
| Spring Boot | "REST API + scheduler + actuator health checks + PostgreSQL" |
| Docker | "Multi-stage build, ~180MB, ECR lifecycle policy (keep 10)" |
| Security | "IRSA per-service-account, OIDC for CI/CD, no hardcoded credentials" |
| Observability | "CloudWatch Container Insights, fluent-bit, zero restarts" |
| Stress Testing | "500 concurrent requests, 500/500 success, 35% CPU headroom" |
