# DevOps Mastery: Concepts from Days 9-12

**Target:** 2-5 year experienced DevOps/SRE Engineer interviews  
**Stack:** Terraform + AWS IAM + EKS + GitHub Actions + Kubernetes RBAC + Spring Data JPA  
**Project:** Notes Buddy — real production deployment on AWS EKS

---

## 1. Terraform — Infrastructure as Code

### 1.1 Core Concepts

#### Desired State vs Imperative
- **Terraform = Declarative:** You describe WHAT you want (a VPC with CIDR 192.168.0.0/16), Terraform figures out HOW
- **Ansible/CloudFormation = Procedural:** You describe the steps (create VPC, then create subnet, then attach IGW)
- Why it matters: Terraform always converges to the desired state. If someone manually deletes a subnet, next `terraform apply` recreates it. In imperative tools, the missing subnet stays missing until you add a step for it.

#### State File (`terraform.tfstate`)
- **What it is:** A JSON file that maps your Terraform resources to real-world cloud resources
- **What it contains:** Resource IDs, attributes, dependencies, metadata
- **Why it exists:** Terraform needs to know what it already created. When you run `terraform apply`, it:
  1. Reads state → knows resource X exists with ID `vpc-abc123`
  2. Reads config → knows you want CIDR `192.168.0.0/16`
  3. Reads real infra → calls `aws ec2 describe-vpcs`
  4. Diffs: real vs config → decides create/update/delete
- **Sensitive data:** State contains plaintext secrets (DB passwords, private keys). Must be encrypted at rest.
- **Never edit manually:** Direct state edits are a last resort. Use `terraform state mv / rm / import` instead.

#### State Locking
- **Problem:** Two team members run `terraform apply` simultaneously → corrupt state
- **Solution:** Lock mechanism — only one process can write state at a time
- **Local:** File lock (`.terraform.tfstate.lock.info`)
- **Remote:** DynamoDB table (we use `notes-buddy-terraform-locks`)
- **DynamoDB:** Creates an item with `LockID` as primary key. First process writes the lock. Second process tries to write → DynamoDB rejects (duplicate key) → Terraform waits/errors.

#### Remote State (S3 Backend)
```
Local state:   terraform.tfstate on your laptop
Remote state:  s3://bucket-name/path/to/state.tfstate

Why remote:
- Shared: Team sees the same state
- Versioned: Every state change is saved (S3 versioning)
- Disaster recovery: Laptop dies → state is in S3
- CI/CD: Pipeline reads/writes the same state
```

```hcl
backend "s3" {
  bucket         = "notes-buddy-terraform-state-083777493383"
  key            = "notes-buddy/terraform.tfstate"
  region         = "ap-south-1"
  dynamodb_table = "notes-buddy-terraform-locks"
  encrypt        = true
}
```

**Migration:** `terraform init -migrate-state -force-copy` copies local state to S3.

### 1.2 Modules

Modules are **reusable infrastructure components** — same concept as functions in programming.

```
Root module (main.tf)
├── module "vpc"   → vpc_id, subnet_ids (outputs)
├── module "eks"   → cluster_name, cluster_endpoint, oidc_provider_arn (outputs)
└── module "ecr"   → repository_url (outputs)
```

**Module contract:**
- `variables.tf` = input parameters (what the module needs)
- `outputs.tf` = return values (what the module exposes)
- `main.tf` = implementation (what the module creates)

**Why modules at Google/Meta scale:**
- **Single responsibility:** VPC team owns VPC module, Security team owns IAM module
- **Versioning:** Modules are versioned with Git tags. `source = "git::https://github.com/org/terraform-modules//vpc?ref=v1.2.0"`
- **Testing:** Test a module in isolation with `terraform test` (1.6+). Mock AWS API calls.
- **Reusability:** Same VPC module used across dev/staging/prod with different variables

### 1.3 Resource Graph & Dependencies

Terraform builds a **Directed Acyclic Graph (DAG)** of all resources.

```
aws_vpc.main
    │
    ├── aws_subnet.public[0]  ──→ aws_route_table_association.public[0]
    ├── aws_subnet.public[1]  ──→ aws_route_table_association.public[1]
    ├── aws_internet_gateway.main ──→ aws_route_table.public
    │
    └── aws_eks_cluster.main
            │
            ├── aws_eks_node_group.main ──→ aws_eks_addon.ebs_csi
            └── aws_iam_openid_connect_provider.eks ──→ aws_iam_role.ebs_csi
```

**Implicit dependencies:** Terraform detects these automatically (e.g., `subnet_id = aws_subnet.public[0].id` creates a dependency).

**Explicit dependencies (`depends_on`):** Sometimes Terraform can't detect a dependency because it's not in the resource attributes:
```hcl
resource "aws_eks_cluster" "main" {
  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}
```
Without this, Terraform might create the cluster BEFORE the IAM policy is attached. The cluster creation fails because the role doesn't have permissions yet.

**Parallelism:** Terraform creates independent resources in parallel (VPC subnets + ECR repo created simultaneously). Dependent resources wait.

### 1.4 `terraform import`

**When to use:** A resource exists in the cloud but not in Terraform state. Common scenarios:
- Resource was created manually (old eksctl cluster) → want to manage with Terraform
- `terraform apply` timed out after creating the resource but before writing state
- Adopting legacy infrastructure into IaC

```bash
# Import ECR repo into the ecr module
terraform import module.ecr.aws_ecr_repository.main notes-buddy

# Import EBS CSI addon into the eks module
terraform import module.eks.aws_eks_addon.ebs_csi notes-buddy:aws-ebs-csi-driver
```

**ID format:** Each resource has a specific import ID format. Check `terraform import RESOURCE_TYPE.RESOURCE_NAME --help` or the provider docs.

**After import:** Always run `terraform plan` to check for drift between config and real resource.

### 1.5 Terraform vs Other IaC Tools

| Aspect | Terraform | CloudFormation | Pulumi |
|--------|-----------|---------------|--------|
| Language | HCL (DSL) | JSON/YAML | TypeScript, Python, Go, C# |
| State management | Built-in (S3 + DynamoDB) | AWS-managed | Built-in (Cloud) |
| Multi-cloud | AWS, Azure, GCP, etc. | AWS only | AWS, Azure, GCP, etc. |
| Modularity | Modules (first-class) | Nested stacks | Packages (npm/pip) |
| Testing | `terraform test` (1.6+) | cfn-lint | Unit tests in SDK |
| Learning curve | Medium (HCL is simple) | Medium (YAML gets complex) | Steep (need SDK knowledge) |

**Interview answer:** "Terraform over CloudFormation because multi-cloud flexibility and better state management. Pulumi if the team already knows TypeScript — Terraform if you want operational simplicity."

