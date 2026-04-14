# RDS PostgreSQL + EKS + External Secrets Demo

This example provisions a complete AWS + Kubernetes environment demonstrating
A/B secret rotation with an EKS workload consuming database credentials via
the [External Secrets Operator](https://external-secrets.io/).

## Architecture

```
  AWS Secrets Manager
  ┌──────────────────────────┐
  │  secret: .../rds/app     │◄──── Rotation Lambda (A/B)
  │  { username, password,   │
  │    host, port, dbname }  │
  └──────────┬───────────────┘
             │ sync (1 min refresh)
  ┌──────────▼───────────────┐
  │  External Secrets        │  (Helm, in EKS)
  │  Operator                │
  └──────────┬───────────────┘
             │ creates/updates
  ┌──────────▼───────────────┐
  │  Kubernetes Secret       │
  │  (secret-cycle-eks-db)   │
  └──────────┬───────────────┘
             │ envFrom
  ┌──────────▼───────────────┐
  │  App Deployment Pods     │──── connects to RDS via env vars
  └──────────────────────────┘
```

**Why External Secrets?**

Kubernetes pods mount secrets at start-up time. External Secrets polls AWS
Secrets Manager every minute (`refreshInterval: 1m`) so the Kubernetes Secret
object stays up-to-date. After rotation, the Lambda triggers a
`rollout restart` on the Deployment so pods relaunch and read the new
credentials from the already-updated Kubernetes Secret.

## Prerequisites

1. Terraform ≥ 1.3  
2. AWS CLI & credentials  
3. `kubectl` (to inspect cluster after apply)  
4. `helm` (used by the Terraform helm provider)  
5. A Docker image for your application

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars

terraform init
terraform apply
```

Update `kubeconfig` after cluster creation:

```bash
aws eks update-kubeconfig --name secret-cycle-eks --region us-east-1
kubectl get externalsecret -n default
kubectl get secret secret-cycle-eks-db -n default -o jsonpath='{.data.username}' | base64 -d
```

Trigger an immediate rotation to test the full flow:

```bash
aws secretsmanager rotate-secret \
  --secret-id $(terraform output -raw app_secret_arn)
```

Watch the Kubernetes Secret update within a minute, then verify the
Deployment has been restarted:

```bash
kubectl rollout status deployment/secret-cycle-eks -n default
```

## Inputs

See `variables.tf` for the full variable list.

## Notes

* The `external-secrets` Helm chart is pinned to a specific version via
  `external_secrets_chart_version`.  Update it to get new features.
* IRSA (IAM Roles for Service Accounts) is used so the operator pod has
  minimal AWS permissions and no long-lived credentials are stored in the
  cluster.
* `deletion_protection = false` by default for easy teardown; set to `true`
  for production.
