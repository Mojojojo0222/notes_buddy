# Day 15 — Helm Charts: Production-Grade Kubernetes Packaging

**Goal:** Replace all raw `kubectl apply -f k8s/` with a single `helm install` command. Package Notes Buddy as a production-grade Helm chart with environment separation, component isolation, and all production patterns (HPA, PDB, Ingress, health checks).

---

## Session Context

Days 1-14 built Notes Buddy as a Spring Boot app with PostgreSQL, deployed it to EKS via raw YAML (`k8s/` directory), provisioned infrastructure with Terraform, set up CI/CD with GitHub Actions, and added full observability (Prometheus + Grafana).

The gap: deploying to EKS required 7 separate `kubectl apply` commands with duplicated values (image tag, replica count, resource sizes) scattered across multiple YAML files. No templating, no environment separation, no package management.

Helm fills this gap. One `helm install` deploys the entire application. Values change per environment. Templates are reusable.

---

## What Was Built

### Chart Structure

```
helm/notes-buddy/
├── Chart.yaml                  # Metadata: name, version, appVersion, sources
├── .helmignore                 # Exclude patterns for packaging
├── values.yaml                 # DEFAULT environment (8 resources)
├── values-dev.yaml             # DEV: ClusterIP, no HPA/PDB (8 resources)
├── values-staging.yaml         # STAGING: LoadBalancer + HPA + RBAC (11 resources)
├── values-production.yaml      # PROD: Full HA with PDB + Ingress + TLS (13 resources)
└── templates/
    ├── _helpers.tpl            # 6 reusable named templates
    ├── NOTES.txt               # Post-install instructions
    ├── namespace.yaml          # Created once via `lookup` check
    ├── configmap.yaml          # Non-sensitive env vars (PORT, DB_HOST, etc.)
    ├── secret.yaml             # DB_PASS (b64enc at render time)
    ├── postgres-pvc.yaml       # PersistentVolumeClaim (1Gi default)
    ├── postgres-deployment.yaml # Stateful: Recreate strategy, fsGroup:999
    ├── postgres-service.yaml   # ClusterIP (DNS name: notes-buddy-postgres)
    ├── app-deployment.yaml     # Stateless: RollingUpdate, probes, checksum annotations
    ├── app-service.yaml        # Configurable type (ClusterIP / LoadBalancer)
    ├── app-hpa.yaml            # CPU + memory, behavior tuning
    ├── app-pdb.yaml            # PodDisruptionBudget for HA
    ├── ingress.yaml            # ALB Ingress with TLS support
    └── rbac.yaml               # GitHub Actions deployer Role + RoleBinding
```

### Resources Per Environment

| Environment | Resources | Key Features |
|-------------|-----------|-------------|
| DEV | 8 | ClusterIP, no HPA/PDB, minimal resources |
| STAGING | 11 | LoadBalancer, HPA (2-4 pods), RBAC |
| PRODUCTION | 13 | LoadBalancer, HPA (3-10 pods), PDB (min 2), Ingress + TLS, RBAC |

---

## Helm Concepts Learned

### 1. Charts
A **chart** is a bundle of K8s YAML templates. `helm/notes-buddy/` is a chart. It has:
- `Chart.yaml` — metadata (name, version, dependencies)
- `values.yaml` — default configuration
- `templates/` — Go-template YAML files
- `_helpers.tpl` — reusable named template functions
- `NOTES.txt` — displayed after `helm install`

### 2. Values at Three Levels
Values cascade: `--set` > `-f values-env.yaml` > `values.yaml`

```bash
# DEV: uses defaults with dev overrides
helm install nb ./helm/notes-buddy -f values-dev.yaml

# PROD: overrides every value
helm install nb ./helm/notes-buddy -f values-production.yaml

# Single override on the fly
helm install nb ./helm/notes-buddy --set image.tag=v2.1.0
```

### 3. Template Functions

| Function | What It Does | Example |
|----------|-------------|---------|
| `{{ .Values.app.replicas }}` | Inject value from YAML | `replicas: 3` |
| `{{ include "notes-buddy.fullname" . }}` | Call a named template | `notes-buddy-app` |
| `{{ .Values.app.env.DB_PASS \| b64enc \| quote }}` | Pipe: base64 + quote | `"bm90ZXNidWRkeQ=="` |
| `{{- toYaml .Values.app.resources \| nindent 12 }}` | Marshal YAML + indent | Resource block |
| `{{ sha256sum (include "templates/configmap.yaml" .) }}` | Content hash | Checksum annotation |
| `{{ if .Values.app.hpa.enabled }}` | Condition | Conditional resource |

### 4. Named Templates (`_helpers.tpl`)

Helpers prevent repeating labels, names, and selectors across every template:

