# CI/CD Pipeline Fix: EKS Authentication for GitHub Actions

## The Problem

GitHub Actions workflow failed at the `kubectl set image` step:

```
Run kubectl set image deployment/notes-buddy \
E0721 17:58:13.882902 memcache.go:265] "Unhandled Error"
  err="couldn't get current server API group list:
  the server has asked for the client to provide credentials"
error: You must be logged in to the server
```

### Root Cause

The EKS cluster doesn't know about the GitHub Actions IAM role. There are **two separate authentication layers**:

1. **AWS Authentication (IAM):** Who you are in AWS. The OIDC role handles this — GitHub Actions assumes `notes-buddy-github-actions-role` successfully.
2. **Kubernetes Authentication (RBAC):** Who you are in the cluster. The `aws-auth` ConfigMap maps IAM principals to Kubernetes users/groups. The GitHub Actions role was NOT in this map.

The pipeline passed `aws eks update-kubeconfig` (because that only needs `eks:DescribeCluster` permission, which the IAM role has). But `kubectl` commands failed because EKS checked the `aws-auth` ConfigMap and found no mapping for this IAM role.

### Architecture of EKS Authentication

```
kubectl command
    │
    ▼
aws eks get-token (generates a token signed by your IAM credentials)
    │
    ▼
Kubernetes API Server (EKS control plane)
    │
    ├── Verifies the token is valid (signed by AWS STS)
    │
    ▼
EKS checks aws-auth ConfigMap in kube-system namespace
    │
    ├── "I know this IAM role: arn:aws:iam::XXX:role/notes-buddy-node-role"
    │   └── → Maps to groups: system:bootstrappers, system:nodes
    │
    ├── "I know this IAM user: arn:aws:iam::XXX:user/cli-user"
    │   └── → (pre-existing, created during cluster setup)
    │
    └── "I DON'T know this IAM role: notes-buddy-github-actions-role"
        └── → REJECTED: "You must be logged in"
```

---

## The Fix (3 Components)

### Component 1: Kubernetes Role (What You Can Do)

Defines what actions the deployer is allowed to perform, scoped to the `notes-buddy` namespace.

```yaml
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
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

**Why these permissions?**
- `update` on `deployments` — needed for `kubectl set image deployment/notes-buddy`
- `get/list/watch` on `pods` — needed for `kubectl rollout status` (it checks pod status)
- `get` on `deployments/status` — needed for rollout status to read the deployment's status subresource

**Security note:** This is a **Role** (namespace-scoped), not a **ClusterRole** (cluster-scoped). The GitHub Actions pipeline can ONLY touch the `notes-buddy` namespace. It cannot see or modify anything in `kube-system`, `amazon-cloudwatch`, or any other namespace.

### Component 2: RoleBinding (Who Gets Access)

Links the Kubernetes group `notes-buddy-deployer` to the Role above.

```yaml
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: github-actions-deployer-binding
  namespace: notes-buddy
subjects:
- kind: Group
  name: notes-buddy-deployer
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: github-actions-deployer
  apiGroup: rbac.authorization.k8s.io
```

**Why use a Group instead of a User?**
- Multiple IAM principals (roles, users) can be mapped to the same group
- If you add more pipelines later, they just need the group in their aws-auth entry
- RBAC management is decoupled from IAM management

### Component 3: aws-auth ConfigMap (The Bridge)

Maps the IAM role to the Kubernetes group.

```yaml
apiVersion: v1
data:
  mapRoles: |
    - rolearn: arn:aws:iam::083777493383:role/notes-buddy-node-role
      groups:
      - system:bootstrappers
      - system:nodes
      username: system:node:{{EC2PrivateDNSName}}
    - rolearn: arn:aws:iam::083777493383:role/notes-buddy-github-actions-role
      username: github-actions-deployer
      groups:
      - notes-buddy-deployer    # ← This group matches the RoleBinding
kind: ConfigMap
```

**The `username` field** is just a human-readable identifier in Kubernetes audit logs — it doesn't affect permissions. **The `groups` field** is what matters — it binds to the RoleBinding.

---

## Commands to Fix (Step by Step)

### Step 1: Check if aws-auth has your role
```bash
kubectl get configmap aws-auth -n kube-system -o yaml
```

### Step 2: Create the Kubernetes Role
```bash
kubectl apply -f - << 'EOF'
apiVersion: rbac.authorization.k8s.io/v1
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
EOF
```

### Step 3: Create the RoleBinding
```bash
kubectl apply -f - << 'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: github-actions-deployer-binding
  namespace: notes-buddy
subjects:
- kind: Group
  name: notes-buddy-deployer
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: github-actions-deployer
  apiGroup: rbac.authorization.k8s.io
EOF
```

### Step 4: Update aws-auth ConfigMap
```bash
kubectl patch configmap aws-auth -n kube-system \
  --patch '{"data":{"mapRoles":"- rolearn: arn:aws:iam::083777493383:role/notes-buddy-node-role\n  groups:\n  - system:bootstrappers\n  - system:nodes\n  username: system:node:{{EC2PrivateDNSName}}\n- rolearn: arn:aws:iam::083777493383:role/notes-buddy-github-actions-role\n  username: github-actions-deployer\n  groups:\n  - notes-buddy-deployer\n"}}'
