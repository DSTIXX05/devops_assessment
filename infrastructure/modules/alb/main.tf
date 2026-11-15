resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"

  # AWS provider v6 replaced the `scheme = "internet-facing"` argument with an
  # `internal` boolean. false means internet-facing, which is what the
  # assessment needs: a public entry point with no DNS record in front of it.
  internal = false

  # Both AZs, so the load balancer keeps serving if one AZ is impaired. This
  # makes the ingress layer resilient; it does not make a single ECS task
  # highly available.
  subnets         = var.public_subnet_ids
  security_groups = [var.security_group_id]

  # Left disabled so `terraform destroy` works without a manual
  # delete-protection toggle. A production deployment would enable this.
  enable_deletion_protection = false

  # Must exceed the application's keep-alive timeout (65s) so the ALB does not
  # close connections the server still considers usable.
  idle_timeout = 70

  tags = merge(
    {
      Name = "${var.name_prefix}-alb"
      Tier = "ingress"
    },
    var.tags,
  )
}

resource "aws_lb_target_group" "app" {
  name        = "${var.name_prefix}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  # Short delay: ECS sends SIGTERM when it stops a task, the app drains in
  # under 10 seconds, and 30 gives headroom without stalling every deploy for
  # the AWS default of 300 seconds.
  deregistration_delay = var.deregistration_delay

  health_check {
    enabled             = true
    path                = var.health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(
    {
      Name = "${var.name_prefix}-tg"
    },
    var.tags,
  )
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  # Assessment limitation: HTTP only. No domain is available, so ACM cannot
  # validate a certificate. Production adds an HTTPS listener on 443 with a
  # redirect here.
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = merge(
    {
      Name = "${var.name_prefix}-http"
    },
    var.tags,
  )
}
