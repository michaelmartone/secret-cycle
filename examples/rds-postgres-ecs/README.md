# RDS PostgreSQL + ECS Demo

This example provisions a complete AWS environment that demonstrates A/B
secret rotation with an ECS Fargate service reading database credentials
from Secrets Manager.

## Architecture

```
                  ┌──────────┐
  Internet ──────►│   ALB    │
                  └────┬─────┘
                       │ HTTP
              ┌────────▼────────┐
              │  ECS Fargate    │  reads DB_SECRET env var
              │  (app tasks)    │  ◄─── Secrets Manager ──────┐
              └────────┬────────┘                              │
                       │ PostgreSQL                       ┌────┴──────┐
              ┌────────▼────────┐                         │ Rotation  │
              │   RDS Postgres  │◄────────────────────────│  Lambda   │
              └─────────────────┘  ALTER USER myapp_b ... └───────────┘
```

**Rotation flow (A/B strategy):**

1. `createSecret` – generate a new password and store it under the *inactive*
   username (e.g. `appuser_b` if `appuser_a` is active).
2. `setSecret` – `ALTER USER appuser_b WITH PASSWORD '<new>'` using master
   credentials.
3. `testSecret` – open a test connection with `appuser_b` / new password.
4. `finishSecret` – promote the pending version to `AWSCURRENT`, then force a
   new ECS deployment so tasks restart and pick up the new username/password.

At no point are all valid database sessions invalidated simultaneously.

## Prerequisites

1. Terraform ≥ 1.3  
2. AWS credentials with sufficient permissions  
3. A Docker image for your application available in ECR or Docker Hub

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars

terraform init
terraform plan
terraform apply
```

After `apply` you can trigger an immediate rotation to verify the setup:

```bash
aws secretsmanager rotate-secret \
  --secret-id <app_secret_arn output>
```

## Inputs

See `variables.tf` for the full list.  The minimum required variables are:

| Variable | Description |
|----------|-------------|
| `db_master_password` | RDS master password |
| `app_db_initial_password` | Initial app DB password |
| `app_image` | Docker image URI for the application |

## Notes

* `db_master_password` and `app_db_initial_password` are marked `sensitive`.
  Pass them via `-var` flags, a `terraform.tfvars` file, or AWS SSM
  Parameter Store / environment variables.  **Never commit passwords.**
* The demo uses `skip_final_snapshot = true` and
  `deletion_protection = false` by default to make teardown easy.  Set
  `deletion_protection = true` for production.
