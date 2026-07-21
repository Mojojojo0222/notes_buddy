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

# ── GitHub Actions OIDC ─────────────────────────────────────────────────────
# Allows GitHub Actions to assume an IAM role without storing AWS keys
# Uses OpenID Connect — GitHub issues a token, AWS verifies it against this provider
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # GitHub's OIDC thumbprint — stable, rarely changes
  thumbprint_list = ["1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

# IAM role that GitHub Actions assumes during CI/CD
resource "aws_iam_role" "github_actions" {
  name = "${var.cluster_name}-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # Restrict to this specific repo and any branch/tag
          "token.actions.githubusercontent.com:sub" = "repo:Mojojojo0222/notes_buddy:*"
        }
      }
    }]
  })
}

# Policy: allow push to ECR
resource "aws_iam_role_policy" "ecr_push" {
  name = "${var.cluster_name}-ecr-push"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage",
        "ecr:BatchGetImage",
        "ecr:DescribeRepositories",
        "ecr:GetRepositoryPolicy",
        "ecr:ListImages"
      ]
      Resource = "*"
    }]
  })
}

# Policy: allow describe EKS cluster (needed for update-kubeconfig)
resource "aws_iam_role_policy" "eks_describe" {
  name = "${var.cluster_name}-eks-describe"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "eks:DescribeCluster",
        "eks:ListClusters"
      ]
      Resource = "*"
    }]
  })
}
