# Day 6 — EKS Deployment + Stress Test

## What We Built
Deployed Notes Buddy to AWS EKS (Elastic Kubernetes Service).
Real cluster. Real database. Real public URL. Real stress test.
500 concurrent requests. Zero failures.

---

## The Full Picture — What Was Running at the End

```
Your Laptop (Git Bash)
    writes → ~/.notes_buddy_log
    (log file stays local — EKS pod can't see it yet, Month 2 fix)

AWS ap-south-1 (Mumbai)
┌─────────────────────────────────────────────────────────┐
│  EKS Cluster: notes-buddy                               │
│  2 nodes, t3.small, Kubernetes 1.34                     │
│                                                         │
│  Namespace: notes-buddy                                 │
│  ┌───────────────────────────────────────────────────┐  │
│  │                                                   │  │
│  │  postgres pod (1/1 Running)                       │  │
│  │    image: postgres:16-alpine                      │  │
│  │    storage: 1Gi EBS gp2 volume (persistent)       │  │
│  │    env: from ConfigMap + Secret                   │  │
│  │    service: postgres-service (ClusterIP :5432)    │  │
│  │                                                   │  │
│  │  notes-buddy pod (1/1 Running)                    │  │
│  │    image: ECR → notes-buddy:latest                │  │
│  │    env: from ConfigMap + Secret                   │  │
│  │    probes: /actuator/health (liveness+readiness)  │  │
│  │    service: notes-buddy-service (LoadBalancer :80)│  │
│  │                                                   │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│  AWS LoadBalancer (ALB)                                 │
│  a0efb8d5...ap-south-1.elb.amazonaws.com               │
│                                                         │
└─────────────────────────────────────────────────────────┘
        ▲
        │  HTTP :80
        │
    Your Browser
```

---

## Tools Used

| Tool | Version | What It Does |
|------|---------|-------------|
| `aws cli` | 2.33.17 | talks to AWS APIs |
| `eksctl` | 0.229.0 | creates/manages EKS clusters |
| `kubectl` | v1.29.2 | talks to Kubernetes API |
| `docker` | latest | builds and tags images |

---

## Step-by-Step — Everything We Did

### Step 1 — Install eksctl
`eksctl` wasn't installed. Downloaded the Windows binary from GitHub releases.
Moved to `/c/Users/Lenovo/eksctl/eksctl.exe`.
Added to PATH in `.bashrc`:
```bash
export PATH=$PATH:/c/Users/Lenovo/eksctl
```

**Why eksctl and not raw AWS CLI?**
Creating an EKS cluster manually via AWS CLI requires 15+ separate API calls —
VPC, subnets, IAM roles, security groups, node groups, addons.
`eksctl` wraps all of that into one command. It uses CloudFormation under the hood.

---

### Step 2 — Create ECR Repository
ECR = Elastic Container Registry. AWS's private Docker Hub.
EKS nodes can't pull from your local Docker. They need the image in a registry they can reach.

```bash
aws ecr create-repository \
  --repository-name notes-buddy \
  --region ap-south-1
```

Returns `repositoryUri`:
`083777493383.dkr.ecr.ap-south-1.amazonaws.com/notes-buddy`

**Authenticate Docker to ECR:**
```bash
aws ecr get-login-password --region ap-south-1 \
  | docker login --username AWS --password-stdin \
    083777493383.dkr.ecr.ap-south-1.amazonaws.com
```

`get-login-password` calls AWS STS, gets a temporary token valid for 12 hours.
Pipes it to `docker login`. After this Docker can push/pull from ECR.

**Tag and push:**
```bash
docker tag notes-buddy:latest \
  083777493383.dkr.ecr.ap-south-1.amazonaws.com/notes-buddy:latest

docker push \
  083777493383.dkr.ecr.ap-south-1.amazonaws.com/notes-buddy:latest
```

---

### Step 3 — Create EKS Cluster

```bash
eksctl create cluster \
  --name notes-buddy \
  --region ap-south-1 \
  --nodegroup-name notes-buddy-nodes \
  --node-type t3.small \
  --nodes 2 \
  --nodes-min 1 \
  --nodes-max 3 \
  --managed
```

