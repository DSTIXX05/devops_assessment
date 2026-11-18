data "aws_region" "current" {}

data "aws_partition" "current" {}

locals {
  container_name = "app"
  cluster_name   = "${var.name_prefix}-cluster"
  service_name   = "${var.name_prefix}-app"

  # Partition-aware so this module is not silently broken in aws-cn or
  # aws-us-gov, where the managed policy ARN prefix differs.
  ecs_task_execution_policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_cluster" "this" {
  name = local.cluster_name

  # Container Insights is deliberately not enabled: it adds CloudWatch metric
  # cost and the assessment's monitoring needs are covered by the ECS and ALB
  # metrics that are always emitted.
  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = merge(
    {
      Name = local.cluster_name
    },
    var.tags,
  )
}

# -----------------------------------------------------------------------------
# IAM
#
# Two roles, deliberately separate:
#   execution role - used by the ECS agent to pull the image and write logs
#   task role      - used by the application code; starts with no permissions
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-task-execution"
  description        = "ECS agent: pull the image from ECR and write to CloudWatch Logs"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = merge(
    {
      Name = "${var.name_prefix}-task-execution"
    },
    var.tags,
  )
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = local.ecs_task_execution_policy_arn
}

resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-task"
  description        = "Application runtime identity. No AWS permissions are granted; the app calls no AWS APIs."
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = merge(
    {
      Name = "${var.name_prefix}-task"
    },
    var.tags,
  )
}

# -----------------------------------------------------------------------------
# Task definition
# -----------------------------------------------------------------------------

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.name_prefix}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.cpu)
  memory                   = tostring(var.memory)

  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = var.container_image
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      # Configuration only. Credentials are never passed as environment
      # variables; if the app ever needs secrets, use Secrets Manager and the
      # execution role's secret-access policy instead.
      environment = [
        { name = "APP_ENV", value = var.environment_name },
        { name = "SERVICE_NAME", value = "${var.name_prefix}-app" },
        { name = "COMMIT_SHA", value = var.commit_sha },
        { name = "HOST", value = "0.0.0.0" },
        { name = "PORT", value = tostring(var.container_port) },
        { name = "LOG_LEVEL", value = "info" },
        { name = "SHUTDOWN_TIMEOUT_MS", value = "10000" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = var.log_group_name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = "ecs"
        }
      }

      # ECS-level container health check. This is separate from the ALB target
      # group check: this one asks "is the process healthy inside the task",
      # the ALB asks "is the task reachable over the network".
      #
      # Uses Node's built-in fetch so no curl/wget is installed in the image.
      healthCheck = {
        command = [
          "CMD-SHELL",
          "node -e \"fetch('http://127.0.0.1:${var.container_port}/health').then(r => process.exit(r.status === 200 ? 0 : 1)).catch(() => process.exit(1))\"",
        ]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 15
      }
    },
  ])

  tags = merge(
    {
      Name = "${var.name_prefix}-app"
    },
    var.tags,
  )
}

# -----------------------------------------------------------------------------
# Service
# -----------------------------------------------------------------------------

resource "aws_ecs_service" "app" {
  name             = local.service_name
  cluster          = aws_ecs_cluster.this.id
  task_definition  = aws_ecs_task_definition.app.arn
  desired_count    = var.desired_count
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  health_check_grace_period_seconds = var.health_check_grace_period_seconds

  network_configuration {
    subnets         = var.subnet_ids
    security_groups = var.security_group_ids

    # ADR-002: public subnet with a public IP so Fargate can reach ECR and
    # CloudWatch without a NAT Gateway. Inbound access is still restricted to
    # the ALB security group.
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = local.container_name
    container_port   = var.container_port
  }

  # Spread tasks across Availability Zones so the two public subnets each host
  # a task when desired_count is 2. This is what gives prod multi-AZ
  # availability; with a single task (dev) it has no effect.
  ordered_placement_strategy {
    type  = "spread"
    field = "attribute:ecs.availability-zone"
  }

  # Automatic rollback if a new deployment never reaches a healthy steady
  # state. This detects infrastructure-level failure, not application bugs -
  # the pipeline still verifies the endpoint itself.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Start the replacement task and wait for it to be healthy before draining
  # the old one, so a single-task service does not drop requests during a
  # deploy.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  lifecycle {
    # Application releases are performed by the CI pipeline, which registers a
    # new task definition revision and updates this service. Without this, every
    # subsequent `terraform plan` would try to revert the running service to the
    # seed revision defined here.
    ignore_changes = [task_definition, desired_count]
  }

  tags = merge(
    {
      Name = local.service_name
    },
    var.tags,
  )
}
