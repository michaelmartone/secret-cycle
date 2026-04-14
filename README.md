# secret-cycle

Secret cycling for AWS environments with EKS and external secrets.

This repository provides a complete solution for rotating AWS Secrets Manager
secrets that store database credentials (username + password).  It supports
an **A/B soft-handoff** strategy that ensures the old credentials remain valid
until the new ones have been verified, preventing service interruptions.

## Repository Layout

```
├── lambda/                          # Python rotation script + tests
│   ├── secret_cycle.py              #   Lambda handler & CLI entry-point
│   ├── requirements.txt             #   Python dependencies
│   └── tests/
│       └── test_secret_cycle.py     #   Unit tests (24 tests)
│
├── terraform/
│   └── modules/
│       ├── secrets-rotation-lambda/ #   Deploy the rotation Lambda
│       └── secrets-access-policy/  #   IAM policy for reading secrets
│
├── examples/
│   ├── rds-postgres-ecs/            #   RDS + ECS Fargate full demo
│   └── rds-postgres-eks/            #   RDS + EKS + external-secrets demo
│
└── helm/
    └── secret-cycle/                #   Helm chart (CronJob-based rotation)
```

---

## How It Works

### A/B Rotation Strategy

Database credentials are stored in a Secrets Manager secret as JSON:

```json
{
  "username": "appuser_a",
  "password": "current-password",
  "host": "db.example.com",
  "port": 5432,
  "dbname": "mydb",
  "engine": "postgres"
}
```

During rotation the script:

1. **createSecret** – generates a new password for the *inactive* account
   (`appuser_b` when `appuser_a` is active) and stores it as `AWSPENDING`.
2. **setSecret** – runs `ALTER USER appuser_b WITH PASSWORD '<new>'` using
   the master DB credentials.  Both accounts are now valid.
3. **testSecret** – opens a test connection with the pending credentials.
4. **finishSecret** – promotes the pending version to `AWSCURRENT`.
   Optionally forces a new ECS deployment or triggers a Kubernetes
   `rollout restart` so services pick up the new username/password.

At no point are all valid sessions invalidated simultaneously.

### Single Rotation Strategy

For services that use a single shared account, set `ROTATION_TYPE=single`.
The script rotates only the password in-place without switching usernames.

---

## Lambda / CLI Configuration

All settings are passed via environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `ROTATION_TYPE` | `ab` or `single` | `ab` |
| `DB_ENGINE` | `postgres`, `mysql`, `mariadb` | `postgres` |
| `MASTER_SECRET_ARN` | ARN of master credentials (required for `ab`) | — |
| `PASSWORD_LENGTH` | Generated password length | `32` |
| `EXCLUDE_CHARACTERS` | Characters excluded from passwords | `/@"'\` |
| `ECS_CLUSTER` | ECS cluster name (triggers force-redeploy) | — |
| `ECS_SERVICE` | ECS service name | — |
| `K8S_NAMESPACE` | Kubernetes namespace (triggers rollout-restart) | — |
| `K8S_DEPLOYMENT` | Kubernetes deployment name | — |
| `K8S_IN_CLUSTER` | Use in-cluster ServiceAccount credentials | `true` |
| `KUBECONFIG_SECRET_ARN` | Secrets Manager ARN for kubeconfig YAML | — |

---

## Terraform Modules

### `terraform/modules/secrets-rotation-lambda`

Packages `lambda/secret_cycle.py` into a ZIP, creates the Lambda function,
wires up the IAM role, and attaches a rotation schedule to the secret.

```hcl
module "rotation" {
  source = "./terraform/modules/secrets-rotation-lambda"

  name_prefix       = "myapp"
  secret_arn        = aws_secretsmanager_secret.app.arn
  master_secret_arn = aws_secretsmanager_secret.master.arn
  rotation_type     = "ab"
  db_engine         = "postgres"
  rotation_days     = 30

  vpc_subnet_ids         = module.vpc.private_subnets
  vpc_security_group_ids = [aws_security_group.lambda.id]

  # Restart ECS after rotation
  ecs_cluster_name = "my-cluster"
  ecs_cluster_arn  = aws_ecs_cluster.main.arn
  ecs_service_name = "my-service"
  ecs_service_arn  = aws_ecs_service.app.id
}
```

### `terraform/modules/secrets-access-policy`

Creates an IAM policy granting `secretsmanager:GetSecretValue` and attaches
it to the supplied IAM role names (e.g. ECS task execution role, EKS IRSA
role).

```hcl
module "app_secret_access" {
  source = "./terraform/modules/secrets-access-policy"

  name_prefix    = "myapp"
  secret_arns    = [aws_secretsmanager_secret.app.arn]
  kms_key_arns   = [aws_kms_key.secrets.arn]
  iam_role_names = [aws_iam_role.ecs_task_execution.name]
}
```

---

## Examples

### ECS (Fargate)

```bash
cd examples/rds-postgres-ecs
terraform init && terraform apply
```

See [examples/rds-postgres-ecs/README.md](examples/rds-postgres-ecs/README.md).

### EKS + External Secrets Operator

```bash
cd examples/rds-postgres-eks
terraform init && terraform apply
```

The [External Secrets Operator](https://external-secrets.io/) syncs the
Secrets Manager secret into a Kubernetes `Secret` every minute.  After
rotation the Lambda triggers a `rollout restart` on the Deployment.

See [examples/rds-postgres-eks/README.md](examples/rds-postgres-eks/README.md).

---

## Helm Chart

Use the Helm chart when you want rotation to be scheduled from *inside* the
cluster (e.g. you don't have a Lambda rotation function set up yet).

```bash
helm upgrade --install secret-cycle helm/secret-cycle \
  --namespace secret-cycle \
  --create-namespace \
  --set rotation.secretArn=arn:aws:secretsmanager:us-east-1:123:secret:myapp \
  --set rotation.masterSecretArn=arn:aws:secretsmanager:us-east-1:123:secret:master \
  --set rotation.type=ab \
  --set rotation.schedule="0 2 * * 0" \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::123:role/rotation-role
```

See [helm/secret-cycle/values.yaml](helm/secret-cycle/values.yaml) for all
options.

---

## Running the Tests

```bash
cd lambda
pip install -r requirements.txt pytest
python -m pytest tests/ -v
```

---

## Security Considerations

* **Passwords are never logged.** The script uses `logging.info` only for
  usernames and metadata; password values are excluded.
* **Secrets Manager VPC endpoint** – deploy the Lambda inside a VPC with a
  Secrets Manager VPC endpoint to prevent traffic leaving the VPC.
* **KMS encryption** – all example secrets use a customer-managed KMS key
  with automatic key rotation enabled.
* **Least-privilege IAM** – the Lambda role has only the permissions it needs
  (`GetSecretValue`, `PutSecretValue`, `UpdateSecretVersionStage`, and
  optionally `ecs:UpdateService`).
* **`.tfvars` files** are excluded from version control via `.gitignore` to
  prevent accidental secret commits.
