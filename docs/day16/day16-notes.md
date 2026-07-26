# Day 16 — ArgoCD GitOps: Cluster Rebuild + ArgoCD Installation

**Date:** 2026-07-26  
**Goal:** Recreate EKS cluster and install ArgoCD for GitOps deployments

---

## Phase 0: Recreate EKS Cluster via Terraform

### Status Before
- EKS cluster had been destroyed (cost saving)
- Terraform state was **partial** — VPC + subnets + IGW + ECR existed in state, everything else was gone
- S3 remote state was intact, DynamoDB locking was active

### Attempt 1: `terraform apply` — Timeout at 10 min

**Problem:** The apply succeeded partially:
- ✅ IAM roles (cluster, node, EBS CSI, GitHub Actions)
- ✅ OIDC provider (GitHub + EKS)
- ✅ EKS cluster (9 min to create)
- ✅ EKS node group (started creating)
- ❌ EBS CSI addon — not created (timeout)
- ❌ CloudWatch addon — not created (timeout)

**Command ran:**
```bash
terraform apply -auto-approve
```
Timed out after 600s (our bash timeout setting).

### Attempt 2: State Lock Contention

**Problem:** When apply timed out, the DynamoDB state lock was NOT released. Second `terraform plan` failed:
```
Error: Error acquiring the state lock
ConditionalCheckFailedException: The conditional request failed
```

**Fix — Force unlock:**
```bash
terraform force-unlock -force <LOCK_ID>
```
The Lock ID was shown in the error message.

### Attempt 3: Re-apply — `EntityAlreadyExists` Errors

**Problem:** The node group and OIDC provider were created by the first apply (despite timeout), so the second apply tried to create them again and failed:
```
EntityAlreadyExists: Provider with url already exists
ResourceInUseException: NodeGroup already exists
```

**Fix — Import existing resources into state:**
```bash
terraform import module.eks.aws_eks_node_group.main notes-buddy:notes-buddy-nodes
terraform import module.eks.aws_iam_openid_connect_provider.eks arn:aws:iam::083777493383:oidc-provider/oidc.eks.ap-south-1.amazonaws.com/id/CDFC3205C2AA124F25E19DA1B7867F78
terraform import module.eks.aws_iam_role.ebs_csi notes-buddy-ebs-csi-role
terraform import module.eks.aws_iam_role_policy_attachment.ebs_csi notes-buddy-ebs-csi-role/arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
```

**Import ID format for EBS CSI Policy Attachment:** `role-name/policy-arn` (not just the name)

### Attempt 4: EBS CSI Addon Stuck in CREATING

**Problem:** After importing, `terraform apply` tried to create EBS CSI addon. It stayed in `CREATING` status for 10+ minutes with no health issues.

**Root cause:** The Terraform `aws_eks_addon` resource wasn't passing a `service_account_role_arn` to the addon. Without it, the addon creates without IRSA and gets stuck trying to assume the default instance profile which doesn't have the right permissions.

**Fix (multi-step):**
1. Delete the stuck addon:
   ```bash
   aws eks delete-addon --cluster-name notes-buddy --addon-name aws-ebs-csi-driver --region ap-south-1
   ```
2. Recreate with explicit role ARN:
   ```bash
   aws eks create-addon --cluster-name notes-buddy --addon-name aws-ebs-csi-driver --region ap-south-1 --service-account-role-arn arn:aws:iam::083777493383:role/notes-buddy-ebs-csi-role --resolve-conflicts OVERWRITE
   ```
3. Update Terraform module to include the role ARN permanently:
   ```hcl
   resource "aws_eks_addon" "ebs_csi" {
     cluster_name             = aws_eks_cluster.main.name
     addon_name               = "aws-ebs-csi-driver"
     service_account_role_arn = aws_iam_role.ebs_csi.arn
     resolve_conflicts        = "OVERWRITE"
     # ...
   }
   ```
4. Import the created addon into state:
   ```bash
   terraform import -lock=false module.eks.aws_eks_addon.ebs_csi notes-buddy:aws-ebs-csi-driver
   ```
