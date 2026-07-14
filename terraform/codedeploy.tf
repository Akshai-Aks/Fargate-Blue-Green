resource "aws_codedeploy_app" "app" {
  name             = "${var.project_name}-cd"
  compute_platform = "ECS"
}

resource "aws_codedeploy_deployment_group" "app" {
  app_name               = aws_codedeploy_app.app.name
  deployment_group_name  = "${var.project_name}-dg"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"

  deployment_style {
    deployment_type   = "BLUE_GREEN"
    deployment_option = "WITH_TRAFFIC_CONTROL"
  }

  # Roll back automatically on an outright deployment failure OR when one of the
  # unhealthy-host alarms trips. The alarm path is what catches the broken v3
  # (container runs, but /health returns 500) -- CodeDeploy does not fail an ECS
  # deployment on ALB health alone.
  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }

  # Alarms CodeDeploy watches for the duration of each deployment.
  alarm_configuration {
    enabled = true
    alarms  = [for a in aws_cloudwatch_metric_alarm.tg_unhealthy : a.alarm_name]
  }

  blue_green_deployment_config {
    # No manual approval gate: shift traffic as soon as the replacement set is ready.
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }

    # Keep the original task set alive for a few minutes after cutover. This is
    # the bake window during which CodeDeploy keeps watching the alarms: if the
    # new release is unhealthy, the alarm trips here and traffic is rerouted back
    # to the original before it is terminated.
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 3
    }
  }

  ecs_service {
    cluster_name = aws_ecs_cluster.main.name
    service_name = aws_ecs_service.app.name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.prod.arn]
      }

      target_group {
        name = aws_lb_target_group.blue.name
      }

      target_group {
        name = aws_lb_target_group.green.name
      }
    }
  }
}