**What this created behind the scenes (CloudFormation):**
- VPC with public + private subnets across 3 AZs (ap-south-1a, 1b, 1c)
- Internet Gateway + NAT Gateway
- EKS Control Plane (managed by AWS — you never touch this)
- Managed Node Group — 2 x t3.small EC2 instances
- IAM roles for nodes and control plane
- Security groups
- CoreDNS, kube-proxy, vpc-cni, metrics-server addons

Took ~18 minutes. This is normal.

**Why t3.small not t3.micro?**
t3.micro = 1GB RAM. Spring Boot alone needs ~256Mi. Add PostgreSQL (~50Mi),
system processes, K8s agent — you'd OOMKill constantly.
t3.small = 2GB RAM. Comfortable headroom.

**Why --managed?**
AWS manages the node group — OS patching, K8s version upgrades, replacement of unhealthy nodes.
Unmanaged = you do all that yourself. Always use managed for learning and production.

---

### Step 4 — Connect kubectl to EKS

```bash
aws eks update-kubeconfig --region ap-south-1 --name notes-buddy
```

This writes a new context to `~/.kube/config`.
Before this command, kubectl only knew about minikube and GKE contexts.
After: `kubectl config current-context` returns the EKS ARN.

---

### Step 5 — Write K8s YAML Files

**namespace.yaml**
Isolates all Notes Buddy resources. Delete the namespace = delete everything inside it.
Every resource has `namespace: notes-buddy` in metadata.

**configmap.yaml**
Non-sensitive config as key-value pairs.
Injected into pods as environment variables.
`DB_HOST: "postgres-service"` — K8s DNS resolves service names automatically.
Same concept as Docker Compose service names.

**secret.yaml**
Sensitive values. Base64 encoded (NOT encrypted — just encoded).
`echo -n "notesbuddy" | base64` → `bm90ZXNidWRkeQ==`
In production: use AWS Secrets Manager or External Secrets Operator.

**postgres.yaml** — 3 resources:
- PersistentVolumeClaim: requests 1Gi EBS storage
- Deployment: runs postgres:16-alpine
- Service (ClusterIP): gives Postgres a stable DNS name inside cluster

**notes-buddy.yaml** — 2 resources:
- Deployment: runs the Spring Boot app from ECR
- Service (LoadBalancer): provisions AWS ALB, exposes port 80 publicly

---

## Problems We Hit — Every Single One

### Problem 1 — eksctl not found
```
bash: eksctl: command not found
```
**Cause:** Binary downloaded but not on PATH.
**Fix:** `export PATH=$PATH:/c/Users/Lenovo/eksctl` + added to `.bashrc`.
**Learning:** PATH is just a list of directories the shell searches for executables.
Adding a directory to PATH makes any binary in it runnable by name.

---

### Problem 2 — PVC stuck in Pending
```
postgres-pvc   Pending
```
**Cause:** EBS CSI driver not installed. EKS doesn't install it by default since K8s 1.23.
The CSI (Container Storage Interface) driver is what translates a PVC request
into an actual EBS volume creation API call to AWS.
Without it, the PVC just sits there waiting forever.

**Fix:**
```bash
eksctl create addon \
  --name aws-ebs-csi-driver \
  --cluster notes-buddy \
  --region ap-south-1 \
  --force
```

---

### Problem 3 — EBS CSI Controller CrashLoopBackOff
```
ebs-csi-controller   1/6   CrashLoopBackOff
```
**Cause:** The CSI controller needs IAM permissions to call AWS EBS APIs
(create volume, attach volume, delete volume). But OIDC was disabled on the cluster,
so it couldn't get those permissions via pod identity.

**What is OIDC?**
OpenID Connect. A way for K8s service accounts to assume IAM roles.
Without OIDC: pods can't get AWS credentials securely.
With OIDC: a pod's service account maps to an IAM role. Pod gets temporary credentials automatically.

