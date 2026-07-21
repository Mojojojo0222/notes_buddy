# Day 9 — Terraform: Infrastructure as Code for Notes Buddy

## What We Built
Replaced all manual `eksctl` + `aws cli` infrastructure with **Terraform modules**.

```
terraform/
├── main.tf              # Root module — calls all child modules
├── variables.tf         # All inputs in one place
├── outputs.tf           # Cluster endpoint, ECR URL, kubeconfig command
├── versions.tf          # Provider versions (AWS 5.x, TLS 4.x)
└── modules/
    ├── vpc/             # VPC + 2 public subnets + IGW + route table
    ├── eks/             # EKS cluster + node group + IAM roles + addons + IRSA
    └── ecr/             # ECR repo + lifecycle policy (keep last 10 images)
```

### Resources Created (24 total)
- **VPC module (6):** VPC, IGW, 2 subnets, route table, 2 route table assoc
- **EKS module (16):** 2 IAM roles (cluster + node), 7 policy attachments, cluster, node group, OIDC provider, EBS CSI role + policy, 2 addons (EBS CSI + CloudWatch)
- **ECR module (2):** Repository + lifecycle policy

## Key Learnings

### Terraform Core Concepts
1. **`terraform init`** — downloads providers, sets up backend. Run once per project.
2. **`terraform plan`** — shows what will change without actually doing it. Use as a review step.
3. **`terraform apply`** — executes the plan. `-auto-approve` skips confirmation.
4. **`terraform import`** — brings existing resources under Terraform management. Needed when resources were created outside Terraform.
5. **`terraform state list`** — see every resource Terraform tracks.
6. **State file (terraform.tfstate)** — Terraform's source of truth. Contains all resource IDs and attributes. Must be stored remotely in production (S3 + DynamoDB lock).

### Modules
- Modules = functions for infrastructure. Same principle: reusable, testable, single responsibility.
- Root module is the "orchestration layer" — pure module calls, no resource definitions.
- `source = "./modules/vpc"` — relative path for local modules. In production, modules come from a registry or Git repo.
- `outputs` expose values from modules to the root module. E.g., VPC module exposes `subnet_ids` for EKS module to consume.
- `variables` are the input parameters. Each module declares what it needs.

### EKS with Terraform
- `aws_eks_cluster` needs `depends_on` on IAM policy attachment, or there's a race condition — cluster created before role has permissions.
- `vpc_config.endpoint_public_access = true` allows `kubectl` from laptop.
- `endpoint_private_access = true` allows nodes to talk to control plane within VPC.
- Node group uses `scaling_config` (desired/min/max) and `update_config` (max_unavailable for rolling updates).
- EKS addons (`aws_eks_addon`) install automatically — no need to run `eksctl` or `kubectl` separately.

### IRSA (IAM Roles for Service Accounts)
- **Problem:** EBS CSI driver pods need to call EC2 API (create volumes, attach, etc.)
- **Old way:** Attach permissions to node IAM role (too broad — any pod on the node inherits those permissions)
- **IRSA way:** Create a dedicated IAM role with a trust policy that scopes access to a specific service account in a specific namespace
- **Trust policy condition:** `system:serviceaccount:kube-system:ebs-csi-controller-sa` — only this service account can assume the role
- **OIDC provider:** EKS has an OIDC issuer URL. The trust policy uses this URL to verify tokens.
- **Annotation:** The service account must be annotated with `eks.amazonaws.com/role-arn` pointing to the IAM role.

### EBS CSI Fix Steps
1. OIDC provider already created by Terraform
2. Created IAM role with trust policy scoped to `ebs-csi-controller-sa`
3. Attached `AmazonEBSCSIDriverPolicy` (includes ec2:DescribeAvailabilityZones, CreateVolume, AttachVolume, etc.)
4. Annotated the service account: `kubectl annotate sa ebs-csi-controller-sa -n kube-system`
5. Restarted EBS CSI deployment
6. Added IAM role to Terraform module so it's permanent

## Problems Hit and Fixed
1. **Terraform apply timed out (15min)** — EBS CSI addon took longer than expected. Second apply showed "already exists" error. Fixed with `terraform import`.
2. **State lock contention** — Two terraform processes can't write state at the same time. Fixed with `-lock=false` on one.
3. **EBS CSI CrashLoopBackOff × 2** — First: IRSA not set up, pod tried to use IMDS which failed. Second: IRSA role didn't have `ec2:DescribeAvailabilityZones` in the managed policy (wait, it does — this was propagation delay). Wait 15-30s after policy attachment.
4. **Windows + /tmp** — `file:///tmp/...` paths don't work in Git Bash. Must inline the JSON or use a Windows path.

## Interview Questions This Answers
- "Walk me through how you provision infrastructure" — Terraform modules for VPC, EKS, ECR. Remote state in S3. Each module reusable across environments.
- "How do you handle IAM in EKS?" — IRSA. Dedicated roles per service account. Trust policy scoped by namespace + service account name.
- "How do you manage state?" — Terraform state is the source of truth. Team uses S3 backend + DynamoDB lock. `terraform plan` in CI, `terraform apply` after review.
- "What's the difference between Terraform and eksctl?" — eksctl is opinionated EKS-only CLI. Terraform is general-purpose IaC that can manage any AWS resource. Terraform composes with VPC, ECR, IAM in one workflow.
- "How would you handle a production EKS upgrade?" — Change `version` in Terraform, `terraform apply`, Terraform triggers cluster upgrade. Node group upgrade uses `update_config.max_unavailable=1` (rolling).

## Status
- Terraform: 24 resources managed, code committed
- EKS: cluster running, 2 nodes, Kubernetes 1.31
- EBS CSI: healthy (6/6 containers)
- CloudWatch: healthy (metrics + logs)
- Notes Buddy: deployed, accessible via LoadBalancer URL
- Next: GitHub Actions CI/CD (Day 10), ArgoCD (Day 11), Karpenter (Day 12)