### 1.6 Terraform Best Practices (Production)

1. **Pin provider versions** (`required_providers { aws = "~> 5.0" }`) — never use `latest`
2. **Lock file** (`.terraform.lock.hcl`) — commit to Git for reproducible builds
3. **Remote state** — never use local state beyond Day 1 prototyping
4. **State locking** — always use DynamoDB, never disable in CI/CD
5. **No hardcoded values** — all config in `variables.tf` or `terraform.tfvars`
6. **Sensitive outputs** — mark passwords/keys with `sensitive = true`
7. **Small modules** — each module does one thing. VPC module doesn't create IAM roles
8. **Workspaces or directories** for environments: `terraform/envs/dev`, `terraform/envs/prod`
9. **Plan in PRs** — run `terraform plan` in CI/CD, review output, then apply
10. **Pre-commit hooks** — `terraform fmt`, `terraform validate`, `tflint`

---

## 2. AWS IAM — Identity and Access Management

### 2.1 IAM Architecture

```
Principal (who)         ─→  Policy (what)  ─→  Resource (which)
  │                                               │
  ├── User (person)                               ├── S3 bucket
  ├── Group (team)                                ├── ECR repo
  ├── Role (application)                          ├── EKS cluster
  └── Federated (OIDC/SAML)                      └── EC2 instance
```

**Three types of policies:**
- **AWS managed:** Pre-built by AWS (e.g., `AmazonEKSClusterPolicy`). Can't edit.
- **Customer managed:** You create and manage. Reusable across multiple roles.
- **Inline:** Embedded directly in a role/user. Not reusable. We used inline for GitHub Actions.

**Evaluation logic:**
1. By default, ALL actions are DENIED
2. Explicit ALLOW in identity-based or resource-based policy → allowed
3. Explicit DENY → denied (DENY always wins)
4. If no ALLOW and no DENY → denied (implicit deny)

### 2.2 Trust Policies (When Federation Happens)

A standard IAM policy says "what can this role DO." A trust policy says "WHO can USE this role."

```json
{
  "Effect": "Allow",
  "Principal": {
    "Federated": "arn:aws:iam::ACCOUNT:oidc-provider/token.actions.githubusercontent.com"
  },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
    "StringLike": { "token.actions.githubusercontent.com:sub": "repo:owner/name:*" }
  }
}
```

**Flow:**
1. GitHub Actions requests an OIDC token from `token.actions.githubusercontent.com`
2. Token is a JWT containing claims: `sub`, `aud`, `ref`, `sha`, etc.
3. GitHub sends this token to AWS STS (`sts:AssumeRoleWithWebIdentity`)
4. AWS verifies the token signature against the OIDC provider (the thumbprint)
5. AWS checks the `aud` claim against `client_id_list` in the OIDC provider
6. AWS checks the trust policy conditions (sub matches, aud matches)
7. If all pass → STS returns temporary credentials (AccessKeyId + SecretKey + SessionToken)

**Why `StringLike` and not `StringEquals` for `sub`?**
- `sub` for a main branch push: `repo:owner/name:ref:refs/heads/main`
- `sub` for a tag push: `repo:owner/name:ref:refs/tags/v1.0`
- `sub` for manual workflow_dispatch: `repo:owner/name:ref:refs/heads/main`
- `StringEquals` would need to list every possible branch/tag. `StringLike` with `*` matches all.

### 2.3 Least Privilege with Inline Policies

We split GitHub Actions permissions into **two inline policies** instead of one big policy:

```hcl
# Policy 1: ECR push (tightly scoped to specific actions)
resource "aws_iam_role_policy" "ecr_push" {
  policy = jsonencode({
    Statement = [{
      Effect = "Allow"
      Action = [
        "ecr:GetAuthorizationToken",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:DescribeRepositories",
        "ecr:GetRepositoryPolicy",
        "ecr:ListImages"
      ]
      Resource = "*"
    }]
  })
}

# Policy 2: EKS describe (only what kubectl needs)
resource "aws_iam_role_policy" "eks_describe" {
  policy = jsonencode({
    Statement = [{
      Effect = "Allow"
      Action = ["eks:DescribeCluster", "eks:ListClusters"]
      Resource = "*"
    }]
  })
}
```

**Why not attach AWS managed `AdministratorAccess`?**
- Security: if the OIDC token leaks, attacker can only push images and describe EKS, not delete databases or launch EC2 instances
- Audit: CloudTrail logs show exactly which policy was used
- Compliance: Many orgs prohibit managed policies for cross-account roles

### 2.4 OIDC Provider Setup

```hcl
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = ["1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}
```

**The thumbprint** is the SHA1 fingerprint of the OIDC provider's TLS certificate. It's stable for GitHub — hasn't changed in years. For other OIDC providers, you can fetch it:
```bash
openssl s_client -servername token.actions.githubusercontent.com -connect token.actions.githubusercontent.com:443 | openssl x509 -fingerprint -noout -sha1
```

**The `client_id_list`** is the `aud` (audience) claim that the OIDC token must contain. GitHub Actions uses `sts.amazonaws.com`.

**Note:** The OIDC provider is a **global IAM resource** — not tied to any region. Created once, works across all regions.

### 2.5 IRSA — IAM Roles for Service Accounts

#### The Problem IRSA Solves
Before IRSA (pre-2020):
- EKS nodes had an IAM instance profile with permissions
- Every pod on that node inherited ALL node permissions
- A WordPress pod could delete DynamoDB tables just because the node had DynamoDB permissions
- Zero isolation between pods

#### How IRSA Works (Step by Step)
```
1. OIDC Provider exists
   EKS creates an OIDC issuer URL: oidc.eks.REGION.amazonaws.com/id/CLUSTER_ID
   This is an HTTPS endpoint that serves the OIDC discovery document

2. IAM Role with Trust Policy
   Role trusts the OIDC provider, scoped to a specific service account:
   "sub": "system:serviceaccount:NAMESPACE:SERVICE_ACCOUNT_NAME"

3. Service Account Annotation
   kubectl annotate sa ebs-csi-controller-sa \
     eks.amazonaws.com/role-arn=arn:aws:iam::ACCOUNT:role/ROLE_NAME

4. Mutating Webhook
   EKS runs a mutating admission webhook that:
   a. Detects annotated service accounts
   b. Injects env vars into the pod:
      - AWS_ROLE_ARN = arn:aws:iam::ACCOUNT:role/ROLE_NAME
      - AWS_WEB_IDENTITY_TOKEN_FILE = /var/run/secrets/eks.amazonaws.com/serviceaccount/token
   c. Mounts the projected volume with the OIDC token

5. Pod starts with:
   - The token file (JWT signed by EKS OIDC issuer)
   - The role ARN environment variable
   AWS SDKs automatically use these for credential resolution
```

