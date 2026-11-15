output "alb_arn" {
  description = "Application Load Balancer ARN."
  value       = aws_lb.this.arn
}

output "alb_dns_name" {
  description = "ALB DNS name. This is the assessment's public entry point and is consumed by the deployment workflow's health verification."
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "ALB hosted zone ID, needed if a custom domain is added later."
  value       = aws_lb.this.zone_id
}

output "alb_arn_suffix" {
  description = "ALB ARN suffix, used as the CloudWatch LoadBalancer dimension."
  value       = aws_lb.this.arn_suffix
}

output "target_group_arn_suffix" {
  description = "Target group ARN suffix, used as the CloudWatch TargetGroup dimension."
  value       = aws_lb_target_group.app.arn_suffix
}

output "target_group_arn" {
  description = "Target group the ECS service registers tasks with."
  value       = aws_lb_target_group.app.arn
}

output "listener_arn" {
  description = "HTTP listener ARN."
  value       = aws_lb_listener.http.arn
}
