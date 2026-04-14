# terraform/modules/secrets-access-policy

Terraform module that creates an IAM policy granting read access to one or
more AWS Secrets Manager secrets and (optionally) the KMS keys used to
encrypt them.  The policy is attached to the supplied IAM role names.

## Usage

### ECS task execution role

```hcl
module "app_secret_access" {
  source = "../../terraform/modules/secrets-access-policy"

  name_prefix    = "myapp"
  secret_arns    = [aws_secretsmanager_secret.app_db.arn]
  kms_key_arns   = [aws_kms_key.secrets.arn]
  iam_role_names = [aws_iam_role.ecs_task_execution.name]

  tags = { Environment = "production" }
}
```

### EKS IRSA (IAM Roles for Service Accounts)

```hcl
module "app_secret_access" {
  source = "../../terraform/modules/secrets-access-policy"

  name_prefix    = "myapp"
  secret_arns    = [aws_secretsmanager_secret.app_db.arn]
  iam_role_names = [aws_iam_role.eks_irsa.name]
}
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `name_prefix` | IAM policy name prefix | `string` | — | yes |
| `secret_arns` | Secret ARNs to grant access to | `list(string)` | — | yes |
| `kms_key_arns` | KMS key ARNs for CMK-encrypted secrets | `list(string)` | `[]` | no |
| `iam_role_names` | IAM role names to attach the policy to | `list(string)` | `[]` | no |
| `tags` | Resource tags | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| `policy_arn` | ARN of the created IAM policy |
| `policy_name` | Name of the created IAM policy |