5. Import CloudWatch addon:
   ```bash
   terraform import -lock=false module.eks.aws_eks_addon.cloudwatch notes-buddy:amazon-cloudwatch-observability
   ```

### Final State — Cluster Ready

```
2 nodes Ready (t3.small, K8s 1.31)
30 Terraform resources managed
EBS CSI: Active (6/6 controller, 3/3 node)
CloudWatch: Active (agent + fluent-bit on both nodes)
CoreDNS: 2/2
kube-proxy: 2/2
```

---

## Phase 1: Install ArgoCD

### Approach
Used the official **ArgoCD Helm chart** (`argo/argo-cd`) — preferred over raw manifests because it demonstrates Helm expertise and makes upgrades easy.

### Helm Values
Created `helm/argocd/values.yaml` with:
- `server.insecure: true` (no TLS cert needed for dev)
- `server.service.type: LoadBalancer` (external access without ingress)
- Resource limits for all components (controller 1Gi mem, server 512Mi, repo 512Mi)
- RBAC policy for admin role
- CRDs managed by Helm with keep on uninstall

### Installation
```bash
kubectl create ns argocd
helm install argocd argo/argo-cd -f values.yaml --namespace argocd
```

All 7 pods came up in under 60 seconds:
- argocd-server (1/1)
- argocd-application-controller (1/1)
- argocd-applicationset-controller (1/1)
- argocd-repo-server (1/1)
- argocd-dex-server (1/1)
- argocd-notifications-controller (1/1)
- argocd-redis (1/1)

### Access: LoadBalancer Provisioned
```
Hostname: aa335e8d179da4eb7b1035e630ff0e41-1249820149.ap-south-1.elb.amazonaws.com
Ports: 80 (HTTP) → 8080, 443 (HTTPS) → 8080
```

### Admin Password
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
# Password: Jzl-KzKg4AY0gNMG
```

### Verification: API Responding
```bash
curl http://localhost:9090/api/version
# {"Version":"v3.4.5"}
```

---

## Problems Encountered (Session 1 — Cluster Rebuild)

| # | Problem | Root Cause | Fix |
|---|---------|------------|-----|
| 1 | `terraform apply` timeout (10 min) | EKS cluster + node group take 9-15 min to create | Increased timeout, ran again |
| 2 | State lock stuck after timeout | Terraform crashed without releasing DynamoDB lock | `terraform force-unlock -force <LOCK_ID>` |
| 3 | `EntityAlreadyExists` on re-apply | Resources created in first apply but not in state | `terraform import` 4 resources |
| 4 | EBS CSI addon stuck CREATING forever | Missing `service_account_role_arn` → no IRSA | Delete + recreate addon with role ARN |
| 5 | Windows port-forward issues | Port 8080 already in use (elevated app) | Used port 9090 instead |
| 6 | ArgoCD CLI login failed via port-forward | Background processes don't persist in Git Bash | Use `kubectl apply -f app.yaml` instead of CLI |

---

## Phase 2: Deploy Notes Buddy via ArgoCD

### Step 1: Create Application CRD

Created `argocd/apps/notes-buddy.yaml` — the ArgoCD Application definition:

```yaml
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
        - values-staging.yaml
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

**The 5-part mental model:**
1. `metadata` — name + namespace (argocd namespace)
2. `project` — default (built-in)
3. `source` — GitHub repo + folder + helm values
4. `destination` — cluster + target namespace
5. `syncPolicy` — auto-sync + prune + self-heal + create-namespace

### Step 2: Apply and Verify

```bash
kubectl apply -f argocd/apps/notes-buddy.yaml
# → application.argoproj.io/notes-buddy created

# Check sync status
kubectl get application -n argocd notes-buddy
# → Synced, Healthy

# Pods come up automatically
kubectl get pods -n notes-buddy -w
# → notes-buddy-app, notes-buddy-postgres
```

### Step 3: Switch from Dev (ClusterIP) to Staging (LoadBalancer)

