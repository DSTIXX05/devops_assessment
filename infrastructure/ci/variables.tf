variable "aws_region" {
  description = "AWS region. Must match the region the environment roots deploy into."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = var.aws_region == "us-east-1"
    error_message = "The approved architecture pins the assessment to us-east-1."
  }
}

variable "aws_profile" {
  description = "Optional AWS CLI profile. Leave empty to use the environment credential chain from scripts/with-operator-creds.sh."
  type        = string
  default     = ""
}

variable "project_name" {
  description = "Prefix matching the environment roots, used to derive resource names and ARNs."
  type        = string
  default     = "devops-assessment"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,32}$", var.project_name))
    error_message = "project_name must be 3-32 characters of lowercase letters, digits, or hyphens."
  }
}

variable "github_owner" {
  description = "GitHub organisation or user that owns the repository. Part of the OIDC sub claim."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository name. Part of the OIDC sub claim."
  type        = string
}

variable "github_branch" {
  description = "Branch allowed to assume the dev deploy role. Must be the branch the deploy workflow runs from."
  type        = string
  default     = "main"
}

variable "github_prod_environment" {
  description = "GitHub Environment name the prod deploy role trusts. Using an Environment instead of a branch means the job must satisfy that environment's protection rules before a token is issued."
  type        = string
  default     = "prod"
}

variable "github_oidc_host" {
  description = "GitHub OIDC provider host. Also the prefix for the token claim condition keys."
  type        = string
  default     = "token.actions.githubusercontent.com"
}

variable "environments" {
  description = "Environments to create deploy roles for. Derived resource names must match what the environment roots create."
  type        = list(string)
  default     = ["dev", "prod"]

  validation {
    condition     = alltrue([for e in var.environments : contains(["dev", "prod"], e)])
    error_message = "environments may only contain \"dev\" and \"prod\"."
  }
}

variable "manage_oidc_provider" {
  description = "Create the GitHub OIDC provider. Leave false when the account already has one (this account does); creating a second fails with EntityAlreadyExists."
  type        = bool
  default     = false
}

variable "extra_tags" {
  description = "Additional tags merged into the default tag set."
  type        = map(string)
  default     = {}
}
