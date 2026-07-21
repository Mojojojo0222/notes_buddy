# Days 9-10: Terraform IaC + GitHub Actions CI/CD

## What We Built This Session

### Day 9 — Terraform Infrastructure as Code
Replaced all manual `eksctl` + `aws cli` with **28 Terraform resources** across 3 modules.

```
terraform/
├── main.tf              # Root — calls all modules + GitHub OIDC resources
├── variables.tf         # cluster_name, instance_type, node counts
├── outputs.tf           # cluster_endpoint, ecr_repository_url, kubeconfig_command
├── versions.tf          # AWS 5.x, TLS 4.x, S3 backend + DynamoDB locking
└── modules/
    ├── vpc/             # VPC (192.168.0.0/16) + 2 public subnets + IGW + route table
    ├── eks/             # IAM (cluster + node + IRSA) + cluster + node group + OIDC + addons
    └── ecr/             # ECR repo + lifecycle policy (keep last 10 images)
```

**What each module creates:**
| Module | Resources | Purpose |
|--------|-----------|---------|
| VPC | 6 | VPC, IGW, 2 subnets, route table, 2 route table assocs |
| EKS | 16 | 3 IAM roles, 8 policy attachments, cluster, node group, OIDC, 2 addons |
| ECR | 2 | Repository + lifecycle policy |
| Root | 4 | GitHub OIDC provider, IAM role, 2 inline policies (ecr_push, eks_describe) |

### Day 10 — GitHub Actions CI/CD Pipeline
Every push to `main` automatically:
1. Builds Docker image → 2. Pushes to ECR → 3. Deploys to EKS via rolling update

**No static AWS keys.** Authentication uses OIDC — GitHub Actions assumes an IAM role directly via short-lived tokens.

---

## End-to-End Architecture

```
Your Terminal (Git Bash)
    │ PROMPT_COMMAND → ~/.notes_buddy_log (local backup)
    │ curl --data-urlencode POST → EKS /ingest (real-time)
    ▼
┌─────────────────────────────────────────────────┐
│              Amazon EKS (ap-south-1)             │
│                                                  │
│  ┌─────────────────┐    ┌────────────────────┐  │
│  │  ALB (port 80)   │───▶│  Notes Buddy App   │  │
│  │  LoadBalancer    │    │  :9098             │  │
│  └─────────────────┘    │  /actuator/health  │  │
│                          │  /commands/all     │  │
│                          │  /summary          │  │
│                          │  /sessions         │  │
│                          │  POST /ingest      │  │
│                          └───────┬────────────┘  │
│                                  │                │
│                          ┌───────▼────────────┐  │
│                          │  PostgreSQL 16      │  │
│                          │  EBS gp2 1Gi        │  │
│                          │  fsGroup: 999       │  │
│                          │  subPath: pgdata    │  │
│                          └────────────────────┘  │
│                                                  │
│  ┌────────────────────────────────────────────┐  │
│  │  EBS CSI (IRSA)  │  CloudWatch Agent       │  │
│  │  HPA (CPU 50%)   │  fluent-bit             │  │
│  └────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
              ▲
              │ OIDC (no keys)
┌─────────────────────────────────────────────────┐
│            GitHub Actions                        │
│  Push main → Build → Push ECR → kubectl set     │
│  IAM role: notes-buddy-github-actions-role       │
└─────────────────────────────────────────────────┘
              ▲
              │ terraform apply
┌─────────────────────────────────────────────────┐
│            Terraform (S3 remote state)           │
│  28 resources, DynamoDB locking                  │
│  State: s3://notes-buddy-terraform-state-*       │
└─────────────────────────────────────────────────┘
```

---

## Problems Hit and Fixed

### Problem 1: Terraform Apply Timed Out (15 min)
**Error:** Process timed out. EBS CSI addon was still creating.

**Root cause:** EBS CSI addon installation takes 4-5 minutes on first create. The 15-min timeout was hit.

**Fix:** Ran `terraform apply` again. It showed "already exists" for ECR repo and EBS CSI addon. Fixed with `terraform import` to bring them into state.

**Lesson:** Always check `terraform state list` after a timeout. Resources might have been created but not tracked. Import them rather than destroying and recreating.

### Problem 2: State Lock Contention
**Error:** `Error acquiring the state lock` when running two `terraform import` commands in parallel.