Changed `valueFiles` from `values-dev.yaml` → `values-staging.yaml`:
- Service type: ClusterIP → LoadBalancer (public URL)
- Replicas: 1 → 2
- HPA: disabled → enabled (2-4)

**New URL:** `http://a4222470eaec245a29c7720b811fb836-1696657361.ap-south-1.elb.amazonaws.com`

### Step 4: Verify All Features

| Feature | Status | How |
|---------|--------|-----|
| Category detection | ✅ | All 9 categories auto-detected |
| Search | ✅ | Full-text ILIKE across 5 fields |
| Solution cards | ✅ | 3 repeated errors with fixes |
| Tagging | ✅ | Inline edit + API |
| Ingestion (exit codes) | ✅ | exitCode stored per command |
| Dashboard HTML | ✅ | Served via ALB |

### Step 5: Update .bashrc for Ingestion

```bash
NOTES_BUDDY_URL="http://a4222470eaec245a29c7720b811fb836-1696657361.ap-south-1.elb.amazonaws.com"
```

Added to `log_command()`: curl POST with `--data-urlencode exitCode=${exit_code}`.

---

## Problems Encountered (Session 2 — Application Deploy)

| # | Problem | Root Cause | Fix |
|---|---------|------------|-----|
| 7 | **Pod capacity exhausted** (t3.small max 11) | ArgoCD (7 pods) + system daemons + CloudWatch filled both nodes | Disabled dex + notifications in ArgoCD values. Reduced all ArgoCD resource requests. Scaled EBS CSI to 1 replica |
| 8 | **App pods stuck Pending** (TooManyPods) | Rolling update couldn't create new pod before killing old one | Forced delete old pods + scale old ReplicaSets to 0 |
| 9 | **Old Docker image cached on nodes** (`IfNotPresent` pull policy) | Node had old `latest` image from earlier deploy | `kubectl patch deployment` with `imagePullPolicy: Always`. Rebuilt with `--no-cache` and pushed fresh `latest` |
| 10 | **Solution cards empty initially** | 48 test commands ingested by old image (no exitCode field) | Re-ingested failed commands with new image → exitCodes stored correctly |
| 11 | **Helm upgrade re-created disabled components** | Edit replaced block that included `dex.enabled: false` | Added settings back to values.yaml |
| 12 | **Helm upgrade got stuck Pending** | Too many changes at once — StatefulSet controller couldn't reconcile | Deleted old ReplicaSets manually, ran clean upgrade |

---

## Trade-offs / Decisions (Day 16)

| Decision | Why | Trade-off |
|----------|-----|-----------|
| Disabled dex + notifications in ArgoCD | Free pod slots on t3.small | No SSO, no Slack alerts in dev |
| Reduced ArgoCD resource requests (controller 256Mi, others 128Mi) | Fit everything on 2 nodes | Performance deg if cluster gets busy |
| Use `values-dev.yaml` initially, then switch to `values-staging.yaml` | Start minimal, add LB when needed | Must update Application YAML to switch |
| `imagePullPolicy: Always` for dev | Ensures fresh image every deploy | Slower pod startup (pulls every time) |
| Built `docker build --no-cache` | Docker cache was using stale layers | Slower build (5 min instead of 30s) |

---

## ArgoCD Dashboard Access

### Via LoadBalancer (preferred)
```
URL:        http://aa335e8d179da4eb7b1035e630ff0e41-1249820149.ap-south-1.elb.amazonaws.com
Username:   admin
Password:   Jzl-KzKg4AY0gNMG
```

### Via Port-Forward (if LB not accessible)
```bash
kubectl port-forward -n argocd svc/argocd-server 9090:80
# → http://localhost:9090
```

### What You Can Do in the UI
1. **Applications** → see notes-buddy, sync status (green = healthy)
2. **Click the app** → see all K8s resources it manages
3. **APP DETAILS** → `SYNC` button to force sync, `REFRESH` to re-read Git
4. **DIFF** tab → shows differences between Git and cluster
5. **HISTORY** → revision timeline, rollback to any version
6. **Settings** → repositories, projects, clusters

---

