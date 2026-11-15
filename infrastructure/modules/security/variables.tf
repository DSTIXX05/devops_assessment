variable "name_prefix" {
  description = "Prefix applied to every security group name in this module."
  type        = string
}

variable "vpc_id" {
  description = "VPC the security groups belong to."
  type        = string
}

variable "app_port" {
  description = "Container port the application listens on. The ALB forwards here and the task group accepts traffic only from the ALB."
  type        = number
  default     = 3000

  validation {
    condition     = var.app_port > 0 && var.app_port <= 65535
    error_message = "app_port must be a valid TCP port."
  }
}

variable "tags" {
  description = "Additional tags merged into each resource."
  type        = map(string)
  default     = {}
}
