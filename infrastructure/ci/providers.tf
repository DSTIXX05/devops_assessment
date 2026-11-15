provider "aws" {
  region = var.aws_region

  # Null by default, for the same reason as the environment roots: an explicit
  # profile makes the provider resolve the AWS CLI console-login token cache,
  # which can attach the account root identity. See
  # docs/runbooks/operator-identity.md.
  profile = var.aws_profile == "" ? null : var.aws_profile

  default_tags {
    tags = local.common_tags
  }
}
