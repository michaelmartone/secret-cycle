output "lambda_function_arn" {
  description = "ARN of the rotation Lambda function."
  value       = aws_lambda_function.rotation.arn
}

output "lambda_function_name" {
  description = "Name of the rotation Lambda function."
  value       = aws_lambda_function.rotation.function_name
}

output "lambda_role_arn" {
  description = "ARN of the IAM role used by the rotation Lambda."
  value       = aws_iam_role.lambda.arn
}
