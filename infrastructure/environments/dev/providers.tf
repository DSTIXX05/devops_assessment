provider "aws" {
  region = var.aws_region

  # Deliberately null. Setting a profile makes the provider resolve the AWS CLI
  # console-login mechanism through an account-scoped token cache, which can
  # silently attach the wrong identity (observed: the account root user). The
  # standard environment credential chain is used instead. See
  # docs/runbooks/operator-identity.md.
  profile = var.aws_profile == "" ? null : var.aws_profile

  default_tags {
    tags = local.common_tags
  }
}
