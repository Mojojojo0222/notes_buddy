resource "aws_ecr_repository" "main" {
  name                 = var.name
  image_tag_mutability = "MUTABLE"  # allows overwriting :latest tag

  # Scan images on push — detects CVEs in your Docker layers
  # Free tier: basic scanning. Paid: enhanced scanning with Snyk
  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = var.name }
}

# Lifecycle policy — automatically delete old images to save storage costs
# Keeps only the last 10 images. Old ones are deleted automatically.
resource "aws_ecr_lifecycle_policy" "main" {
  repository = aws_ecr_repository.main.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
