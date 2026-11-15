variable "aws_region" {
  description = "AWS region for this environment."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = var.aws_region == "us-east-1"
    error_message = "The approved architecture pins the assessment to us-east-1. The S3 backend bucket is also region-specific."
  }
}

variable "aws_profile" {
  description = "Optional named AWS CLI profile. Leave empty to use the environment credential chain supplied by scripts/with-operator-creds.sh."
  type        = string
  default     = ""
}

variable "project_name" {
  description = "Prefix for all resource names and the cost-allocation tag."
  type        = string
  default     = "devops-assessment"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,32}$", var.project_name))
    error_message = "project_name must be 3-32 characters of lowercase letters, digits, or hyphens."
  }
}

variable "environment" {
  description = "Environment identifier. Also used in resource names and the state key."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be either \"dev\" or \"prod\"."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the environment VPC. Each environment must use a non-overlapping range."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block, for example 10.30.0.0/16."
  }
}

variable "container_port" {
  description = "TCP port the application listens on inside the container. Must match the ALB target group port."
  type        = number
  default     = 3000

  validation {
    condition     = var.container_port > 0 && var.container_port <= 65535
    error_message = "container_port must be a valid TCP port."
  }
}

variable "container_image" {
  description = "Full image URI including tag, for example <account>.dkr.ecr.<region>.amazonaws.com/<repo>:<sha>."
  type        = string

  validation {
    condition     = can(regex("^[^:]+(:[0-9]+)?/[^@]+:[^:]+$", var.container_image))
    error_message = "container_image must include an explicit tag. Deploying without a tag defeats SHA-based traceability."
  }
}

variable "desired_count" {
  description = "Initial ECS task count. One is a deliberate single point of failure (ADR-005); this deployment is not highly available."
  type        = number
  default     = 1

  validation {
    condition     = var.desired_count >= 1
    error_message = "desired_count must be at least 1."
  }
}

variable "task_cpu" {
  description = "Fargate task CPU units. 256 = 0.25 vCPU."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 512
}

variable "alarm_email" {
  description = "Email address subscribed to the CloudWatch alarm SNS topic. Leave empty for console-visible alarms with no subscriber."
  type        = string
  default     = ""

  validation {
    condition     = var.alarm_email == "" || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alarm_email))
    error_message = "alarm_email must be empty or a valid email address."
  }
}

variable "extra_tags" {
  description = "Additional tags merged into the default tag set."
  type        = map(string)
  default     = {}
}
