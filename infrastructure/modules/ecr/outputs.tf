output "repository_name" {
  description = "ECR repository name."
  value       = aws_ecr_repository.this.name
}

output "repository_url" {
  description = "Registry URL without a tag. The pipeline appends :<commit-sha>."
  value       = aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  description = "Repository ARN, used for scoping IAM policies."
  value       = aws_ecr_repository.this.arn
}
