variable "name_prefix" {
  description = "Prefix for the load balancer and target group names."
  type        = string
}

variable "vpc_id" {
  description = "VPC the target group belongs to."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets for the internet-facing load balancer. Both AZs are attached so the ALB itself survives an AZ loss."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group for the ALB (ingress 80, egress to the task group only)."
  type        = string
}

variable "container_port" {
  description = "Port the target group forwards to."
  type        = number
  default     = 3000
}

variable "health_check_path" {
  description = "HTTP path used for target health checks."
  type        = string
  default     = "/health"
}

variable "deregistration_delay" {
  description = "Seconds to wait before removing a draining target. Must exceed the app's shutdown drain time (10s) so in-flight requests complete."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Additional tags merged into each resource."
  type        = map(string)
  default     = {}
}
