# Outputs are how modules expose values to their callers
# The EKS module needs to know which VPC and subnets to deploy into

output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}
