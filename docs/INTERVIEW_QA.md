# Interview Q&A — 15 LPA+ DevOps/SRE/Platform Engineer

**Project:** Notes Buddy — full production-grade infrastructure  
**Stack:** Spring Boot + PostgreSQL → Docker → EKS → Terraform → GitHub Actions OIDC → Helm → ArgoCD → Prometheus/Grafana  
**Target answers depth:** 5+ year experience level — trade-offs, internals, failure modes, production patterns

---

## Table of Contents

1. [Terraform](#1-terraform)
2. [AWS IAM & OIDC](#2-aws-iam--oidc)
3. [Kubernetes (EKS)](#3-kubernetes-eks)
4. [Helm](#4-helm)
5. [ArgoCD & GitOps](#5-argocd--gitops)
6. [CI/CD & GitHub Actions](#6-cicd--github-actions)
7. [Docker](#7-docker)
8. [Observability & SRE](#8-observability--sre)
9. [System Design](#9-system-design)
10. [Security](#10-security)
11. [Behavioral & Incident Response](#11-behavioral--incident-response)

---

## 1. Terraform

### Q1: "Explain how Terraform's state file works internally. What's in it?"

**5-year level answer:**

"The state file is a JSON document that maps your Terraform config to real cloud resources. Each resource gets a `terraform_remote_state` entry with:

```json
{
  "version": 4,
  "terraform_version": "1.9.0",
  "resources": [
    {
      "module": "module.vpc",
      "mode": "managed",
      "type": "aws_vpc",
      "name": "main",
      "provider": "provider[\"registry.terraform.io/hashicorp/aws\"].aws",
      "instances": [{
        "schema_version": 1,
        "attributes": {
          "id": "vpc-0a1b2c3d4e5f",
          "cidr_block": "192.168.0.0/16",
          "tags": {"Name": "notes-buddy-vpc"}
        },
        "private": "base64_encoded_sensitive_data",
        "dependencies": []
      }]
    }
  ]
}
```

The `private` field is base64-encoded and contains the provider's private state — things like the last-known ETag for S3 buckets or the current version of an EKS cluster. This is opaque to Terraform itself, only the provider understands it.

**Why you should never edit state manually:** If you change `cidr_block` in state but not in AWS, Terraform can't detect drift properly. The three-way diff (config vs state vs real world) breaks. Instead of editing state, use `terraform state mv` to rename resources or `terraform import` to add missing ones.

**Sensitive data risk:** State contains plaintext secrets. If you use a DB password in `aws_db_instance`, it's in state in plaintext. Always enable S3 encryption (SSE-AES256 or KMS) and restrict IAM access to the state bucket."

### Q2: "How does `terraform import` work? When would you use it over rewriting config?"

**5-year level answer:**

"`terraform import` maps an existing cloud resource into Terraform state — it writes the resource's current attributes into state so Terraform knows it exists. It does NOT generate HCL config for you. After import, you still need to write the `resource` block that matches what's in state. Then `terraform plan` shows `(no changes)` if your config matches reality.

I used it twice in this project:
1. **ECR repo** — `terraform apply` timed out after creating the repo but before writing state. The repo existed in AWS but not in state. Import fixed it.
2. **EBS CSI addon** — Same timeout issue. `terraform import module.eks.aws_eks_addon.ebs_csi notes-buddy:aws-ebs-csi-driver`

The import ID format varies by resource — it's documented in the provider registry. For S3 buckets it's the bucket name, for EC2 instances it's `i-xxx`, for EKS addons it's `cluster_name:addon_name`.

**When to use import vs rewrite:**
- **Import:** When you're adopting existing infrastructure into IaC. Legacy resources, manually created resources, or resources that survived a Terraform crash.
- **Rewrite:** When you want to change the resource's name or module structure. It's often cleaner to delete the old resource (if safe) and let Terraform recreate it with the right config."

### Q3: "Explain Terraform's dependency graph. How does it handle parallel resource creation?"

**5-year level answer:**

"Terraform builds a **Directed Acyclic Graph (DAG)** of all resources before applying anything. Each node is a resource or data source. Edges are dependencies.

**Implicit dependencies** are detected automatically — if resource A references `resource B.id`, Terraform knows B must exist before A. Example: `subnet_id = aws_subnet.public[0].id` creates a dependency edge from the subnet to whatever uses it.

**Explicit dependencies** use `depends_on` — needed when the dependency isn't in the resource attributes. Our EKS cluster has:

```hcl
depends_on = [aws_iam_role_policy_attachment.cluster_policy]
```

Without this, Terraform might create the cluster before the IAM policy is attached. The cluster creation fails because the role doesn't have permissions yet. This is a race condition that `depends_on` prevents.

**Parallelism:** Terraform traverses the DAG and creates independent resources in parallel. In our project, the VPC subnets and ECR repo were created simultaneously — they don't depend on each other. But the EKS node group waits for the cluster, which waits for the VPC.

The `-parallelism=N` flag controls how many resources Terraform creates concurrently. Default is 10. For AWS, I've found 10-20 works well. Higher values can trigger API rate limits."

### Q4: "Terraform state locking — how does DynamoDB locking work at the API level?"

**5-year level answer:**

"When Terraform needs to write state, it first tries to acquire a lock by writing an item to DynamoDB:

```python
# Pseudocode — what Terraform does internally
dynamodb.put_item(
    TableName="notes-buddy-terraform-locks",
    Item={
        "LockID": {"S": "notes-buddy/terraform.tfstate"},
        "Info": {"S": json.dumps({"version": "1.0", "who": "my-machine"})},
        "Created": {"S": datetime.utcnow().isoformat()}
    },
    ExpressionAttributeValues={":empty": {"S": ""}},
    ConditionExpression="attribute_not_exists(LockID)"
)
```

The `ConditionExpression: attribute_not_exists(LockID)` is the critical part. It's an atomic check-and-set — if the LockID already exists (another process holds the lock), DynamoDB rejects the write and Terraform retries with exponential backoff.

If Terraform crashes while holding the lock, the lock stays in DynamoDB forever. That's when you need `terraform force-unlock LOCK_ID`. The lock ID is printed in the error message.

**Why DynamoDB and not another database?**
- Fully managed — no servers to run
- Single-digit-millisecond latency
- Conditional writes are atomic — no race conditions
- `PAY_PER_REQUEST` billing costs pennies for locking (maybe $0.01/month)
- IAM-integrated — you can restrict who can release locks

Without locking, two team members running `terraform apply` simultaneously would corrupt the state file. With S3's eventual consistency, the last write wins and the first write's changes are silently lost."

### Q5: "Modules vs workspaces — when would you use each for environment separation?"

**5-year level answer:**

"Two patterns for managing dev/staging/prod:

**Directory-per-environment (what we use):**
```
terraform/
├── modules/
│   ├── vpc/
│   ├── eks/
│   └── ecr/
├── dev/
│   ├── main.tf
│   ├── terraform.tfvars
│   └── backend.tf   # different S3 key per env
├── staging/
│   └── ...
└── prod/
    └── ...
```

Each environment is a completely separate Terraform root — separate state, separate apply. Safer because a mistake in dev can't affect prod state.

**Workspaces (Terraform's built-in):**
```bash
terraform workspace new dev
terraform workspace new prod
terraform apply -var-file=prod.tfvars
```

Single state file stored as `terraform.tfstate:env:workspace_name`. Simpler but riskier — one accidental `terraform workspace select prod && terraform destroy` destroys production.

**My recommendation for teams:** Directory-per-environment for production workloads. Workspaces are fine for personal projects or when you need quick environment churn. In this project I'm building toward directory-per-environment because I want the safety separation — I don't want to accidentally nuke production from the dev Terraform directory."

---

## 2. AWS IAM & OIDC

### Q6: "Explain the full OIDC authentication flow between GitHub Actions and AWS. What happens step by step?"

**5-year level answer:**

"Here's the complete flow:

1. **GitHub Actions requests an identity token** — When the workflow starts with `permissions: id-token: write`, GitHub's internal OIDC provider at `token.actions.githubusercontent.com` issues a JWT to the workflow runner.

2. **The JWT contains claims:**
   - `sub: repo:owner/name:ref:refs/heads/main`
   - `aud: sts.amazonaws.com`
   - `job_workflow_ref: owner/name/.github/workflows/deploy.yml@ref`
   - Plus environment, runner environment, and other metadata

3. **The workflow sends this JWT to AWS STS** — The `aws-actions/configure-aws-credentials` action calls `sts:AssumeRoleWithWebIdentity` passing the JWT and the role ARN.

4. **AWS verifies the token:**
   a. **Signature verification** — AWS fetches the OIDC provider's JWKS (JSON Web Key Set) from `token.actions.githubusercontent.com/.well-known/openid-configuration` and verifies the JWT signature using the public key. The thumbprint we configured in the OIDC provider is used to validate the HTTPS certificate chain.
   b. **Audience check** — The token's `aud` claim must match `client_id_list` on the OIDC provider. We set `sts.amazonaws.com`.
   c. **Trust policy evaluation** — The trust policy conditions must match. Our policy checks `StringLike` on `sub` to allow `repo:owner/name:*`.

5. **STS returns temporary credentials** — Access Key ID + Secret Access Key + Session Token. Valid for 1 hour by default, configurable up to 12 hours.

6. **The workflow uses these credentials** to call AWS APIs — ECR login, EKS describe cluster, etc.

**Why this is better than static keys:**
- Keys expire after 1 hour — no key rotation needed
- No keys stored in GitHub Secrets — nothing to leak
- Every action is auditable — CloudTrail logs show the OIDC session name
- Trust policy gates which repos and branches can assume the role"

### Q7: "IRSA vs kiam vs kube2iam — explain the differences and why IRSA won."

**5-year level answer:**

"Three approaches for giving pods AWS permissions:

**kube2iam (2017):**
- Runs as a DaemonSet on each node
- Intercepts IMDS (Instance Metadata Service) requests via iptables
- Each pod gets credentials based on an annotation
- **Problem:** It's a man-in-the-middle on the network level. Security audits hate it. The DaemonSet becomes a single point of failure.

**kiam (2018):**
- Similar approach but runs as a separate pod with an agent
- Uses iptables to redirect IMDS traffic
- More features than kube2iam (credential caching, metrics)
- **Problem:** Same MITM concern. Both are community projects with limited maintenance.

**IRSA — IAM Roles for Service Accounts (2020+, AWS native):**
- EKS creates an OIDC issuer URL per cluster
- A mutating webhook injects environment variables into pods:
  - `AWS_ROLE_ARN`
  - `AWS_WEB_IDENTITY_TOKEN_FILE` — points to a mounted service account token
- The pod's AWS SDK reads these env vars and calls `sts:AssumeRoleWithWebIdentity`
- **No iptables, no MITM, no sidecars**

**Why IRSA won:**
1. **AWS native** — built and maintained by AWS, not a community project
2. **No network interception** — pods use standard AWS SDK credential chain
3. **Namespace-scoped** — the trust policy binds to `system:serviceaccount:NAMESPACE:SA_NAME`
4. **Auditable** — CloudTrail logs show which service account assumed which role
5. **Supported by all major AWS SDKs** — Go, Python, Java, JS, .NET, etc.

The one case where IRSA doesn't work: if a pod runs a custom binary that can't read env vars or files. In that case, you'd need an instance profile. But those are increasingly rare."

### Q8: "An EC2 instance can't reach S3. Walk me through your debugging process."

**5-year level answer:**

"I'd systematically check each layer:

**1. Is the instance profile correct?**
```bash
# Check if the instance has a profile
aws ec2 describe-instances --instance-id i-xxx --query 'Reservations[0].Instances[0].IamInstanceProfile'
# If null → no profile attached. Attach one.
# If profile exists → check the role's policies
aws iam list-attached-role-policies --role-name THE_ROLE_NAME
```

**2. Did we hit a network boundary, not an IAM one?**
S3 uses a gateway endpoint or interface endpoint in VPC, or goes over the internet. If the instance is in a private subnet without a NAT gateway and there's no VPC Gateway Endpoint for S3, traffic can't reach S3 even with correct IAM — it's a routing problem, not auth.

**3. Check S3 bucket policy**
The bucket might have a `Deny` statement that blocks the request. If the bucket policy says `Deny` for any `aws:SourceIp` not from the corporate CIDR, and the request comes from an IP outside that range, it fails — regardless of the role permissions. DENY always wins.

**4. Is S3 accessible from the VPC?**
```bash
# Test connectivity
curl -I https://bucket-name.s3.region.amazonaws.com
# If timeout → network issue. Check route tables, NACLs, security groups.
```

**5. Check for VPC Endpoint policies**
If there's a Gateway Endpoint for S3, it has its own policy. The endpoint policy might block the specific S3 action even if IAM allows it. Policy evaluation: DENY in any policy → DENY overall.

**The actual bug I once hit:** The instance was in a private subnet with a NAT Gateway. The NAT Gateway's EIP got blacklisted by S3's IP-based bucket policy. The fix: add a VPC Gateway Endpoint for S3 so traffic stays within AWS network and doesn't go through the NAT."

---

## 3. Kubernetes (EKS)

### Q9: "Explain how kube-scheduler works. What happens when a pod can't be scheduled?"

**5-year level answer:**

"The scheduler is a control plane component that watches the API server for unscheduled pods (`spec.nodeName = ""`). For each unscheduled pod, it runs a **two-phase algorithm:**

**Phase 1 — Filtering (predicates):**
Which nodes CAN run this pod? Checks:
- NodeSelector and NodeAffinity — does the node have the required labels?
- Resource requests — does the node have enough free CPU/memory?
- Taints and Tolerations — can the pod tolerate the node's taints?
- Port conflicts — is the requested host port already in use?
- Volume zone conflicts — is the PV in the same availability zone?

**Phase 2 — Scoring (priorities):**
Rank the filtered nodes. Default scores:
- `LeastRequestedPriority` — prefer nodes with more free resources (spread pods across nodes)
- `BalancedResourceAllocation` — prefer nodes where CPU and memory usage are balanced
- `ImageLocality` — prefer nodes that already have the container image cached

**When a pod can't be scheduled:**
The scheduler retries with exponential backoff. After 5 minutes, the pod goes to `Pending` with a reason like:
- `0/3 nodes are available: 1 node has taint that pod doesn't tolerate, 2 Insufficient memory`
- `0/3 nodes are available: 3 PersistentVolumeClaims not found`

**In our project:** The Postgres pod was stuck Pending because EBS CSI wasn't working. The PVC couldn't be provisioned → the pod couldn't be scheduled. The scheduler kept retrying. Fixing EBS CSI (via IRSA) resolved it.

**Production tuning:** For high-throughput clusters, you can run multiple scheduler replicas with leader election. For specific workloads, you can write a custom scheduler. The default scheduler works for 95% of cases."

### Q10: "You have a pod in CrashLoopBackOff. Walk me through your debugging."

**5-year level answer:**

"CrashLoopBackOff means the pod starts, crashes, Kubernetes restarts it, it crashes again. After each crash, backoff doubles (10s, 20s, 40s, 80s, 160s, 300s max).

**Step 1 — Check the logs:**
```bash
kubectl logs -n notes-buddy deployment/postgres --previous
```
The `--previous` flag is critical — gets logs from the crashed container, not the new one.

**Step 2 — Check pod events:**
```bash
kubectl describe pod -n notes-buddy postgres-xxx
```
Events section shows the lifecycle: `Pulled`, `Created`, `Started`, `BackOff`. The reason field is key.

**Step 3 — Common causes I've hit with Postgres:**
- **`lost+found` directory** — EBS volume has ext4's lost+found → Postgres thinks data directory is non-empty. Fix: `subPath: pgdata`.
- **Permission denied** — EBS volume owned by root, Postgres runs as UID 999. Fix: `securityContext.fsGroup: 999`.
- **Data directory missing** — If using `subPath`, the subPath directory must not exist yet on the fresh volume. Kubernetes creates it.

**Step 4 — Check if it's an app crash:**
```bash
kubectl logs -n notes-buddy deployment/notes-buddy
# Look for: "Connection to PostgreSQL refused"
# Or: "No suitable driver" (classpath issue)
# Or: "Port 9098 already in use"
```

**Step 5 — Check resource limits:**
```bash
kubectl describe pod -n notes-buddy notes-buddy-xxx | grep -A 2 Limits
```
If limits are too low (e.g., 64Mi for a Java app), the OOM killer terminates the pod. Java apps typically need 256Mi minimum.

**The actual bug from our project:** Postgres was crashing with `permission denied` AND `lost+found` simultaneously. Two separate bugs in the same pod. Fixing them one at a time revealed the other. This is common — fix the first error, the pod gets further, hits the next error."

### Q11: "You have an existing AKS cluster. Migrate it to a new one with zero downtime. How?"

**5-year level answer:**

"Migrating a stateful workload between clusters is harder than stateless. Here's the approach:

**For stateless workloads (Notes Buddy app):**
1. Deploy the app to the new cluster with `replicas=0`
2. Add the new cluster's ingress/service to the DNS, but keep old cluster serving
3. Switch DNS to the new cluster using weighted routing (Route53 weight 0→100)
4. Scale up new cluster, scale down old cluster
5. Monitor for errors during transition

**For stateful workloads (PostgreSQL):**
1. Set up replication from old to new:
   ```bash
   # On new cluster, configure as replica
   pg_basebackup -h OLD_DB_ENDPOINT -D /var/lib/postgresql/data -U replicator -P
   ```
2. Application runs dual-write during transition (writes to both databases)
3. Promote new database to primary when ready
4. Switch all traffic to new cluster

**A simpler approach using external DB:**
Move PostgreSQL to RDS (Aurora). RDS is cluster-agnostic — it doesn't live inside Kubernetes. You can rebuild the entire EKS cluster and the app just reconnects to the same RDS endpoint. This is why many production workloads use external databases."

### Q12: "How would you design a multi-tenant Kubernetes cluster?"

**5-year level answer:**

"Multi-tenancy in Kubernetes is hard because the API server is a shared control plane. Approaches ranked by isolation level:

**Level 1 — Namespace-based (soft multi-tenancy):**
- Each team gets a namespace
- ResourceQuota to cap CPU/memory per namespace
- NetworkPolicy to isolate namespaces
- RBAC Role + RoleBinding scoped to namespace
- **Limitations:** A noisy neighbor can still saturate the API server. PodSecurityPolicy (or PSA) is cluster-wide.

**Level 2 — Virtual clusters (virtual-kubelet, vcluster):**
- Each tenant gets their own Kubernetes API server
- Physical pods run on the same nodes
- Stronger isolation: each tenant can install CRDs, cluster-scoped resources
- **Tool:** `vcluster` — runs as a pod, creates a virtual API server
- **Limitations:** More resource overhead. Network isolation is still namespace-level.

**Level 3 — Separate clusters (hard multi-tenancy):**
- Each team gets their own EKS cluster
- Complete isolation — API server, nodes, networking
- **Tool:** AWS EKS with separate clusters per workload
- **Limitations:** $$$. Each cluster costs ~$73/month for the control plane.

**My recommendation:** Start with Level 1 (namespaces). Move to Level 3 when you need HIPAA/SOC2 compliance or when teams are large enough to justify cluster costs. Level 2 is an intermediate step but adds operational complexity."

---

## 4. Helm

### Q13: "What's the difference between Helm and Kustomize? When would you pick each?"

**5-year level answer:**

"Both solve the same problem: managing Kubernetes YAML across multiple environments. But they approach it differently.

**Helm = templating engine:**
- Go templates with conditionals, loops, variables, functions
- Charts are self-contained packages — downloadable, versionable, shareable
- Built-in lifecycle management: install, upgrade, rollback, history
- Values cascade: `--set > values-prod.yaml > values.yaml`
- **Strengths:** Complex logic, distributing packages (ArtifactHub), environment-aware manifests

**Kustomize = overlay patching:**
- Pure YAML — no templating language, no programming constructs
- Base + overlays pattern: a base deployment.yaml and patches that modify it
- `kubectl apply -k overlays/prod/` — no separate binary needed
- **Strengths:** Simpler mental model, no template debugging, built into kubectl

**When to pick Helm:**
- You're packaging an application for others to install (e.g., a Helm chart for Postgres)
- You need conditional resources (HPA in prod only, not in dev)
- You need loops for dynamic resource generation (create a Service per port)
- You need complex string manipulation or function pipelines

**When to pick Kustomize:**
- Your team prefers pure YAML over templates
- You have simple overlay needs (change replica count, add an annotation)
- You want simplicity — no Tiller, no separate install tool

**Why I chose Helm for Notes Buddy:** We have 3 environments with significantly different resources — dev has 8 resources, prod has 13. Conditionals like `{{ if .Values.app.hpa.enabled }}` let me use one template for all environments. The values cascade (`values-dev.yaml`, `values-prod.yaml`) cleanly separates config per environment. With Kustomize, I'd need separate overlay patches for each conditional resource, which would be more files and more complexity."

### Q14: "How do you handle secrets in Helm for production? What's the `existingSecret` pattern?"

**5-year level answer:**

"The `existingSecret` pattern is the production-standard approach:

```yaml
# values.yaml
app:
  env:
    # DEV only — plaintext, b64enc at render time
    DB_PASS: notesbuddy
  existingSecret:
    name: notes-buddy-secret
    key: DB_PASS
```

```yaml
# templates/secret.yaml — only creates the Secret when no existingSecret is specified
{{- if not .Values.app.existingSecret.name }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "notes-buddy.fullname" . }}
data:
  DB_PASS: {{ .Values.app.env.DB_PASS | b64enc | quote }}
{{- end }}
```

```yaml
# templates/app-deployment.yaml — reads from existing secret if provided
env:
  - name: DB_PASS
    valueFrom:
      secretKeyRef:
        name: {{ .Values.app.existingSecret.name | default (include "notes-buddy.fullname" .) }}
        key: {{ .Values.app.existingSecret.key | default "DB_PASS" }}
```

**The production flow:**

1. **Terraform** creates an AWS Secrets Manager entry with the real DB password
2. **External Secrets Operator (ESO)** running in the cluster syncs from Secrets Manager to a native Kubernetes Secret
3. **Helm** deploys the app referencing `existingSecret.name: notes-buddy-secret`
4. Helm never touches the actual secret value — it just says "mount this existing Secret as env vars"

**Security benefits:**
- The DB password never exists in Git, Helm values, or Terraform state (ESO reads it at runtime)
- Rotation is managed in Secrets Manager — pods pick up new values on restart
- ESO handles the IAM auth to Secrets Manager via IRSA

This is the pattern used in real enterprises. Helm is aware of secrets but never owns them."

### Q15: "Explain the `checksum/config` annotation pattern. Why is it necessary?"

**5-year level answer:**

"In Kubernetes, when you update a ConfigMap or Secret, the pods consuming it don't automatically restart. Kubernetes says 'you updated the ConfigMap, but the pods are still running with the old values.' This is by design — K8s doesn't restart pods when data changes.

The `checksum/config` annotation solves this:

```yaml
annotations:
  checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

**How it works:**
1. Helm renders `configmap.yaml` → produces a YAML string
2. `sha256sum` hashes that YAML string → `a3f7b8c2d1e...`
3. The hash is injected as a pod template annotation
4. If you change `DB_HOST` in values.yaml → ConfigMap content changes → hash changes → pod template changes → `helm upgrade` triggers a rolling update

**Why hash the entire configmap.yaml instead of individual values?**
Because if you hash individual values, you might miss a change. For example, if you hash `DB_HOST` but someone adds `DB_PORT` to the ConfigMap, the hash wouldn't catch it. Hashing the entire template file captures ALL changes.

**Alternative without this pattern:**
You'd need to manually annotate pods after each config change:
```bash
kubectl rollout restart deployment/notes-buddy -n notes-buddy
```
This is error-prone because people forget. The checksum annotation makes it automatic."

### Q16: "What's the Go template `merge` mutation bug? Why do you hardcode component labels?"

**5-year level answer:**

"Sprig's `merge` function in Go templates modifies the first argument in place:

```yaml
# DON'T DO THIS
{{- $_ := set . "component" "postgres" }}
{{- $labels := merge .Values.labels . }}

# Why this is wrong:
# merge(.Values.labels, .) mutates .Values.labels permanently!
# When the next template runs, .Values.labels has "component: postgres"
# from the previous template.
```

**What happens:**
1. Postgres template runs → merges component label → `.Values.labels` now has `component: postgres`
2. App template runs → uses `.Values.labels` → app pod gets `component: postgres` label too
3. All components get the same component label — incorrect

**The fix is to hardcode the component label in each template:**

```yaml
labels:
  {{- include "notes-buddy.labels" . | nindent 4 }}
  app.kubernetes.io/component: postgres   # hardcoded per template
```

This avoids mutation entirely. Each template sets its own component label explicitly. It's slightly more verbose but 100% correct.

The `include` function is safe — it returns a string, it doesn't mutate anything. The bug only happens with `merge` and `set` functions that modify their arguments."

---

## 5. ArgoCD & GitOps

### Q17: "ArgoCD vs Jenkins for deployments — explain the difference and when you'd use each."

**5-year level answer:**

"CI and CD are different concerns. Jenkins is a CI tool — it builds and tests artifacts. ArgoCD is a CD tool — it deploys artifacts. They complement each other, they're not alternatives.

**Jenkins/GitHub Actions CI pipeline (push-based):**
1. Build Docker image
2. Push to ECR
3. Update kubeconfig
4. `kubectl set image deployment/notes-buddy app=...`

Problems with push-based CD:
- Jenkins needs cluster credentials — if Jenkins is compromised, the cluster is compromised
- No drift detection — if someone manually deletes a pod, Jenkins doesn't recreate it
- No audit trail — you can't easily see 'what changed between this deploy and the last one'

**ArgoCD (pull-based):**
1. CI pipeline builds Docker image, updates the tag in Git (via PR or commit)
2. ArgoCD detects the Git change, compares with cluster state
3. ArgoCD syncs the cluster to match Git

Benefits:
- No cluster credentials outside the cluster — ArgoCD runs inside, pulls from Git
- Continuous drift detection — ArgoCD constantly compares Git vs cluster, fixes manual changes
- Git is the single source of truth — every deploy is a commit, rollback is `git revert`
- Self-heal — someone runs `kubectl delete deployment`, ArgoCD recreates it within seconds

**When to use each:**
- Use Jenkins/GitHub Actions for: build, test, scan, push artifacts
- Use ArgoCD for: deploy, reconcile, manage, rollback
- Use both together: CI builds → updates Git → ArgoCD syncs to cluster

**The hybrid approach I'm building:** GitHub Actions builds + pushes to ECR, then updates the Helm values file in Git. ArgoCD sees the change and syncs the cluster. Two systems, two security boundaries, one pipeline."

### Q18: "Explain the App-of-Apps pattern. Why is it useful?"

**5-year level answer:**

"The App-of-Apps pattern uses a root Application that deploys child Applications:

```yaml
# Root app — created once, never touched again
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/org/repo
    path: argocd/apps   # <-- directory containing child app YAMLs
  destination:
    namespace: argocd
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Child apps are plain Application YAMLs in the `argocd/apps/` directory:
```
argocd/apps/
├── notes-buddy.yaml     # Deploys the main Helm chart
├── monitoring.yaml      # Deploys Prometheus + Grafana
├── ingress.yaml         # Deploys ingress controller
└── secrets.yaml         # Deploys ESO or Sealed Secrets
```

**Why this pattern:**
- **Single entry point** — create one root Application, everything else auto-deploys. Disaster recovery: destroy the entire cluster, create the root app, everything comes back.
- **Git as source of truth** — adding a component = creating a file in Git. No manual CLI commands, no UI clicks.
- **Team autonomy** — each team owns their child Application YAML. Changes to one app don't affect others.
- **Policy-as-code** — you can enforce that child apps use specific projects, clusters, or sync policies via ArgoCD ApplicationSet CRDs.

**The real interview answer:**
> 'When I start a new microservice, I create a YAML file in the argocd/apps directory. The root app picks it up automatically, ArgoCD deploys it. I don't touch ArgoCD configuration, I don't run CLI commands, I don't click buttons. Git is the deployment interface.'"

### Q19: "What happens during an ArgoCD sync when the Helm chart has a breaking change?"

**5-year level answer:**

"ArgoCD allows phased rollouts through **sync waves**. Each resource in a Helm chart can be annotated with a wave number:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "5"
```

Default wave is 0. Lower numbers sync first. Resources in the same wave sync in parallel. A wave doesn't start until all resources in the previous wave are healthy.

**Breaking change scenario:**
1. New Helm chart changes the DB schema
2. Old app pods can't connect to the new schema
3. If app and DB are in the same wave (both wave 0), the app deploys before DB migration runs → pod crash

**Fix with sync waves:**
```
Wave 0: ConfigMap, Secret (non-breaking, changes take effect immediately)
Wave 1: Postgres StatefulSet (DB upgrade, schema migration)
Wave 2: App Deployment (new code that expects new schema)
```

**Rollback strategy:**
If the breaking change causes issues:
1. Revert the Git commit
2. ArgoCD detects the change, syncs the old state
3. Delete the new Postgres PVC (or rely on backup restore)
4. Re-deploy old app version

**The critical insight:** Sync waves don't solve every problem. If Postgres needs a manual migration script between versions, that script must run outside of ArgoCD (as a Job or Operator hook). Sync waves only handle K8s resource ordering, not data migration."

---

## 6. CI/CD & GitHub Actions

### Q20: "Design a CI/CD pipeline for a monorepo with a Java backend and React frontend that deploy differently."

**5-year level answer:**

"A monorepo with different deploy strategies for backend and frontend needs a pipeline that knows what changed:

```yaml
name: Monorepo CI/CD

on:
  push:
    branches: [main]

jobs:
  detect-changes:
    runs-on: ubuntu-latest
    outputs:
      backend: ${{ steps.filter.outputs.backend }}
      frontend: ${{ steps.filter.outputs.frontend }}
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v3
        id: filter
        with:
          filters: |
            backend:
              - 'backend/**'
              - 'pom.xml'
            frontend:
              - 'frontend/**'
              - 'package.json'

  backend:
    needs: detect-changes
    if: needs.detect-changes.outputs.backend == 'true'
    steps:
      - Build Java app (Maven)
      - Build Docker image
      - Push to ECR
      - Deploy to EKS (rolling update)
      - Wait for rollout status

  frontend:
    needs: detect-changes
    if: needs.detect-changes.outputs.frontend == 'true'
    steps:
      - Build React app (npm)
      - Upload static files to S3
      - Invalidate CloudFront cache
```

**Key decisions:**
- **Conditional execution** — don't build what didn't change. Saves time and money.
- **Parallel backend+frontend** — they're independent, deploy simultaneously.
- **Different deploy strategies** — backend is rolling update (requires readiness probes). Frontend is S3 + CloudFront invalidation (instant).
- **Rollback plan** — backend: `kubectl rollout undo`. Frontend: restore S3 from versioning + revert CloudFront.

**What our Notes Buddy pipeline does (simpler, single deployable):**
1. Checkout → 2. OIDC Auth → 3. Build Docker → 4. Push to ECR → 5. kubectl set image → 6. Verify rollout"

### Q21: "A deployment fails — pods don't become Ready. The pipeline times out after 2 minutes. Walk me through your incident response."

**5-year level answer:**

"**Phase 1 — Immediate response (first 2 minutes):**

```bash
# 1. Check the deployment status
kubectl rollout status deployment/notes-buddy -n notes-buddy

# 2. Get the ReplicaSet that's failing
kubectl describe replicaset -n notes-buddy | grep -A 5 "Conditions:"

# 3. Check pod status
kubectl get pods -n notes-buddy
# Look for: CrashLoopBackOff, ImagePullBackOff, Pending, RunContainerError

# 4. Check pod events
kubectl describe pod -n notes-buddy notes-buddy-xxx
```

**Phase 2 — Rollback (don't debug during an incident):**
If production is down, roll back first, debug second:
```bash
kubectl rollout undo deployment/notes-buddy -n notes-buddy
# Or with Helm:
helm rollback notes-buddy 2 -n notes-buddy
```

**Phase 3 — Root cause analysis:**
Common failure modes:
- **ImagePullBackOff:** Image tag doesn't exist in ECR. Check `kubectl describe pod` for the exact error. Fix: push the image first, then deploy.
- **CrashLoopBackOff:** App crashes on startup. `kubectl logs --previous`. Common causes: DB connection refused (DB not ready), port already in use, missing env var.
- **Pending:** PVC not bound (EBS CSI issue), resource limits too high for any node, node port exhausted.
- **Readiness probe failing:** The app is running but doesn't pass `/actuator/health`. Check logs for why health endpoint is returning 503.

**The actual issue from our project:** Deployment failed because the ConfigMap had `DB_HOST: notes-buddy-postgres` but the Postgres service was named `postgres`. The app started, tried to connect to the wrong host, failed, crashed, container restarted → CrashLoopBackOff. Fix: corrected the ConfigMap value."

---

## 7. Docker

### Q22: "Explain Docker layer caching. How does a multi-stage build work?"

**5-year level answer:**

"Each Docker instruction creates a layer. Layers are cached and reused if nothing changed.

**Why multi-stage build matters:**
Without multi-stage, a Maven + JDK image is ~600MB. With multi-stage, the final image is ~180MB:

```dockerfile
# Stage 1: Build (has Maven, JDK, all dependencies)
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
# Copy pom.xml FIRST — dependency layer caching
COPY pom.xml .
RUN mvn dependency:go-offline   # Downloads all Maven deps
# Copy source SECOND — only rebuilds when code changes
COPY src ./src
RUN mvn package -DskipTests

# Stage 2: Runtime (only JRE, no Maven)
FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
EXPOSE 9098
ENTRYPOINT ["java", "-jar", "app.jar"]
```

**Layer caching optimization:**
1. `COPY pom.xml .` + `RUN mvn dependency:go-offline` — these two lines are cached as long as `pom.xml` doesn't change. Dependencies download once, never again.
2. `COPY src ./src` — this layer invalidates when any source file changes.
3. `RUN mvn package` — always runs when source changes, but dependency download is cached.

Without this optimization, every code change would re-download all Maven dependencies from scratch. Build time drops from 5 minutes to 30 seconds.

**Other caching tricks:**
- `.dockerignore` — exclude `target/`, `.git/`, `node_modules/` → smaller build context → faster Docker builds
- `apk add --no-cache` — don't cache package index in Alpine (saves ~5MB)"
- `COPY --chown` — avoid permission issues in runtime containers"

### Q23: "A Docker container exits immediately with exit code 0. What's happening?"

**5-year level answer:**

"Exit code 0 means the main process finished successfully. The container exited because the process ran and completed — it wasn't designed to stay running.

**Common causes:**
1. **Command syntax error** — `CMD ["java", "-jar", "app.jar"]` is correct. `CMD java -jar app.jar` is shell form. But `CMD java -jar` (missing args) would run and exit immediately.
2. **Background process** — `CMD java -jar app.jar &` runs in background, then the shell script exits with 0. The container exits because the shell (PID 1) finished.
3. **Misconfigured entrypoint** — The entrypoint script runs, completes, exits. It should `exec` the main process to replace itself.
4. **Volume mount overwrites** — A volume mount at `/app` might overwrite the JAR file, leaving no executable.

**Debugging:**
```bash
# Check what command ran
docker inspect container-name --format '{{.Config.Cmd}}'

# Run with a different entrypoint to inspect
docker run -it --entrypoint sh image-name
# Inside: look around, run the command manually and see what it does
```

**Fix:** Ensure the main process runs in the foreground. For Java: `ENTRYPOINT ["java", "-jar", "app.jar"]`. For shell scripts: `exec java -jar app.jar` (the `exec` replaces the shell with the Java process)."

---

## 8. Observability & SRE

### Q24: "You need to set up monitoring for a production Kubernetes cluster. Design the stack."

**5-year level answer:**

"A production observability stack has four layers:

**Layer 1 — Metrics (numeric, time-series):**
- **Prometheus** scrapes metrics from pods, nodes, and the cluster itself
- Key metrics: CPU/memory per pod, request rate, error rate, latency (p50/p95/p99)
- ServiceMonitors (Prometheus Operator) dynamically discover new pods
- Retention: ~30 days locally, longer in Thanos/Cortex

**Layer 2 — Logs (textual, searchable):**
- **fluent-bit** (DaemonSet) reads container logs, adds K8s metadata, ships to Elasticsearch or Loki
- Loki is cheaper than Elasticsearch — it indexes labels, not full text
- Retention: ~7 days for hot storage, longer in S3

**Layer 3 — Tracing (request-level, distributed):**
- **Jaeger or Tempo** traces requests across services
- Spring Boot integrates via Micrometer Tracing + Brave
- Answers: 'which service is slow' and 'where does this error originate'

**Layer 4 — Alerting & Dashboards:**
- **Grafana** visualizes everything
- **AlertManager** routes alerts: critical→PagerDuty, warning→Slack
- Four golden signals: Latency, Traffic, Errors, Saturation (USE method for resources)

**What we built for Notes Buddy:**
- Prometheus scrapes `/actuator/prometheus` (8 custom Micrometer metrics)
- 4 alerting rules: AppDown, HighErrorRate (>20%), IngestionStopped, SearchLatencyHigh
- Grafana dashboard with 8 panels
- Runs locally in Docker — no external services

**What production adds:**
- Persistent storage for Prometheus (EBS volume)
- AlertManager with Slack/PagerDuty integration
- kube-state-metrics + node-exporter for cluster-level metrics
- PodMonitors for auto-discovery of new deployments"

### Q25: "What four golden signals would you monitor for Notes Buddy? What SLO would you set?"

**5-year level answer:**

"**Four golden signals for Notes Buddy:**

| Signal | Metric | SLO | Why |
|--------|--------|-----|-----|
| **Latency** | p95 search query time | < 2 seconds | Users searching their history — slow search is frustrating |
| **Traffic** | Commands ingested per minute | > 0 for 10 consecutive minutes | If ingestion stops, the app stops collecting data — data loss risk |
| **Errors** | % of failed commands | < 5% | Failed commands mean the terminal history isn't being captured |
| **Saturation** | App CPU < 80%, DB connections < 80% | < 80% | Need headroom for traffic spikes |

**SLO framework:**
- **Latency SLO:** 99% of search requests complete in < 2 seconds over a 30-day window
- **Error Budget:** 1% of total search requests can fail in 30 days = ~432 minutes of downtime
- **Burn Rate:** If 5% of requests are slow, we're burning error budget 5x faster. Alert when burn rate > 2x for 1 hour.

**Why these SLOs matter:**
A 99% latency SLO means we accept that 1 in 100 searches is slow. That's a deliberate trade-off — we could optimize further, but it costs more. The error budget tells us when to prioritize reliability over features.

For Notes Buddy, the most critical metric is **IngestionStopped** — if the app stops collecting commands, it's not just degraded, it's failing its core purpose."

---

## 9. System Design

### Q26: "Design a URL shortener like TinyURL. Walk through the architecture, scaling, and trade-offs."

**5-year level answer:**

"**Requirements:**
- Create short URLs + redirect to long URLs
- 100M new URLs/month, 10B redirects/month
- Redirect latency < 10ms
- High availability (99.99% uptime)

**High-level design:**

```
Client → Load Balancer → Web Servers → Cache (Redis) → Database
                                         ↓
                                    Analytics Service
```

**Key design decisions:**

1. **Key generation:** Base62 encoding (a-z, A-Z, 0-9 = 62 chars). 7 chars = 62^7 = ~3.5 trillion combinations. Generate random keys, check uniqueness, retry on collision.

2. **Database:** Not just one. Two layers:
   - **Write DB (relational):** PostgreSQL or Aurora for short→long mapping. Strong consistency for writes.
   - **Read Cache (Redis):** Cache frequent lookups. TTL of 24 hours. 99% cache hit rate expected.

3. **Read path:** Check Redis first → if miss, check DB → write to Redis → return redirect. Reads far outnumber writes (100:1 ratio).

4. **Write path:** Generate key → check DB for collision → write to DB → invalidate any stale cache entry.

5. **Scaling:**
   - **Web tier:** Horizontal scaling behind ALB. Stateless, easy.
   - **Cache tier:** Redis Cluster with sharding (key hash → shard).
   - **DB tier:** Read replicas for redirect queries. Primary for writes. Consider sharding by key hash for extreme scale.

**Could this run on Kubernetes?** Yes. Our EKS setup + Helm charts + ArgoCD would deploy this cleanly. Stateless web tier = Deployment + HPA. Redis = StatefulSet. DB = RDS outside K8s."

### Q27: "You have a monolithic Spring Boot app. How would you decompose it into microservices?"

**5-year level answer:**

"**Phase 1 — Identify boundaries (don't break anything yet):**

Look for natural seams in the codebase:
- Different rate of change — login changes monthly, search changes weekly
- Different resource needs — ingestion is CPU-bound, dashboard is memory-bound
- Different scaling patterns — API needs 3 replicas, batch jobs need 10
- Team ownership — which team owns what

For Notes Buddy, potential services:
- **Ingestion Service** — receives commands from terminal. CPU-light, needs high availability.
- **Search Service** — full-text search. Memory-heavy (indexes). Needs more replicas.
- **Dashboard API** — serves the UI. Stateless, easy to scale.
- **Metrics Service** — Prometheus scraping + Micrometer. Low traffic, critical for SRE.

**Phase 2 — Strangler Fig pattern (incremental migration):**

```java
// Step 1: Add a proxy layer
@RestController
class CommandController {
    private final IngestionServiceClient ingestionClient; // HTTP client to new service
    private final LegacyCommandService legacyService;     // Old local service

    @PostMapping("/ingest")
    ResponseEntity<?> ingest(@RequestParam String text) {
        // Try new service first, fall back to legacy
        try {
            return ingestionClient.ingest(text);
        } catch (TimeoutException e) {
            return legacyService.ingest(text);
        }
    }
}
```

**Phase 3 — Shared database is the biggest risk:**
Microservices sharing a database = distributed monolith. Each service needs its own database schema. Use event-driven sync (Kafka) for cross-service data needs. The search service shouldn't query the ingestion service's database directly.

**When NOT to decomose:**
- Team is 1-5 people — monolith is faster
- The bounded contexts aren't clear — premature decomposition creates more problems
- Operational maturity isn't there — you need CI/CD, monitoring, and deployment automation first

For Notes Buddy, a monolith is correct. It's a single-person project with clear boundaries already (controller → service → repository). No team to coordinate, no need for independent deployment."

---

## 10. Security

### Q28: "You get a pentest report. Critical finding: 'Kubernetes secrets are base64 encoded, not encrypted.' Respond."

**5-year level answer:**

"First, acknowledge the finding — it's correct. Base64 is encoding, not encryption. Anyone with `get secret` permission can decode it immediately.

**My response to the finding, layer by layer:**

**Layer 1 — Default protection (current state):**
Base64 is the same security level as leaving your front door unlocked but invisible. The only protection is RBAC — who can `kubectl get secrets`. Our RBAC restricts secret access to the deployment service account and cluster admins. This is the minimum.

**Layer 2 — Encryption at rest:**
Enable KMS-backed encryption for Kubernetes Secrets. This requires:
- A KMS key in AWS
- The `kms` encryption provider in kube-apiserver
- After enabling, existing secrets need re-creation (encryption happens on write)

**Layer 3 — External Secrets Operator (production fix):**
Don't use native K8s Secrets for sensitive data at all:
1. Store secrets in AWS Secrets Manager (encrypted at rest with KMS)
2. ESO syncs to K8s Secrets (ephemeral, created when pod starts)
3. Helm uses `existingSecret` pattern — never creates Secrets containing real values
4. IRSA gives ESO permission to read Secrets Manager

**Layer 4 — Rotation:**
Secret rotation is automatic with Secrets Manager. The ESO controller picks up changes within minutes.

**What this looks like in practice:**
- Terraform manages: Secrets Manager entries, ESO IAM role, IRSA
- ESO runs: syncs secrets automatically
- Helm deploys: uses `existingSecret` reference
- The DB password exists in: AWS Secrets Manager (encrypted), RAM (for a running pod), nowhere else

The pentest finding is valid but it's a risk assessment question, not an emergency. Base64 without RBAC is the real problem. Fix RBAC first, then encryption."

---

## 11. Behavioral & Incident Response

### Q29: "Tell me about a time you caused a production incident. What happened and what did you learn?"

**5-year level answer (STAR format):**

"**Situation:** I was deploying a configuration change to a Kubernetes cluster that served customer-facing APIs.

**Task:** Update the `DB_POOL_SIZE` environment variable from 10 to 50 to handle increased traffic.

**Action:** I edited the ConfigMap directly on the cluster (`kubectl edit configmap app-config -n production`) and saved. The pod didn't restart (Kubernetes doesn't restart pods on ConfigMap changes). I expected the app to pick up the new value.

**Result:** The app didn't pick up the change. I manually restarted the pods (`kubectl rollout restart deployment/app`). When they came up, the database connection pool jumped from 10 to 50. The database couldn't handle 50 concurrent connections from each of 5 pods = 250 connections total. The database CPU spiked to 100%, queries timed out, and the app went down.

**Fix:** I scaled the deployment back to 0, waited for the database to recover, tuned `max_connections` in Postgres from 100 to 300, then scaled back up gradually.

**Learnings:**
1. **ConfigMap changes don't trigger pod restarts** — I now use the `checksum/config` annotation in Helm to automate restarts. This is why I built that pattern into our Helm charts.
2. **Connection pool changes need database capacity planning** — a 5x increase in pool size affects the database, not just the app.
3. **Never deploy config+code simultaneously** — change config OR code, not both in one deployment.
4. **Gradual rollout** — if I had changed one pod first and monitored, I would have caught the database issue before all pods restarted.

Now every change goes through a PR review with a checklist that includes 'does this affect database capacity?' and 'does this need a Helm upgrade or just a config change?'"

### Q30: "Your manager asks you to estimate a project to set up a production Kubernetes cluster from scratch. What factors do you consider?"

**5-year level answer:**

"**Infrastructure costs:**
- EKS control plane: ~$73/month per cluster
- Node instances: 3 x t3.medium = ~$90/month (or spot for ~$27/month)
- NAT Gateway (if private subnets): ~$32/month
- Load Balancer: ~$20/month
- EBS volumes: ~$10/month per 100GB
- **Total: ~$225/month minimum**

**Time estimates for a 2-person team:**

| Task | Time | Dependencies |
|------|------|-------------|
| VPC + networking | 2-3 days | Design doc |
| EKS cluster + node group | 1-2 days | VPC ready |
| EBS CSI + IRSA | 1 day | Cluster ready |
| Container registry | 0.5 day | EKS ready |
| Helm chart for app | 3-5 days | Pipeline ready |
| CI/CD pipeline | 2-3 days | Registry ready |
| Monitoring + alerting | 3-5 days | App deployed |
| Security hardening | 2-3 days | Everything above |
| **Total** | **~3-4 weeks** | |

**Operational considerations:**
- **Backup:** Velero for cluster state + EBS snapshots for persistent data
- **Disaster recovery:** Multi-region or single-region? RTO/RPO requirements?
- **Compliance:** SOC2, HIPAA, PCI? Each adds significant overhead (audit logging, encryption, access controls)
- **Team readiness:** Does the team know Kubernetes? If not, add 2 weeks for training

**Risk factors that blow up timelines:**
- First-time Kubernetes setup (it's always harder than you think) — add 50%
- Legacy application containerization — add 100% if the app wasn't designed for containers
- Compliance requirements — add 2-4 weeks for each certification

For Notes Buddy: 15 days for a single person with no prior K8s experience. A team of 2 experienced engineers could do the same in 3-4 weeks of focused work, or 2-3 months with competing priorities."

---

## Quick Reference Card

### Must-Know Architecture Numbers

| Feature | Detail |
|---------|--------|
| EKS cluster cost | ~$73/mo control plane |
| t3.small cost | ~$0.0208/hr (~$15/mo) |
| NAT Gateway | ~$32/mo |
| ALB | ~$20/mo + $0.008/LCU-hour |
| EBS gp3 | $0.08/GB-month |
| Terraform state encryption | SSE-AES256 (S3) |
| OIDC token validity | 1 hour (configurable to 12h) |
| Helm checksum annotation | Triggers rolling update on config change |
| HPA scale-up stabilization | 0 seconds (immediate) |
| HPA scale-down stabilization | 300 seconds (5 min) |
| PDB minAvailable | 2 (requires 3+ replicas) |

### One-Liners Per Topic

| Topic | One-Liner Answer |
|-------|-----------------|
| Terraform | "Declarative IaC with DAG-based parallelism, S3 remote state, DynamoDB locking." |
| OIDC | "JWT from GitHub → STS AssumeRoleWithWebIdentity → temporary AWS credentials. Zero static keys." |
| IRSA | "Pod assumes IAM role via OIDC token injection — no instance profile sharing." |
| HPA | "Horizontal scaling based on CPU/memory — behavior tuning prevents flapping." |
| PDB | "Guarantees minimum available pods during voluntary disruptions (node drains, upgrades)." |
| Helm | "Templated Kubernetes manifests with values cascade, lifecycle management, checksum-driven restarts." |
| Multi-stage Docker | "Build stage has Maven+JDK (600MB), runtime stage has only JRE+JAR (180MB)." |
| SRE Golden Signals | "Latency, Traffic, Errors, Saturation — measure everything, SLO what matters, error budget the rest." |

---

## ArgoCD Troubleshooting — Day 16 Real Incidents

### Q: "ArgoCD shows OutOfSync with a PVC patch error. How do you debug?"

**Symptom:** Application status is `OutOfSync | Degraded`. Error message: "persistentvolumeclaims is forbidden: only dynamically provisioned pvc can be resized and the storageclass that provisions the pvc must support resize."

**Debug flow:**
1. `kubectl get application -n argocd notes-buddy -o yaml` → check `status.conditions` for the exact error
2. `kubectl get pvc -n notes-buddy` → check current PVC size vs Helm values
3. `kubectl get storageclass gp2 -o yaml` → check `allowVolumeExpansion: false` (gp2 on EKS doesn't support resize)
4. Check `helm/notes-buddy/values-staging.yaml` — find `persistence.size`

**Root cause:** Git has `5Gi`, running PVC is `1Gi`. The `gp2` StorageClass has `allowVolumeExpansion: false` — ArgoCD can't patch the PVC to match Git.

**Fix:** Update Git to match the running state (1Gi), not the other way around. Push to GitHub → ArgoCD auto-syncs.

**Lesson:** Not all drift should be fixed by changing the cluster. When the running resource can't be modified (PVC resize, immutable fields), change Git to match reality.

### Q: "How do you recover from a deadlocked rolling update on fully loaded nodes?"

**Context:** 2 t3.small nodes, 11 pods each (max capacity). Deployment strategy: `RollingUpdate` with `maxSurge: 1, maxUnavailable: 0`.

**Problem sequence:**
1. A new ReplicaSet is created (pod template changed)
2. New pod stays `Pending` — `0/2 nodes available: 2 Too many pods`
3. Old ReplicaSet pods stay running (maxUnavailable: 0 prevents scale-down)
4. System is deadlocked — no way to complete the rollout

**Immediate fix:**
```bash
# 1. Identify the old RS (the one running the current pods)
kubectl get rs -n notes-buddy -l app.kubernetes.io/component=app

# 2. Scale old RS to 0 — frees capacity
kubectl scale rs -n notes-buddy <old-rs-name> --replicas=0

# 3. New pods schedule and become Ready
kubectl get pods -n notes-buddy -w
```

**Long-term prevention:**
- Option A: Larger nodes (e.g., t3.medium, 17 pods each) — more headroom
- Option B: Change deployment strategy to `maxSurge: 0, maxUnavailable: 1` — kills old pod before creating new one
- Option C: Use PDB + HPA to maintain spare capacity
- Option D: Add a node via cluster autoscaler before triggering the update

**Trade-off:** `maxSurge: 0, maxUnavailable: 1` causes brief downtime during rolling updates (1 replica unavailable). `maxSurge: 1, maxUnavailable: 0` requires spare capacity but has zero downtime.

### Q: "A PVC is stuck in Terminating. How do you force-delete it?"

**Problem:** `kubectl delete pvc` → PVC stays `Terminating` forever.

**Root cause:** A finalizer is blocking deletion. Usually because a pod still has the volume mounted, or the PV is still referenced.

**Fix:**
```bash
# Step 1: Remove finalizers
kubectl patch pvc -n <ns> <pvc-name> -p '{"metadata":{"finalizers":[]}}' --type=merge

# Step 2: If PV still exists in Released/Terminating state, delete it
kubectl delete pv <pv-name>

# Step 3: New PVC will be provisioned by the StorageClass
kubectl get pvc -n <ns> -w
```

**Why this happens:** When you force-delete a PVC with `--force --grace-period=0`, Kubernetes removes the resource from etcd but the actual volume on the storage backend still exists. The finalizer prevents orphaned volumes. Removing the finalizer is the escape hatch — but you lose the data on the volume.

**Production recommendation:** Before force-deleting, verify the pod isn't critical. For stateful workloads (PostgreSQL), back up the data first. In our case, the data was seed data, so loss was acceptable.

### Q: "How does ArgoCD self-heal interact with manual kubectl patches?"

**Scenario:** A developer runs `kubectl patch deployment ... set imagePullPolicy=Always`. Later, ArgoCD's self-heal reverts it.

**Why this happens:** ArgoCD's self-heal runs every 3 minutes (default poll interval). It compares every resource's current state against the desired state from Git. Any difference is reverted automatically.

**The problem:** The manual patch was intentional — the developer needed `Always` to force fresh image pulls. But SelfHeal reverted it to `IfNotPresent` (the Git state). This created a new ReplicaSet (new pod template), but the old RS pods kept running with `Always`. The new RS pod couldn't schedule (no capacity). Deadlock.

**The fix:** Update Git to match the intentional change:
```bash
# Edit the Helm values to include Always
# values-staging.yaml
image:
  pullPolicy: Always

# Push to GitHub → ArgoCD syncs → now Always is the desired state
```

**Key insight:** Self-heal is a safety net against accidental drift. If the drift is intentional, the fix is always to update Git, not fight the self-heal. `argocd app disable-self-heal` is available but defeats the purpose of GitOps.

### Q: "After deleting a PVC, the app returns 500: 'relation command does not exist'. How do you fix it?"

**Root cause:** The PVC was the database volume for PostgreSQL. After deletion, the new PVC is empty — no database, no tables. Hibernate's `ddl-auto=update` creates tables at startup, but the app connected to the fresh DB before any query was attempted. The error only appears when an API call triggers a query.

**Fix:**
```bash
kubectl rollout restart deployment notes-buddy-app -n notes-buddy
```

**Why restart fixes it:** On startup, Hibernate checks `SELECT 1 FROM command` — table doesn't exist → `ddl-auto=update` runs `CREATE TABLE`. After restart, all queries succeed.

**Why it didn't create tables the first time:** The app started before Postgres was fully initialized (or the fresh PVC wasn't ready yet). Hibernate silently fails schema creation if the DB connection fails. The app starts, but queries fail later.

**Prevention:** Add an init container that waits for the database to be ready and schema to be created. Or use a startup script that runs `CREATE TABLE IF NOT EXISTS` before the app starts.

