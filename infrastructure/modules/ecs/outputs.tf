output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.this.arn
}

output "service_name" {
  description = "ECS service name. The deployment workflow updates this service."
  value       = aws_ecs_service.app.name
}

output "task_definition_arn" {
  description = "ARN of the seed task definition revision created by Terraform."
  value       = aws_ecs_task_definition.app.arn
}

output "task_definition_family" {
  description = "Task definition family. The pipeline registers new revisions into this family."
  value       = aws_ecs_task_definition.app.family
}

output "execution_role_arn" {
  description = "Task execution role ARN. The deploy role needs iam:PassRole on this and the task role."
  value       = aws_iam_role.execution.arn
}

output "task_role_arn" {
  description = "Application task role ARN."
  value       = aws_iam_role.task.arn
}