```

**Note:** The `\n` in the JSON is important — the `mapRoles` field is a multiline YAML string. Every newline must be explicit in the JSON patch.

### Step 5: Verify the fix
```bash
# Check aws-auth has both roles
kubectl get configmap aws-auth -n kube-system -o yaml

# Check RBAC
kubectl get role github-actions-deployer -n notes-buddy -o yaml
kubectl get rolebinding github-actions-deployer-binding -n notes-buddy -o yaml

# Quick test (authenticate as a similar user)
kubectl auth can-i update deployment -n notes-buddy
```

---

## How to Test End-to-End

Push an empty commit to trigger the workflow:
```bash
git commit --allow-empty -m "test: trigger CI/CD after EKS auth fix"
git push
```

Or run the workflow manually from GitHub UI:
1. Go to your repo → Actions tab
2. Select "Deploy to EKS" workflow
3. Click "Run workflow" → "Run workflow"

---

## Terraform Integration

To make this permanent, add the aws-auth mapping to Terraform. Two approaches:

### Option A: Kubernetes Provider (Recommended)
Add the `kubernetes` provider to Terraform:
```hcl
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name]
  }
}

resource "kubernetes_role_v1" "github_actions_deployer" {
  metadata {
    name      = "github-actions-deployer"
    namespace = "notes-buddy"
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "watch", "update", "patch"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments/status"]
    verbs      = ["get"]
  }
}
```

### Option B: aws_eks_access_entry (EKS 1.23+)
```hcl
resource "aws_eks_access_entry" "github_actions" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.github_actions.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "github_actions" {
  cluster_name  = aws_eks_cluster.main.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
  principal_arn = aws_iam_role.github_actions.arn

  access_scope {
    namespaces = ["notes-buddy"]
    type       = "namespace"
  }
}
```

---

## Alternative: Access Entries (Newer Approach)

EKS 1.23+ supports **Access Entries**, which replace the `aws-auth` ConfigMap entirely:

```bash
# Create an access entry for the GitHub Actions role
aws eks create-access-entry \
  --cluster-name notes-buddy \
  --principal-arn arn:aws:iam::083777493383:role/notes-buddy-github-actions-role \
  --type STANDARD \
  --user github-actions-deployer

# Associate with a managed policy (namespace-scoped view)
aws eks associate-access-policy \
  --cluster-name notes-buddy \
  --principal-arn arn:aws:iam::083777493383:role/notes-buddy-github-actions-role \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy \
  --access-scope type=namespace,namespaces=[notes-buddy]
```

**Trade-off:** Access Entries work with EKS-managed policies only (View, Edit, Admin). Fine-grained custom RBAC still needs the aws-auth + Role/RoleBinding approach.

---

## Quick Reference

| Command | Purpose |
|---------|---------|
| `kubectl get configmap aws-auth -n kube-system -o yaml` | See current IAM→K8s mappings |
| `kubectl patch configmap aws-auth -n kube-system --patch '...'` | Add IAM role mapping |
| `kubectl create role --verb=update --resource=deployments -n notes-buddy --name=my-role --dry-run=client -o yaml` | Generate role YAML |
| `kubectl create rolebinding my-binding --role=my-role -n notes-buddy --group=my-group --dry-run=client -o yaml` | Generate rolebinding YAML |
| `kubectl auth can-i update deployment -n notes-buddy --as-group=notes-buddy-deployer` | Test RBAC as a group member |
| `aws eks create-access-entry --cluster-name notes-buddy --principal-arn ROLE_ARN` | Modern alternative to aws-auth |

---

## Why This Happened (Interview Explanation)

**"Tell me about a CI/CD pipeline failure and how you debugged it."**

> "Our GitHub Actions workflow failed at the deployment step — `kubectl set image` returned 'the server has asked for the client to provide credentials.' 
> 
> The AWS authentication was fine — the OIDC role was assumed correctly and `aws eks update-kubeconfig` passed. But `kubectl` commands failed because EKS didn't know about our IAM role.
> 
> In EKS, there are two authentication layers: **AWS IAM** signs the request, then the **aws-auth ConfigMap** maps the IAM principal to a Kubernetes user/group. Our GitHub Actions IAM role existed in AWS but wasn't listed in the aws-auth ConfigMap.
> 
> The fix had three parts:
> 1. Created a Kubernetes `Role` with deployment update/get permissions in the `notes-buddy` namespace
> 2. Created a `RoleBinding` linking that role to a Kubernetes group called `notes-buddy-deployer`
> 3. Added our IAM role to the `aws-auth` ConfigMap with the group `notes-buddy-deployer`
> 
> The key insight: AWS authentication is separate from Kubernetes authorization. Passing `update-kubeconfig` only means you can reach the API server — it doesn't mean you can do anything once you get there."