**Root cause:** Terraform locks the state file during write operations. Two concurrent processes can't both write.

**Fix:** Used `-lock=false` on the second import command. The DynamoDB lock table we set up (`notes-buddy-terraform-locks`) prevents this in CI/CD.

**Lesson:** Never disable locking in automated pipelines. For emergency manual ops, `-lock=false` is acceptable if you know no other process is running.

### Problem 3: EBS CSI CrashLoopBackOff (×2)
**Error 1:** `no EC2 IMDS role found`
**Error 2:** `not authorized to perform ec2:DescribeAvailabilityZones`

**Root cause (layer 1):** EBS CSI addon installed without IRSA — pods tried IMDS (Instance Metadata Service), which failed because EKS nodes don't have EBS CSI permissions on the instance profile (by design — AWS moved to IRSA).

**Root cause (layer 2):** After setting up IRSA with `AmazonEBSCSIDriverPolicy`, the policy hadn't propagated yet. The pod assumed the correct role but the permissions weren't active — took 15-30 seconds.

**Fix:**
```bash
# 1. Create IAM role with trust policy scoped to ebs-csi-controller-sa
aws iam create-role --role-name notes-buddy-ebs-csi-role ...
aws iam attach-role-policy --role-name notes-buddy-ebs-csi-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy

# 2. Annotate the service account
kubectl annotate sa ebs-csi-controller-sa -n kube-system \
  eks.amazonaws.com/role-arn=arn:aws:iam::083777493383:role/notes-buddy-ebs-csi-role

# 3. Restart the deployment
kubectl rollout restart deployment ebs-csi-controller -n kube-system

# 4. Wait 30s, then check
kubectl get pods -n kube-system | grep ebs-csi
```

**Lesson:** Error messages tell you which layer is failing:
- `no EC2 IMDS role found` = **Authentication** problem (can't get credentials at all)
- `not authorized` = **Authorization** problem (got credentials but missing permissions)
- The shift from one to the other means your fix is working — you just moved to the next layer.

### Problem 4: GitHub Actions OIDC — Missing id-token Permission
**Error:** `unable to get ID token`

**Root cause:** GitHub Actions defaults `permissions.id-token` to `read`. OIDC token exchange requires `write`.

**Fix:** Added to workflow:
```yaml
permissions:
  id-token: write    # REQUIRED for OIDC
  contents: read
```

**Lesson:** This is a deliberate GitHub security decision — prevents workflows from getting identity tokens unless they explicitly ask. Always remember `id-token: write` when using OIDC.

### Problem 5: OIDC Trust Policy — StringEquals vs StringLike
**Error:** No error — the workflow authenticated but only worked for main branch pushes, not `workflow_dispatch` or tags.

**Root cause:** `StringEquals` requires exact match. `sub` claim is `repo:owner/name:ref:refs/heads/main` for main branch, but different for other triggers.

**Fix:** Changed to `StringLike` with wildcard:
```json
"StringLike": {
  "token.actions.githubusercontent.com:sub": "repo:Mojojojo0222/notes_buddy:*"
}
```

**Lesson:** `StringLike` with `*` wildcard allows any branch/tag/PR. For production, restrict to specific branches with `ref:refs/heads/main`.

### Problem 6: kubectl "You must be logged in" on CI/CD
**Error:**
```
kubectl set image deployment/notes-buddy \
  error: You must be logged in to the server
  (the server has asked for the client to provide credentials)
```

**Root cause:** The IAM role `notes-buddy-github-actions-role` was authenticated in AWS (passed `aws eks update-kubeconfig`) but NOT authorized in EKS. EKS has two auth layers:
1. **AWS IAM** — signs the request (OIDC role handles this ✅)
2. **aws-auth ConfigMap** — maps IAM principals to K8s users/groups ❌ missing

**Fix (3 components):**

**Component A — Kubernetes Role** (what you can do):
```yaml
kind: Role
metadata:
  name: github-actions-deployer
  namespace: notes-buddy
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch", "update", "patch"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments/status"]
  verbs: ["get"]
```

**Component B — RoleBinding** (who gets access):
```yaml
kind: RoleBinding
metadata:
  name: github-actions-deployer-binding
  namespace: notes-buddy
subjects:
- kind: Group
  name: notes-buddy-deployer
roleRef:
  kind: Role
  name: github-actions-deployer
```

**Component C — aws-auth ConfigMap** (bridge between IAM and K8s):
```yaml
data:
  mapRoles: |
    - rolearn: arn:aws:iam::083777493383:role/notes-buddy-node-role
      groups: [system:bootstrappers, system:nodes]
    - rolearn: arn:aws:iam::083777493383:role/notes-buddy-github-actions-role
      username: github-actions-deployer
      groups: [notes-buddy-deployer]    # ← matches RoleBinding
```

**The key insight:** `aws eks update-kubeconfig` only means you can *reach* the API server. The `aws-auth` ConfigMap determines what you can *do* once you get there.

### Problem 7: Windows /tmp Path Not Available
**Error:** `Unable to load paramfile file:///tmp/...` when using `aws iam create-role --assume-role-policy-document file:///tmp/policy.json`

**Root cause:** Git Bash on Windows doesn't have `/tmp` (or it's a different path than Linux expects).

