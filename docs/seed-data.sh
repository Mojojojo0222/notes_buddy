#!/bin/bash
# Notes Buddy — Seed data with realistic timestamps
# Usage: URL=http://<host>:9098 bash docs/seed-data.sh   (defaults to localhost)
URL="${URL:-http://localhost:9098}"

post() {
  local ts=$1 text=$2 dir=$3 repo=$4 exit=$5
  curl -s -X POST "$URL/ingest" \
    --data-urlencode "text=$text" \
    --data-urlencode "workingDir=$dir" \
    --data-urlencode "repoName=$repo" \
    --data-urlencode "timestamp=$ts" \
    --data-urlencode "exitCode=$exit" -o /dev/null
}

echo "Seeding commands with realistic timestamps..."

# === 2026-08-08 (Yesterday) ===

# Morning session — git work
post "2026-08-08T09:15:00" "git status" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-08T09:16:00" "git add src/main/java/com/notesbuddy/controller/CommandController.java" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-08T09:17:00" "git commit -m \"add search endpoint\"" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-08T09:18:00" "git push origin main" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-08T09:20:00" "git log --oneline -5" "/e/Notes_Buddy" "notes-buddy" 0

# Docker work
post "2026-08-08T09:30:00" "docker build -t notes-buddy ." "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-08T09:35:00" "docker ps -a" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-08T09:36:00" "docker compose up -d" "/e/Notes_Buddy" "notes-buddy" 0

# Afternoon — Terraform
post "2026-08-08T14:00:00" "terraform init" "/e/Notes_Buddy/terraform" "notes-buddy" 0
post "2026-08-08T14:05:00" "terraform plan" "/e/Notes_Buddy/terraform" "notes-buddy" 0
post "2026-08-08T14:10:00" "terraform apply -auto-approve" "/e/Notes_Buddy/terraform" "notes-buddy" 0

# Failures
post "2026-08-08T14:30:00" "terraform apply -auto-approve" "/e/Notes_Buddy/terraform" "notes-buddy" 1
post "2026-08-08T14:31:00" "terraform apply -auto-approve" "/e/Notes_Buddy/terraform" "notes-buddy" 1
post "2026-08-08T14:32:00" "terraform force-unlock -force LOCK_ID" "/e/Notes_Buddy/terraform" "notes-buddy" 0

# Kubernetes evening
post "2026-08-08T18:00:00" "kubectl get pods -n notes-buddy" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-08T18:01:00" "kubectl describe pod notes-buddy-app -n notes-buddy" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-08T18:05:00" "kubectl logs -n notes-buddy deployment/notes-buddy-app -f" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-08T18:10:00" "helm list -n argocd" "/e/Notes_Buddy" "notes-buddy" 0

# === 2026-08-09 (Today) ===

# Morning
post "2026-08-09T08:00:00" "cd src/main/java/com/notesbuddy/service" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-09T08:05:00" "ls -la" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-09T08:10:00" "cat pom.xml" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-09T08:15:00" "mvn clean package -DskipTests" "/e/Notes_Buddy" "notes-buddy" 0

# EBS CSI debugging
post "2026-08-09T09:00:00" "kubectl describe pod ebs-csi-controller -n kube-system" "/e/Notes_Buddy" "notes-buddy" 1
post "2026-08-09T09:01:00" "kubectl describe pod ebs-csi-controller -n kube-system" "/e/Notes_Buddy" "notes-buddy" 1
post "2026-08-09T09:02:00" "kubectl describe pod ebs-csi-controller -n kube-system" "/e/Notes_Buddy" "notes-buddy" 1
post "2026-08-09T09:05:00" "kubectl annotate sa ebs-csi-controller-sa -n kube-system eks.amazonaws.com/role-arn=arn:aws:iam::083777493383:role/notes-buddy-ebs-csi-role --overwrite" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-09T09:06:00" "kubectl rollout restart deployment ebs-csi-controller -n kube-system" "/e/Notes_Buddy" "notes-buddy" 0

# Port conflict issue
post "2026-08-09T10:00:00" "java -jar target/notes-buddy-0.0.1.jar" "/e/Notes_Buddy" "notes-buddy" 1
post "2026-08-09T10:01:00" "java -jar target/notes-buddy-0.0.1.jar" "/e/Notes_Buddy" "notes-buddy" 1
post "2026-08-09T10:02:00" "netstat -ano | grep 9098" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-09T10:03:00" "kill PID_FROM_NETSTAT" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-09T10:05:00" "java -jar target/notes-buddy-0.0.1.jar" "/e/Notes_Buddy" "notes-buddy" 0

