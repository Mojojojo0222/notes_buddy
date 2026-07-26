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

### Key Files
- `helm/argocd/values.yaml` — ArgoCD config (LoadBalancer, resource limits, dex disabled)
- `argocd/apps/notes-buddy.yaml` — Application CRD (points to `helm/notes-buddy` with `values-staging.yaml`)
- `docs/COMMANDS.md` — All application commands reference
- `docs/COMMANDS_DAYWISE.md` — Day-wise implementation commands