**Fix — 2 steps:**
```bash
# Step 1: enable OIDC on the cluster
eksctl utils associate-iam-oidc-provider \
  --cluster notes-buddy \
  --region ap-south-1 \
  --approve

# Step 2: create IAM service account for the CSI driver
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster notes-buddy \
  --region ap-south-1 \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve \
  --override-existing-serviceaccounts
```

Then restart the controller:
```bash
kubectl rollout restart deployment ebs-csi-controller -n kube-system
```

---

### Problem 4 — Postgres CrashLoopBackOff (lost+found)
```
initdb: error: directory "/var/lib/postgresql/data" exists but is not empty
initdb: detail: It contains a lost+found directory
```
**Cause:** When EBS formats a volume with ext4 filesystem, it creates a `lost+found`
directory at the root. PostgreSQL refuses to initialize in a non-empty directory.

**Fix:** Use `subPath` to mount a subdirectory of the volume, not the root:
```yaml
volumeMounts:
  - name: postgres-storage
    mountPath: /var/lib/postgresql/data
    subPath: pgdata        # mount only the pgdata subdirectory
env:
  - name: PGDATA
    value: /var/lib/postgresql/data/pgdata
```
`subPath: pgdata` tells K8s: create a `pgdata` folder inside the EBS volume
and mount only that. PostgreSQL never sees `lost+found`.

---

### Problem 5 — Postgres Permission Denied
```
mkdir: can't create directory '/var/lib/postgresql/data/pgdata': Permission denied
```
**Cause:** EBS volume is owned by root (UID 0). The postgres process inside
the container runs as UID 999 (the `postgres` user in Alpine Linux).
UID 999 can't write to a directory owned by root.

**Fix:** `securityContext.fsGroup`:
```yaml
spec:
  securityContext:
    fsGroup: 999
```
`fsGroup` tells K8s: before starting any container in this pod,
run `chown -R :999` on all mounted volumes.
So the EBS volume becomes group-owned by GID 999 = postgres group.
The postgres process can now write to it.

**Why fsGroup not runAsUser?**
`runAsUser: 999` would make the container run as postgres user.
But the volume chown happens at pod startup before containers start.
`fsGroup` is specifically designed for this — it's the "volume ownership" field.

---

### Problem 6 — kubectl no current context
```
error: current-context is not set
```
**Cause:** kubectl config had minikube and GKE contexts but not EKS.
EKS cluster was created but kubeconfig wasn't updated.

**Fix:**
```bash
aws eks update-kubeconfig --region ap-south-1 --name notes-buddy
```

---

### Problem 7 — Docker volume mount not working locally
```
Waiting for log file: /root/.notes_buddy_log
```
**Cause:** On Windows, Git Bash `$HOME` = `/c/Users/Lenovo` (Unix path).
Docker Desktop on Windows needs `C:/Users/Lenovo` (Windows path).
`-v "$HOME/.notes_buddy_log:..."` passed the wrong format.

**Fix:** Use explicit Windows path:
```bash
-v "C:/Users/Lenovo/.notes_buddy_log:/root/.notes_buddy_log"
```

---

## Stress Test Results

### Test 1 — 200 requests, 20 concurrent
```bash
for i in $(seq 1 200); do
  curl -s -o /dev/null -w "%{http_code}\n" \
    http://<elb-url>/actuator/health
done | sort | uniq -c
```
Result: `200 200` — all 200 returned HTTP 200. Zero failures.

### Test 2 — 500 requests, 500 concurrent (background jobs)
```bash
for i in $(seq 1 500); do
  curl -s -o /dev/null -w "%{http_code}\n" \
    http://<elb-url>/commands/all &
done | sort | uniq -c
```
Result: `500 200` — all 500 returned HTTP 200. Zero failures.

### Resource Usage Under Load
```
Idle:    notes-buddy  2-3m CPU   197Mi RAM
Peak:    notes-buddy  174m CPU   200Mi RAM
Settled: notes-buddy  98m CPU    200Mi RAM
Postgres: 1-5m CPU    49Mi RAM   (flat throughout)
```

