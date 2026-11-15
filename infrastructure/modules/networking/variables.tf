variable "name_prefix" {
  description = "Prefix applied to every resource name in this module."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "availability_zone_count" {
  description = "Number of Availability Zones to span. Two is the minimum for an ALB; one task in one AZ is still a single point of failure."
  type        = number
  default     = 2

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 4
    error_message = "availability_zone_count must be between 2 and 4."
  }
}

variable "tags" {
  description = "Additional tags merged into each resource. Provider default_tags are applied separately."
  type        = map(string)
  default     = {}
}
