# Day 10 — GitHub Actions CI/CD + OIDC Authentication

## What We Built
A fully automated CI/CD pipeline that runs on every push to `main`:
1. Build Docker image
2. Push to Amazon ECR
3. Deploy to EKS via rolling update

**No static AWS keys stored anywhere.** Authentication uses OIDC (OpenID Connect) — GitHub Actions assumes an IAM role directly using short-lived tokens.

---

## Architecture

```
Git Push to main
    │
    ▼
GitHub Actions Workflow (.github/workflows/deploy.yml)
    │
    ├── 1. Checkout code
    ├── 2. Configure AWS credentials via OIDC
    │      ├── GitHub issues ID token
    │      ├── AWS verifies token against OIDC provider
    │      └── GitHub Actions assumes IAM role (notes-buddy-github-actions-role)
    ├── 3. Login to ECR
    ├── 4. Build Docker image (tagged with commit SHA + latest)
    ├── 5. Push image to ECR
    ├── 6. Update kubeconfig (aws eks update-kubeconfig)
    ├── 7. kubectl set image (rolling update)
    └── 8. kubectl rollout status (verify deployment)
```

---

## Components Created

### 1. GitHub OIDC Provider (AWS IAM Identity Provider)
- URL: `https://token.actions.githubusercontent.com`
- Audience: `sts.amazonaws.com`
- Purpose: Allows AWS to trust tokens issued by GitHub Actions

### 2. IAM Role: `notes-buddy-github-actions-role`
**Trust Policy** — who can assume this role:
```json
{
  "Effect": "Allow",
  "Principal": {
    "Federated": "arn:aws:iam::083777493383:oidc-provider/token.actions.githubusercontent.com"
  },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
    },
    "StringLike": {
      "token.actions.githubusercontent.com:sub": "repo:Mojojojo0222/notes_buddy:*"
    }
  }
}
```
- `StringLike` with `*` — allows any branch, tag, or PR to deploy
- For production: restrict to `ref:refs:heads/main` instead of `*`

**Permissions (two inline policies):**
| Policy | Actions | Why |
|--------|---------|-----|
| `ecr_push` | `ecr:GetAuthorizationToken`, `BatchCheckLayerAvailability`, `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`, `PutImage`, `BatchGetImage`, `DescribeRepositories`, `GetRepositoryPolicy`, `ListImages` | Push Docker images to ECR |
| `eks_describe` | `eks:DescribeCluster`, `eks:ListClusters` | Generate kubeconfig for kubectl |

### 3. Workflow File (`.github/workflows/deploy.yml`)
```yaml
name: Deploy to EKS
on:
  push:
    branches: [main]
  workflow_dispatch:     # manual trigger from GitHub UI

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write    # REQUIRED for OIDC
      contents: read
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::083777493383:role/notes-buddy-github-actions-role
          aws-region: ap-south-1
      - uses: aws-actions/amazon-ecr-login@v2
      - run: docker build -t $REGISTRY/$REPO:$SHA .
      - run: docker push $REGISTRY/$REPO:$SHA
      - run: aws eks update-kubeconfig --name notes-buddy
      - run: kubectl set image deployment/notes-buddy -n notes-buddy notes-buddy=$REGISTRY/$REPO:$SHA
      - run: kubectl rollout status deployment/notes-buddy -n notes-buddy --timeout=120s
```

---

## Problems Hit and Fixed

### Problem 1: OIDC `sub` Condition — `StringEquals` vs `StringLike`
**Issue:** Initial attempt used `StringEquals` with `repo:owner/name:ref:refs/heads/main` — this only allowed pushes to `main` branch. But we also wanted `workflow_dispatch` and future tag-based deployments.

**Fix:** Changed to `StringLike` with value `repo:Mojojojo0222/notes_buddy:*`. The `*` matches any branch, tag, or pull request event.

**Interview takeaway:** The `sub` claim in the OIDC token contains the full GitHub context: `repo:owner/name:ref:refs/heads/main` for branch pushes. Use `StringLike` with appropriate wildcards to control access at the right granularity.

### Problem 2: Missing `id-token: write` Permission
**Issue:** The workflow failed with "unable to get ID token" error.

**Root cause:** GitHub Actions workflows default to `permissions: read` for `id-token`. OIDC requires `write` permission to request an identity token.

**Fix:** Added `permissions: id-token: write` at the job level.

**Interview takeaway:** This is a common gotcha. Without explicit `id-token: write`, GitHub won't issue the OIDC token that AWS needs to authenticate the workflow.

### Problem 3: Terraform State Lock Contention
**Issue:** Two `terraform import` commands ran in parallel and one failed with "state lock" error.

