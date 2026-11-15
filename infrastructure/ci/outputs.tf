output "deploy_role_arns" {
  description = "Map of environment to deploy role ARN. Set these as the AWS_ROLE_ARN variable in each GitHub environment."
  value       = { for env, role in aws_iam_role.deploy : env => role.arn }
}

output "allowed_subjects" {
  description = "The OIDC sub claim each role accepts. Useful when debugging an AssumeRoleWithWebIdentity denial."
  value       = { for env, cfg in local.deploy_roles : env => cfg.subject }
}

output "oidc_provider_arn" {
  description = "GitHub OIDC provider referenced by the trust policies."
  value       = local.oidc_provider_arn
}

output "oidc_provider_managed_here" {
  description = "False when the pre-existing account provider is being referenced rather than created."
  value       = var.manage_oidc_provider
}

output "aws_account_id" {
  description = "Account the deploy roles exist in."
  value       = local.account_id
}
