# ── IAM Role for EKS Control Plane ───────────────────────────────────────────
# The EKS control plane needs permission to manage AWS resources on your behalf
# (create load balancers, describe EC2 instances, etc.)
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"

  # Trust policy — who can assume this role
  # eks.amazonaws.com = the EKS service itself
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Attach AWS managed policy — gives EKS control plane all permissions it needs
resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ── IAM Role for EKS Worker Nodes ────────────────────────────────────────────
# EC2 nodes need permissions to:
# - join the cluster (AmazonEKSWorkerNodePolicy)
# - configure pod networking (AmazonEKS_CNI_Policy)
# - pull images from ECR (AmazonEC2ContainerRegistryReadOnly)
# - ship metrics/logs to CloudWatch (CloudWatchAgentServerPolicy)
resource "aws_iam_role" "node_group" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_cloudwatch" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ── EKS Cluster ───────────────────────────────────────────────────────────────
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = "1.31"
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_public_access  = true   # kubectl from laptop works
    endpoint_private_access = true   # nodes talk to control plane privately
  }

  # Cluster must wait for IAM role policy to be attached before creation
  # Without this depends_on, Terraform might try to create the cluster
  # before the IAM role has the policy — race condition
  depends_on = [aws_iam_role_policy_attachment.cluster_policy]

  tags = { Name = var.cluster_name }
}

# ── OIDC Provider ─────────────────────────────────────────────────────────────
# Enables IAM Roles for Service Accounts (IRSA)
# Pods can assume IAM roles without hardcoding AWS credentials
# Required for: EBS CSI driver, CloudWatch agent, Karpenter
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# ── EKS Managed Node Group ────────────────────────────────────────────────────
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-nodes"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = var.subnet_ids
  instance_types  = [var.node_instance_type]

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  # Rolling update strategy — replaces nodes one at a time
  # max_unavailable = 1 means at most 1 node is down during updates
  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]

  tags = { Name = "${var.cluster_name}-nodes" }
}

# ── IRSA: IAM Role for EBS CSI Driver ───────────────────────────────────────
# EBS CSI driver pods assume this role to create/manage EBS volumes
# Trust relationship scoped to ebs-csi-controller-sa in kube-system
resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ── EKS Addons ────────────────────────────────────────────────────────────────
# EBS CSI driver — needed for PersistentVolumeClaims backed by EBS
resource "aws_eks_addon" "ebs_csi" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "aws-ebs-csi-driver"

  depends_on = [
    aws_eks_node_group.main,
    aws_iam_role_policy_attachment.ebs_csi
  ]
}

# CloudWatch observability — metrics + logs for all pods
resource "aws_eks_addon" "cloudwatch" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "amazon-cloudwatch-observability"

  depends_on = [aws_eks_node_group.main]
}
