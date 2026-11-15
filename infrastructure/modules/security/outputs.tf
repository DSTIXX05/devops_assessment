output "alb_security_group_id" {
  description = "Security group attached to the Application Load Balancer."
  value       = aws_security_group.alb.id
}

output "task_security_group_id" {
  description = "Security group attached to the ECS task ENIs."
  value       = aws_security_group.task.id
}
