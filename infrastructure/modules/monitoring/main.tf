resource "aws_cloudwatch_log_group" "app" {
  # Naming convention from the design document: /ecs/<project>/<environment>
  name              = "/ecs/${var.name_prefix}"
  retention_in_days = var.log_retention_days

  tags = merge(
    {
      Name      = "/ecs/${var.name_prefix}"
      Component = "application-logs"
    },
    var.tags,
  )
}

# -----------------------------------------------------------------------------
# Alarm notification
#
# SNS so alarms have somewhere to publish. Email subscriptions cost nothing and
# need no extra service; the subscriber must confirm the link AWS sends.
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "alarms" {
  name = "${var.name_prefix}-alarms"

  tags = merge(
    {
      Name = "${var.name_prefix}-alarms"
    },
    var.tags,
  )
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alarm_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# -----------------------------------------------------------------------------
# Alarms
#
# Thresholds are initial operational values for a single-task assessment
# service, not tuned production baselines. Each names the §11.2 signal it covers.
# -----------------------------------------------------------------------------

# Application or target errors returned to clients.
resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name        = "${var.name_prefix}-target-5xx"
  alarm_description = "Target group is returning 5xx responses - the application is failing, not just slow."

  namespace   = "AWS/ApplicationELB"
  metric_name = "HTTPCode_Target_5XX_Count"
  statistic   = "Sum"
  period      = 60

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.target_5xx_threshold
  evaluation_periods  = 2

  # No requests means no 5xx. Silence is not a failure.
  treat_missing_data = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = var.tags
}

# Loss of healthy targets - the ingress equivalent of "the service is down".
#
# Metric name is UnHealthyHostCount, with a capital H. The natural spelling
# (UnhealthyHostCount) does not exist in CloudWatch and silently leaves the
# alarm in INSUFFICIENT_DATA forever - verified against list-metrics, not assumed.
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name        = "${var.name_prefix}-unhealthy-hosts"
  alarm_description = "At least one target is failing ALB health checks. A single-task service has no redundancy."

  namespace   = "AWS/ApplicationELB"
  metric_name = "UnHealthyHostCount"
  statistic   = "Maximum"
  period      = 60

  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  evaluation_periods  = 2

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = var.tags
}

# Capacity: the service has no live tasks. Published per service without
# Container Insights, so this covers §11.2's "running task count" signal for
# free.
resource "aws_cloudwatch_metric_alarm" "live_task_count" {
  alarm_name        = "${var.name_prefix}-live-task-count-low"
  alarm_description = "ECS service has fewer live tasks than desired (${var.desired_count})."

  namespace   = "AWS/ECS"
  metric_name = "LiveTaskCount"
  statistic   = "Minimum"
  period      = 60

  comparison_operator = "LessThanThreshold"
  threshold           = var.desired_count
  evaluation_periods  = 2

  # Zero tasks is the failure being alarmed on, so absence of data is treated as
  # bad rather than ignored.
  treat_missing_data = "breaching"

  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = var.service_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = var.tags
}

# Sustained CPU pressure on the service.
resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  alarm_name        = "${var.name_prefix}-ecs-cpu-high"
  alarm_description = "ECS service CPU above ${var.cpu_threshold_percent}% for 10 minutes."

  namespace   = "AWS/ECS"
  metric_name = "CPUUtilization"
  statistic   = "Average"
  period      = 300

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.cpu_threshold_percent
  evaluation_periods  = 2

  treat_missing_data = "notBreaching"

  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = var.service_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = var.tags
}

# Sustained memory pressure. With a 0.5 GB task this fires before the container
# is OOM-killed, which is the point.
resource "aws_cloudwatch_metric_alarm" "ecs_memory" {
  alarm_name        = "${var.name_prefix}-ecs-memory-high"
  alarm_description = "ECS service memory above ${var.memory_threshold_percent}% for 10 minutes."

  namespace   = "AWS/ECS"
  metric_name = "MemoryUtilization"
  statistic   = "Average"
  period      = 300

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.memory_threshold_percent
  evaluation_periods  = 2

  treat_missing_data = "notBreaching"

  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = var.service_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = var.tags
}

# Note on metric availability: CloudWatch only creates a metric once a datapoint
# exists. HTTPCode_Target_5XX_Count is absent until the first 5xx response is
# served, so that alarm legitimately sits at INSUFFICIENT_DATA on a healthy
# service. treat_missing_data = "notBreaching" keeps that from reading as a
# fault, and the alarm resolves and evaluates from the first real 5xx onward.