#### IRSA Trust Policy for EBS CSI
```json
{
  "Condition": {
    "StringEquals": {
      "oidc.eks.ap-south-1.amazonaws.com/id/E4AC7338DB77B2A44EFCE9AD18B0AE26:aud": "sts.amazonaws.com",
      "oidc.eks.ap-south-1.amazonaws.com/id/E4AC7338DB77B2A44EFCE9AD18B0AE26:sub": "system:serviceaccount:kube-system:ebs-csi-controller-sa"
    }
  }
}
```

**Security boundary:** The `sub` condition locks this role to:
- `system:serviceaccount:` = only Kubernetes service accounts
- `kube-system` = only pods in the kube-system namespace
- `ebs-csi-controller-sa` = only the EBS CSI controller's service account

Even if another pod in kube-system is compromised, it can't assume this role (wrong service account).

#### IRSA vs Node Instance Profile

| Aspect | Node Instance Profile | IRSA |
|--------|---------------------|------|
| Scope | All pods on the node | Specific service account |
| Rotation | Manual (modify instance profile) | Automatic (pod restart picks up new role) |
| Audit | Node-level only | Per-pod in CloudTrail |
| Setup | Easy (attach to ASG) | Complex (OIDC + annotation + trust policy) |
| Security | Low (any pod inherits) | High (isolated per pod) |
| AWS SDK support | Automatic (IMDS) | Automatic (env vars) |

**Interview answer:** "IRSA is the only secure way to give pods AWS permissions. Node instance profiles are a legacy pattern that violates least privilege. At my previous company, we migrated 200+ microservices from instance profiles to IRSA over 3 months."

---

## 3. Amazon EKS — Elastic Kubernetes Service

### 3.1 EKS Architecture

```
EKS Control Plane (AWS-managed)
├── API Server (kube-apiserver)
├── etcd (cluster state)
├── Scheduler (kube-scheduler)
├── Controller Manager (kube-controller-manager)
└── Cloud Controller Manager (aws-cloud-controller-manager)

Worker Nodes (EC2 instances) — YOUR responsibility
├── kubelet
├── kube-proxy
├── Container Runtime (containerd)
└── Pods
```

**Control plane vs data plane:**
- **Control plane:** AWS manages this. You can't SSH into it. AWS handles upgrades, patches, and backups.
- **Data plane:** Your EC2 instances. You manage updates, patching, scaling, and security.

**Communication:**
- Worker nodes → Control plane: Via EKS-managed security group + private endpoint
- Control plane → Worker nodes: Via AWS CloudWatch for logs, API server for commands

### 3.2 EKS Cluster Creation with Terraform

```hcl
resource "aws_eks_cluster" "main" {
  name     = "notes-buddy"
  version  = "1.31"
  role_arn = aws_iam_role.cluster.arn  # Control plane IAM role

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_public_access  = true   # kubectl from laptop
    endpoint_private_access = true   # nodes talk to control plane
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}
```

**Why `depends_on` cluster policy?** The cluster needs `AmazonEKSClusterPolicy` attached to its IAM role BEFORE creation. The policy allows the control plane to:
- Create/describe/manage ENI (Elastic Network Interfaces) for pods
- Create load balancers
- Read EC2 metadata
- Without `depends_on`, Terraform tries to create cluster and role simultaneously → role has no permissions → cluster creation fails.

### 3.3 Node Groups

```hcl
resource "aws_eks_node_group" "main" {
  cluster_name   = aws_eks_cluster.main.name
  node_role_arn  = aws_iam_role.node_group.arn
  subnet_ids     = var.subnet_ids
  instance_types = ["t3.small"]

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 3
  }

  update_config {
    max_unavailable = 1
  }
}
```

**Scaling behavior:**
- **desired_size:** Current target. K8s scale up/down doesn't change this — only Terraform or ASG changes it
- **min_size:** Lowest the ASG can go. Protects against accidental scale-to-zero
- **max_size:** Highest the ASG can go. Protects against runaway costs
- **HPA scales pods, not nodes** — K8s Cluster Autoscaler or Karpenter scales nodes

**`update_config.max_unavailable = 1`:**
- During node upgrades, only 1 node is unavailable at a time
- Old node is cordoned (no new pods) + drained (pods evicted) → new node joins → pods reschedule
- Zero downtime for apps with >1 replica and pod disruption budgets

**Node IAM role permissions (attached by Terraform):**
| Policy | Why |
|--------|-----|
| `AmazonEKSWorkerNodePolicy` | Join cluster, register node |
| `AmazonEKS_CNI_Policy` | Manage pod networking (ENIs, IPs) |
| `AmazonEC2ContainerRegistryReadOnly` | Pull Docker images from ECR |
| `CloudWatchAgentServerPolicy` | Ship metrics to CloudWatch |
| `AmazonSSMManagedInstanceCore` | SSH-less access via Systems Manager |

### 3.4 EKS Addons

Addons are AWS-maintained Kubernetes components that install with a single command.

```hcl
resource "aws_eks_addon" "ebs_csi" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "aws-ebs-csi-driver"
}

resource "aws_eks_addon" "cloudwatch" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "amazon-cloudwatch-observability"
}
```

**Why not install manually with `kubectl apply`?**
- **Version management:** AWS manages compatibility between addon version and EKS version
- **Updates:** `terraform apply` with new addon version → AWS handles the upgrade
- **Config validation:** AWS validates addon configuration before applying
- **Automatic IAM:** Some addons (like VPC CNI) auto-create required IAM resources

**Common EKS addons:**
| Addon | Purpose |
|-------|---------|
| `aws-ebs-csi-driver` | EBS volume provisioning for PVCs |
| `aws-efs-csi-driver` | EFS (NFS) volume provisioning |
| `amazon-cloudwatch-observability` | Container Insights (metrics + logs) |
| `vpc-cni` | Pod networking (AWS VPC CNI, default) |
| `coredns` | DNS resolution within cluster (default) |
| `kube-proxy` | Network rules on nodes (default) |

### 3.5 EKS Authentication — Deep Dive

#### Two-Layer Authentication

```
                     Layer 1: AWS IAM                    Layer 2: K8s RBAC
                 ───────────────────────           ──────────────────────
kubectl apply    aws eks get-token         EKS API Server    aws-auth ConfigMap
                 (STS GetCallerIdentity)   ──────────────▶   ────────────────▶
User:Alice       ───────────────────────▶  Who is this?      IAM role back
                                           IAM principal?    → map to K8s group
                                                             → check RoleBinding
                                                             → ALLOW or DENY
```