**Fix:** Inline the JSON directly in the command instead of using `file://`:
```bash
aws iam create-role \
  --role-name notes-buddy-ebs-csi-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Federated": "arn:aws:iam::ACCOUNT:oidc-provider/..."},
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {...}
    }]
  }'
```

**Lesson:** Windows Git Bash doesn't have Linux-style `/tmp`. Use inline JSON or a Windows path like `C:/Users/...`.

### Problem 8: PostgreSQL NOTICE Messages in CI/CD Output
**Error (cosmetic):** `NOTICE: relation "command" already exists, skipping`
**Meaning:** Hibernate's `ddl-auto=update` runs on every startup and tries to create tables that already exist. These are NOTICE-level messages, not errors.

**Fix:** Ignore them. They're harmless. The app works fine. Only worry about ERROR or FATAL messages.

**Lesson:** Not every log message needs fixing. Learn to distinguish between INFO/NOTICE (informational), WARN (something is suboptimal but working), and ERROR (something broke).

### Problem 9: EKS Auth Mode — Access Entries Not Available
**Error:** `InvalidRequestException: The cluster's authentication mode must be set to [API, API_AND_CONFIG_MAP]`

**Root cause:** The cluster was created with the default `CONFIG_MAP` auth mode. Access Entries (the modern auth mechanism) require `API_AND_CONFIG_MAP` mode.

**Fix:** Stuck with `aws-auth` ConfigMap approach for this cluster. Changing auth mode requires recreating the cluster. Access Entries would be used for new clusters going forward.

**Trade-off:** The `aws-auth` ConfigMap approach is older but battle-tested. Access Entries simplify management but require cluster recreation to enable. For this project, `aws-auth` is fine.

---

## IRSA Deep Dive (IAM Roles for Service Accounts)

### Why IRSA Matters
Before IRSA, pods inherited the IAM permissions of the node's instance profile. Every pod on the same node had the same AWS permissions — zero isolation. IRSA solved this by letting each pod assume a dedicated IAM role.

### How It Works
```
Pod (ebs-csi-controller)
    │
    ├── 1. Pod has env var: AWS_WEB_IDENTITY_TOKEN_FILE
    │      (mounted from projected volume by OIDC provider)
    │
    ├── 2. Reads token file → sends to STS:AssumeRoleWithWebIdentity
    │      Token is signed by EKS OIDC issuer
    │      Contains: service account name + namespace
    │
    ├── 3. STS verifies token against OIDC provider
    │      Checks: token signature, audience (sts.amazonaws.com)
    │
    ├── 4. If valid, STS returns temporary AWS credentials
    │      Scoped to the IAM role's permissions
    │
    └── 5. Pod uses these credentials for all AWS API calls
```

### What We Set Up
| Component | Value |
|-----------|-------|
| IAM Role | `notes-buddy-ebs-csi-role` |
| Policy | `AmazonEBSCSIDriverPolicy` (DescribeAvailabilityZones, CreateVolume, AttachVolume, etc.) |
| Service Account | `ebs-csi-controller-sa` in `kube-system` |
| Annotation | `eks.amazonaws.com/role-arn=arn:aws:iam::083777493383:role/notes-buddy-ebs-csi-role` |
| OIDC Provider | Created by Terraform EKS module |

