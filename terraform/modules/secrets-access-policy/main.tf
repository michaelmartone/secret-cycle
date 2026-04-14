# terraform/modules/secrets-access-policy/main.tf
#
# Creates an IAM policy that grants read access to one or more Secrets
# Manager secrets and (optionally) the KMS key used to encrypt them.
# The policy is then attached to the supplied IAM roles or users.

terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

data "aws_iam_policy_document" "secret_read" {
  # Allow reading the current value of each secret
  statement {
    sid = "ReadSecrets"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecretVersionIds",
    ]
    resources = var.secret_arns
  }

  # Allow listing secrets so SDKs can resolve friendly names
  statement {
    sid       = "ListSecrets"
    actions   = ["secretsmanager:ListSecrets"]
    resources = ["*"]
  }

  # Optional KMS decrypt permission (needed when secrets use a customer CMK)
  dynamic "statement" {
    for_each = length(var.kms_key_arns) > 0 ? [1] : []
    content {
      sid       = "KmsDecrypt"
      actions   = ["kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey"]
      resources = var.kms_key_arns
    }
  }
}

resource "aws_iam_policy" "secret_read" {
  name        = "${var.name_prefix}-secret-read"
  description = "Grants read access to the ${var.name_prefix} application secrets."
  policy      = data.aws_iam_policy_document.secret_read.json
  tags        = var.tags
}

# Attach to supplied IAM roles
resource "aws_iam_role_policy_attachment" "roles" {
  for_each   = toset(var.iam_role_names)
  role       = each.key
  policy_arn = aws_iam_policy.secret_read.arn
}