**What this means:**
- CPU limit is 500m. Peak was 174m = 35% of limit. Plenty of headroom.
- RAM barely moved (197 → 200Mi). No memory leak. JVM heap is stable.
- Postgres is not the bottleneck. It barely moved.
- App recovered quickly — 174m spike settled to 98m as requests completed.

---

## K8s Concepts Learned Today (With Context)

### Namespace
Virtual cluster inside a real cluster. Isolates resources.
`kubectl get pods` shows nothing. `kubectl get pods -n notes-buddy` shows everything.
Delete namespace = delete all resources inside it. Clean teardown.

### ConfigMap vs Secret
ConfigMap = non-sensitive config (port, DB host, DB name).
Secret = sensitive config (passwords, tokens). Base64 encoded, not encrypted.
Both get injected as env vars. Pods reference them by name.
If ConfigMap changes → pods need restart to pick up new values (unless using volume mount).

### PersistentVolumeClaim (PVC)
A request for storage. "I need 1Gi of ReadWriteOnce storage."
K8s finds a matching PersistentVolume (or dynamically provisions one via StorageClass).
`gp2` StorageClass → EBS volume created automatically in AWS.
`ReadWriteOnce` = one node can mount it at a time. Correct for single Postgres pod.

### Deployment vs StatefulSet
We used Deployment for Postgres. This works but has a limitation:
if the pod moves to a different node, the EBS volume must detach and reattach.
EBS is AZ-specific — if pod moves to a different AZ, it can't reattach.
Proper fix: StatefulSet + EBS in same AZ, or use RDS instead.
For learning purposes, Deployment is fine.

### Service Types
- `ClusterIP` (postgres-service): only reachable inside the cluster. No external access.
- `LoadBalancer` (notes-buddy-service): provisions AWS ALB. Gets a public DNS name.
- `NodePort`: exposes on each node's IP. Not used here.
- `Ingress`: routes HTTP traffic by hostname/path. More powerful than LoadBalancer. Next step.

### Liveness vs Readiness Probe
Both hit `/actuator/health` but serve different purposes:

Liveness: "Is this pod alive?"
- Fails → pod is killed and restarted
- `initialDelaySeconds: 60` — wait 60s before first check (Spring Boot startup time)
- `failureThreshold: 3` — 3 consecutive failures before kill

Readiness: "Is this pod ready to receive traffic?"
- Fails → pod removed from LoadBalancer rotation (no traffic sent to it)
- `initialDelaySeconds: 45` — check earlier than liveness
- Use case: pod is alive but still warming up (loading caches, connecting to DB)

### Resource Requests vs Limits
```yaml
resources:
  requests:
    memory: "256Mi"
    cpu: "250m"
  limits:
    memory: "512Mi"
    cpu: "500m"
```
`requests` = guaranteed. Scheduler uses this to decide which node to place pod on.
`limits` = hard ceiling. Exceed memory limit → OOMKilled. Exceed CPU limit → throttled (not killed).
`250m` = 250 millicores = 0.25 of one CPU core.
Always set both. Without limits, one bad pod can starve the whole node.

### EBS CSI Driver
CSI = Container Storage Interface. A standard plugin interface for storage.
The EBS CSI driver translates K8s PVC requests into AWS EBS API calls.
Without it: PVC stays Pending forever.
Needs IAM permissions (via OIDC + service account) to call AWS APIs.

### OIDC + IAM Service Accounts
OIDC = OpenID Connect. Lets K8s service accounts assume IAM roles.
Without OIDC: pods can't get AWS credentials securely.
With OIDC: pod's service account → IAM role → temporary AWS credentials.
This is the secure way. Never put AWS credentials inside a pod as env vars.

---

## Interview Questions — How to Answer Every One

---

### "Walk me through how you deployed this application to Kubernetes."

**How to answer:**
Start from the image, go to the cluster, end with the URL.