```yaml
# In _helpers.tpl:
{{- define "notes-buddy.labels" -}}
helm.sh/chart: {{ include "notes-buddy.name" . }}-{{ .Chart.Version }}
{{ include "notes-buddy.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

# In any template:
metadata:
  labels:
    {{- include "notes-buddy.labels" . | nindent 4 }}
```

This ensures EVERY resource has consistent labels. `kubectl get all -l app.kubernetes.io/instance=notes-buddy` works across all components.

### 5. Component Labels

Every resource gets `app.kubernetes.io/component: <name>`:

```
app.kubernetes.io/component: app       # Spring Boot deployment, service
app.kubernetes.io/component: postgres  # PostgreSQL deployment, service, PVC
app.kubernetes.io/component: hpa       # HorizontalPodAutoscaler
app.kubernetes.io/component: pdb       # PodDisruptionBudget
app.kubernetes.io/component: ingress   # Ingress
app.kubernetes.io/component: rbac      # Role + RoleBinding
app.kubernetes.io/component: config    # ConfigMap
app.kubernetes.io/component: secrets   # Secret
```

This enables fine-grained queries:
```bash
# All Postgres resources
kubectl get all -l app.kubernetes.io/component=postgres -n notes-buddy

# All app resources
kubectl get all -l app.kubernetes.io/component=app -n notes-buddy
```

### 6. Conditionals: Environment-Aware Resources

```yaml
# Only exists in production:
{{- if .Values.app.pdb.enabled }}
apiVersion: policy/v1
kind: PodDisruptionBudget
...
{{- end }}
```

DEV has 8 resources. PRODUCTION has 13. Same templates, different values.

### 7. `lookup` Function: Idempotent Namespace

```yaml
{{- if not (lookup "v1" "Namespace" "" (include "notes-buddy.namespace" .)) }}
apiVersion: v1
kind: Namespace
...
{{- end }}
```

`lookup` checks if the namespace already exists before creating it. On `helm install` → creates namespace. On `helm upgrade` → finds it exists → skips. The `helm.sh/resource-policy: keep` annotation prevents deletion on `helm uninstall`.

### 8. Checksum Annotations: Automatic Pod Restarts

```yaml
annotations:
  checksum/config: {{ include "templates/configmap.yaml" . | sha256sum }}
  checksum/secret: {{ include "templates/secret.yaml" . | sha256sum }}
```

When ConfigMap or Secret values change (e.g., you change `DB_USER` in values.yaml), the checksum changes → the pod template changes → Helm triggers a rolling update. Without this, changing env vars in values.yaml would have NO effect on running pods until you manually restart them.

### 9. Secret Handling: `b64enc` at Render Time

```yaml
data:
  DB_PASS: {{ .Values.app.env.DB_PASS | b64enc | quote }}
```

The password is stored as plaintext in `values.yaml` but base64-encoded at template render time. This is standard Helm practice. For production, the secret should come from an external secrets manager (AWS Secrets Manager, Vault, Sealed Secrets).

### 10. Production Patterns

| Pattern | Implementation | Why |
|---------|---------------|-----|
| **RollingUpdate** | `maxUnavailable: 0, maxSurge: 1` | Zero-downtime deploys |
| **Readiness probe** | `/actuator/health`, 45s delay | Don't send traffic to booting pods |
| **Liveness probe** | `/actuator/health`, 60s delay | Restart deadlocked pods |
| **Resource requests/limits** | CPU 250m/500m, Mem 256Mi/512Mi | Scheduler placement + OOM protection |
| **HPA** | CPU 50%, 3-10 replicas | Auto-scale under load |
| **HPA behavior** | Scale-up instantly, scale-down over 5min | Prevent flapping |
| **PDB** | `minAvailable: 2` | Never drop below 2 pods during maintenance |
| **Recreate for Postgres** | `strategy: Recreate` | Avoid two pods claiming same PVC |
| **fsGroup** | `999` | Postgres can write to EBS volume |
| **subPath** | `pgdata` | Avoid `lost+found` collision |

---

## How the Original k8s/ Maps to Helm

| Raw YAML (`k8s/`) | Helm Template | Parameterized? |
|-------------------|---------------|---------------|
| `namespace.yaml` | `templates/namespace.yaml` | Namespace from release name |
| `configmap.yaml` | `templates/configmap.yaml` | All values from `values.yaml` |
| `secret.yaml` | `templates/secret.yaml` | Password from `values.yaml`, `b64enc` encoded |
| `postgres.yaml` | `postgres-pvc.yaml` + `postgres-deployment.yaml` + `postgres-service.yaml` | PVC size, resources, image tag |
| `notes-buddy.yaml` | `app-deployment.yaml` + `app-service.yaml` | Replicas, image, probes, resources |
| `hpa.yaml` | `app-hpa.yaml` | Min/max replicas, metrics, behavior |
| `rbac-github-actions.yaml` | `rbac.yaml` | Group name, role ARN |

Before Helm: `kubectl apply -f k8s/` (7 files, manual edits per env)
After Helm: `helm install nb ./helm/notes-buddy -f values-prod.yaml` (1 command, env isolated)

