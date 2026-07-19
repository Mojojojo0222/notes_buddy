# Day 6 Session 2 — HPA Autoscaling + CloudWatch Container Insights

## What We Built
- HPA (HorizontalPodAutoscaler) — auto-scales pods based on CPU usage
- CloudWatch Container Insights — centralized metrics + logs for every pod in the cluster
- Ran a live stress test and watched pods scale 1 → 4 in real time
- Queried live Spring Boot logs from AWS CloudWatch Logs Insights
- Confirmed zero errors from the app in its entire EKS lifetime

---

## The Full Picture After This Session

```
AWS ap-south-1 (Mumbai)
┌─────────────────────────────────────────────────────────────┐
│  EKS Cluster: notes-buddy                                   │
│                                                             │
│  Namespace: notes-buddy                                     │
│    notes-buddy pod (1-4 replicas, managed by HPA)          │
│    postgres pod (1 replica, fixed)                          │
│    HPA: cpu > 50% → scale up, cpu < 50% sustained → scale down │
│                                                             │
│  Namespace: amazon-cloudwatch                               │
│    cloudwatch-agent-* (1 per node) → metrics to CloudWatch  │
│    fluent-bit-* (1 per node) → logs to CloudWatch Logs      │
│    controller-manager → manages the observability stack     │
│                                                             │
│  AWS CloudWatch                                             │
│    Container Insights → CPU/memory/network graphs per pod   │
│    Log Group: /aws/containerinsights/notes-buddy/application│
│    Logs Insights → query logs with SQL-like syntax          │
└─────────────────────────────────────────────────────────────┘
```

---

## Part A — HPA (HorizontalPodAutoscaler)

### What HPA Does
HPA watches a Deployment and adjusts the replica count automatically based on a metric.
You define: "if average CPU across all pods exceeds 50%, add more pods."
HPA does the math, issues the scale command, and watches the result.

### Prerequisites — metrics-server
HPA needs real-time CPU/memory data from pods.
That data comes from `metrics-server` — a lightweight in-cluster component
that scrapes resource usage from each node's kubelet every 15 seconds.

Without metrics-server, HPA shows `<unknown>/50%` in the TARGETS column and never scales.

Our cluster already had it running (installed during Day 6 session 1):
```bash
kubectl get deployment metrics-server -n kube-system
# NAME             READY   UP-TO-DATE   AVAILABLE   AGE
# metrics-server   2/2     2            2           25h
```

### The HPA YAML (applied inline)
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: notes-buddy-hpa
  namespace: notes-buddy
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: notes-buddy
  minReplicas: 1
  maxReplicas: 4
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
```

**Every line explained:**

`apiVersion: autoscaling/v2` — v2 supports multiple metrics (CPU + memory + custom).
v1 only supported CPU. Always use v2.

`scaleTargetRef` — which Deployment to control. HPA reads this Deployment's pod count
and issues scale up/down commands against it.

`minReplicas: 1` — never scale below 1. App always has at least one pod running.

`maxReplicas: 4` — hard ceiling. Prevents runaway scaling from a bug or attack.
In production, set this based on your DB connection pool size —
if each pod opens 10 DB connections and your DB allows 100, maxReplicas = 10.

`averageUtilization: 50` — target is 50% CPU utilization AVERAGED across all pods.
Not "any pod over 50%" — the average. This matters.

**The HPA math:**
```
desiredReplicas = ceil(currentReplicas * (currentCPU / targetCPU))

Example: 1 pod at 127% CPU, target 50%
desiredReplicas = ceil(1 * (127 / 50)) = ceil(2.54) = 3
```

### Live Stress Test Results

```
TIME    CPU        REPLICAS   WHAT HAPPENED
0s      1%/50%     1          baseline, idle
105s    86%/50%    1          load-gen hit, single pod overwhelmed
2m      127%/50%   2          HPA math: ceil(1 * 127/50) = 3, scaled to 2 first
2m15s   89%/50%    3          still high, scaled to 3
2m30s   44%/50%    3          3 pods absorbing load, under threshold
3m30s   60%/50%    3          spike again
4m      77%/50%    4          maxReplicas hit
4m30s   45%/50%    4          4 pods holding load comfortably
```

Scale-down after load-gen deleted:
```
12m     21%/50%    4          load gone, CPU dropping
13m     0%/50%     3          scale-down begins (5-min stabilization window)
15m     0%/50%     2          continues
17m     0%/50%     2          still cooling down
```

### The Stabilization Window — Why Scale-Down Is Slow
Scale-up is fast (15-30 seconds). Scale-down is deliberately slow (5 minutes default).

Why? Imagine this without the window:
- CPU drops for 10 seconds → HPA scales down → CPU spikes again → HPA scales up
- Repeat every 30 seconds. This is called "flapping" and it kills your app.

The stabilization window says: "only scale down if CPU has been below threshold
for 5 consecutive minutes." Prevents thrashing.

In production you can tune this:
```yaml
behavior:
  scaleDown:
    stabilizationWindowSeconds: 300  # default
  scaleUp:
    stabilizationWindowSeconds: 0    # scale up immediately
