# Notes Buddy — Command Reference

## Application-Level Commands

### Build & Run

```bash
# Build JAR locally
mvn clean package -DskipTests

# Run locally (needs PostgreSQL)
java -jar target/notes-buddy-0.0.1.jar

# Build Docker image
docker build -t notes-buddy .

# Run with Docker
docker run -d -p 9098:9098 \
  -v "$HOME/.notes_buddy_log:/root/.notes_buddy_log" \
  --name notes-buddy notes-buddy

# Full stack with Docker Compose (Postgres + App + Prometheus + Grafana)
docker compose up -d
```

### ECR — Push Image

```bash
# Login
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin 083777493383.dkr.ecr.ap-south-1.amazonaws.com

# Tag & push
docker tag notes-buddy:latest 083777493383.dkr.ecr.ap-south-1.amazonaws.com/notes-buddy:latest
docker push 083777493383.dkr.ecr.ap-south-1.amazonaws.com/notes-buddy:latest
```

### Terraform — Infrastructure

```bash
cd terraform

terraform init                     # First time or after backend changes
terraform plan                     # Preview changes
terraform apply -auto-approve      # Create/update infra
terraform destroy -auto-approve    # Tear down everything
terraform force-unlock LOCK_ID     # Release stuck state lock
terraform import <ADDR> <ID>       # Import existing resource into state
terraform state list               # List all managed resources
```

### Kubectl — Cluster Access

```bash
aws eks update-kubeconfig --region ap-south-1 --name notes-buddy

kubectl get nodes
kubectl get pods --all-namespaces
kubectl get pods -n notes-buddy
kubectl get svc -n notes-buddy
kubectl logs -n notes-buddy deployment/notes-buddy-app -f
kubectl describe pod -n notes-buddy <pod-name>
kubectl port-forward -n notes-buddy svc/notes-buddy-app 9098:9098
kubectl rollout restart deployment -n notes-buddy notes-buddy-app
kubectl scale deployment -n notes-buddy notes-buddy-app --replicas=1
```

### Helm — Deploy Notes Buddy

```bash
# DEV (ClusterIP, 1 replica, no HPA)
helm install notes-buddy ./helm/notes-buddy -f values-dev.yaml --namespace notes-buddy --create-namespace

# STAGING (LoadBalancer, 2 replicas, HPA 2-4)
helm install notes-buddy ./helm/notes-buddy -f values-staging.yaml --namespace notes-buddy --create-namespace

# Upgrade
helm upgrade notes-buddy ./helm/notes-buddy -f values-staging.yaml

# Rollback
helm rollback notes-buddy 1 -n notes-buddy

# Uninstall
helm uninstall notes-buddy -n notes-buddy

# Debug (no cluster needed)
helm template notes-buddy ./helm/notes-buddy -f values-dev.yaml
helm lint ./helm/notes-buddy
```

### ArgoCD — GitOps

```bash
# Install
kubectl create ns argocd
helm install argocd argo/argo-cd -f helm/argocd/values.yaml --namespace argocd

# Access
kubectl get svc -n argocd argocd-server
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Create Application
kubectl apply -f argocd/apps/notes-buddy.yaml

# CLI (if installed)
argocd app list
argocd app sync notes-buddy
argocd app diff notes-buddy
argocd app rollback notes-buddy 2

# Port-forward UI
kubectl port-forward -n argocd svc/argocd-server 9090:80
# → http://localhost:9090 (admin / password from above)
```

### API Endpoints

```bash
BASE="http://<load-balancer-url>"

# Health
curl $BASE/actuator/health                         # UP/DOWN + DB status

# Commands
curl $BASE/commands/all                            # All commands JSON
curl $BASE/commands/search?q=docker               # Full-text search
curl $BASE/commands/by-date?date=2026-07-26        # Commands for a date

# Summary
curl $BASE/summary                                 # Today's stats
curl $BASE/summary/weekly                          # Weekly stats + error count

# Sessions
curl $BASE/sessions                                # Grouped by 30-min gaps

# Ingestion
curl -X POST $BASE/ingest \
  -d "text=git status" \
  -d "workingDir=/e/Notes_Buddy" \
  -d "repoName=notes-buddy" \
  -d "exitCode=0"

# Tagging
curl -X POST $BASE/commands/1/tag -d "tag=my-label"

# Solutions (repeated errors with fixes)
curl $BASE/solutions

# Metrics (Prometheus)
curl $BASE/actuator/prometheus | grep notesbuddy_
```

### .bashrc — Terminal Logging

Setup in `~/.bashrc`:

```bash
NOTES_LOG="$HOME/.notes_buddy_log"
NOTES_BUDDY_URL="http://<load-balancer-url>"

log_command() {
    local exit_code=$?
    local last_cmd
    last_cmd=$(history 1 | sed 's/^[ ]*[0-9]*[ ]*//')
    local repo
    repo=$(git rev-parse --show-toplevel 2>/dev/null | xargs basename 2>/dev/null || echo "none")
    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S')
    echo "${ts}|$(pwd)|${repo}|${last_cmd}|${exit_code}" >> "$NOTES_LOG"
    curl -s -o /dev/null -X POST \
      --data-urlencode "text=${last_cmd}" \
      --data-urlencode "workingDir=$(pwd)" \
      --data-urlencode "repoName=${repo}" \
      --data-urlencode "timestamp=${ts}" \
      --data-urlencode "exitCode=${exit_code}" \
      "${NOTES_BUDDY_URL}/ingest" &
}

export PROMPT_COMMAND='history -a; log_command'
```