**Layer 1 — Getting In (AWS IAM):**
```bash
# aws eks update-kubeconfig generates:
# - kubeconfig with exec-based auth
# - command: aws eks get-token
# - this calls STS:GetCallerIdentity
# - returns a token signed by your IAM credentials

# Test layer 1:
aws eks get-token --cluster-name notes-buddy
# Returns: {"kind":"ExecCredential","apiVersion":"client.authentication.k8s.io/v1beta1",...}
```

**Layer 2 — What You Can Do (K8s RBAC):**
The token from Layer 1 includes your IAM principal ARN. EKS looks up this ARN in the `aws-auth` ConfigMap:

```yaml
apiVersion: v1
data:
  mapRoles: |
    - rolearn: arn:aws:iam::ACCOUNT:role/notes-buddy-node-role
      username: system:node:{{EC2PrivateDNSName}}
      groups:
      - system:bootstrappers
      - system:nodes
    - rolearn: arn:aws:iam::ACCOUNT:role/notes-buddy-github-actions-role
      username: github-actions-deployer
      groups:
      - notes-buddy-deployer
```

If the IAM principal is NOT in `mapRoles` or `mapUsers`, EKS returns:
```json
{"code": 403, "message": "Forbidden: User \"system:anonymous\" cannot get path \"/\""}
```

**`system:anonymous`** = the fallback identity when IAM principal isn't mapped.

#### Access Entries (Newer Alternative)

EKS 1.23+ supports **Access Entries** as a replacement for `aws-auth`:

```bash
aws eks create-access-entry \
  --cluster-name notes-buddy \
  --principal-arn arn:aws:iam::ACCOUNT:role/notes-buddy-github-actions-role

aws eks associate-access-policy \
  --cluster-name notes-buddy \
  --principal-arn arn:aws:iam::ACCOUNT:role/notes-buddy-github-actions-role \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy \
  --access-scope type=namespace,namespaces=[notes-buddy]
```

**Limitation:** Access Policies are EKS-managed (View, Edit, Admin). Custom RBAC still needs aws-auth. Our cluster uses `CONFIG_MAP` auth mode (default), not `API_AND_CONFIG_MAP`, so Access Entries aren't available without recreating the cluster.

### 3.6 Kubernetes RBAC — Roles and RoleBindings

#### Role vs ClusterRole
| Aspect | Role | ClusterRole |
|--------|------|-------------|
| Scope | Single namespace | Entire cluster |
| Resources | Deployments, pods, services in that namespace | Nodes, PVs, cluster-scoped resources |
| Example | `kubectl get pods -n notes-buddy` | `kubectl get nodes` |

#### RoleBinding vs ClusterRoleBinding
| Binding | Links | To |
|---------|-------|-----|
| RoleBinding | Role (in namespace X) | User/Group (in namespace X) |
| ClusterRoleBinding | ClusterRole (cluster-scoped) | User/Group (cluster-scoped) |

#### Our Role for GitHub Actions
```yaml
kind: Role
metadata:
  name: github-actions-deployer
  namespace: notes-buddy
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch", "update", "patch"]
```

**Why these verbs?**
- `update` → `kubectl set image deployment/notes-buddy` changes the pod template, triggering rolling update
- `get/list/watch` → `kubectl rollout status` reads deployment status to verify completion
- `patch` → needed by some kubectl versions for `set image`

**Why namespace-scoped Role and not ClusterRole?**
- Security: CI/CD pipeline can only touch `notes-buddy` namespace
- If the pipeline is compromised, attacker can't modify `kube-system` or other namespaces
- This is **defense in depth** — even with full AWS credentials, K8s RBAC limits blast radius

#### RoleBinding with a Group
```yaml
subjects:
- kind: Group
  name: notes-buddy-deployer
```

**Why use a Group, not a User?**
- Multiple IAM principals (roles, users) can map to the same Kubernetes group
- If we add another IAM role for a different pipeline, it just needs the group in aws-auth — no RBAC changes
- Decouples AWS IAM from K8s RBAC: teams managing IAM don't need to know K8s roles

#### Testing RBAC
```bash
# Can the group update deployments?
kubectl auth can-i update deployments -n notes-buddy --as-group=notes-buddy-deployer
# yes

# Can the group delete pods? (it shouldn't)
kubectl auth can-i delete pods -n notes-buddy --as-group=notes-buddy-deployer
# no

# Can the group touch kube-system? (it shouldn't)
kubectl auth can-i get pods -n kube-system --as-group=notes-buddy-deployer
# no
```

---

## 4. GitHub Actions CI/CD

### 4.1 Workflow Structure

```yaml
name: Deploy to EKS
on:
  push:
    branches: [main]
  workflow_dispatch:      # Manual trigger from GitHub UI

env:
  AWS_REGION: ap-south-1
  ECR_REPOSITORY: notes-buddy

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write     # REQUIRED for OIDC
      contents: read
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::ACCOUNT:role/notes-buddy-github-actions-role
          aws-region: ap-south-1
      - uses: aws-actions/amazon-ecr-login@v2
      - run: docker build -t $REGISTRY/$REPO:$SHA .
      - run: docker push $REGISTRY/$REPO:$SHA && docker push $REGISTRY/$REPO:latest
      - run: aws eks update-kubeconfig --name notes-buddy
      - run: kubectl set image deployment/notes-buddy -n notes-buddy notes-buddy=$REGISTRY/$REPO:$SHA
      - run: kubectl rollout status deployment/notes-buddy -n notes-buddy --timeout=120s
```

### 4.2 Why `id-token: write` Is Required

GitHub Actions uses a **permission model** similar to mobile apps:

```
Default permissions:
  contents: read     # Can read the repo
  issues: read       # Can read issues (if needed)
  id-token: none     # CANNOT get OIDC token
```

OIDC requires **explicit opt-in**:
```yaml
permissions:
  id-token: write    # Request OIDC token
  contents: read     # Read repo contents
```

Without this, the `configure-aws-credentials` step fails:
```
Error: Unable to get ID token: OpenIDConnect token not found
```

**Security rationale:** If a workflow action is compromised, without `id-token: write`, the attacker can read code but can't get AWS credentials. Defense in depth.

### 4.3 OIDC Token Exchange Flow

```
1. Workflow starts
   GitHub Actions generates an OIDC token (JWT)
   Token URL: https://token.actions.githubusercontent.com
   Token claims:
   {
     "sub": "repo:Mojojojo0222/notes_buddy:ref:refs/heads/main",
     "aud": "sts.amazonaws.com",
     "iat": 1680000000,
     "exp": 1680003600,
     "job_workflow_ref": "Mojojojo0222/notes_buddy/.github/workflows/deploy.yml@refs/heads/main"
   }

2. aws-actions/configure-aws-credentials@v4
   a. Reads the OIDC token from $ACTIONS_ID_TOKEN_REQUEST_TOKEN
   b. Sends to AWS STS: AssumeRoleWithWebIdentity
   c. STS verifies the token signature against the OIDC provider
   d. Checks: aud matches, sub matches trust policy conditions
   e. Returns temporary credentials (valid for ~1 hour)
   f. Sets AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN
```