> "I started by containerizing the Spring Boot app with a multi-stage Dockerfile —
> Maven build stage, then a slim JRE Alpine runtime stage.
> Pushed the image to ECR using `aws ecr get-login-password` piped to `docker login`.
>
> Created an EKS cluster using eksctl — 2 managed t3.small nodes across 3 AZs in Mumbai.
> eksctl handled the VPC, subnets, IAM roles, and addons via CloudFormation.
>
> Wrote 5 YAML files: namespace for isolation, ConfigMap for non-sensitive config,
> Secret for the DB password, a postgres Deployment with a PVC-backed EBS volume,
> and the app Deployment with liveness and readiness probes pointing at /actuator/health.
>
> The app Service is type LoadBalancer — EKS provisioned an AWS ALB automatically.
> Stress tested with 500 concurrent requests, got 500/500 success,
> peak CPU was 174 millicores against a 500m limit."

---

### "What is the difference between a liveness probe and a readiness probe?"

> "Both are health checks but they trigger different actions.
>
> Liveness probe answers: is this pod alive?
> If it fails, Kubernetes kills the pod and restarts it.
> You use it to recover from deadlocks or unrecoverable states.
>
> Readiness probe answers: is this pod ready to serve traffic?
> If it fails, the pod is removed from the Service's endpoint list —
> no traffic is routed to it — but it's not killed.
> You use it during startup (app still warming up) or when temporarily overloaded.
>
> In our case both hit /actuator/health. The readiness probe starts checking at 45 seconds,
> liveness at 60 seconds, because Spring Boot takes about 30-40 seconds to start."

---

### "What is a PersistentVolumeClaim and why do you need it?"

> "A PVC is a request for storage. You declare what you need —
> size, access mode, storage class — and Kubernetes fulfills it.
>
> Without a PVC, pod storage is ephemeral — when the pod dies, all data dies with it.
> For PostgreSQL that's obviously unacceptable.
>
> In EKS with the gp2 StorageClass, a PVC automatically provisions an EBS volume.
> The volume persists independently of the pod — if the pod restarts or moves,
> the same EBS volume reattaches and the data is still there.
>
> We hit a real issue: EBS formats with ext4 which creates a lost+found directory.
> PostgreSQL refuses to initialize in a non-empty directory.
> Fixed it with subPath: pgdata — mounts a subdirectory of the volume,
> so PostgreSQL never sees lost+found."

---

### "What is the difference between ConfigMap and Secret?"

> "Both inject configuration into pods as environment variables or volume mounts.
>
> ConfigMap is for non-sensitive data — port numbers, hostnames, feature flags.
> It's stored in plain text in etcd.
>
> Secret is for sensitive data — passwords, tokens, certificates.
> It's base64 encoded in etcd, not encrypted by default.
> For real encryption you'd enable etcd encryption at rest or use
> AWS Secrets Manager with the External Secrets Operator.
>
> The key rule: never put passwords in a ConfigMap. Always use Secrets.
> In our deployment, DB_HOST and PORT come from ConfigMap,
> DB_PASS comes from a Secret."

---

### "What happened when the EBS CSI driver crashed? How did you fix it?"

> "The EBS CSI controller pods were in CrashLoopBackOff.
> The error was that OIDC was disabled on the cluster,
> so the CSI driver couldn't get IAM permissions to call AWS EBS APIs.
>
> The fix was two steps:
> First, enable OIDC on the cluster with eksctl utils associate-iam-oidc-provider.
> This creates an OIDC identity provider in IAM that trusts the cluster.
>
> Second, create an IAM service account for the CSI driver,
> attaching the AmazonEBSCSIDriverPolicy managed policy.
> This maps the Kubernetes service account to an IAM role.
> When the CSI controller pod runs, it automatically gets temporary AWS credentials
> via the OIDC token — no hardcoded keys anywhere.
>
> Then restarted the deployment and all 6 containers came up healthy."

---

### "Why did you use a Deployment for PostgreSQL instead of a StatefulSet?"

