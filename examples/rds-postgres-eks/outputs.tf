output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.main.id
}

output "rds_endpoint" {
  description = "RDS endpoint."
  value       = aws_db_instance.postgres.endpoint
}

output "app_secret_arn" {
  description = "ARN of the application Secrets Manager secret."
  value       = aws_secretsmanager_secret.app.arn
}

output "eks_cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "rotation_lambda_arn" {
  description = "ARN of the rotation Lambda."
  value       = module.rotation.lambda_function_arn
}

output "external_secrets_role_arn" {
  description = "IAM role ARN used by the external-secrets operator."
  value       = aws_iam_role.external_secrets.arn
}
