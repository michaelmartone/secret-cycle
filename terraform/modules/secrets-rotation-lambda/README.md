# terraform/modules/secrets-rotation-lambda

Terraform module that packages and deploys the `secret_cycle.py` Lambda
function and configures AWS Secrets Manager to call it on a schedule.

## Features

* Bundles the `lambda/` directory into a deployment ZIP automatically.
* Supports both **A/B** (soft-handoff) and **single** rotation strategies.
* Optionally restarts an **ECS** service or a **Kubernetes** deployment
  after each successful rotation.
* Supports VPC deployment (required when the database is in a private subnet).

## Usage

```hcl
module "rotation" {
  source = "../../terraform/modules/secrets-rotation-lambda"

  name_prefix       = "myapp"
  secret_arn        = aws_secretsmanager_secret.app.arn
  master_secret_arn = aws_secretsmanager_secret.master.arn
  rotation_type     = "ab"
  db_engine         = "postgres"
  rotation_days     = 30

  vpc_subnet_ids         = module.vpc.private_subnets
  vpc_security_group_ids = [aws_security_group.lambda.id]

  # Optional: restart ECS service after rotation
  ecs_cluster_arn  = aws_ecs_cluster.main.arn
  ecs_cluster_name = aws_ecs_cluster.main.name
  ecs_service_arn  = aws_ecs_service.app.id
  ecs_service_name = aws_ecs_service.app.name

  tags = { Environment = "production" }
}
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `name_prefix` | Prefix for resource names | `string` | — | yes |
| `secret_arn` | ARN of the secret to rotate | `string` | — | yes |
| `rotation_type` | `"ab"` or `"single"` | `string` | `"ab"` | no |
| `db_engine` | `"postgres"`, `"mysql"`, or `"mariadb"` | `string` | `"postgres"` | no |
| `master_secret_arn` | ARN of master credentials (required for A/B) | `string` | `null` | no |
| `lambda_source_dir` | Path to the `lambda/` directory | `string` | `"../../../lambda"` | no |
| `lambda_timeout` | Lambda timeout (seconds) | `number` | `60` | no |
| `lambda_memory_mb` | Lambda memory (MB) | `number` | `128` | no |
| `password_length` | Generated password length | `number` | `32` | no |
| `rotation_days` | Days between automatic rotations | `number` | `30` | no |
| `vpc_subnet_ids` | Subnet IDs for VPC config | `list(string)` | `[]` | no |
| `vpc_security_group_ids` | Security group IDs for VPC config | `list(string)` | `[]` | no |
| `ecs_cluster_arn` | ECS cluster ARN | `string` | `null` | no |
| `ecs_service_arn` | ECS service ARN | `string` | `null` | no |
| `k8s_namespace` | Kubernetes namespace | `string` | `null` | no |
| `k8s_deployment` | Kubernetes deployment name | `string` | `null` | no |
| `kubeconfig_secret_arn` | Secrets Manager ARN for kubeconfig | `string` | `null` | no |
| `extra_env_vars` | Additional Lambda env vars | `map(string)` | `{}` | no |
| `tags` | Resource tags | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| `lambda_function_arn` | ARN of the rotation Lambda |
| `lambda_function_name` | Name of the rotation Lambda |
| `lambda_role_arn` | ARN of the Lambda IAM role |