## ArgoCD Auto-Sync Confirmation

```
You edit helm/notes-buddy/values-dev.yaml
  → git add, git commit, git push to main
  → ArgoCD polls GitHub (default: 3 min interval)
  → Detects drift: "Git has different values than cluster"
  → Auto-syncs: applies the change to EKS
  → If drift was manual (kubectl edit), SelfHeal reverts it
```

---

## Current Cluster State (End of Day 16)

```
EKS:          2 t3.small nodes, K8s 1.31
Terraform:    30 resources, S3 state + DynamoDB locks
ArgoCD:       5 pods (dex + notifications disabled), v3.4.5
App:          Notes Buddy + PostgreSQL (via Helm staging profile)
URL:          http://a4222470eaec245a29c7720b811fb836-1696657361.ap-south-1.elb.amazonaws.com
Features:     Search, Solutions, Tags, Categories, Ingestion, HPA
```

---

## Phase 3: Post-Deploy Troubleshooting (Same Session)

After ArgoCD was Synced + Healthy, several issues emerged when the user tested real ingestion.

### Problem 1: ArgoCD OutOfSync — PVC Resize Error

**Symptom:** ArgoCD showed `OutOfSync | Degraded`. Error: "persistentvolumeclaims 'notes-buddy-postgres' is forbidden: only dynamically provisioned pvc can be resized and the storageclass that provisions the pvc must support resize"

**Root cause:** `values-staging.yaml` had `persistence.size: 5Gi` but the running PVC was created at `1Gi` (from default values). The `gp2` storage class has `allowVolumeExpansion: false`, so ArgoCD kept failing to patch the PVC.

**Fix:**
```bash
# Changed values-staging.yaml: 5Gi → 1Gi to match running PVC
# Pushed to GitHub → ArgoCD auto-synced
```

**Why gp2 doesn't support resize:** The `gp2` StorageClass was created by EKS with `allowVolumeExpansion: false`. The in-tree `kubernetes.io/aws-ebs` provisioner doesn't support volume expansion. EBS CSI driver with a custom StorageClass would support it.

### Problem 2: Stale ReplicaSets + Node Capacity Deadlock

**Symptom:** Rolling update created a new RS pod but it stayed Pending. Error: `0/2 nodes are available: 2 Too many pods`.

**Root cause:** Three layers:
1. Previous manual `kubectl patch deployment` had set `imagePullPolicy: Always`, creating RS `596fdffb8d`.
2. ArgoCD synced deployment back to `IfNotPresent` (git state), creating new RS `7d96ff7c5d`.
3. Both t3.small nodes at 11/11 pod capacity — no room for the new RS pod.

Deployment strategy: `rollingUpdate.maxSurge: 1, maxUnavailable: 0` — creates new pod before killing old ones, but with no capacity, the new pod stays Pending forever.

**Fix (multi-step):**
1. Set `image.pullPolicy: Always` in `values-staging.yaml` → pushed to git → matches running RS
2. Scaled old RS (`596fdffb8d`) to 0 → freed 2 pod slots
3. New RS pods scheduled and became Ready
4. Deleted stale RSes (`7d96ff7c5d`, `9b54f8d4b`, `54576d8ccb`)

### Problem 3: PVC Stuck Terminating

**Symptom:** After `kubectl delete pvc`, the PVC stayed in `Terminating` status. New PVC couldn't be created.

**Root cause:** PVC had a finalizer from the running Postgres pod (volume still in use). Force-delete with `--force --grace-period=0` didn't work — PV still existed.

**Fix:**
```bash
# Remove finalizer from stuck PVC
kubectl patch pvc -n notes-buddy notes-buddy-postgres -p '{"metadata":{"finalizers":[]}}' --type=merge

# Delete old PV that was stuck in Released state
kubectl delete pv pvc-c525e09b-e823-43c2-87d0-9be3e85c2ab8
```

After PV deletion, new PVC was provisioned by EBS CSI and Postgres pod was recreated with fresh storage.

### Problem 4: Database Tables Missing After PVC Recreation