```

### Why We Can't Scale Notes-Buddy Horizontally in Production (Yet)
Two pods would both run HistoryWatcher, both reading the same log file,
both writing the same bookmark to the DB — causing duplicate commands.

The fix (Month 2): ingestion API. Laptop sends commands via HTTP POST.
Any number of pods can handle POST requests — stateless, safe to scale.
HPA becomes fully useful after that change.

---

## Part B — CloudWatch Container Insights

### What CloudWatch Container Insights Does
Collects metrics AND logs from every container in the cluster.
Sends them to AWS CloudWatch where you can:
- See CPU/memory/network graphs per pod, per node, per namespace
- Query logs with SQL-like syntax (Logs Insights)
- Set alarms on any metric
- Correlate a CPU spike with the log lines that caused it

### The Three Components Installed

```
amazon-cloudwatch-observability-controller-manager
    manages the whole observability stack
    watches for new nodes, deploys agents automatically

cloudwatch-agent-* (DaemonSet — one per node)
    collects CPU, memory, network, disk metrics
    polls kubelet every 60 seconds
    ships metrics to CloudWatch Metrics namespace: ContainerInsights

fluent-bit-* (DaemonSet — one per node)
    tails /var/log/containers/*.log on each node
    parses container logs, adds kubernetes metadata
    ships to CloudWatch Logs: /aws/containerinsights/notes-buddy/application
```

**DaemonSet** = a pod that runs on EVERY node automatically.
When a new node joins the cluster, K8s automatically starts a DaemonSet pod on it.
Perfect for agents that need to run everywhere (logging, monitoring, security).

### How We Installed It

**Step 1 — Attach IAM policy to node role**
The cloudwatch-agent needs permission to call CloudWatch APIs (PutMetricData, CreateLogGroup etc).
This permission goes on the EC2 node's IAM role — all pods on that node inherit it.

```bash
aws iam attach-role-policy \
  --role-name eksctl-notes-buddy-nodegroup-notes-NodeInstanceRole-qL5i1BrJBdJN \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
```

**Step 2 — Install the addon**
```bash
aws eks create-addon \
  --cluster-name notes-buddy \
  --addon-name amazon-cloudwatch-observability \
  --region ap-south-1
```

EKS addons are managed components — AWS handles version upgrades, compatibility checks.
Better than manually applying YAML because AWS ensures it works with your K8s version.

**Verify:**
```bash
kubectl get pods -n amazon-cloudwatch
# NAME                                                    READY   STATUS
# amazon-cloudwatch-observability-controller-manager-*   1/1     Running
# cloudwatch-agent-22cnq                                 1/1     Running
# cloudwatch-agent-9vmjt                                 1/1     Running
# fluent-bit-8nbcn                                       1/1     Running
# fluent-bit-jv8qw                                       1/1     Running
```

### Understanding the Container Insights Dashboard

**Container performance table — what the numbers mean:**

```
Container     Pod                    CPU      Memory
postgres      postgres-*             <0.1%    2.2%
notes-buddy   notes-buddy-65d9fb4f4d 0.1%     11.3%
```

`CPU <0.1%` — postgres is idle. Less than 0.1% of its CPU limit used.

`Memory 11.3%` — notes-buddy using 11.3% of its 512Mi limit = ~57Mi.
That's the Spring Boot JVM at idle. Healthy. No leak.

`Memory 2.2%` — postgres using ~11Mi. No active queries.

**Pod CPU utilization over pod limit** — the dangerous graph.
When this hits 100%, the kernel is throttling your app's threads.
CPU throttling = your app is slower than it should be, not killed.
During the stress test this spiked — that's what triggered HPA.

**Network RX/TX:**
- RX = bytes received by the pod (incoming requests)
- TX = bytes transmitted (responses sent)
- cloudwatch-agent and fluent-bit top the network charts — they're constantly
  shipping data to AWS. That's their entire job.

**Number of container restarts** — most important SRE metric.
All zeros = healthy cluster. Any non-zero = something is crashing.
First thing to check when on-call: "which pods have restarts > 0?"

**Pod container status waiting reason crashed** — shows `No data available`.
This means zero CrashLoopBackOff pods. In production, data here = emergency.

### Understanding the Log Structure

Every log entry fluent-bit ships is a JSON blob:
```json
{
  "time": "2026-07-19T19:28:42.345Z",
  "stream": "stdout",
  "_p": "F",
  "log": "Waiting for log file: /root/.notes_buddy_log",
  "kubernetes": {
    "pod_name": "notes-buddy-65d9fb4f4d-4kvz9",
    "namespace_name": "notes-buddy",
    "host": "ip-192-168-77-72.ap-south-1.compute.internal",
    "pod_ip": "192.168.78.54",
    "container_name": "notes-buddy",
    "container_image": "083777493383.dkr.ecr.ap-south-1.amazonaws.com/notes-buddy:latest"
  }
}
```

`stream: stdout` — normal app log. `stream: stderr` — error output.
`_p: F` — Full line. `_p: P` — Partial (log line was split across multiple reads).
`log` — the actual message your app printed.
`kubernetes.*` — metadata fluent-bit added automatically. You didn't write this.

**The pipeline:**
```
Spring Boot System.out.println()
    → container stdout
    → /var/log/containers/*.log on the node
    → fluent-bit tails the file
    → adds kubernetes metadata
    → ships to CloudWatch Logs
    → queryable in Logs Insights
```

### Logs Insights Queries

**Query 1 — All logs from your namespace:**
```
fields @timestamp, log, kubernetes.pod_name, stream
| filter kubernetes.namespace_name = "notes-buddy"
| sort @timestamp desc
| limit 100
```
Result: 158 records matched. All from notes-buddy pod.
Every line: `Waiting for log file: /root/.notes_buddy_log`
Exactly every 10 seconds — the @Scheduled(fixedDelay=10000) firing.

**Query 2 — Only errors from your namespace:**
```
fields @timestamp, log, kubernetes.pod_name, stream
| filter kubernetes.namespace_name = "notes-buddy"
| filter stream = "stderr"
| sort @timestamp desc
| limit 50
```
Result: **zero records**. App has produced zero errors in its entire EKS lifetime.

### The "Failed to watch VolumeSnapshotClass" Errors — What They Are

These appear constantly in the unfiltered log view from `ebs-csi-controller`:
```
"Failed to watch" err="failed to list *v1.VolumeSnapshotClass:
the server could not find the requested resource"
```

This is NOT your app. This is an AWS system pod (`ebs-csi-controller`).
The `csi-snapshotter` sidecar is looking for the VolumeSnapshot CRD
which isn't installed on this cluster (we don't use volume snapshots).
It's a known benign warning. No action needed.

**SRE triage process for any error:**
1. Which pod? → `ebs-csi-controller`, not my app
2. What's the error? → looking for a CRD that doesn't exist
3. Impact on my app? → zero. My pods show no errors.
4. Decision → known AWS issue, ignore, not a production risk

Not every error needs fixing. Triage first.

### The Histogram — Reading Log Volume Over Time

The bar chart in Logs Insights shows log volume per time bucket.
The spike around 19:00-19:15 = exactly when load-gen was running.
More requests → more Spring Boot logs → more entries shipped to CloudWatch.
You can literally see your stress test in the log volume graph.

---

## What Each Number in CloudWatch Actually Means

| Number | What It Is | What It Means |
|--------|-----------|---------------|
| `cpu: 1%/50%` in HPA | current/target | 1% CPU used, threshold is 50% |
| `cpu: 127%/50%` in HPA | over 100% | pod is using 127% of its CPU REQUEST (not limit) |
| `0.1% CPU` in Container Insights | % of CPU limit | 0.1% of 500m limit = 0.5m cores |
| `11.3% memory` in Container Insights | % of memory limit | 11.3% of 512Mi = ~57Mi |
| `174m CPU` in stress test | millicores | 174/1000 of one CPU core |
| `200Mi RAM` in stress test | mebibytes | 200 * 1024 * 1024 bytes |
| `6,790 records scanned` in Logs Insights | log entries | total lines fluent-bit shipped |
| `1.7s` query time in Logs Insights | scan speed | CloudWatch indexed the logs |

---

## Interview Questions — HPA + CloudWatch

### "What is HPA and how does it work?"

> "HPA is HorizontalPodAutoscaler. It watches a Deployment and adjusts
> the replica count based on metrics — CPU, memory, or custom metrics.
>
> It needs metrics-server running in the cluster to get real-time CPU data.
> Every 15 seconds, metrics-server scrapes kubelet on each node.
> HPA polls metrics-server every 30 seconds and runs the formula:
> desiredReplicas = ceil(currentReplicas * currentMetric / targetMetric)
>
> We set target at 50% CPU. Under load, one pod hit 127% —
> HPA calculated ceil(1 * 127/50) = 3 replicas and scaled up.
> When load stopped, it waited 5 minutes (stabilization window) before scaling back down.
> This prevents flapping — rapid scale up/down cycles that would destabilize the app."

---

### "Why is scale-down slower than scale-up?"

> "Intentional design. The stabilization window for scale-down defaults to 5 minutes.
> Scale-up is immediate because the cost of not scaling up (user-facing slowness) is high.
> The cost of not scaling down (a few extra pods running) is low — just money.
>
> Without the window, a brief CPU drop would trigger scale-down,
> then the next request spike would trigger scale-up again.
> This flapping is worse than just keeping the extra pods running.
>
> You can tune both windows independently in the HPA behavior spec."

---

### "What is CloudWatch Container Insights?"

> "It's AWS's managed observability solution for EKS.
> Two components: cloudwatch-agent collects metrics (CPU, memory, network),
> fluent-bit collects logs from every container.
> Both run as DaemonSets — one pod per node, automatically.
>
> Metrics go to CloudWatch Metrics under the ContainerInsights namespace.
> Logs go to CloudWatch Logs under /aws/containerinsights/cluster-name/application.
>
> You get a pre-built dashboard showing CPU/memory per pod, restart counts,
> network traffic. And Logs Insights for querying logs with SQL-like syntax.
>
> We installed it via EKS addon — one command, AWS manages the version."

---

### "How would you debug a production issue using CloudWatch?"

> "Three-step process:
>
> First, check Container Insights — is CPU or memory spiking on a specific pod?
> Are there restart counts increasing? That narrows down which pod is the problem.
>
> Second, go to Logs Insights and filter to that pod's namespace and stderr:
> `filter kubernetes.namespace_name = 'my-app' | filter stream = 'stderr'`
> This shows only error logs from my app, nothing else.
>
> Third, correlate the timestamp of the CPU spike with the log lines at that time.
> CloudWatch lets you click a point on the metrics graph and jump to logs at that time.
>
> In our case, running the stderr query returned zero records —
> the app has never produced an error log on EKS."

---

### "What is a DaemonSet?"

> "A DaemonSet ensures one pod runs on every node in the cluster.
> When a new node joins, K8s automatically starts the DaemonSet pod on it.
> When a node is removed, the pod is garbage collected.
>
> Perfect for infrastructure agents that need to run everywhere:
> log collectors (fluent-bit), metrics agents (cloudwatch-agent),
> security scanners, network plugins.
>
> You never set replicas on a DaemonSet — the replica count equals the node count."

---

### "What is the difference between metrics-server and CloudWatch agent?"

> "metrics-server is in-cluster only. It stores the last few minutes of CPU/memory data
> in memory. It's used by HPA and kubectl top. Data is gone when metrics-server restarts.
> It's lightweight — designed for real-time decisions, not historical analysis.
>
> CloudWatch agent ships metrics to AWS CloudWatch where they're stored for 15 months.
> You can see trends over days, weeks, months. Set alarms. Build dashboards.
> It's for observability and analysis, not for HPA decisions.
>
> Both were running in our cluster. HPA used metrics-server.
> The Container Insights dashboard used CloudWatch agent data."

---

## Key Files Changed This Session

No new application code was written. All changes were infrastructure:

1. HPA applied inline (not saved to file yet — save before cluster delete)
2. IAM policy `CloudWatchAgentServerPolicy` attached to node role
3. EKS addon `amazon-cloudwatch-observability` installed

### Save HPA to file before deleting cluster:
```bash
kubectl get hpa notes-buddy-hpa -n notes-buddy -o yaml > k8s/hpa.yaml
```

---

## Cluster Deletion Checklist

When ready to delete:
```bash
# 1. Save HPA YAML
kubectl get hpa notes-buddy-hpa -n notes-buddy -o yaml > k8s/hpa.yaml

# 2. Commit everything
git add k8s/hpa.yaml
git commit -m "day6-session2: add HPA yaml"
git push

# 3. Delete cluster (this deletes everything: nodes, EBS volumes, ALB)
eksctl delete cluster --name notes-buddy --region ap-south-1
```

Recreate anytime in ~20 minutes:
```bash
eksctl create cluster --name notes-buddy --region ap-south-1 \
  --nodegroup-name notes-buddy-nodes --node-type t3.small \
  --nodes 2 --nodes-min 1 --nodes-max 3 --managed

aws eks update-kubeconfig --region ap-south-1 --name notes-buddy
kubectl apply -f k8s/
```

---

## What's Next

| Feature | Why | When |
|---------|-----|------|
| Ingestion API | HTTP POST so EKS pod can receive commands from laptop | Month 2 |
| Ingress + TLS | Clean HTTPS URL, single ALB | Next EKS session |
| RDS PostgreSQL | Production-grade DB | Month 2 |
| HPA fully useful | After ingestion API removes single-replica constraint | Month 2 |
| CloudWatch Alarms | Alert when CPU > 80% or pod restarts > 0 | Next EKS session |
