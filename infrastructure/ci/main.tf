data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  common_tags = merge(
    {
      Project     = var.project_name
      Environment = "shared"
      ManagedBy   = "terraform"
      Component   = "ci-identity"
    },
    var.extra_tags,
  )

  # One entry per environment. The only security-relevant difference between dev
  # and prod is `subject`: a branch for dev, a GitHub Environment for prod.
  #
  # The subject uses GitHub's IMMUTABLE format, which includes numeric IDs:
  #   repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:refs/heads/main
  #
  # This is not the format most documentation shows. It was adopted by GitHub to
  # make the claim immune to repository renames and transfers - an attacker who
  # gains control of the name cannot produce a token that matches.
  #
  # Discovered empirically: the first pipeline run failed with "Not authorized
  # to perform sts:AssumeRoleWithWebIdentity" because the trust policy expected
  # repo:OWNER/REPO:ref:... while the token actually carried the @id form.
  deploy_roles = {
    for env in var.environments : env => {
      name_prefix = "${var.project_name}-${env}"

      subject_prefix = "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repository}@${var.github_repo_id}"

      subject = (
        env == "prod"
        ? "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repository}@${var.github_repo_id}:environment:${var.github_prod_environment}"
        : "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repository}@${var.github_repo_id}:ref:refs/heads/${var.github_branch}"
      )
    }
  }

  # Resource ARNs each role may touch, derived from the same naming convention
  # the environment roots use. Deriving them here avoids a cross-root state
  # dependency: this root does not need to read dev/ or prod/ state.
  target_arns = {
    for env, cfg in local.deploy_roles : env => {
      ecr_repository = "arn:${local.partition}:ecr:${var.aws_region}:${local.account_id}:repository/${cfg.name_prefix}-app"
      ecs_cluster    = "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:cluster/${cfg.name_prefix}-cluster"
      ecs_service    = "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:service/${cfg.name_prefix}-cluster/${cfg.name_prefix}-app"
      ecs_tasks      = "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:task/${cfg.name_prefix}-cluster/*"

      # Both forms are needed. Calling describe-task-definition with a family
      # name authorises against the bare family ARN; registering or describing a
      # specific revision uses the fanned ARN with the revision suffix. Granting
      # only "<family>:*" leaves the family-name call unauthorised.
      ecs_taskdef_family = "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:task-definition/${cfg.name_prefix}-app"
      ecs_taskdef        = "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:task-definition/${cfg.name_prefix}-app:*"

      execution_role = "arn:${local.partition}:iam::${local.account_id}:role/${cfg.name_prefix}-task-execution"
      task_role      = "arn:${local.partition}:iam::${local.account_id}:role/${cfg.name_prefix}-task"
    }
  }
}

# -----------------------------------------------------------------------------
# OIDC provider
#
# This account already has a GitHub provider (used by another project), so the
# default is to reference it rather than create it - a second one fails with
# EntityAlreadyExists.
#
# Referencing rather than importing is deliberate: this project does not manage
# a shared, account-level resource. If Terraform owned it, destroying this stack
# could remove a provider that other projects depend on.
# -----------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  count = var.manage_oidc_provider ? 1 : 0

  url            = "https://${var.github_oidc_host}"
  client_id_list = ["sts.amazonaws.com"]

  tags = merge(
    {
      Name = "github-actions-oidc"
    },
    local.common_tags,
  )
}

locals {
  oidc_provider_arn = (
    var.manage_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : "arn:${local.partition}:iam::${local.account_id}:oidc-provider/${var.github_oidc_host}"
  )
}

# -----------------------------------------------------------------------------
# Trust policies
#
# Answers only "who may become this role". Note what makes this safe: the
# Principal proves GitHub signed the token, but the StringEquals condition on
# `sub` is what proves the token is about this repository, on this ref.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "assume" {
  for_each = local.deploy_roles

  statement {
    sid    = "GitHubActionsOidcOnly"
    effect = "Allow"

    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringEquals, not StringLike. A wildcard here would authorise every
    # branch, tag, pull request, and workflow in the repository.
    condition {
      test     = "StringEquals"
      variable = "${var.github_oidc_host}:sub"
      values   = [each.value.subject]
    }
  }
}

resource "aws_iam_role" "deploy" {
  for_each = local.deploy_roles

  name                 = "${each.value.name_prefix}-github-deploy"
  description          = "GitHub Actions deployment role for the ${each.key} environment. Assumable only via OIDC from ${each.value.subject}."
  assume_role_policy   = data.aws_iam_policy_document.assume[each.key].json
  max_session_duration = 3600

  tags = merge(
    {
      Name        = "${each.value.name_prefix}-github-deploy"
      Environment = each.key
    },
    local.common_tags,
  )
}

# -----------------------------------------------------------------------------
# Permissions policies
#
# Answers "what the role may do once assumed". Scoped to this environment's
# resources only, so the dev role cannot reach prod.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "deploy" {
  for_each = local.deploy_roles

  # Account-scoped by AWS design: GetAuthorizationToken has no resource-level
  # permissions. This is the one Resource:"*" statement that cannot be narrowed,
  # and it is stated here rather than left for a reviewer to notice.
  statement {
    sid       = "EcrGetAuthorizationToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPushToEnvironmentRepository"
    effect = "Allow"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
    ]

    resources = [local.target_arns[each.key].ecr_repository]
  }

  # RegisterTaskDefinition does not support resource-level permissions, so this
  # action requires "*". The blast radius is limited by the PassRole condition
  # below: the pipeline can only register task definitions that use this
  # environment's two ECS roles.
  statement {
    sid       = "EcsRegisterTaskDefinition"
    effect    = "Allow"
    actions   = ["ecs:RegisterTaskDefinition"]
    resources = ["*"]
  }

  statement {
    sid     = "EcsTaskDefinitionReadAndTag"
    effect  = "Allow"
    actions = ["ecs:DescribeTaskDefinition", "ecs:TagResource"]
    resources = [
      local.target_arns[each.key].ecs_taskdef_family,
      local.target_arns[each.key].ecs_taskdef,
    ]
  }

  statement {
    sid    = "EcsUpdateEnvironmentService"
    effect = "Allow"

    actions = [
      "ecs:DescribeClusters",
      "ecs:DescribeServices",
      "ecs:UpdateService",
      "ecs:ListTasks",
      "ecs:DescribeTasks",
    ]

    resources = [
      local.target_arns[each.key].ecs_cluster,
      local.target_arns[each.key].ecs_service,
      local.target_arns[each.key].ecs_tasks,
    ]
  }

  # Narrow PassRole: only this environment's ECS roles, and only to ECS. Without
  # the condition the pipeline could pass these roles to any service it can
  # call, which is the classic privilege-escalation path for CI roles.
  statement {
    sid     = "PassEcsTaskRolesToEcsOnly"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      local.target_arns[each.key].execution_role,
      local.target_arns[each.key].task_role,
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "deploy" {
  for_each = local.deploy_roles

  name   = "${each.value.name_prefix}-github-deploy"
  role   = aws_iam_role.deploy[each.key].id
  policy = data.aws_iam_policy_document.deploy[each.key].json
}