---

## Security: Secrets in Helm Charts

**The question:** "Where do secrets come from in Helm? Is it safe to store them in values.yaml?"

**Answer in three layers:**

### Layer 1: values.yaml (What We Built)
The password lives in `values.yaml` as plaintext. At template render time, `b64enc` base64-encodes it. This is standard Helm — the same security level as the original `k8s/secret.yaml` which was also base64.

**Is this safe for production?**
- **No.** Base64 is encoding, not encryption. Anyone with access to `values.yaml` or the rendered Secret YAML can decode the password.
- **Acceptable for:** DEV, learning, personal tools (like Notes Buddy running locally).
- **Not acceptable for:** Production with compliance requirements (SOC2, HIPAA, PCI).

### Layer 2: Terraform + External Secrets (Production Pattern)
Your Terraform already exists and manages IAM roles. The production pattern is:
1. Store secrets in **AWS Secrets Manager** (encrypted at rest with KMS)
2. Use **External Secrets Operator** (ESO) in K8s to sync Secrets Manager → K8s Secret
3. Helm values.yaml contains `existingSecret: "notes-buddy-secret"` → Helm skips creating the Secret → it already exists from ESO
4. Terraform creates the Secrets Manager entry + IAM role for ESO

### Layer 3: Sealed Secrets (GitOps Pattern)
- Encrypt the secret with `kubeseal` → store the encrypted SealedSecret in Git
- Only the controller in the cluster can decrypt it
- Helm chart creates a SealedSecret instead of a regular Secret
- The SealedSecret controller decrypts it to a regular Secret at runtime

**Your current setup is safe because:**
- You run locally or on your own cluster
- Terraform doesn't store secrets — it creates IAM roles, not secrets
- The only "secret" is the Postgres password (`notesbuddy`) which is a dev credential
- For production: add External Secrets Operator + AWS Secrets Manager, Terraform creates the secret entry

---

## Testing the Chart

```bash
# 1. Validate chart structure (no cluster needed)
helm lint ./helm/notes-buddy

# 2. Render YAML locally (no cluster needed)
helm template notes-buddy ./helm/notes-buddy \
  -f ./helm/notes-buddy/values-dev.yaml --namespace notes-buddy

# 3. Dry-run (needs cluster connection, no changes made)
helm install notes-buddy ./helm/notes-buddy \
  -f ./helm/notes-buddy/values-dev.yaml \
  --namespace notes-buddy --create-namespace --dry-run

# 4. Real install
helm install notes-buddy ./helm/notes-buddy \
  -f ./helm/notes-buddy/values-dev.yaml \
  --namespace notes-buddy --create-namespace

# 5. Upgrade
helm upgrade notes-buddy ./helm/notes-buddy \
  -f ./helm/notes-buddy/values-dev.yaml

# 6. Rollback
helm rollback notes-buddy 1 -n notes-buddy

# 7. Uninstall
helm uninstall notes-buddy -n notes-buddy
```

---

## Key Decisions Log

| Decision | Rationale |
|----------|-----------|
| Single chart, not parent+subchart | Notes Buddy is one app. Subcharts add complexity (values scoping, dependency order). Single chart is simpler and sufficient. |
| Component labels in templates, not helpers | Avoids `merge` mutation bug. Hardcoding `component: app` is explicit and safe. |
| `lookup` for namespace | Idempotent install. Without it, second install fails with "namespace already exists." |
| `checksum/config` annotations | Automatic pod restart on config change. Without it, changing values.yaml doesn't restart pods — users think the change took effect but it didn't. |
| DEV=ClusterIP, PROD=LoadBalancer | DEV: port-forward for local dev. PROD: ALB for external traffic. Same template, different value. |
| `values-*.yaml` files, not Helm subdirs | Simpler. Helm supports `-f filename.yaml` natively. No need for `-f environments/dev/values.yaml`. |
| `existingConfigMap` / `existingSecret` pattern | Allows Terraform or External Secrets Operator to manage secrets without Helm fighting them. |
| `b64enc` in template, not pre-encoded | Values.yaml stays human-readable. Encoding happens at render time. |

---

## What This Enables Next

1. **ArgoCD GitOps** — Point ArgoCD at this chart. Git push → ArgoCD syncs → cluster updates. Rollback = `git revert`.
2. **Helm repository** — Package the chart (`helm package`) and host it (S3, GitHub Pages, ChartMuseum).
3. **CI/CD integration** — `helm upgrade` in GitHub Actions workflow instead of `kubectl set image`.
4. **Kustomize comparison** — Understand when to use Helm (templating, packaging) vs Kustomize (overlays, no server-side).
5. **Helm unit tests** — Write `templates/tests/` for chart validation.
6. **Dependency charts** — Extract Postgres into a subchart or use Bitnami's Postgres chart.
