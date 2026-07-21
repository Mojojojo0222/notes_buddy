# VPC — the network boundary for everything
# All EKS nodes, pods, and load balancers live inside this VPC
resource "aws_vpc" "main" {
  cidr_block           = "192.168.0.0/16"
  enable_dns_hostnames = true   # pods need DNS to resolve each other by name
  enable_dns_support   = true

  tags = {
    Name = "${var.cluster_name}-vpc"
    # EKS needs these tags to discover which VPC belongs to the cluster
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# Internet Gateway — allows resources in public subnets to reach the internet
# Without this: nodes can't pull Docker images, can't call AWS APIs
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.cluster_name}-igw" }
}

# Public subnets — one per AZ for high availability
# LoadBalancer services get provisioned here (public-facing)
# EKS nodes also go here (simpler setup, fine for learning + small prod)
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "192.168.${count.index}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  # Nodes in public subnets get public IPs — needed to pull images from ECR
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.cluster_name}-public-${count.index}"
    # EKS uses this tag to know which subnets to put LoadBalancers in
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }
}

# Route table — tells traffic where to go
# All outbound traffic (0.0.0.0/0) goes to the Internet Gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.cluster_name}-public-rt" }
}

# Associate route table with each public subnet
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Data source — fetches available AZs in the region dynamically
# So the code works in any region without hardcoding AZ names
data "aws_availability_zones" "available" {
  state = "available"
}
