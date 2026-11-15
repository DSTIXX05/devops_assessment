variable "aws_region" {
  description = "AWS region for all assessment resources."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = var.aws_region == "us-east-1"
    error_message = "The approved architecture pins the assessment to us-east-1. Change this validation deliberately if the region decision changes."
  }
}

variable "aws_profile" {
  description = "Optional named AWS CLI profile. Leave empty (default) to use the environment credential chain, which is how short-lived operator credentials are supplied. Never used in CI."
  type        = string
  default     = ""
}

variable "project_name" {
  description = "Prefix for resource names and the cost-allocation tag."
  type        = string
  default     = "devops-assessment"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,32}$", var.project_name))
    error_message = "project_name must be 3-32 characters of lowercase letters, digits, or hyphens."
  }
}

variable "state_bucket_name" {
  description = "Optional explicit Terraform state bucket name. Defaults to <project>-tfstate-<account>-<region> so the name is globally unique."
  type        = string
  default     = ""
}

variable "budget_limit_usd" {
  description = "Monthly AWS Budget limit in USD. A notification threshold, not a hard spending cap."
  type        = number
  default     = 30

  validation {
    condition     = var.budget_limit_usd > 0
    error_message = "budget_limit_usd must be greater than zero."
  }
}

variable "budget_notification_email" {
  description = "Email address for budget alerts. Leave empty to create the budget without notifications (for example in a shared or demo account)."
  type        = string
  default     = ""

  validation {
    condition     = var.budget_notification_email == "" || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_notification_email))
    error_message = "budget_notification_email must be empty or a valid email address."
  }
}