**Fix:** Used `-lock=false` on the second import. The lock is held by the first process that acquires it — subsequent processes must wait or skip the lock.

**Interview takeaway:** Terraform state locking prevents concurrent modifications. In production, DynamoDB is used for locking (we set this up). Never disable locking in CI/CD pipelines — only for emergency manual operations.

### Problem 4: EBS CSI CrashLoopBackOff (Legacy from Terraform setup)
**Issue:** EBS CSI driver pods crashed repeatedly because they had no IAM permissions to call EC2 APIs.

**Root cause:** The EBS CSI addon was installed without IRSA — pods tried to use IMDS (Instance Metadata Service) which failed, then fell back to the IRSA annotation which hadn't been set up yet.

**Fix (three layers):**
1. Created IAM role `notes-buddy-ebs-csi-role` with `AmazonEBSCSIDriverPolicy`
2. Annotated `ebs-csi-controller-sa` service account with `eks.amazonaws.com/role-arn`
3. Added the role to Terraform EKS module so it's permanent

**Key insight:** The error message changed from "no EC2 IMDS role found" to "not authorized to perform ec2:DescribeAvailabilityZones" after IRSA was working — this told us IRSA was authenticating correctly but the policy hadn't propagated yet (takes 15-30 seconds).

---

## Interview Questions & Answers

### Q: "How does your CI/CD pipeline work?"
**A:** "Every push to main triggers a GitHub Actions workflow. It builds a Docker image, tags it with the commit SHA, pushes to ECR, and runs `kubectl set image` to trigger a rolling update on EKS. No manual steps. The whole pipeline takes about 3-4 minutes."

### Q: "How do you handle AWS credentials in CI/CD?"
**A:** "We use OIDC — no static keys. GitHub Actions requests a short-lived identity token, exchanges it for AWS credentials via STS AssumeRoleWithWebIdentity, and the role's trust policy restricts which repo/branch can assume it. Zero credential rotation overhead."

### Q: "What's the difference between OIDC and static access keys?"
**A:**
| Aspect | OIDC | Static Keys |
|--------|------|-------------|
| Credential lifetime | Minutes (per workflow run) | Months/years (until rotated) |
| Rotation | Automatic (every run) | Manual (easy to forget) |
| Leak impact | Low (expires fast) | Critical (full access until revoked) |
| Setup complexity | One-time (IAM provider + role) | Simple (generate + store in secrets) |
| Audit trail | Full (which repo, branch, run) | Limited (just the key ID) |

### Q: "How do you handle deployment failures?"
**A:** "The workflow runs `kubectl rollout status --timeout=120s` after the deployment. If pods don't become ready within 2 minutes, the workflow fails and sends a notification. Rollback is manual — `kubectl rollout undo deployment/notes-buddy -n notes-buddy` to go back to the previous revision, or `kubectl set image` to a known-good image tag."

### Q: "What's in your Docker image and how do you version it?"
**A:** "We use multi-stage Docker builds. The `pom.xml` is copied first to cache Maven dependencies. The image is tagged with the Git commit SHA (unique, traceable) and `latest` (convenient for dev). ECR lifecycle policy keeps only the last 10 images to save storage."

---

## Key Learnings

### GitHub Actions + AWS OIDC
1. **OIDC > static keys** — Every company interview asks about secrets management. OIDC is the modern answer.
2. **`permissions: id-token: write`** is mandatory — GitHub won't issue tokens without it.
3. **`workflow_dispatch`** trigger — allows manual runs from GitHub UI. Useful for debugging and one-off deployments.
4. **`aws-actions/configure-aws-credentials@v4`** handles the entire OIDC exchange — just pass the role ARN.
5. **`amazon-ecr-login@v2`** wraps `docker login` with the ECR registry URL automatically.

### Terraform + IAM
1. **IAM roles can have multiple inline policies** — separate ECR and EKS policies for least privilege.
2. **OIDC provider is global (IAM)** — created once, available across all regions.
3. **GitHub's OIDC thumbprint** is `1c58a3a8518e8759bf075b76b750d4f2df264fcd` — stable, rarely changes.

### Kubernetes Deployments
1. **`kubectl set image`** updates the deployment's container image and triggers a rolling update — doesn't restart the pod, just updates the spec.
2. **`kubectl rollout status`** blocks until the deployment is complete or times out — essential for CI/CD verification.
3. **Rolling update strategy** — K8s replaces pods one at a time, ensuring zero downtime if health probes are configured.

---

## Status
- CI/CD pipeline live on GitHub
- Every push to main → build → push → deploy automatically
- OIDC authentication — no hardcoded keys
- Terraform managing the OIDC provider + IAM role (4 resources)
- Next: ArgoCD (GitOps — Day 11)
