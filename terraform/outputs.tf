output "region" {
  description = "Deployment region."
  value       = var.aws_region
}

output "alb_dns_name" {
  description = "Public DNS name of the ALB (browse http://<this>/)."
  value       = aws_lb.main.dns_name
}

output "ecr_repository_url" {
  description = "ECR repo URL to build/push images to."
  value       = aws_ecr_repository.app.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  value = aws_ecs_service.app.name
}

output "task_definition_family" {
  value = aws_ecs_task_definition.app.family
}

output "container_name" {
  value = local.container_name
}

output "container_port" {
  value = var.container_port
}

output "codedeploy_app_name" {
  value = aws_codedeploy_app.app.name
}

output "codedeploy_deployment_group_name" {
  value = aws_codedeploy_deployment_group.app.deployment_group_name
}

output "prod_listener_arn" {
  value = aws_lb_listener.prod.arn
}
