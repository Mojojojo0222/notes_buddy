# Day 16 — ArgoCD GitOps

## What Was Done
1. **EKS Cluster Recreated** via Terraform (30 resources, 2 nodes, EBS CSI + CloudWatch addons)
2. **Terraform state recovered** — imported 4 orphaned resources, fixed state lock contention
3. **EBS CSI addon bug fixed** — added `service_account_role_arn` to module after addon got stuck CREATING
4. **ArgoCD Installed** via Helm chart (`argo/argo-cd`) — 7 pods, LoadBalancer enabled
5. **ArgoCD API verified** — v3.4.5, admin access confirmed

## Key Problems Solved
- State lock contention after timeout → `terraform force-unlock`
- EBS CSI addon stuck CREATING → missing `service_account_role_arn` parameter
- EntityAlreadyExists on re-apply → `terraform import` 4 resources

## Current Cluster State
- 2 t3.small nodes, K8s 1.31
- 30 Terraform resources
- ArgoCD: Running (argocd namespace), LB at `aa335e8d179da4eb7b1035e630ff0e41-1249820149.ap-south-1.elb.amazonaws.com`
- Admin password: `Jzl-KzKg4AY0gNMG`

## Next: Deploy Notes Buddy via ArgoCD Application

## Credentials
```
ArgoCD URL: http://aa335e8d179da4eb7b1035e630ff0e41-1249820149.ap-south-1.elb.amazonaws.com
Username: admin  
Password: Jzl-KzKg4AY0gNMG
```
