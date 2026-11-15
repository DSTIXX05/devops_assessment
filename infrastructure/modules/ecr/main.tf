resource "aws_ecr_repository" "this" {
  name = var.repository_name

  # Tags are immutable. Images are released under the Git commit SHA, so a tag
  # can never legitimately need to move. This blocks a silent overwrite of a
  # release, which is the whole point of SHA tagging.
  #
  # Consequence: a pipeline that re-pushes the same SHA fails loudly instead of
  # quietly replacing an artefact that may already be running.
  image_tag_mutability = "IMMUTABLE"

  force_delete = var.force_delete

  image_scanning_configuration {
    # Informational only. ECR scanning is asynchronous and cannot gate a
    # pipeline; Trivy in CI is the blocking control. This exists for the extra
    # base-OS coverage and for the console evidence.
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(
    {
      Name = var.repository_name
    },
    var.tags,
  )
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  # Without a lifecycle policy every deploy leaves another image behind and the
  # repository grows without bound.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Retain the 20 most recent tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 20
        }
        action = {
          type = "expire"
        }
      },
    ]
  })
}
