variable "name_prefix" {
  description = "Prefix for resource names, for example devops-assessment-dev."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention. Seven days is enough to debug an assessment deployment and caps ingestion storage cost."
  type        = number
  default     = 7

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be one of the values CloudWatch Logs accepts."
  }
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix (app/<name>/<id>) used as the CloudWatch LoadBalancer dimension."
  type        = string
}

variable "target_group_arn_suffix" {
  description = "Target group ARN suffix (targetgroup/<name>/<id>) used as the CloudWatch TargetGroup dimension."
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster name for service-level metric dimensions."
  type        = string
}

variable "service_name" {
  description = "ECS service name for service-level metric dimensions."
  type        = string
}

variable "alarm_email" {
  description = "Email address subscribed to the alarm SNS topic. Leave empty to create the topic and alarms without a subscriber; alarms still change state and remain visible in the console."
  type        = string
  default     = ""

  validation {
    condition     = var.alarm_email == "" || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alarm_email))
    error_message = "alarm_email must be empty or a valid email address."
  }
}

variable "target_5xx_threshold" {
  description = "Target 5xx responses in a 1-minute period that trigger the alarm. An initial operational threshold, not a universal production value."
  type        = number
  default     = 5
}

variable "cpu_threshold_percent" {
  description = "Average ECS service CPU utilisation percentage that triggers the alarm."
  type        = number
  default     = 80
}

variable "memory_threshold_percent" {
  description = "Average ECS service memory utilisation percentage that triggers the alarm."
  type        = number
  default     = 85
}

variable "tags" {
  description = "Additional tags merged into each resource."
  type        = map(string)
  default     = {}
}
