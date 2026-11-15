terraform {
  backend "s3" {
    # Created by infrastructure/bootstrap. If this repository is forked into a
    # different account, change the bucket name - it encodes the account ID.
    bucket = "devops-assessment-tfstate-471112980487-us-east-1"
    key    = "dev/terraform.tfstate"
    region = "us-east-1"

    # Encrypt state at rest in S3 (server-side, AES256).
    encrypt = true

    # Native S3 state locking: Terraform writes a .tflock object next to the
    # state object and uses conditional writes, so a concurrent apply fails
    # immediately instead of racing. Replaces the legacy DynamoDB lock table.
    # Requires Terraform >= 1.10 and an S3 bucket that supports conditional
    # writes.
    use_lockfile = true
  }
}
