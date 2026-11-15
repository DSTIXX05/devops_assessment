variable "name_prefix" {
  description = "Prefix for cluster, service, family, and IAM role names."
  type        = string
}

variable "environment_name" {
  description = "Value passed to the container as APP_ENV."
  type        = string
}

variable "container_image" {
  description = "Full image URI including tag, for example <account>.dkr.ecr.<region>.amazonaws.com/<repo>:<sha>."
  type        = string

  validation {
    condition     = can(regex("^[^:]+(:[0-9]+)?/[^@]+:[^:]+$", var.container_image))
    error_message = "container_image must include an explicit tag. Deploying by digest or without a tag defeats SHA-based traceability."
  }
}

variable "container_port" {
  description = "Port the container listens on and the target group forwards to."
  type        = number
  default     = 3000
}

variable "cpu" {
  description = "Task CPU units. 256 = 0.25 vCPU."
  type        = number
  default     = 256
}

variable "memory" {
  description = "Task memory in MiB. Must be a valid Fargate combination for the chosen CPU."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Initial desired task count. One is a deliberate single point of failure per ADR-005 - this deployment is not highly available."
  type        = number
  default     = 1

  validation {
    condition     = var.desired_count >= 1
    error_message = "desired_count must be at least 1."
  }
}

variable "subnet_ids" {
  description = "Subnets for the task ENIs. Public subnets per ADR-002."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security groups for the task ENIs."
  type        = list(string)
}

variable "target_group_arn" {
  description = "Target group the service registers tasks with."
  type        = string
}

variable "log_group_name" {
  description = "CloudWatch log group for the awslogs driver."
  type        = string
}

variable "commit_sha" {
  description = "Git commit SHA baked into the container as COMMIT_SHA so a running task can be traced to a source revision."
  type        = string
  default     = "unknown"
}

variable "health_check_grace_period_seconds" {
  description = "Grace period before ECS starts replacing tasks that fail the ALB health check. Covers container start-up."
  type        = number
  default     = 60
}

variable "log_retention_days" {
  description = "Unused placeholder retained for interface stability; retention is owned by the monitoring module."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Additional tags merged into each resource."
  type        = map(string)
  default     = {}
}
