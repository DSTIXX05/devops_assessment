variable "repository_name" {
  description = "ECR repository name. Conventionally <project>-<environment>-app."
  type        = string
}

variable "force_delete" {
  description = "Allow destroy to delete the repository even when it still contains images. Left false so teardown requires a deliberate choice."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags merged into each resource."
  type        = map(string)
  default     = {}
}
