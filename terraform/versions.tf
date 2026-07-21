terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state in S3 — single source of truth shared across machines
  # DynamoDB table prevents concurrent applies (state locking)
  # Versioning on bucket keeps full history of every change
  backend "s3" {
    bucket         = "notes-buddy-terraform-state-083777493383"
    key            = "notes-buddy/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "notes-buddy-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}