# Docker fail
post "2026-08-09T11:00:00" "docker run -p 8080:8080 notes-buddy" "/e/Notes_Buddy" "notes-buddy" 1
post "2026-08-09T11:01:00" "docker run -p 8080:8080 notes-buddy" "/e/Notes_Buddy" "notes-buddy" 1
post "2026-08-09T11:02:00" "docker run -p 9098:9098 notes-buddy" "/e/Notes_Buddy" "notes-buddy" 0

# Git fail
post "2026-08-09T11:30:00" "git pull" "/e/Notes_Buddy" "notes-buddy" 128
post "2026-08-09T11:31:00" "git pull" "/e/Notes_Buddy" "notes-buddy" 128
post "2026-08-09T11:32:00" "git stash && git pull" "/e/Notes_Buddy" "notes-buddy" 0

# Afternoon — Kubernetes
post "2026-08-09T14:00:00" "kubectl get nodes" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-09T14:01:00" "kubectl get pods --all-namespaces" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-09T14:05:00" "kubectl get svc -n argocd argocd-server" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-09T14:10:00" "curl -s http://localhost:9098/actuator/health" "/e/Notes_Buddy" "notes-buddy" 0

# File operations
post "2026-08-09T15:00:00" "mkdir -p helm/argocd/templates" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-09T15:01:00" "cp Dockerfile Dockerfile.backup" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-09T15:05:00" "rm -rf target" "/e/Notes_Buddy" "notes-buddy" 0

# Editor
post "2026-08-09T16:00:00" "grep -r TODO src/" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-09T16:05:00" "nano Dockerfile" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-09T16:10:00" "tail -f ~/.notes_buddy_log" "/home" "none" 0

# Network
post "2026-08-09T17:00:00" "ssh -i key.pem ec2-user@192.168.1.100" "/home" "none" 0
post "2026-08-09T17:05:00" "ping -c 4 google.com" "/home" "none" 0

# Ingestion API test
post "2026-08-09T18:00:00" "curl -X POST http://localhost:9098/ingest -d text=test" "/e/Notes_Buddy" "notes-buddy" 0

# === GitOps session (today evening) ===
post "2026-08-09T19:00:00" "git commit -m \"fix: match postgres PVC size to running state\"" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-09T19:02:00" "git push origin main" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-09T19:05:00" "kubectl get applications -n argocd" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-09T19:07:00" "kubectl get application notes-buddy -n argocd -o jsonpath='{.status.sync.status}'" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-09T19:08:00" "kubectl get application notes-buddy -n argocd -o jsonpath='{.status.health.status}'" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-09T19:10:00" "argocd app sync notes-buddy" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-09T19:12:00" "kubectl rollout status deployment/notes-buddy-app -n notes-buddy" "/e/Notes_Buddy" "notes-buddy" 0

# === Stress testing session ===
post "2026-08-09T20:00:00" "k6 run load-test.js" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-09T20:05:00" "k6 run --vus 200 --duration 60s load-test.js" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-09T20:10:00" "kubectl get hpa notes-buddy-hpa -n notes-buddy" "/e/Notes_Buddy" "notes-buddy" 0
post "2026-08-09T20:12:00" "kubectl top pods -n notes-buddy" "/e/Notes_Buddy" "notes-buddy" 0

# === Package manager session ===
post "2026-08-09T21:00:00" "npm install" "/e/frontend-project" "frontend-project" 0
post "2026-08-09T21:02:00" "npm run build" "/e/frontend-project" "frontend-project" 0
post "2026-08-09T21:04:00" "npm run build" "/e/frontend-project" "frontend-project" 1
post "2026-08-09T21:05:00" "npm run build" "/e/frontend-project" "frontend-project" 1
post "2026-08-09T21:06:00" "npm cache clean --force" "/e/frontend-project" "frontend-project" 0
post "2026-08-09T21:08:00" "npm run build" "/e/frontend-project" "frontend-project" 0

echo ""
echo "=== Verify ==="
curl -s "$URL/summary"
echo ""
echo "=== Solutions ==="
curl -s "$URL/solutions" | tr '}' '\n' | head -10
echo ""
echo "=== Sessions ==="
curl -s "$URL/sessions" | tr '}' '\n' | grep startTime | head -5
