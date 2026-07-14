# Health-based rollback for ECS blue/green.
#
# CodeDeploy does NOT fail an ECS deployment just because ALB health checks are
# failing -- as long as the container is RUNNING, it shifts traffic and marks
# the deployment Succeeded. So `auto_rollback_configuration` on DEPLOYMENT_FAILURE
# alone will not catch a "runs but unhealthy" release like v3 (whose /health
# returns 500). A CloudWatch alarm on the target group's unhealthy host count is
# what actually enforces health-based rollback: CodeDeploy watches these alarms
# during the deployment and, if one trips, stops and rolls back (see the
# deployment group's alarm_configuration + DEPLOYMENT_STOP_ON_ALARM).
resource "aws_cloudwatch_metric_alarm" "tg_unhealthy" {
  for_each = {
    blue  = aws_lb_target_group.blue.arn_suffix
    green = aws_lb_target_group.green.arn_suffix
  }

  alarm_name          = "${var.project_name}-${each.key}-unhealthy-hosts"
  alarm_description   = "Unhealthy hosts present in the ${each.key} target group"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  # An idle target group publishes no data; that must read as "healthy" so it
  # never blocks a deployment from starting.
  treat_missing_data = "notBreaching"

  dimensions = {
    TargetGroup  = each.value
    LoadBalancer = aws_lb.main.arn_suffix
  }

  tags = { Name = "${var.project_name}-${each.key}-unhealthy-hosts" }
}
