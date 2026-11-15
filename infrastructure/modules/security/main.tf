# -----------------------------------------------------------------------------
# Security groups
#
# The groups are created first and the rules afterwards, as separate resources.
# Inline `ingress`/`egress` blocks would create a dependency cycle, because the
# ALB group's egress refers to the task group and the task group's ingress refers
# back to the ALB group.
# -----------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "Application Load Balancer: HTTP ingress from the internet, egress to ECS tasks only"
  vpc_id      = var.vpc_id

  tags = merge(
    {
      Name = "${var.name_prefix}-alb"
      Tier = "ingress"
    },
    var.tags,
  )
}

resource "aws_security_group" "task" {
  name        = "${var.name_prefix}-task"
  description = "ECS Fargate tasks: application port reachable only from the ALB"
  vpc_id      = var.vpc_id

  tags = merge(
    {
      Name = "${var.name_prefix}-task"
      Tier = "compute"
    },
    var.tags,
  )
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "Assessment HTTP ingress on port 80 - no TLS because no domain is available for ACM validation"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_task" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward requests and health checks to the task port only"
  referenced_security_group_id = aws_security_group.task.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "task_from_alb" {
  security_group_id            = aws_security_group.task.id
  description                  = "Application port accepts traffic from the ALB security group only - never 0.0.0.0/0"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

# Outbound, deliberately unrestricted.
#
# Tasks sit in a public subnet (ADR-002) so there is no NAT Gateway to traverse.
# Fargate needs egress to pull images from ECR, publish logs to CloudWatch, and
# reach the assessment's own dependencies. Restricting this to AWS service CIDRs
# is not practical, and interface endpoints would add roughly $7/month per
# endpoint per AZ - more than the resources they protect.
#
# This is stated as a known limitation in the README rather than described as a
# control that exists.
resource "aws_vpc_security_group_egress_rule" "task_outbound_all" {
  security_group_id = aws_security_group.task.id
  description       = "Required for ECR image pulls and CloudWatch Logs delivery - unrestricted by design, see ADR-002"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
