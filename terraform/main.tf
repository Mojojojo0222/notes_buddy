# Root module — wires all child modules together
# No resource definitions here. Just module calls with their inputs.
# This is the "orchestration layer" — pure config, no implementation.

# VPC — network foundation
module "vpc" {
  source       = "./modules/vpc"
  cluster_name = var.cluster_name
}

# EKS — Kubernetes control plane + worker nodes
module "eks" {
  source              = "./modules/eks"
  cluster_name        = var.cluster_name
  subnet_ids          = module.vpc.public_subnet_ids
  node_instance_type  = var.node_instance_type
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
}

# ECR — container image registry
module "ecr" {
  source = "./modules/ecr"
  name   = var.cluster_name
}
