data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # Globally unique by construction: account ID and region are already unique.
  state_bucket_name = (
    var.state_bucket_name != ""
    ? var.state_bucket_name
    : "${var.project_name}-tfstate-${local.account_id}-${var.aws_region}"
  )

  common_tags = {
    Project     = var.project_name
    Environment = "shared"
    ManagedBy   = "terraform"
    Component   = "terraform-bootstrap"
  }
}

# -----------------------------------------------------------------------------
# Terraform remote state bucket
#
# This root uses local state because it is what creates the backend that all
# other roots depend on. The bootstrap state file stays on the operator's
# workstation and is gitignored.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket_name

  # Deliberately not using prevent_destroy: the assessment requires a
  # documented, repeatable teardown path. Destruction of this bucket is guarded
  # by procedure instead - see infrastructure/bootstrap/README.md.
  tags = {
    Name    = local.state_bucket_name
    Purpose = "terraform-state"
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    # Every state revision is recoverable. This is the primary protection
    # against a corrupted or partially written state file.
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3 rather than SSE-KMS: no key, no per-key monthly charge, no
      # additional key policy to manage. State contains resource identifiers and
      # resource attributes, not application secrets. Revisit if the state ever
      # holds sensitive values or if key-level audit is required.
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "state" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json

  # Public access blocking must land before a bucket policy, otherwise AWS can
  # reject the policy while the bucket is still considered public.
  depends_on = [aws_s3_bucket_public_access_block.state]
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    # Versioning is the safety net; unbounded version retention is not. 90 days
    # keeps roughly a quarter of history at negligible storage cost.
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# -----------------------------------------------------------------------------
# Cost guardrail
#
# AWS Budgets: the first two budgets per account are free, email notifications
# need no SNS topic, so this costs $0. It is a notification, not a hard cap -
# AWS will not stop resources when the threshold is crossed.
# -----------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  name         = "${var.project_name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = var.budget_notification_email == "" ? [] : [
      { threshold = 50, operator = "GREATER_THAN", type = "ACTUAL" },
      { threshold = 80, operator = "GREATER_THAN", type = "ACTUAL" },
      { threshold = 100, operator = "GREATER_THAN", type = "ACTUAL" },
      { threshold = 100, operator = "GREATER_THAN", type = "FORECASTED" },
    ]

    content {
      comparison_operator        = notification.value.operator
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value.type
      subscriber_email_addresses = [var.budget_notification_email]
    }
  }
}
