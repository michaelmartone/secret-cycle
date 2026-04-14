output "policy_arn" {
  description = "ARN of the secrets-read IAM policy."
  value       = aws_iam_policy.secret_read.arn
}

output "policy_name" {
  description = "Name of the secrets-read IAM policy."
  value       = aws_iam_policy.secret_read.name
}