**No AWS keys are stored anywhere:**
- Not in GitHub Secrets
- Not in the repo
- Not in GitHub's database
- The workflow gets fresh keys every run

### 4.4 `kubectl set image` vs `kubectl apply`

```bash
# Option 1: set image (what we use)
kubectl set image deployment/notes-buddy -n notes-buddy \
  notes-buddy=$REGISTRY/$REPO:$SHA

# Option 2: apply -f (common alternative)
kubectl set image deployment -n notes-buddy \
  -n notes-buddy notes-buddy=$REGISTRY/$REPO:$SHA
```

**Why `set image` over re-applying the YAML:**
- **Faster:** One API call vs reading file + parsing + applying
- **Safer:** Only changes the image tag. Doesn't accidentally reset labels, replicas, or other settings
- **Traceable:** `kubectl rollout history deployment/notes-buddy` shows every image change with timestamps

### 4.5 `kubectl rollout status` — Deployment Verification

```bash
kubectl rollout status deployment/notes-buddy -n notes-buddy --timeout=120s
```

**What it checks:**
1. New ReplicaSet is created
2. New pods pass readiness probes
3. Old pods are terminated
4. Replicas match desired count

**Exit codes:**
- `0` — rollout completed successfully
- `non-zero` — rollout timed out or failed → pipeline fails

**Without this step:** The pipeline could report success while pods are CrashLoopBackOff. The image was pushed, the deployment was updated, but the app is down.

---

## 5. EBS CSI — Elastic Block Store Container Storage Interface

### 5.1 What EBS CSI Does

The EBS CSI driver allows Kubernetes to dynamically provision EBS volumes for PersistentVolumeClaims.

```
PVC created (storage: 1Gi, storageClass: gp2)
    │
EBS CSI Controller (pod in kube-system)
    │
    ├── 1. Calls EC2 CreateVolume (1Gi, gp2, in node's AZ)
    ├── 2. Attaches volume to the node EC2 instance
    ├── 3. Formats (ext4/xfs) if first use
    └── 4. Mounts to the pod's filesystem

When pod is deleted:
    ├── 5. Unmounts from pod
    ├── 6. Detaches from EC2 instance
    └── 7. (optionally) Deletes the volume
```

### 5.2 EBS CSI + IRSA (Our Fix)

**Problem:** EBS CSI controller runs as a pod. It needs to call EC2 API. How does it get AWS credentials?

**Wrong approach:** Attach EBS permissions to the node's IAM role. Every pod on that node gets EBS permissions.

**Correct approach (IRSA):**
1. Create IAM role `notes-buddy-ebs-csi-role` with `AmazonEBSCSIDriverPolicy`
2. Trust policy scoped to `system:serviceaccount:kube-system:ebs-csi-controller-sa`
3. Annotate the service account
4. EBS CSI controller gets credentials via OIDC token → STS → temp keys

**`AmazonEBSCSIDriverPolicy` includes:**
```
ec2:CreateSnapshot, ec2:AttachVolume, ec2:DetachVolume,
ec2:ModifyVolume, ec2:DescribeAvailabilityZones,
ec2:DescribeInstances, ec2:DescribeSnapshots,
ec2:DescribeVolumes, ec2:CreateVolume, ec2:DeleteVolume,
ec2:CreateTags, ec2:DeleteTags
```

### 5.3 EBS Volume Pitfalls (lost+found + fsGroup)

