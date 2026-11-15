output "log_group_name" {
  description = "CloudWatch log group the ECS task definition writes to via the awslogs driver."
  value       = aws_cloudwatch_log_group.app.name
}

output "log_group_arn" {
  description = "Log group ARN, used to scope the task execution role's log permissions."
  value       = aws_cloudwatch_log_group.app.arn
}

output "alarm_topic_arn" {
  description = "SNS topic the alarms publish to."
  value       = aws_sns_topic.alarms.arn
}

output "alarm_names" {
  description = "Names of the CloudWatch alarms created for this environment."
  value = [
    aws_cloudwatch_metric_alarm.target_5xx.alarm_name,
    aws_cloudwatch_metric_alarm.unhealthy_hosts.alarm_name,
    aws_cloudwatch_metric_alarm.live_task_count.alarm_name,
    aws_cloudwatch_metric_alarm.ecs_cpu.alarm_name,
    aws_cloudwatch_metric_alarm.ecs_memory.alarm_name,
  ]
}
