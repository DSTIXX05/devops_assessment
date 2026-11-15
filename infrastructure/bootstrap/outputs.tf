output "state_bucket_name" {
  description = "Terraform state bucket. Consumed by the dev/prod backend.tf partial configuration."
  value       = aws_s3_bucket.state.bucket
}

output "state_bucket_arn" {
  description = "ARN of the Terraform state bucket."
  value       = aws_s3_bucket.state.arn
}

output "state_bucket_region" {
  description = "Region of the state bucket."
  value       = var.aws_region
}

output "aws_account_id" {
  description = "Account the bootstrap was applied to. Confirms the correct target account."
  value       = data.aws_caller_identity.current.account_id
}

output "aws_caller_arn" {
  description = "ARN of the identity that applied the bootstrap."
  value       = data.aws_caller_identity.current.arn
}

output "budget_name" {
  description = "Name of the monthly AWS Budget guardrail."
  value       = aws_budgets_budget.monthly.name
}

output "budget_limit_usd" {
  description = "Monthly budget notification threshold in USD (not a hard cap)."
  value       = var.budget_limit_usd
}
