output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.main.id
}

output "rds_endpoint" {
  description = "RDS instance endpoint."
  value       = aws_db_instance.postgres.endpoint
}

output "app_secret_arn" {
  description = "ARN of the application Secrets Manager secret."
  value       = aws_secretsmanager_secret.app.arn
}

output "master_secret_arn" {
  description = "ARN of the master Secrets Manager secret."
  value       = aws_secretsmanager_secret.master.arn
}

output "rotation_lambda_arn" {
  description = "ARN of the rotation Lambda function."
  value       = module.rotation.lambda_function_arn
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.app.name
}

output "alb_dns_name" {
  description = "ALB DNS name."
  value       = aws_alb.main.dns_name
}
