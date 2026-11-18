data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  name_prefix = "${var.project_name}-${var.environment}"

  # Trailing tag of the image URI, used as COMMIT_SHA inside the container so a
  # running task can be traced to a source revision.
  image_tag = try(regex(":([^:/]+)$", var.container_image)[0], "unknown")

  # Mirror of the names the ECS module derives internally. Passed by value rather
  # than read back from module.ecs, because module.ecs consumes the log group
  # from module.monitoring - reading its outputs here would create a cycle
  # between the two modules.
  ecs_cluster_name = "${local.name_prefix}-cluster"
  ecs_service_name = "${local.name_prefix}-app"

  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Component   = "environment"
    },
    var.extra_tags,
  )
}

# -----------------------------------------------------------------------------
# Identity guard
#
# Fails the plan if Terraform is running as the account root user. Design
# document §9.1 and §12.2 forbid root for routine work, and the failure mode is
# silent: a profile configured for an IAM user can resolve to root through the
# CLI's token cache. This check makes it loud, on every invocation, regardless of
# how Terraform was started.
# -----------------------------------------------------------------------------
resource "terraform_data" "identity_guard" {
  input = data.aws_caller_identity.current.arn

  lifecycle {
    precondition {
      condition     = !endswith(data.aws_caller_identity.current.arn, ":root")
      error_message = "Refusing to apply as the account root user. Authenticate as a non-root IAM identity - see docs/runbooks/operator-identity.md."
    }
  }
}

# -----------------------------------------------------------------------------
# Networking
#
# Two Availability Zones, public subnets only, no NAT Gateway (ADR-002). Cost:
# VPC networking itself is free.
# -----------------------------------------------------------------------------
module "networking" {
  source = "../../modules/networking"

  name_prefix             = local.name_prefix
  vpc_cidr                = var.vpc_cidr
  availability_zone_count = 2
  tags                    = var.extra_tags
}

# -----------------------------------------------------------------------------
# Security groups
#
# ALB accepts HTTP from the internet; tasks accept the application port only
# from the ALB security group. Cost: security groups are free.
# -----------------------------------------------------------------------------
module "security" {
  source = "../../modules/security"

  name_prefix = local.name_prefix
  vpc_id      = module.networking.vpc_id
  app_port    = var.container_port
  tags        = var.extra_tags
}

# -----------------------------------------------------------------------------
# Container registry
#
# SHA-tagged, immutable images. Cost: storage only (~$0.10/GB-month; the image
# is ~54 MB compressed, so cents per year).
# -----------------------------------------------------------------------------
module "ecr" {
  source = "../../modules/ecr"

  repository_name = "${local.name_prefix}-app"
  tags            = var.extra_tags
}

# -----------------------------------------------------------------------------
# Observability
#
# The log group must exist before the task definition references it. Alarms are
# added in Phase 6.
# -----------------------------------------------------------------------------
module "monitoring" {
  source = "../../modules/monitoring"

  name_prefix = local.name_prefix

  # CloudWatch dimensions use ARN suffixes, available from the alb module.
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix

  cluster_name = local.ecs_cluster_name
  service_name = local.ecs_service_name

  alarm_email   = var.alarm_email
  desired_count = var.desired_count
  tags          = var.extra_tags
}

# -----------------------------------------------------------------------------
# Ingress
#
# Internet-facing ALB across both public subnets. This makes the ingress layer
# resilient across AZs; it does not make the single ECS task highly available.
#
# Cost: roughly $16-20/month in us-east-1 (hourly charge plus LCU usage).
# -----------------------------------------------------------------------------
module "alb" {
  source = "../../modules/alb"

  name_prefix       = local.name_prefix
  vpc_id            = module.networking.vpc_id
  public_subnet_ids = module.networking.public_subnet_ids
  security_group_id = module.security.alb_security_group_id
  container_port    = var.container_port
  tags              = var.extra_tags
}

# -----------------------------------------------------------------------------
# Compute
#
# Two Fargate tasks spread across the two Availability Zones (multi-AZ for prod
# only; dev remains a single task). The service spreads tasks across AZs via an
# ordered placement strategy, so one AZ or task can fail without taking the
# service down.
#
# Cost: ~$18/month for 2 x 0.25 vCPU / 0.5 GB if left running continuously, plus
# public IPv4 charges for the task ENIs.
# -----------------------------------------------------------------------------
module "ecs" {
  source = "../../modules/ecs"

  name_prefix        = local.name_prefix
  environment_name   = var.environment
  container_image    = var.container_image
  container_port     = var.container_port
  cpu                = var.task_cpu
  memory             = var.task_memory
  desired_count      = var.desired_count
  subnet_ids         = module.networking.public_subnet_ids
  security_group_ids = [module.security.task_security_group_id]
  target_group_arn   = module.alb.target_group_arn
  log_group_name     = module.monitoring.log_group_name
  commit_sha         = local.image_tag
  tags               = var.extra_tags

  # The service registers with the target group, so the listener must exist
  # before ECS attempts its first task health check.
  depends_on = [module.alb]
}
