# terraform/modules/secrets-rotation-lambda/main.tf
#
# Creates a Lambda function that acts as an AWS Secrets Manager rotation
# function.  The Lambda package is assembled from the lambda/ directory at
# the root of this repository.
#
# The module also creates:
#   * an IAM execution role for the Lambda
#   * a Secrets Manager rotation schedule attached to the target secret
#   * a Lambda resource-based policy that allows Secrets Manager to invoke it

terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Lambda deployment package
# ---------------------------------------------------------------------------

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = var.lambda_source_dir
  output_path = "${path.module}/.build/secret_cycle.zip"
}

# ---------------------------------------------------------------------------
# IAM role for the Lambda execution
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name_prefix}-rotation-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "lambda_permissions" {
  # CloudWatch Logs
  statement {
    sid     = "Logs"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "arn:aws:logs:*:*:log-group:/aws/lambda/${var.name_prefix}-rotation-lambda:*",
    ]
  }

  # Read / write the secret being rotated plus the master secret
  statement {
    sid = "SecretsManager"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:UpdateSecretVersionStage",
    ]
    resources = concat(
      [var.secret_arn],
      var.master_secret_arn != null ? [var.master_secret_arn] : []
    )
  }

  # Allow the Lambda to generate a random password via Secrets Manager
  statement {
    sid       = "GetRandomPassword"
    actions   = ["secretsmanager:GetRandomPassword"]
    resources = ["*"]
  }

  # Optional: ECS – force new deployment
  dynamic "statement" {
    for_each = var.ecs_cluster_arn != null ? [1] : []
    content {
      sid       = "EcsForceDeployment"
      actions   = ["ecs:UpdateService"]
      resources = [var.ecs_service_arn]
    }
  }

  # Optional: VPC networking (required when Lambda runs inside a VPC)
  dynamic "statement" {
    for_each = length(var.vpc_subnet_ids) > 0 ? [1] : []
    content {
      sid = "VpcNetworking"
      actions = [
        "ec2:CreateNetworkInterface",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DeleteNetworkInterface",
        "ec2:AssignPrivateIpAddresses",
        "ec2:UnassignPrivateIpAddresses",
      ]
      resources = ["*"]
    }
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "rotation-policy"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

# ---------------------------------------------------------------------------
# Lambda function
# ---------------------------------------------------------------------------

resource "aws_lambda_function" "rotation" {
  function_name = "${var.name_prefix}-rotation-lambda"
  description   = "AWS Secrets Manager rotation function (${var.rotation_type} strategy)"
  role          = aws_iam_role.lambda.arn
  handler       = "secret_cycle.lambda_handler"
  runtime       = "python3.12"
  timeout       = var.lambda_timeout
  memory_size   = var.lambda_memory_mb

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = merge(
      {
        ROTATION_TYPE  = var.rotation_type
        DB_ENGINE      = var.db_engine
        PASSWORD_LENGTH = tostring(var.password_length)
      },
      var.master_secret_arn != null ? { MASTER_SECRET_ARN = var.master_secret_arn } : {},
      var.ecs_cluster_arn != null ? {
        ECS_CLUSTER = var.ecs_cluster_name
        ECS_SERVICE = var.ecs_service_name
      } : {},
      var.k8s_namespace != null ? {
        K8S_NAMESPACE  = var.k8s_namespace
        K8S_DEPLOYMENT = var.k8s_deployment
        K8S_IN_CLUSTER = "false"
        KUBECONFIG_SECRET_ARN = var.kubeconfig_secret_arn != null ? var.kubeconfig_secret_arn : ""
      } : {},
      var.extra_env_vars
    )
  }

  dynamic "vpc_config" {
    for_each = length(var.vpc_subnet_ids) > 0 ? [1] : []
    content {
      subnet_ids         = var.vpc_subnet_ids
      security_group_ids = var.vpc_security_group_ids
    }
  }

  tags = var.tags
}

# Allow Secrets Manager to invoke the Lambda
resource "aws_lambda_permission" "secrets_manager" {
  statement_id  = "AllowSecretsManager"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotation.function_name
  principal     = "secretsmanager.amazonaws.com"
  source_arn    = var.secret_arn
}

# ---------------------------------------------------------------------------
# Attach the rotation schedule to the secret
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret_rotation" "rotation" {
  secret_id           = var.secret_arn
  rotation_lambda_arn = aws_lambda_function.rotation.arn

  rotation_rules {
    automatically_after_days = var.rotation_days
  }
}
