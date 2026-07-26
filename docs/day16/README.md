# Day 16 — ArgoCD GitOps

## What Was Done (Full Day)
1. **EKS Cluster Recreated** via Terraform (30 resources, 2 nodes, EBS CSI + CloudWatch addons)
2. **Terraform state recovered** — imported 4 orphaned resources, fixed state lock contention
3. **EBS CSI addon bug fixed** — added `service_account_role_arn` to module after addon got stuck CREATING
4. **ArgoCD Installed** via Helm chart (`argo/argo-cd`) — 7 pods, LoadBalancer enabled
5. **ArgoCD optimized for t3.small** — disabled dex + notifications, reduced resource limits
6. **Application CRD created** — `argocd/apps/notes-buddy.yaml`
7. **Notes Buddy deployed via ArgoCD** — Synced + Healthy
8. **Switched from dev to staging** — ClusterIP → LoadBalancer (public URL)
9. **New Docker image built + pushed** with all features (search, solutions, tags, exit codes)
10. **All features verified** — search, solution cards, tagging, ingestion, categories

## Current Cluster State
- 2 t3.small nodes, K8s 1.31
- 30 Terraform resources
- ArgoCD: 5 pods (dex + notifications disabled), v3.4.5
- App URL: `http://a4222470eaec245a29c7720b811fb836-1696657361.ap-south-1.elb.amazonaws.com`
- Admin password: `Jzl-KzKg4AY0gNMG`

## Key Problems Solved (All Day)
- State lock contention after timeout → `terraform force-unlock`
- EBS CSI addon stuck CREATING → missing `service_account_role_arn` parameter
- EntityAlreadyExists on re-apply → `terraform import` 4 resources
- t3.small pod capacity (11/node) → disabled dex + notifications, reduced resource requests
- Old Docker image cached (`IfNotPresent`) → `imagePullPolicy: Always` + `--no-cache` rebuild
- Solution cards empty → re-ingested commands after new image deployed

## Credentials
```
ArgoCD URL: http://aa335e8d179da4eb7b1035e630ff0e41-1249820149.ap-south-1.elb.amazonaws.com
Username:   admin
Password:   Jzl-KzKg4AY0gNMG

App URL:    http://a4222470eaec245a29c7720b811fb836-1696657361.ap-south-1.elb.amazonaws.com
```
