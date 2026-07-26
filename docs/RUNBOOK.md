# Notes Buddy — Runbook

How to run this application in every environment, with every problem you'll hit and how to fix it.

---

## Table of Contents
1. [Prerequisites](#prerequisites)
2. [Local — Without Docker (Spring Boot + Maven)](#local--without-docker-spring-boot--maven)
3. [Local — With Docker (docker-compose)](#local--with-docker-docker-compose)
4. [AWS EKS (Kubernetes)](#aws-eks-kubernetes)
5. [Helm Charts (Recommended)](#helm-charts-recommended)
6. [ArgoCD GitOps](#argocd-gitops)
7. [One-Time Setup: .bashrc + Log File](#one-time-setup-bashrc--log-file)
8. [Commands Quick Reference](#commands-quick-reference)
9. [Troubleshooting Index](#troubleshooting-index)

---

## Prerequisites

| Tool | Version | Why |
|------|---------|-----|
| Java | 17+ | Spring Boot runtime |
| Maven | 3.8+ | Build the JAR |
| Docker | Latest | Container build + run |
| kubectl | 1.28+ | Talk to EKS |
| AWS CLI | 2.x | Authenticate to AWS/EKS |
| Terraform | 1.0+ | Provision infra (optional for AWS) |

Check all at once:
```bash
java -version && mvn --version && docker --version && kubectl version --client && aws --version && terraform --version
```

---

## Local — Without Docker (Spring Boot + Maven)

### Quick Start
```bash
# 1. Install PostgreSQL locally (or point to any running Postgres)
#    Options: brew install postgresql, choco install postgresql, Docker Postgres

# 2. Build the app
cd E:\Notes_Buddy
mvn clean package -DskipTests

# 3. Set env vars (optional — defaults work for local Postgres)
set DB_HOST=localhost
set DB_PORT=5432
set DB_NAME=notesbuddy
set DB_USER=notesbuddy
set DB_PASS=notesbuddy
set PORT=9098

# 4. Run
java -jar target/notes-buddy-0.0.1.jar
```

### If You Don't Have PostgreSQL
The app needs PostgreSQL. The easiest way to get a local PG without installing it:

```bash
# Run Postgres in Docker (even if you run the app outside Docker)
docker run -d \
  --name notes-buddy-pg \
  -e POSTGRES_DB=notesbuddy \
  -e POSTGRES_USER=notesbuddy \
  -e POSTGRES_PASSWORD=notesbuddy \
  -p 5432:5432 \
  postgres:16-alpine
```

Then run the app with `DB_HOST=localhost` (default).

### Verify It's Running
```bash
# Health check
curl http://localhost:9098/actuator/health
# Expected: {"status":"UP","components":{"db":{"status":"UP",...}}}

# Dashboard
# Open http://localhost:9098 in browser
```

### Stop
```bash
# Stop the app: Ctrl+C in the terminal

# Stop Postgres container
docker stop notes-buddy-pg && docker rm notes-buddy-pg

# Or if installed natively:
# pg_ctl stop (Linux/Mac) or net stop postgresql (Windows)
```

---

## Local — With Docker (docker-compose)

### Quick Start
```bash
# 1. Build the Docker image
cd E:\Notes_Buddy
docker build -t notes-buddy .

# 2. Start everything (Postgres + Notes Buddy + Prometheus + Grafana)
docker compose up -d

# 3. Check logs
docker compose logs -f notes-buddy

# 4. Verify
curl http://localhost:9098/actuator/health
# Open http://localhost:9098 in browser
```

### What docker-compose Starts
| Service | Port | Purpose |
|---------|------|---------|
| `postgres` | 5432 | Database |
| `notes-buddy` | 9098 | Spring Boot app |
| `prometheus` | 9090 | Metrics collection |
| `grafana` | 3000 | Metrics dashboard (admin/admin) |

### Stop Everything
```bash
docker compose down -v    # -v removes volumes (deletes DB data)
docker compose down       # keeps volumes (DB data survives)
```

### Run Only Postgres (app outside Docker)
```bash
docker compose up -d postgres
# Then run the app with: DB_HOST=localhost
```

### Rebuild After Code Changes
```bash
docker build -t notes-buddy . && docker compose up -d notes-buddy
```

---

## AWS EKS (Kubernetes)

### Provision Infrastructure
```bash
cd E:\Notes_Buddy\terraform

# First time only
terraform init

# See what will be created
terraform plan

# Create everything (VPC + EKS + ECR + IAM + addons)
terraform apply -auto-approve

# Update kubeconfig
aws eks update-kubeconfig --region ap-south-1 --name notes-buddy
```

> **Terraform creates:** VPC, 2 subnets, IGW, IAM roles (cluster, node, EBS CSI, GitHub Actions), EKS cluster, node group, OIDC provider, ECR repo, CloudWatch + EBS CSI addons, GitHub OIDC provider.
> **28 resources total.** State stored in S3 bucket `notes-buddy-terraform-state-ACCOUNT_ID`.

### Deploy the App (Helm — Preferred)
```bash
cd E:\Notes_Buddy\helm\notes-buddy

# DEV: 8 resources, ClusterIP, no HPA
helm install notes-buddy . -f values-dev.yaml --namespace notes-buddy --create-namespace

# STAGING: 11 resources, LoadBalancer, HPA (2-4), RBAC
helm install notes-buddy . -f values-staging.yaml --namespace notes-buddy --create-namespace

# PRODUCTION: 13 resources, Ingress+TLS, HPA (3-10), PDB, RBAC
helm install notes-buddy . -f values-production.yaml --namespace notes-buddy --create-namespace
```

> **Helm replaces 10 `kubectl apply` commands with 1 `helm install`.** See [Helm Charts section](#helm-charts-recommended) for full lifecycle commands.

### Deploy the App (Raw YAML — Legacy)
```bash
cd E:\Notes_Buddy

kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/secret.yaml
kubectl apply -f k8s/postgres.yaml
kubectl apply -f k8s/notes-buddy.yaml
kubectl apply -f k8s/hpa.yaml
kubectl apply -f k8s/rbac-github-actions.yaml

# Watch pods come up
kubectl get pods -n notes-buddy -w
```

### Push a New Image
```bash
# Build and tag
docker build -t notes-buddy .
docker tag notes-buddy:latest 083777493383.dkr.ecr.ap-south-1.amazonaws.com/notes-buddy:latest

# Login and push
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin 083777493383.dkr.ecr.ap-south-1.amazonaws.com
docker push 083777493383.dkr.ecr.ap-south-1.amazonaws.com/notes-buddy:latest

# Restart the deployment
kubectl rollout restart deployment/notes-buddy -n notes-buddy
```

### Automatic CI/CD (GitHub Actions)
Every push to `main` branch runs the pipeline automatically:
1. Builds Docker image
2. Pushes to ECR (tagged with commit SHA + latest)
3. Runs `kubectl set image` to trigger rolling update
4. Verifies rollout status

To trigger manually: GitHub → Actions → "Deploy to EKS" → Run workflow.

### Get the Dashboard URL
```bash
kubectl get svc -n notes-buddy notes-buddy-service
# EXTERNAL-IP column shows the LoadBalancer URL
```

### Access Pod Logs
```bash
kubectl logs -n notes-buddy deployment/notes-buddy -f
kubectl logs -n notes-buddy deployment/postgres -f
```

### Port-Forward (No LoadBalancer Needed)
```bash
kubectl port-forward -n notes-buddy deployment/notes-buddy 9098:9098
# Then open http://localhost:9098
```

### Scale the App
```bash
# Manual
kubectl scale deployment/notes-buddy -n notes-buddy --replicas=3

# Automatic (HPA targets 50% CPU)
kubectl get hpa -n notes-buddy -w
```

### Destroy Everything (Stop Paying)
```bash
# Delete K8s resources
kubectl delete ns notes-buddy

# Destroy Terraform infra (takes ~10 min)
cd E:\Notes_Buddy\terraform
terraform destroy -auto-approve

# Verify nothing left
aws eks list-clusters --region ap-south-1
aws ecr describe-repositories --region ap-south-1
```

---

## Helm Charts (Recommended)

Helm is the preferred way to deploy Notes Buddy. The chart is at `helm/notes-buddy/` with 13 templates and 3 environment profiles.

### Prerequisites
```bash
# Install Helm (if not present)
# Windows: choco install kubernetes-helm
# Mac: brew install helm
# Linux: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify
helm version --short   # should be v3.x
```

### Chart Structure
```
helm/notes-buddy/
├── Chart.yaml              # Name: notes-buddy, version: 0.1.0
├── values.yaml             # Default config (100+ values)
├── values-dev.yaml         # DEV overrides (8 resources)
├── values-staging.yaml     # STAGING overrides (11 resources)
├── values-production.yaml  # PRODUCTION overrides (13 resources)
├── .helmignore
└── templates/
    ├── _helpers.tpl        # 6 reusable templates
    ├── NOTES.txt           # Post-install instructions
    ├── namespace.yaml      # Idempotent (lookup)
    ├── configmap.yaml      # Non-sensitive env vars
    ├── secret.yaml         # DB password (b64enc at render)
    ├── postgres-pvc.yaml
    ├── postgres-deployment.yaml
    ├── postgres-service.yaml
    ├── app-deployment.yaml
    ├── app-service.yaml
    ├── app-hpa.yaml
    ├── app-pdb.yaml
    ├── ingress.yaml
    └── rbac.yaml
```

### Environment Profiles

| Setting | DEV | STAGING | PRODUCTION |
|---------|-----|---------|------------|
| App replicas | 1 | 2 | 3 |
| Service type | ClusterIP | LoadBalancer | LoadBalancer |
| HPA | disabled | enabled (2-4) | enabled (3-10) |
| PDB | disabled | disabled | minAvailable: 2 |
| Ingress | disabled | disabled | enabled + TLS |
| RBAC | disabled | enabled | enabled |
| App resources | 256Mi/512Mi | 384Mi/768Mi | 512Mi/1Gi |
| Postgres storage | 1Gi | 1Gi | 10Gi (gp3) |
| Total K8s resources | 8 | 11 | 13 |

### Lifecycle Commands

```bash
# === INSTALL (first time) ===

# DEV — minimal, no external dependencies
helm install notes-buddy ./helm/notes-buddy \
  -f values-dev.yaml \
  --namespace notes-buddy --create-namespace

# STAGING — LoadBalancer + HPA
helm install notes-buddy ./helm/notes-buddy \
  -f values-staging.yaml \
  --namespace notes-buddy --create-namespace

# PRODUCTION — full HA with Ingress, HPA, PDB
helm install notes-buddy ./helm/notes-buddy \
  -f values-production.yaml \
  --namespace notes-buddy --create-namespace

# === UPGRADE (config change or new image) ===
helm upgrade notes-buddy ./helm/notes-buddy \
  -f values-dev.yaml

# Override just the image tag on the fly:
helm upgrade notes-buddy ./helm/notes-buddy \
  -f values-production.yaml \
  --set image.tag=v2.1.0

# === ROLLBACK ===
helm rollback notes-buddy 2 -n notes-buddy

# === STATUS / HISTORY ===
helm list -n notes-buddy                         # all releases
helm history notes-buddy -n notes-buddy          # revision timeline
helm status notes-buddy -n notes-buddy           # release details

# === UNINSTALL ===
helm uninstall notes-buddy -n notes-buddy

# === DEBUG (no cluster needed) ===

# Render YAML and inspect
helm template notes-buddy ./helm/notes-buddy -f values-dev.yaml

# Validate chart
helm lint ./helm/notes-buddy

# Dry-run install (see what would be created)
helm install notes-buddy ./helm/notes-buddy \
  -f values-production.yaml \
  --namespace notes-buddy --create-namespace \
  --dry-run --debug
```

### Packaging
```bash
# Package into a .tgz for distribution
helm package ./helm/notes-buddy -d ./helm/

# Result: helm/notes-buddy-0.1.0.tgz
# Can be hosted on any HTTP server or Helm repo
```

### Common Modifications

**Change environment:**
```bash
# Just switch the values file
helm upgrade notes-buddy ./helm/notes-buddy -f values-production.yaml
```

**Override a single value:**
```bash
helm upgrade notes-buddy ./helm/notes-buddy \
  -f values-dev.yaml \
  --set app.replicas=3 \
  --set image.tag=latest
```

**Change Postgres password (DEV only):**
```bash
# Edit values.yaml directly:
# app.env.DB_PASS: newpassword

# Then upgrade (checksum/secret changes → pods restart automatically)
helm upgrade notes-buddy ./helm/notes-buddy -f values-dev.yaml
```

---

## ArgoCD GitOps

ArgoCD synchronizes your cluster to match Git. Every change flows Git → ArgoCD → Cluster.

### Installation
```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
kubectl create ns argocd
helm install argocd argo/argo-cd -f helm/argocd/values.yaml --namespace argocd
```

### Access
```bash
# Get LoadBalancer URL
kubectl get svc -n argocd argocd-server -o jsonpath="{.status.loadBalancer.ingress[0].hostname}"

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

**Current ArgoCD:**
```
ArgoCD URL: http://aa335e8d179da4eb7b1035e630ff0e41-1249820149.ap-south-1.elb.amazonaws.com
Username:   admin
Password:   Jzl-KzKg4AY0gNMG

App URL:    http://a4222470eaec245a29c7720b811fb836-1696657361.ap-south-1.elb.amazonaws.com
```

### ArgoCD Pod Optimization (t3.small)
Default ArgoCD installs 7 components. On t3.small (11 pods/node), we disabled:
- `dex.enabled: false` — SSO not needed for dev
- `notifications.enabled: false` — Slack/email alerts not needed
- Reduced resource requests: controller 256Mi, all others 128Mi, redis 64Mi
- Result: 5 running pods instead of 7

### Port-forward (if LB not accessible)
```bash
kubectl port-forward -n argocd svc/argocd-server 9090:80
# Then open http://localhost:9090
```

### Create an Application (via YAML)
```yaml
# argocd/apps/notes-buddy.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: notes-buddy
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Mojojojo0222/notes_buddy
    targetRevision: HEAD
    path: helm/notes-buddy
    helm:
      valueFiles:
        - values-staging.yaml      # change to values-dev.yaml for ClusterIP
  destination:
    server: https://kubernetes.default.svc
    namespace: notes-buddy
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```
```bash
kubectl apply -f argocd/apps/notes-buddy.yaml
```

### The 5-Part Application CRD
| Section | Description |
|---------|-------------|
| `metadata` | Name + namespace (must be `argocd`) |
| `project` | ArgoCD project (default is fine for single-team) |
| `source` | Git repo URL + path + revision + Helm values |
| `destination` | Target cluster (`kubernetes.default.svc`) + namespace |
| `syncPolicy` | Auto-sync + prune (delete removed resources) + selfHeal (revert drifts) |

### Key Commands
```bash
# List applications
argocd app list

# Sync (force deploy)
argocd app sync notes-buddy

# Rollback to revision 2
argocd app rollback notes-buddy 2

# See diff between Git and cluster
argocd app diff notes-buddy

# Or use kubectl (no argocd CLI needed)
kubectl get application -n argocd notes-buddy
kubectl get application -n argocd notes-buddy -o yaml
```

### ArgoCD UI
1. Navigate to the ArgoCD URL
2. Login with admin / password
3. **Applications** tab → see `notes-buddy` with green circle (Healthy)
4. Click the app → see all managed K8s resources
5. **APP DETAILS** → SYNC button, REFRESH button
6. **DIFF** tab → see Git vs cluster differences
7. **HISTORY** → rollback to any previous revision
8. **Settings** → repositories, projects, cluster management

### Auto-Sync Flow
```bash
# 1. Edit Helm values locally
# 2. Push to GitHub
git add helm/notes-buddy/values-dev.yaml
git commit -m "change replicas to 3"
git push
# 3. ArgoCD detects change within 3 min → auto-syncs
# 4. Cluster updates automatically — no kubectl or helm needed
```

### Troubleshooting ArgoCD on t3.small

**Pod capacity exhausted:**
```bash
# Check node pod count
kubectl get pods --all-namespaces -o wide | wc -l

# Free slots: scale down non-critical components
kubectl scale deployment -n kube-system ebs-csi-controller --replicas=1
```

**Old image cached:**
```bash
kubectl patch deployment -n notes-buddy notes-buddy-app -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"notes-buddy","imagePullPolicy":"Always"}]}}}}'
```

**Multiple ReplicaSets stuck:**
```bash
kubectl scale rs -n notes-buddy <old-rs-name> --replicas=0
kubectl delete pod -n notes-buddy <stuck-pod> --force --grace-period=0
```

**Solution cards empty:**
Commands ingested by old images don't have exitCode/tag fields.
Re-ingest failed commands after deploying new image.

### App-of-Apps Pattern (Future)
Create a root Application that watches a directory. Child Applications in that directory auto-deploy:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/Mojojojo0222/notes_buddy
    path: argocd/apps
  destination:
    namespace: argocd
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## One-Time Setup: .bashrc + Log File

The app gets its data from `~/.notes_buddy_log`. This file is written by a `PROMPT_COMMAND` hook in your shell.

### Setup `.bashrc`
```bash
# Add to ~/.bashrc (Linux/Mac) or ~/.bash_profile (Git Bash on Windows)
NOTES_LOG="$HOME/.notes_buddy_log"

log_command() {
    local last_cmd
    last_cmd=$(history 1 | sed 's/^[ ]*[0-9]*[ ]*//')
    local repo
    repo=$(git rev-parse --show-toplevel 2>/dev/null | xargs basename 2>/dev/null || echo "none")
    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S')
    echo "${ts}|$(pwd)|${repo}|${last_cmd}" >> "$NOTES_LOG"
}

export PROMPT_COMMAND='history -a; log_command'
```

### For Git Bash on Windows
Create/edit `~/.bash_profile`:
```bash
if [ -f ~/.bashrc ]; then
    source ~/.bashrc
fi
```
Git Bash reads `.bash_profile` on startup, not `.bashrc`. Without this, nothing works and you'll see "Waiting for log file" forever.

### Reload Without Reopening Terminal
```bash
source ~/.bashrc
```

### Verify the Log File
```bash
# After running a few commands:
tail -f ~/.notes_buddy_log
# Format: 2026-07-21T17:42:39|/path/to/dir|repo-name|command text
```

---

## Commands Quick Reference

### Build
| Command | When |
|---------|------|
| `mvn clean package -DskipTests` | Build JAR locally |
| `docker build -t notes-buddy .` | Build Docker image |
| `docker compose up -d` | Build + start everything |

### Run
| Command | When |
|---------|------|
| `java -jar target/notes-buddy-0.0.1.jar` | Local without Docker |
| `docker compose up -d` | Local with Docker |
| `helm install notes-buddy ./helm/notes-buddy -f values-dev.yaml --namespace notes-buddy --create-namespace` | Deploy to K8s (Helm, preferred) |
| `kubectl apply -f k8s/` | Deploy to K8s (raw YAML, legacy) |

### Monitor
| Command | What It Shows |
|---------|---------------|
| `curl localhost:9098/actuator/health` | App health (UP/DOWN, DB status) |
| `curl localhost:9098/commands/all` | All ingested commands (JSON) |
| `curl localhost:9098/commands/search?q=docker` | Full-text search across all commands |
| `curl localhost:9098/solutions` | Solution cards — repeated errors with fixes |
| `curl localhost:9098/summary` | Today's stats (JSON) |
| `curl localhost:9098/summary/weekly` | Weekly stats with error count (JSON) |
| `curl localhost:9098/sessions` | Session grouping (JSON) |
| `kubectl get pods -n notes-buddy -w` | Pod status in real time |
| `kubectl logs -n notes-buddy deployment/notes-buddy -f` | Live app logs |
| `docker compose logs -f notes-buddy` | Live logs (Docker) |
| `helm list -n notes-buddy` | List all Helm releases |
| `helm status notes-buddy -n notes-buddy` | Show release status + NOTES.txt |
| `helm history notes-buddy -n notes-buddy` | Show all revision history |
| `helm template notes-buddy ./helm/notes-buddy -f values-dev.yaml` | Render YAML without installing |
| `helm lint ./helm/notes-buddy` | Validate chart syntax |
| `helm rollback notes-buddy 2 -n notes-buddy` | Rollback to revision 2 |
| `kubectl -n argocd get pods` | Check ArgoCD pod health |
| `kubectl -n argocd get svc argocd-server` | Get ArgoCD LoadBalancer URL |
| `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d` | Get ArgoCD admin password |
| `kubectl port-forward -n argocd svc/argocd-server 9090:80` | ArgoCD UI via localhost |
| `argocd app list` | List all ArgoCD applications |
| `argocd app sync notes-buddy` | Force sync Notes Buddy |
| `argocd app rollback notes-buddy 2` | Rollback Notes Buddy to revision 2 |
| `argocd app diff notes-buddy` | Compare Git vs cluster state |

### Debug
| Command | When |
|---------|------|
| `kubectl describe pod -n notes-buddy <pod-name>` | Pod events + errors |
| `kubectl exec -it -n notes-buddy deployment/postgres -- psql -U notesbuddy -d notesbuddy -c "SELECT * FROM command;"` | Query DB directly |
| `curl -X POST -d "text=test command" -d "workingDir=/test" -d "repoName=test" -d "timestamp=2026-07-21T12:00:00" http://localhost:9098/ingest` | Ingest a command manually |

---

## Troubleshooting Index

### 1. "Waiting for log file: /root/.notes_buddy_log"
**Where:** App logs, shown every 10s
**Meaning:** The HistoryWatcher can't find the log file at the expected path.
**Environments:**
- **Local:** Did you set up `.bashrc`? Check `~/.notes_buddy_log` exists. Run `echo test >> ~/.notes_buddy_log` to create it.
- **Docker:** The volume mount `$HOME/.notes_buddy_log:/root/.notes_buddy_log` maps your host file into the container. If the file doesn't exist on your host, the mount creates a directory instead of a file. **Fix:** `touch ~/.notes_buddy_log` on your host before starting Docker.
- **EKS:** Expected. The pod doesn't have access to your laptop's log file. Commands should be sent via the `/ingest` API. See problem #9 below.

### 2. App Won't Start — "Connection to PostgreSQL refused"
**Error:** `org.postgresql.util.PSQLException: Connection refused`
**Meaning:** App started before PostgreSQL was ready.
**Environments:**
- **Local:** Is PostgreSQL running? `pg_isready` or `docker ps | grep postgres`.
- **Docker:** docker-compose uses `depends_on: condition: service_healthy` — Postgres must pass a `pg_isready` check before the app starts. Wait 10-15s on first run.
- **EKS:** Check `kubectl logs -n notes-buddy deployment/postgres`. The pod might be CrashLoopBackOff (see #5).

### 3. "the server has asked for the client to provide credentials"
**Where:** `kubectl` commands
**Meaning:** Your IAM user/role isn't mapped in the EKS `aws-auth` ConfigMap.
**Fix:** 
```bash
# Check current mappings
kubectl get configmap aws-auth -n kube-system -o yaml

# Add your IAM user (for admin access)
kubectl edit configmap aws-auth -n kube-system
# Add under mapRoles:
# - rolearn: arn:aws:iam::YOUR_ACCOUNT:role/YOUR_ROLE
#   username: your-username
#   groups:
#   - system:masters
```
For GitHub Actions specifically, see `docs/day10/CI-CD-FIX-GUIDE.md`.

### 4. EBS CSI CrashLoopBackOff
**Error:** `no EC2 IMDS role found` or `not authorized to perform ec2:DescribeAvailabilityZones`
**Where:** `kubectl get pods -n kube-system | grep ebs-csi`
**Meaning:** The EBS CSI driver can't authenticate to AWS.
**Fix (IRSA — IAM Roles for Service Accounts):**
```bash
# Check if IRSA is set up
kubectl describe sa ebs-csi-controller-sa -n kube-system
# Look for "eks.amazonaws.com/role-arn" annotation

# If missing, check the IAM role exists
aws iam get-role --role-name notes-buddy-ebs-csi-role

# If role exists but annotation missing:
kubectl annotate sa ebs-csi-controller-sa -n kube-system \
  eks.amazonaws.com/role-arn=arn:aws:iam::083777493383:role/notes-buddy-ebs-csi-role \
  --overwrite

# Restart the deployment
kubectl rollout restart deployment ebs-csi-controller -n kube-system

# If role doesn't exist, create it in Terraform:
# Run `terraform apply` from the terraform/ directory
```
**Root cause:** The EBS CSI driver needs to call EC2 API to create/attach volumes. Without IRSA, the pod has no AWS credentials. The Terraform module now includes this role — just run `terraform apply`.

### 5. PostgreSQL CrashLoopBackOff
**Error:** `Permission denied` or `lost+found` or `data directory ... not empty`
**Where:** `kubectl logs -n notes-buddy deployment/postgres`
**Meaning:** The EBS volume isn't properly configured for Postgres.
**Two known causes:**

**Cause A — EBS volume ownership (fsGroup):**
```yaml
# In the pod spec (k8s/postgres.yaml)
securityContext:
  fsGroup: 999   # Postgres runs as UID 999
```
Without `fsGroup`, the volume is owned by root → Postgres can't write.
**Test:** `kubectl exec -it -n notes-buddy deployment/postgres -- ls -la /var/lib/postgresql/data`
**Fix:** Ensure `securityContext.fsGroup: 999` is in the deployment YAML.

**Cause B — lost+found collision:**
```yaml
# Volume mount (k8s/postgres.yaml)
volumeMounts:
  - name: postgres-storage
    mountPath: /var/lib/postgresql/data
    subPath: pgdata            # ← THIS is critical
```
EBS volumes are formatted ext4, which creates a `lost+found` directory. Postgres checks that the data directory is empty on init — `lost+found` blocks it.
**Fix:** Use `subPath: pgdata` + `PGDATA` env var.

### 6. "RepositoryAlreadyExistsException" (Terraform)
**Error:** `Error creating ECR Repository: RepositoryAlreadyExistsException`
**Meaning:** The ECR repo was created (first apply) but didn't make it into Terraform state.
**Fix:**
```bash
terraform import module.ecr.aws_ecr_repository.main notes-buddy
```
This happens when `terraform apply` times out after the resource is created but before state is written.

### 7. "Addon already exists" (Terraform)
**Error:** `Error creating EKS Add-On: ResourceInUseException: Addon already exists`
**Meaning:** Same as #6 — addon exists but isn't in Terraform state.
**Fix:**
```bash
terraform import module.eks.aws_eks_addon.ebs_csi notes-buddy:aws-ebs-csi-driver
```

### 8. State Lock Error (Terraform)
**Error:** `Error acquiring the state lock` or `The state file could not be read`
**Meaning:** Another Terraform process is running.
**Fix:**
```bash
# Wait for the other process to finish, or force-unlock:
terraform force-unlock LOCK_ID

# Or skip locking (NOT recommended in CI/CD, OK for manual):
terraform plan -lock=false
```

### 9. "Waiting for log file" on EKS (Expected)
**Error:** Recurring log message every 10s on EKS — **this is expected.**
**Why:** The EKS pod can't read your laptop's `~/.notes_buddy_log`. The HistoryWatcher was designed for local file-based ingestion.
**Fix (already done):** Day 8 built the `/ingest` API endpoint. The `.bashrc` on your laptop sends commands via `curl POST` to the EKS URL in the background.
```bash
# Your .bashrc already includes this:
NOTES_BUDDY_URL="http://YOUR_ALB_URL"
curl -s -o /dev/null -X POST --data-urlencode "text=${last_cmd}" \
  --data-urlencode "workingDir=$(pwd)" \
  --data-urlencode "repoName=${repo}" \
  --data-urlencode "timestamp=${ts}" \
  "${NOTES_BUDDY_URL}/ingest" &
```
**Check if it's working:** Hit the `/ingest` endpoint manually:
```bash
curl -X POST http://YOUR_ALB_URL/ingest \
  -d "text=docker ps" \
  -d "workingDir=/home" \
  -d "repoName=test" \
  -d "timestamp=2026-07-21T12:00:00"
# Expected: saved or skipped
```
Then check: `curl http://YOUR_ALB_URL/commands/all | head`

### 10. HPA Shows `<unknown>` for Metrics
**Error:** `kubectl get hpa -n notes-buddy` shows `cpu: <unknown>/50%`
**Meaning:** metrics-server isn't installed or isn't collecting CPU metrics.
**Fix:**
```bash
# Check metrics-server pods
kubectl get pods -n kube-system | grep metrics-server

# If not running, install it:
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Wait 1-2 minutes, then check again
kubectl top pods -n notes-buddy
kubectl get hpa -n notes-buddy
```

### 11. PVC Stays Pending
**Error:** `kubectl get pvc -n notes-buddy` shows `STATUS: Pending`
**Meaning:** No storage class can provision the volume.
**Fix:**
```bash
# Check storage classes
kubectl get storageclass

# For EKS, gp2 (EBS) should be available. If not:
# Install EBS CSI driver
kubectl apply -k "github.com/kubernetes-sigs/aws-ebs-csi-driver/deploy/kubernetes/overlays/stable/?ref=release-1.32"

# Or provision via Terraform (already included in the EKS module)
```

### 12. Can't Pull Image from ECR
**Error:** `ImagePullBackOff` or `ErrImagePull`
**Where:** `kubectl describe pod -n notes-buddy <pod-name>`
**Meaning:** The pod can't access the ECR repository.
**Fix:**
```bash
# Check the node role has ECR permissions (attached by Terraform)
aws iam list-attached-role-policies --role-name notes-buddy-node-role
# Should include: AmazonEC2ContainerRegistryReadOnly

# If image doesn't exist in ECR, push it:
docker push 083777493383.dkr.ecr.ap-south-1.amazonaws.com/notes-buddy:latest
```

### 13. PVC Stuck Terminating
**Error:** `kubectl get pvc -n notes-buddy` shows `STATUS: Terminating` that never completes.
**Meaning:** A finalizer (usually from a running pod still using the volume) is blocking deletion.
**Fix:**
```bash
# Remove finalizers from the stuck PVC
kubectl patch pvc -n notes-buddy <pvc-name> -p '{"metadata":{"finalizers":[]}}' --type=merge

# If the underlying PV is still present, delete it
kubectl delete pv <pv-name>
```
**Background:** When a PVC is force-deleted while a pod is still using the volume, the finalizer prevents full cleanup. This is a safety mechanism that sometimes needs manual override.

### 14. ArgoCD OutOfSync — PVC Cannot Be Resized
**Error:** `error when patching: persistentvolumeclaims "notes-buddy-postgres" is forbidden: only dynamically provisioned pvc can be resized and the storageclass that provisions the pvc must support resize`
**Meaning:** The PVC size in Git differs from the running PVC, and the StorageClass doesn't support volume expansion.
**Root cause:** The `gp2` StorageClass (in-tree `kubernetes.io/aws-ebs`) has `allowVolumeExpansion: false`. Only EBS CSI driver with a custom StorageClass supports resize.
**Fix:** Either:
- Match the Helm values to the running PVC size (simplest)
- Or delete the PVC and let it be recreated at the desired size (data loss)
```bash
# Option A: Match Git to cluster
# Edit values-dev/staging.yaml to use the running size, push to git

# Option B: Delete and recreate PVC (data loss)
kubectl delete pvc -n notes-buddy notes-buddy-postgres
kubectl patch pvc -n notes-buddy notes-buddy-postgres -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null; true
# Then let ArgoCD recreate it at the desired size
```

### 15. Rolling Update Deadlock (TooManyPods)
**Error:** `0/2 nodes are available: 2 Too many pods.`
**Where:** Pod stays Pending after a deployment update.
**Meaning:** The RollingUpdate strategy (`maxSurge: 1, maxUnavailable: 0`) creates a new pod before killing old ones, but both nodes are at pod capacity.
**Fix:**
```bash
# Find the old ReplicaSet (the one with running pods)
kubectl get rs -n notes-buddy

# Scale it to 0 to free capacity
kubectl scale rs -n notes-buddy <old-rs-name> --replicas=0

# The new ReplicaSet pods will now schedule
kubectl get pods -n notes-buddy -w
```
**Prevention:** On small nodes, consider `maxSurge: 0, maxUnavailable: 1` for the deployment strategy, or use larger instance types.

### 16. App Returns 500 — "relation 'command' does not exist"
**Error:** `org.postgresql.util.PSQLException: ERROR: relation "command" does not exist`
**Meaning:** The database tables don't exist — usually after a PVC recreation or database reset.
**Fix:** Restart the app so Hibernate's `ddl-auto=update` creates the schema:
```bash
kubectl rollout restart deployment notes-buddy-app -n notes-buddy
```
**Note:** If Postgres wasn't ready when the app first started, Hibernate silently skips schema creation. The error only appears when a query is attempted.

### 17. Ingested Commands Not Appearing on Dashboard
**Error:** Commands sent via `curl POST /ingest` return `saved` but don't show on the dashboard.
**Where:** User's terminal → `.bashrc` → EKS ALB
**Three things to check:**
```bash
# 1. Is NOTES_BUDDY_URL set and uncommented?
grep NOTES_BUDDY_URL ~/.bashrc

# 2. Is the curl POST uncommented in log_command()?
grep -A5 "send to EKS" ~/.bashrc

# 3. Is the ALB URL reachable?
curl -s http://YOUR_ALB_URL/summary
```
**Common fixes:**
- Uncomment the curl block in `log_command()`
- Add `--data-urlencode "timestamp=$(date '+%Y-%m-%dT%H:%M:%S')"` and `--data-urlencode "exitCode=${exit_code}"` params
- Verify `NOTES_BUDDY_URL` has no trailing slash

### 18. ALB Takes Too Long to Provision
**Error:** `curl: (28) Connection timeout` when hitting the LoadBalancer URL
**Meaning:** The ALB (Application Load Balancer) is still provisioning. This takes 2-5 minutes after `kubectl apply -f k8s/notes-buddy.yaml`.
**Fix:** Wait. Check status:
```bash
kubectl get svc -n notes-buddy notes-buddy-service -w
# Look for EXTERNAL-IP to appear

# In the meantime, use port-forward:
kubectl port-forward -n notes-buddy deployment/notes-buddy 9098:9098
```

---

## Environment Comparison

| Feature | Local (no Docker) | Docker | EKS |
|---------|------------------|--------|-----|
| **DB** | PostgreSQL (native or Docker) | PostgreSQL (container) | PostgreSQL (pod + EBS) |
| **Setup time** | 5 min | 2 min | 20 min (Terraform) |
| **Log file** | `~/.notes_buddy_log` | Volume mounted | `/ingest` API only |
| **Port** | 9098 | 9098 | 80 (ALB) → 9098 |
| **Data persistence** | Local PG | Docker volume | EBS volume (survives pod restarts) |
| **Deploy command** | `java -jar target/...` | `docker compose up -d` | `helm install ... -f values-*.yaml` |
| **Cost** | Free | Free | ~$50-70/mo (2 t3.small + ALB + EBS) |
| **Auto-restart** | No | Yes (unless `docker compose down`) | Yes (K8s keeps pods running) |

---

## File Locations

| File | Purpose |
|------|---------|
| `src/main/java/com/notesbuddy/NotesApplication.java` | Entry point |
| `src/main/resources/application.properties` | Config (env vars) |
| `Dockerfile` | Multi-stage Docker build |
| `docker-compose.yml` | Local Docker environment |
| `k8s/namespace.yaml` | K8s namespace (LEGACY — use Helm) |
| `k8s/configmap.yaml` | Environment variables for K8s (LEGACY — use Helm) |
| `k8s/secret.yaml` | DB password (base64) (LEGACY — use Helm) |
| `k8s/postgres.yaml` | PostgreSQL PVC + Deployment + Service (LEGACY — use Helm) |
| `k8s/notes-buddy.yaml` | App Deployment + LoadBalancer Service (LEGACY — use Helm) |
| `k8s/hpa.yaml` | CPU-based autoscaling (LEGACY — use Helm) |
| `k8s/rbac-github-actions.yaml` | GitHub Actions RBAC Role + RoleBinding (LEGACY — use Helm) |
| `helm/notes-buddy/Chart.yaml` | Helm chart metadata (name, version, kubeVersion) |
| `helm/notes-buddy/values.yaml` | Default configuration (100+ values) |
| `helm/notes-buddy/values-dev.yaml` | DEV environment overrides |
| `helm/notes-buddy/values-staging.yaml` | STAGING environment overrides |
| `helm/notes-buddy/values-production.yaml` | PRODUCTION environment overrides |
| `helm/notes-buddy/templates/_helpers.tpl` | Reusable named templates |
| `helm/notes-buddy/templates/NOTES.txt` | Post-install instructions |
| `helm/argocd/values.yaml` | ArgoCD Helm values (LoadBalancer, resource limits, RBAC) |
| `argocd/apps/notes-buddy.yaml` | ArgoCD Application definition for Notes Buddy (TODO) |
| `terraform/` | Full IaC: VPC, EKS, ECR, IAM, OIDC |
| `.github/workflows/deploy.yml` | CI/CD pipeline |
| `docs/AI_CONTEXT.md` | Private AI session memory (DO NOT PUSH) |
| `docs/INTERVIEW_STORY.md` | Full project story + interview prep |
| `docs/CONCEPTS_MASTER.md` | DevOps concepts for interview prep |
| `docs/day*/README.md` | Per-day detailed notes |

---

## Observability (SRE Stack)

### Metrics Endpoint
```bash
curl http://localhost:9098/actuator/prometheus | grep notesbuddy_
```

### Grafana Dashboard
```bash
# URL: http://localhost:3000 (admin/admin)
# 1. Add Prometheus data source: http://prometheus:9090
# 2. Import grafana-dashboard.json from project root
```

### Prometheus Alerts
```bash
curl http://localhost:9090/api/v1/rules   # check rules loaded
curl http://localhost:9090/api/v1/targets # check targets up
```

| Alert | When | Response |
|-------|------|----------|
| AppDown | Unreachable 30s | `docker compose logs notes-buddy` |
| HighErrorRate | >20% fail 2m | Check recent exit codes |
| IngestionStopped | 0 commands 10m | Check log file exists |
| SearchLatencyHigh | p95 > 2s | DB query perf |
