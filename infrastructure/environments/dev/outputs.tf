output "environment" {
  description = "Environment this state belongs to."
  value       = var.environment
}

output "name_prefix" {
  description = "Common resource name prefix for this environment."
  value       = local.name_prefix
}

output "aws_region" {
  description = "Region this environment is deployed into."
  value       = var.aws_region
}

output "aws_account_id" {
  description = "Account the environment is deployed into."
  value       = local.account_id
}

output "aws_caller_arn" {
  description = "Identity that ran the last plan/apply. Standing evidence that no root credentials are used."
  value       = data.aws_caller_identity.current.arn
}

# --- Networking ---------------------------------------------------------------

output "vpc_id" {
  description = "VPC ID for this environment."
  value       = module.networking.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs, ordered by Availability Zone."
  value       = module.networking.public_subnet_ids
}

output "availability_zones" {
  description = "Availability Zones the VPC spans."
  value       = module.networking.availability_zones
}

# --- Security -----------------------------------------------------------------

output "alb_security_group_id" {
  description = "Security group for the Application Load Balancer."
  value       = module.security.alb_security_group_id
}

output "task_security_group_id" {
  description = "Security group for the ECS task ENIs."
  value       = module.security.task_security_group_id
}

# --- Registry and logs --------------------------------------------------------

output "ecr_repository_name" {
  description = "ECR repository name."
  value       = module.ecr.repository_name
}

output "ecr_repository_url" {
  description = "ECR repository URL. The pipeline appends :<commit-sha>."
  value       = module.ecr.repository_url
}

output "log_group_name" {
  description = "CloudWatch log group receiving application logs."
  value       = module.monitoring.log_group_name
}

output "alarm_topic_arn" {
  description = "SNS topic the CloudWatch alarms publish to."
  value       = module.monitoring.alarm_topic_arn
}

output "alarm_names" {
  description = "CloudWatch alarms created for this environment."
  value       = module.monitoring.alarm_names
}

# --- Ingress and compute ------------------------------------------------------

output "alb_dns_name" {
  description = "Public entry point. The deployment workflow verifies /health against this hostname."
  value       = module.alb.alb_dns_name
}

output "alb_arn" {
  description = "Application Load Balancer ARN."
  value       = module.alb.alb_arn
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = module.ecs.cluster_name
}

output "ecs_service_name" {
  description = "ECS service name."
  value       = module.ecs.service_name
}

output "task_definition_arn" {
  description = "Seed task definition revision."
  value       = module.ecs.task_definition_arn
}