### IRSA Trust Policy
```json
{
  "Effect": "Allow",
  "Principal": {
    "Federated": "arn:aws:iam::083777493383:oidc-provider/oidc.eks.ap-south-1.amazonaws.com/id/E4AC7338DB77B2A44EFCE9AD18B0AE26"
  },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "oidc.eks.ap-south-1.amazonaws.com/id/E4AC7338DB77B2A44EFCE9AD18B0AE26:aud": "sts.amazonaws.com",
      "oidc.eks.ap-south-1.amazonaws.com/id/E4AC7338DB77B2A44EFCE9AD18B0AE26:sub": "system:serviceaccount:kube-system:ebs-csi-controller-sa"
    }
  }
}
```

**The `sub` condition** is the security boundary: `system:serviceaccount:kube-system:ebs-csi-controller-sa` — only the EBS CSI driver's service account in kube-system can assume this role. No other pod, not even in the same namespace, can use it.

---

## Remote Terraform State (S3 + DynamoDB)

### Why Remote State
Local `terraform.tfstate` is fine for one person. For team collaboration (or disaster recovery), state must be stored remotely.

### What We Set Up
```hcl
backend "s3" {
  bucket         = "notes-buddy-terraform-state-083777493383"
  key            = "notes-buddy/terraform.tfstate"
  region         = "ap-south-1"
  dynamodb_table = "notes-buddy-terraform-locks"
  encrypt        = true
}
```

| Component | Purpose |
|-----------|---------|
| **S3 bucket** | Stores the state file. Versioning enabled — every change is tracked |
| **SSE-AES256** | Encryption at rest. State files contain secrets (DB passwords, IPs) |
| **Public access block** | No one can read the state file except authenticated AWS principals |
| **DynamoDB table** | State locking — prevents two people from running `terraform apply` simultaneously |
| **PAY_PER_REQUEST** | Costs pennies per month. No need to provision read/write capacity |

### Migration
```bash
# Before: local terraform.tfstate
# After: S3 backend
terraform init -migrate-state -force-copy
```

Terraform copies the local state to S3 on `init`. From that point, every `plan` and `apply` reads/writes to S3.

---

## Docs Created This Session

| File | Lines | What It Covers |
|------|-------|----------------|
| `docs/day10/README.md` | ~400 | This file — full Day 9+10 documentation |
| `docs/day10/CI-CD-FIX-GUIDE.md` | 331 | EKS auth fix: aws-auth + RBAC + troubleshooting |
| `docs/day9/README.md` | ~150 | Day 9 Terraform deep-dive |
| `docs/RUNBOOK.md` | 564 | Complete run guide: local/Docker/EKS + 13 troubleshooting scenarios |
| `docs/INTERVIEW_STORY.md` | 428 | Full project story + interview answers for every technology |

---

## State of the Project After Days 9-10

```
App:           Spring Boot + PostgreSQL
Container:     Docker + ECR (multi-stage, ~180MB)
Orchestration: Kubernetes (EKS 1.31, 2 t3.small nodes)
Autoscaling:   HPA (CPU 50%, 1-4 replicas)
Observability: CloudWatch Container Insights
IaC:           Terraform (28 resources, S3 state + DynamoDB locks)
CI/CD:         GitHub Actions (OIDC auth, build-push-deploy)
Security:      IRSA per service account, OIDC for CI/CD
DNS:           Route53 (via ALB — ac668cb9220164bd1ad26559418741a4-749616980.ap-south-1.elb.amazonaws.com)
```

### Active URLs
- **Dashboard:** http://ac668cb9220164bd1ad26559418741a4-749616980.ap-south-1.elb.amazonaws.com
- **Health:** http://ac668cb9220164bd1ad26559418741a4-749616980.ap-south-1.elb.amazonaws.com/actuator/health
- **ECR:** 083777493383.dkr.ecr.ap-south-1.amazonaws.com/notes-buddy

### Terraform Resources: 28
```
module.vpc:        6
module.eks:        16
module.ecr:        2
root (GitHub OIDC): 4
```

### Next Up
| Day | Topic | What You'll Learn |
|-----|-------|-------------------|
| 11 | **ArgoCD** | GitOps — Git as source of truth, sync policies, rollback = git revert |
| 12 | **Karpenter** | Node autoscaling — provision nodes in 30s, spot instances (70% cheaper) |
