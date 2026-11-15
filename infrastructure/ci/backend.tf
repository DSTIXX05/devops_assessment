terraform {
  backend "s3" {
    # Same bucket as the environment roots, different key. CI identity is
    # managed separately from the infrastructure it deploys into.
    bucket = "devops-assessment-tfstate-471112980487-us-east-1"
    key    = "ci/terraform.tfstate"
    region = "us-east-1"

    encrypt      = true
    use_lockfile = true
  }
}
