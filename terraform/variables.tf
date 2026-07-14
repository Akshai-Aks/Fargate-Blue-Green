variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Name prefix applied to all resources."
  type        = string
  default     = "fargate-bg"
}

variable "image_tag" {
  description = "Image tag the ECS task definition boots with on first apply. Push this tag to ECR before the full apply."
  type        = string
  default     = "v1"
}

variable "container_port" {
  description = "Port the container listens on (matches app PORT / Dockerfile EXPOSE)."
  type        = number
  default     = 8080
}

variable "task_cpu" {
  description = "Fargate task CPU units."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate task memory (MiB)."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Number of tasks in the service."
  type        = number
  default     = 1
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "health_check_path" {
  description = "HTTP path the ALB target group polls."
  type        = string
  default     = "/health"
}