**Symptom:** API returned 500: `ERROR: relation "command" does not exist`.

**Root cause:** New PVC was empty. Postgres fresh start → no tables. Hibernate `ddl-auto=update` creates tables on app startup, but the app connected to Postgres before the tables were needed. The error only appeared when an API call triggered a query.

**Fix:** `kubectl rollout restart deployment notes-buddy-app -n notes-buddy` — app restarted, Hibernate detected missing tables and created them via `ddl-auto=update`.

### Problem 5: Rolling Restart Caused Same Capacity Deadlock

**Symptom:** `kubectl rollout restart` created another new RS — had to clean up again.

**Fix:** Scaled old app RS to 0, which deleted the running pods. New RS with updated template then had capacity to schedule its pods.

### Problem 6: `.bashrc` Ingestion Not Working

**Symptom:** User updated `NOTES_BUDDY_URL` in `.bashrc` but commands still didn't appear on dashboard.

**Root cause:** The `log_command()` function had the curl POST lines commented out with `# cluster down, this will just fail quietly in background`. Only the local file write was active.

**Fix:** User uncommented the curl block and added `--data-urlencode` params for `timestamp`, `exitCode`, and `repoName`.

### Problem 7: Seed Data Lost After PVC Recreate

**Symptom:** All 48 test commands were gone after the new PVC provisioned.

**Fix:** Re-seeded with `docs/seed-data.sh` — 46 commands across 2 days (July 25-26) with timestamps spread across realistic working hours.

### Commits Pushed (Post-Deploy Fixes)
```bash
89690d2 fix: match postgres PVC size to running state (1Gi) to fix ArgoCD sync error
2f4be58 fix: set imagePullPolicy=Always in staging to match running state
```

### Lessons Learned

1. **Volume expansion requires StorageClass support.** `gp2` (in-tree `kubernetes.io/aws-ebs`) doesn't support it. EBS CSI driver + custom StorageClass with `allowVolumeExpansion: true` would allow PVC resize without recreation.

2. **t3.small pod limit (11) is a hard constraint.** On 2 nodes (22 total pods), there's zero room for surge during rolling updates. Either: (a) use `maxSurge: 0` and `maxUnavailable: 1` to avoid the deadlock, or (b) use bigger nodes.

3. **SelfHeal is powerful but painful when running state conflicts with Git.** Manual patches (imagePullPolicy) get reverted. If the running state is correct, the fix is to update Git, not fight SelfHeal.

4. **PVC Terminating with finalizers** — force-delete via `kubectl patch pvc -p '{"metadata":{"finalizers":[]}}'` is the escape hatch.

5. **`ddl-auto=update` is reactive, not proactive.** Tables are created at startup, but if the app starts before Postgres is ready, schema creation silently fails. Restart fixes it.

6. **Ingestion pipeline has 4 failure points:** (a) `.bashrc` function defined, (b) URL uncommented, (c) curl params correct, (d) network reachable. Each can silently break the pipeline.

### Final State
```
ArgoCD:      Synced | Healthy
App URL:     http://a4222470eaec245a29c7720b811fb836-1696657361.ap-south-1.elb.amazonaws.com
ArgoCD URL:  http://aa335e8d179da4eb7b1035e630ff0e41-1249820149.ap-south-1.elb.amazonaws.com
Data:        46 commands across 2 days (July 25-26)
Seed script: docs/seed-data.sh (re-runnable)
Ingestion:   Live — user's terminal commands flowing in
```

### Key Files
- `helm/argocd/values.yaml` — ArgoCD config (LoadBalancer, resource limits, dex disabled)
- `argocd/apps/notes-buddy.yaml` — Application CRD (points to `helm/notes-buddy` with `values-staging.yaml`)
- `helm/notes-buddy/values-staging.yaml` — Staging profile with `pullPolicy: Always` + `persistence.size: 1Gi`
- `docs/seed-data.sh` — Re-seed script (46 commands, 2 days)
- `docs/COMMANDS.md` — All application commands reference
- `docs/COMMANDS_DAYWISE.md` — Day-wise implementation commands