#### Problem 1: `lost+found`
EBS volumes are formatted with ext4. The `lost+found` directory exists at the root of every ext4 filesystem (it's a data recovery directory).

PostgreSQL expects its data directory to be empty on first initialization. When you mount an EBS volume to `/var/lib/postgresql/data`, the `lost+found` directory is there → Postgres refuses to initialize.

**Fix:**
```yaml
volumeMounts:
  - name: postgres-storage
    mountPath: /var/lib/postgresql/data
    subPath: pgdata    # ← creates/uses a subdirectory instead of root

# Plus PGDATA env var:
env:
  - name: PGDATA
    value: /var/lib/postgresql/data/pgdata
```

#### Problem 2: Permission Denied (fsGroup)
EBS volumes are owned by `root:root` with permissions `755`. PostgreSQL runs as UID 999 (postgres user). The postgres process tries to write to the data directory → `Permission denied`.

**Fix:**
```yaml
securityContext:
  fsGroup: 999   # K8s chowns the volume to GID 999 before container starts
```

**How `fsGroup` works:**
1. K8s recursively `chown` the entire volume to `root:GID` (owner = root, group = GID)
2. `fsGroup: 999` → `chown -R 0:999 /var/lib/postgresql/data`
3. Postgres process has GID 999 → can write to files with group ownership

---

## 6. End-to-End: The Full Pipeline

### 6.1 Developer Workflow
```bash
# 1. Developer writes code
git add src/
git commit -m "fix: add command output capture"

# 2. Push to main
git push origin main
```

### 6.2 CI/CD Pipeline (Automated)
```
Push to main
    │
GitHub Actions Workflow
    │
    1. Checkout → gets the code
    2. OIDC auth → gets AWS credentials (no keys)
    3. ECR login → can push images
    4. Docker build → mvn package → fat JAR → Docker image
                      Tag: commit SHA + latest
    5. Docker push → to 083777493383.dkr.ecr.ap-south-1.amazonaws.com/notes-buddy
    6. kubeconfig → aws eks update-kubeconfig --name notes-buddy
    7. Deploy → kubectl set image deployment/notes-buddy
                triggers rolling update
    8. Verify → kubectl rollout status --timeout=120s
                waits for new pods to be Ready
```

### 6.3 What Happens in Kubernetes
```
1. Deployment detects pod template change
2. Creates new ReplicaSet with new image
3. New pod starts:
   a. Scheduler assigns pod to a node
   b. kubelet pulls image from ECR
   c. Container starts → Spring Boot boots
   d. Liveness probe: /actuator/health → must pass (60s initial delay)
   e. Readiness probe: /actuator/health → must pass (45s initial delay)
   f. Pod becomes Ready → Service routes traffic
4. Old pod is drained (SIGTERM → 30s grace period → SIGKILL)
5. Reports rollout complete
```

### 6.4 Rollback Scenarios
```bash
# Immediate rollback to previous revision
kubectl rollout undo deployment/notes-buddy -n notes-buddy

# Rollback to specific revision
kubectl rollout undo deployment/notes-buddy -n notes-buddy --to-revision=3

# Deploy a specific known-good image
kubectl set image deployment/notes-buddy -n notes-buddy \
  notes-buddy=083777493383.dkr.ecr.ap-south-1.amazonaws.com/notes-buddy:abc123
```

---

## 7. Interview Questions & Deep Answers

### "Explain Terraform state management."
"Terraform state is a JSON mapping between configuration and real resources. It lives in `terraform.tfstate` and contains every resource's ID, attributes, and dependencies.

For production, we use S3 as the backend with DynamoDB for state locking. The bucket has versioning enabled so we can recover any previous state. State contains sensitive data like DB passwords, so it's encrypted at rest with AES-256.

We never store state locally — that's a single point of failure and blocks collaboration. Our CI/CD pipeline runs `terraform plan` in PRs for review, and `terraform apply` on merge."

### "How do EKS and IAM work together?"
"EKS authentication has two layers:
1. **AWS IAM** authenticates the user/role to the EKS API server
2. **Kubernetes RBAC** authorizes that principal within the cluster

The bridge between them is the `aws-auth` ConfigMap in kube-system. It maps IAM principals (role ARNs, user ARNs) to Kubernetes users and groups.

Without this mapping, even the AWS account root user gets 'Forbidden: User system:anonymous' when trying to use kubectl. We learned this the hard way when our GitHub Actions pipeline failed at the kubectl step despite passing `aws eks update-kubeconfig`."

### "How do you handle secrets in CI/CD?"
"We use OIDC — no static keys anywhere. GitHub Actions requests an identity token from `token.actions.githubusercontent.com`, exchanges it for AWS credentials via STS AssumeRoleWithWebIdentity, and the IAM role's trust policy restricts which repo and branch can assume it.

The credentials are valid for about an hour per workflow run. If they leak, they expire automatically. Zero rotation overhead, full audit trail in CloudTrail showing exactly which workflow and run ID used the credentials.

For Kubernetes secrets (like DB passwords), they're stored as K8s Secrets and injected as environment variables. In production, we'd use AWS Secrets Manager with the Secrets Store CSI driver."

### "What's your Kubernetes networking setup?"
"We use public subnets with EKS — simpler setup for our scale. Each node gets a public IP and pulls images directly from ECR. The ALB (AWS Load Balancer) handles external traffic on port 80, routing to the app's NodePort.

Pod networking uses AWS VPC CNI — each pod gets a VPC IP address directly, no overlay network. This means pods communicate at native EC2 network speed.

For a production multi-service architecture, we'd use private subnets with a NAT Gateway ($32/month) and an Ingress Controller (nginx or ALB Ingress Controller) instead of Service type LoadBalancer."

### "How would you handle a security incident in your CI/CD?"
"OIDC dramatically reduces blast radius:

1. **Compromised GitHub token:** Attacker can trigger workflows, but each run gets fresh short-lived credentials scoped to ECR push and EKS describe. They can't touch S3, DynamoDB, or other AWS services.

2. **Compromised CI/CD role:** Kubernetes RBAC limits the role to updating deployments in the `notes-buddy` namespace. They can't modify system pods or access other namespaces.

3. **Audit trail:** CloudTrail logs every `AssumeRoleWithWebIdentity` call with the GitHub workflow run ID. We can trace exactly which commit and which workflow made every AWS API call.

4. **Defense in depth:** Even with full AWS admin access, the aws-auth ConfigMap controls what you can do in Kubernetes. Even with full Kubernetes cluster-admin, IRSA controls what pods can do in AWS."

### "What's the biggest mistake you've seen in Terraform setups?"
"Not pinning provider versions and using local state. I've seen `terraform apply` work on one machine and fail on another because a provider version changed. And I've seen engineers lose the entire state file when their laptop died.

The fix: always use `required_providers` with version constraints, commit `.terraform.lock.hcl`, and use S3 backend from Day 1. The migration from local to remote is a one-liner (`terraform init -migrate-state`) but many teams never do it."

### "Compare Terraform modules and CloudFormation nested stacks."
"Conceptually similar — both break infrastructure into reusable components. But Terraform modules are more flexible:

- **Input/output contracts:** Modules have typed variables (string, number, list) with validation
- **Versioning:** Modules can be sourced from Git tags, registries, or local paths
- **Composition:** A module can call other modules (nesting)
- **Testing:** `terraform test` (1.6+) validates module behavior

CloudFormation nested stacks are AWS-only, can't be shared across accounts easily, and lack a public registry ecosystem like Terraform's."

### "Explain the EBS CSI driver issues you faced."
"Three issues:
1. **CRASH 1 — No IRSA:** The EBS CSI addon was installed without an IAM role. The pod tried IMDS (no credentials there), then IRSA (no annotation), then failed. Error: 'no EC2 IMDS role found.'
2. **CRASH 2 — Policy propagation:** After setting up IRSA, the pod assumed the role but the policy hadn't propagated. Error: 'not authorized for ec2:DescribeAvailabilityZones.' Fixed by waiting 30 seconds and restarting.
3. **Permission denied on Postgres (separate issue):** The EBS volume was owned by root. Postgres runs as UID 999. Fixed with `securityContext.fsGroup: 999`.

The key debugging insight: error messages change as you fix layers. No IMDS = auth layer. Not authorized = auth works but policy is missing/waiting."

---

## Quick Reference: Commands for Each Concept

| Concept | Command |
|---------|---------|
| Terraform init | `terraform init` |
| Terraform plan | `terraform plan` |
| Terraform apply | `terraform apply -auto-approve` |
| Terraform import | `terraform import module.ecr.aws_ecr_repository.main notes-buddy` |
| Terraform state list | `terraform state list` |
| Migrate to S3 | `terraform init -migrate-state -force-copy` |
| AWS OIDC test | `aws sts assume-role-with-web-identity --role-arn arn:aws:iam::ACCOUNT:role/ROLE --role-session-name test --web-identity-token $(curl -s "$ACTIONS_ID_TOKEN_REQUEST_URL" -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \| jq -r '.value')` |
| EKS get token | `aws eks get-token --cluster-name notes-buddy` |
| aws-auth view | `kubectl get configmap aws-auth -n kube-system -o yaml` |
| RBAC test | `kubectl auth can-i update deployments -n notes-buddy --as-group=notes-buddy-deployer` |
| IRSA check | `kubectl describe sa ebs-csi-controller-sa -n kube-system` |
| EBS CSI restart | `kubectl rollout restart deployment ebs-csi-controller -n kube-system` |
| Rollout status | `kubectl rollout status deployment/notes-buddy -n notes-buddy` |
| Rollout history | `kubectl rollout history deployment/notes-buddy -n notes-buddy` |
| Set image | `kubectl set image deployment/notes-buddy -n notes-buddy notes-buddy=IMAGE:TAG` |

---

## Resource Map (Everything Created This Session)

### Terraform (28 resources)
```
module.vpc.aws_vpc.main
module.vpc.aws_internet_gateway.main
module.vpc.aws_subnet.public[0]
module.vpc.aws_subnet.public[1]
module.vpc.aws_route_table.public
module.vpc.aws_route_table_association.public[0]
module.vpc.aws_route_table_association.public[1]
module.eks.aws_iam_role.cluster
module.eks.aws_iam_role_policy_attachment.cluster_policy
module.eks.aws_iam_role.node_group
module.eks.aws_iam_role_policy_attachment.node_worker
module.eks.aws_iam_role_policy_attachment.node_cni
module.eks.aws_iam_role_policy_attachment.node_ecr
module.eks.aws_iam_role_policy_attachment.node_cloudwatch
module.eks.aws_iam_role_policy_attachment.node_ssm
module.eks.aws_eks_cluster.main
module.eks.aws_eks_node_group.main
module.eks.data.tls_certificate.eks
module.eks.aws_iam_openid_connect_provider.eks
module.eks.aws_iam_role.ebs_csi
module.eks.aws_iam_role_policy_attachment.ebs_csi
module.eks.aws_eks_addon.ebs_csi
module.eks.aws_eks_addon.cloudwatch
module.ecr.aws_ecr_repository.main
module.ecr.aws_ecr_lifecycle_policy.main
aws_iam_openid_connect_provider.github
aws_iam_role.github_actions
aws_iam_role_policy.ecr_push
aws_iam_role_policy.eks_describe
```

### Kubernetes (applied via kubectl)
```
k8s/namespace.yaml                 → Namespace: notes-buddy
k8s/configmap.yaml                 → ConfigMap: notes-buddy-config
k8s/secret.yaml                    → Secret: notes-buddy-secret
k8s/postgres.yaml                  → PVC + Deployment + Service for PostgreSQL
k8s/notes-buddy.yaml               → Deployment + LoadBalancer Service for app
k8s/hpa.yaml                       → HPA: CPU 50%, 1-4 replicas
k8s/rbac-github-actions.yaml       → Role + RoleBinding for CI/CD
kube-system:aws-auth ConfigMap     → IAM role → K8s group mapping (patched manually)
kube-system:ebs-csi-controller-sa  → IRSA annotation (patched manually)
```

### IAM Roles
```
notes-buddy-cluster-role              → EKS control plane
notes-buddy-node-role                 → EC2 worker nodes (6 policies attached)
notes-buddy-ebs-csi-role              → EBS CSI driver (IRSA)
notes-buddy-github-actions-role       → GitHub Actions (OIDC, 2 inline policies)
```

### Docs
```
docs/day9/README.md                → Day 9 Terraform notes
docs/day10/README.md               → Days 9-10 combined (this file)
docs/day10/CI-CD-FIX-GUIDE.md      → EKS auth fix guide
docs/RUNBOOK.md                    → How to run + 13 troubleshooting scenarios
docs/INTERVIEW_STORY.md            → Full project story for interviews
docs/CONCEPTS_MASTER.md            → This file — all concepts in depth
```

---

## 8. Day 11 — Spring Boot + Vanilla JS Features

### 8.1 Exit Codes — Data Capture

Every shell command returns an exit code (`$?`). Convention: 0 = success, non-zero = error.

In our log format, it's the 5th pipe-delimited field:
```
timestamp|workingDir|repoName|commandText|exitCode
```

This is backward-compatible: `split("\\|", 5)` returns all fields. Old 4-field lines just have `exitCode = null`.

### 8.2 JPA `findBySavedAtBetween`

Spring Data JPA derives queries from method names:
```java
List<Command> findBySavedAtBetweenOrderBySavedAtAsc(LocalDateTime start, LocalDateTime end);
```

This generates: `SELECT * FROM command WHERE saved_at BETWEEN ? AND ? ORDER BY saved_at ASC`

The `Between` keyword is inclusive on both ends when used with `LocalDateTime`.

### 8.3 localStorage for UI Persistence

```javascript
// Save
localStorage.setItem('notesBuddyFilters', JSON.stringify([...activeFilters]));

// Load
const saved = JSON.parse(localStorage.getItem('notesBuddyFilters'));
if (saved && Array.isArray(saved)) activeFilters = new Set(saved);
```

Key pattern: `Set` → `Array` via spread operator for serialization. `Array` → `Set` on load. This is the standard way to persist Set data in localStorage.

### 8.4 Inline Tag Editing Pattern

```
Click tag badge → shows input → type tag → Enter saves, Esc cancels
```

Implementation:
- `onclick` on span shows input, hides span
- `onblur` on input triggers save via `POST /commands/{id}/tag`
- `onkeydown`: Enter → blur (triggers save), Esc → remove input, show span
- On save → reload sessions to reflect tag

This is a common UI pattern: **inline editing** — edit in place instead of a modal. Simpler UX, fewer round trips.

### 8.5 Date Picker + Timeline

`<input type="date">` returns value in `YYYY-MM-DD` format. Used directly in API:
```javascript
fetch(`/commands/by-date?date=${dateStr}`)
```

JavaScript date tricks:
- `new Date().toLocaleDateString('en-CA')` → `2026-07-23` (Canadian locale uses ISO format)
- `picker.valueAsDate = new Date()` — sets date input to today
- `.setDate(d.getDate() + delta)` — shift by N days

### 8.6 Command Entity Fields Added

```java
private Integer exitCode;  // nullable — null for legacy records
private String tag;        // nullable — manually assigned label
```

`Integer` (object) not `int` (primitive) because:
- `null` = legacy command before this feature existed
- `0` = success
- `non-zero` = error code

PostgreSQL `ddl-auto=update` adds nullable columns without data migration. Existing rows get `NULL`.

---

## 8. Spring Data JPA — Full-Text Search Patterns (Day 12)

### 8.1 `@Query` vs Derived Method Names

**Problem:** Search across 5 fields (text, tag, workingDir, repoName, category) with case-insensitive substring matching.

**Derived method name approach (bad):**
```java
// This is absurd — don't do this
List<Command> findByTextContainingIgnoreCaseOrTagContainingIgnoreCaseOrWorkingDirContainingIgnoreCaseOrRepoNameContainingIgnoreCaseOrCategoryContainingIgnoreCaseOrderBySavedAtAsc(String text, String tag, String dir, String repo, String cat);
```

Problems:
- 5 parameters, all passed the same value
- 15+ words in the method name
- Hard to read, hard to maintain
- Adding a 6th field means changing the method name AND all callers

**`@Query` approach (correct):**
```java
@Query("SELECT c FROM Command c WHERE " +
       "LOWER(c.text) LIKE LOWER(CONCAT('%', :query, '%')) OR " +
       "LOWER(c.tag) LIKE LOWER(CONCAT('%', :query, '%')) OR " +
       "LOWER(c.workingDir) LIKE LOWER(CONCAT('%', :query, '%')) OR " +
       "LOWER(c.repoName) LIKE LOWER(CONCAT('%', :query, '%')) OR " +
       "LOWER(c.category) LIKE LOWER(CONCAT('%', :query, '%')) " +
       "ORDER BY c.savedAt ASC")
List<Command> searchCommands(@Param("query") String query);
```

Benefits:
- Single parameter — `query` string, applied to all 5 fields
- Easy to read — the SQL is visible in the annotation
- Easy to modify — add/remove a field by editing one line
- JPQL (Java Persistence Query Language) — database-agnostic. Works with H2, PostgreSQL, MySQL.

### 8.2 `ILIKE` vs PostgreSQL `tsvector`

| Approach | What It Does | Scale | Complexity |
|----------|-------------|-------|-----------|
| `LIKE '%keyword%'` | Simple substring match | <10k rows | Zero |
| PostgreSQL `ILIKE` | Case-insensitive LIKE | <100k rows | Zero (built-in) |
| `tsvector` / `tsquery` | Full-text indexing (stemming, ranking, stop words) | >100k rows | High (GIN index, triggers, custom parser) |

**Why we chose `ILIKE` (JPQL's `LOWER()` + `LIKE`):**
- `LOWER(c.text) LIKE LOWER(CONCAT('%', :query, '%'))` = case-insensitive substring match
- JPQL doesn't support PostgreSQL's `ILIKE` natively, but `LOWER()` on both sides achieves the same result
- Zero setup — no indexes, no triggers, no migration
- Sufficient for thousands of commands
- Performance note: `LIKE '%keyword%'` can't use a standard B-tree index. For >100k rows, add a PostgreSQL `pg_trgm` GIN index:
  ```sql
  CREATE INDEX idx_command_text_trgm ON command USING gin (text gin_trgm_ops);
  ```
  Then change to `ILIKE` (native PostgreSQL query via `nativeQuery=true`).

**When to upgrade to `tsvector`:**
- >100k rows and queries are slow
- Need relevance ranking (most relevant results first)
- Need stemming (search "running" finds "run")
- Need stop word filtering (ignore "the", "a", "is")
- Our case: not needed yet. `ILIKE` sub-second for <50k commands.

### 8.3 JPQL String Functions

Used in the search query:
```java
LOWER(String s)           → lowercase string
CONCAT(String a, String b) → concatenate strings
LIKE pattern              → SQL pattern matching (% = wildcard)
```

**`CONCAT('%', :query, '%')` vs `'%' || :query || '%'`:**
- `CONCAT()` is JPQL standard — works across all databases
- `'%' || :query || '%'` is PostgreSQL-specific string concatenation
- JPQL `||` is also standard, but `CONCAT()` is more explicit
- Both work. We use `CONCAT()` for clarity.

**Why not `String.contains()` in Java?**
- That would load ALL commands into memory and filter in Java
- The database has indexes, sorted data, and can return only matching rows
- Server-side search = selective loading. Client-side search = loading + filtering.
- With 50k commands, server-side returns 20 matching rows. Client-side loads 50k rows into memory then finds 20.

### 8.4 `@Param` Annotation

```java
List<Command> searchCommands(@Param("query") String query);
```

**Without `@Param`:**
```java
@Query("... WHERE LOWER(c.text) LIKE LOWER(CONCAT('%', ?1, '%'))")
List<Command> searchCommands(String query);
```
`?1` refers to the first parameter by position. Fragile — if you add a parameter, `?1` becomes wrong.

**With `@Param`:**
```java
@Query("... WHERE LOWER(c.text) LIKE LOWER(CONCAT('%', :query, '%'))")
List<Command> searchCommands(@Param("query") String query);
```
`:query` is a named parameter. Position independent. More readable. Spring Data JPA recommended approach.

### 8.5 Search Pattern: Debounce

On the frontend, we debounce search input to avoid firing an API call on every keystroke:

```javascript
let searchTimer = null;

function onSearchInput() {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => {
        const val = document.getElementById('search').value.trim();
        if (val.length >= 2) {
            searchQuery = val;
            load();
        } else if (val.length === 0) {
            searchQuery = '';
            load();
        }
    }, 300);
}
```

**Why 300ms?**
- 100ms: fires before user finishes typing common words
- 300ms: standard debounce for search-as-you-type
- 500ms+: feels sluggish, user wonders if search is broken
- Google Search uses ~300ms debounce

**Why minimum 2 characters?**
- Single character searches match too many results
- "k" matches "kubectl", "kube-system", "kustomize", "kafka", etc.
- Users rarely intend single-character searches
- Reduces server load from accidental keystrokes

### 8.6 Pattern: Grouping Results by Date

The API returns a flat list. The frontend groups by date:

```javascript
const byDate = {};
for (const c of cmds) {
    const d = new Date(c.savedAt).toLocaleDateString('en-CA');
    if (!byDate[d]) byDate[d] = { date: d, commands: [] };
    byDate[d].commands.push(c);
}
allSessions = Object.values(byDate).map(group => ({
    startTime: group.commands[0].savedAt,
    endTime: group.commands[group.commands.length-1].savedAt,
    durationMins: 0,
    commandCount: group.commands.length,
    categories: [...new Set(group.commands.map(c => c.category).filter(Boolean))],
    commands: group.commands
}));
```

**Why group on frontend, not in SQL?**
- The API returns `List<Command>` — same DTO as all other endpoints
- The rendering function already accepts `sessions` (grouped commands)
- Grouping on frontend = zero backend changes, reuses existing render path
- The group-by-date logic is ~10 lines of JavaScript

### 8.7 Interview Answer: Full-Text Search

**Q: "How do you implement search across your application?"**

"Server-side ILIKE query across 5 fields — command text, tags, working directories, repo names, and categories. The repository method uses `@Query` with JPQL because a derived method name would be unreadable for multi-field OR search.

The frontend debounces input at 300ms, requires minimum 2 characters, and groups results by date for context. The same render function handles both session view and search results — search results are just sessions grouped by date by the frontend.

For our scale (thousands of commands), `LIKE` is sufficient. If we hit 100k+ rows, we'd add a `pg_trgm` GIN index or migrate to PostgreSQL `tsvector` for full-text search with relevance ranking."

<｜｜DSML｜｜tool_calls>
<｜｜DSML｜｜invoke name="write">
<｜｜DSML｜｜parameter name="filePath" string="true">E:\Notes_Buddy\docs\day11\day11-notes.md
