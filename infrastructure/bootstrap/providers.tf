terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Left null unless explicitly set.
  #
  # Setting `profile` pins shared-config resolution, and this account's profiles
  # authenticate through the AWS CLI console-login mechanism (`login_session`).
  # When the provider resolves that mechanism it consumes an account-scoped
  # token cache, which can silently attach the wrong identity - in this case the
  # root user, cached from an earlier root sign-in, even though the CLI itself
  # reports an IAM user.
  #
  # Leaving it null makes the provider use the standard environment credential
  # chain, which honours short-lived credentials exported from the operator's
  # actual session. See infrastructure/scripts/with-operator-creds.sh.
  profile = var.aws_profile == "" ? null : var.aws_profile

  # Applied to every resource this root creates so cost allocation and
  # ownership are answerable without reading the code.
  default_tags {
    tags = local.common_tags
  }
}
