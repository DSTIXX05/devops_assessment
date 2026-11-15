terraform {
  # Matches infrastructure/.terraform-version. Minor-version pin keeps the S3
  # backend's use_lockfile behaviour (requires >= 1.10) fixed across runs.
  required_version = "~> 1.17.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