> "For this learning project, a Deployment works fine.
> But in production, PostgreSQL should be a StatefulSet.
>
> The difference: StatefulSets give each pod a stable identity and
> a dedicated PVC. Pod-0 always gets the same volume, even after restarts.
> Deployments don't guarantee this — if the pod moves to a different node,
> the EBS volume has to detach and reattach, which takes time and can fail
> if the new node is in a different AZ (EBS is AZ-specific).
>
> For a single-replica Postgres in a learning environment, Deployment is acceptable.
> For production: StatefulSet, or better yet, use RDS — managed PostgreSQL
> with automated backups, multi-AZ failover, and no operational overhead."

---

### "What is the difference between ClusterIP and LoadBalancer service types?"

> "ClusterIP is the default. It gives the service a stable internal IP
> reachable only inside the cluster. We used this for PostgreSQL —
> only the app pod needs to talk to it, no external access needed.
>
> LoadBalancer provisions an external load balancer from the cloud provider.
> In EKS, this creates an AWS ALB with a public DNS name.
> We used this for the app so browsers can reach it.
>
> There's also NodePort (exposes on each node's IP, not production-grade)
> and Ingress (HTTP routing by hostname/path, more flexible than LoadBalancer,
> single ALB for multiple services — the right choice at scale)."

---

### "How does Kubernetes know which pods to send traffic to?"

> "Through labels and selectors.
>
> Every pod has labels in its metadata — key-value pairs like `app: notes-buddy`.
> Every Service has a selector — it watches for pods matching that selector.
>
> When a pod starts with matching labels, it's automatically added to the
> Service's endpoint list. When it dies, it's removed.
> The Service's ClusterIP stays stable — it's the pods behind it that change.
>
> This is how rolling updates work — new pods come up, get added to the Service,
> old pods are removed. Zero downtime."

---

### "What would you change about this deployment for production?"

> "Several things:
>
> 1. Replace H2/single-node Postgres with RDS — managed, multi-AZ, automated backups.
>
> 2. Use Ingress with TLS instead of a raw LoadBalancer —
>    one ALB for all services, HTTPS, custom domain.
>
> 3. Store secrets in AWS Secrets Manager with External Secrets Operator —
>    not base64 in a YAML file.
>
> 4. Enable CloudWatch logging for the cluster and pods.
>
> 5. Add HorizontalPodAutoscaler for the app once we remove the single-replica constraint.
>    Currently we can't scale horizontally because two pods would both try to read
>    the same log file and write the same bookmark — causing duplicates.
>    The fix is an ingestion API that accepts commands via HTTP POST,
>    then any number of replicas can handle requests.
>
> 6. Use ECR image scanning and set imagePullPolicy: Always."

---

## Cost Awareness

| Resource | Approximate Cost |
|----------|-----------------|
| EKS Control Plane | $0.10/hour = $2.40/day |
| 2 x t3.small nodes | $0.023/hour each = $1.10/day |
| EBS 1Gi gp2 | ~$0.01/day |
| ALB | ~$0.02/hour = $0.48/day |
| **Total** | **~$4/day** |

**Always delete the cluster when not using it:**
```bash
eksctl delete cluster --name notes-buddy --region ap-south-1
```

Recreate anytime:
```bash
eksctl create cluster --name notes-buddy --region ap-south-1 \
  --nodegroup-name notes-buddy-nodes --node-type t3.small \
  --nodes 2 --nodes-min 1 --nodes-max 3 --managed

aws eks update-kubeconfig --region ap-south-1 --name notes-buddy
kubectl apply -f k8s/
```

Everything is in YAML. Infrastructure as code. Recreate in 20 minutes.

---

## What's Next

| Feature | Why | When |
|---------|-----|------|
| Ingress + TLS | Clean URL, HTTPS, single ALB | Next EKS session |
| RDS PostgreSQL | Production-grade DB, no StatefulSet complexity | Month 2 |
| Ingestion API | HTTP POST endpoint so EKS pod can receive commands from laptop | Month 2 |
| HPA | Auto-scale app pods under load | After ingestion API |
| CloudWatch logs | Centralized logging for pods | Next EKS session |
| ECR image scanning | Security — detect vulnerabilities in image | Next EKS session |
