# Notes Buddy — Runbook

How to run this application in every environment, with every problem you'll hit and how to fix it.

---

## Table of Contents
1. [Prerequisites](#prerequisites)
2. [Local — Without Docker (Spring Boot + Maven)](#local--without-docker-spring-boot--maven)
3. [Local — With Docker (docker-compose)](#local--with-docker-docker-compose)
4. [AWS EKS (Kubernetes)](#aws-eks-kubernetes)
5. [One-Time Setup: .bashrc + Log File](#one-time-setup-bashrc--log-file)
6. [Commands Quick Reference](#commands-quick-reference)
7. [Troubleshooting Index](#troubleshooting-index)

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

### Deploy the App
```bash
cd E:\Notes_Buddy

# Create namespace and all resources
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
| `kubectl apply -f k8s/` | Deploy to EKS |

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

### 13. ALB Takes Too Long to Provision
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
| `k8s/namespace.yaml` | K8s namespace |
| `k8s/configmap.yaml` | Environment variables for K8s |
| `k8s/secret.yaml` | DB password (base64) |
| `k8s/postgres.yaml` | PostgreSQL PVC + Deployment + Service |
| `k8s/notes-buddy.yaml` | App Deployment + LoadBalancer Service |
| `k8s/hpa.yaml` | CPU-based autoscaling |
| `k8s/rbac-github-actions.yaml` | GitHub Actions RBAC Role + RoleBinding |
| `terraform/` | Full IaC: VPC, EKS, ECR, IAM, OIDC |
| `.github/workflows/deploy.yml` | CI/CD pipeline |
| `docs/AI_CONTEXT.md` | Private AI session memory (DO NOT PUSH) |
| `docs/INTERVIEW_STORY.md` | Full project story + interview prep |
| `docs/CONCEPTS_MASTER.md` | DevOps concepts for interview prep |
| `docs/day*/README.md` | Per-day detailed notes |
