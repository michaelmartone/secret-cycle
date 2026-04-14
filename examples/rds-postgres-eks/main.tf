# examples/rds-postgres-eks/main.tf
#
# End-to-end demo: RDS PostgreSQL + AWS Secrets Manager (A/B rotation) + EKS.
#
# Resources created:
#   * VPC with public/private subnets
#   * RDS PostgreSQL instance (private subnet)
#   * Secrets Manager secrets (master + app a/b)
#   * Lambda rotation function (via secrets-rotation-lambda module)
#   * EKS cluster with a managed node group
#   * IRSA (IAM Roles for Service Accounts) for the application pod
#   * Helm release: external-secrets operator
#   * Kubernetes ExternalSecret and SecretStore manifests
#   * Sample Deployment that mounts the synced Kubernetes Secret

terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.25"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
      command     = "aws"
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    command     = "aws"
  }
}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------

data "aws_availability_zones" "available" { state = "available" }
data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Networking (shared with ECS example pattern)
# ---------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "${var.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-igw" })
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = merge(var.tags, {
    Name                                        = "${var.name_prefix}-public-${count.index}"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.name_prefix}"  = "shared"
  })
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = merge(var.tags, {
    Name                                        = "${var.name_prefix}-private-${count.index}"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.name_prefix}"  = "shared"
  })
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-nat-eip" })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = merge(var.tags, { Name = "${var.name_prefix}-nat" })
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = merge(var.tags, { Name = "${var.name_prefix}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = merge(var.tags, { Name = "${var.name_prefix}-private-rt" })
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------

resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-rds"
  description = "Allow PostgreSQL from EKS nodes and Lambda"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-rds-sg" })
}

resource "aws_security_group" "lambda" {
  name        = "${var.name_prefix}-rotation-lambda"
  description = "Rotation Lambda security group"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-lambda-sg" })
}

# ---------------------------------------------------------------------------
# KMS
# ---------------------------------------------------------------------------

resource "aws_kms_key" "secrets" {
  description             = "${var.name_prefix} secrets encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = var.tags
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.name_prefix}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# ---------------------------------------------------------------------------
# Secrets Manager
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "master" {
  name       = "${var.name_prefix}/rds/master"
  kms_key_id = aws_kms_key.secrets.arn
  tags       = var.tags
}

resource "aws_secretsmanager_secret_version" "master" {
  secret_id = aws_secretsmanager_secret.master.id
  secret_string = jsonencode({
    username = var.db_master_username
    password = var.db_master_password
    host     = aws_db_instance.postgres.address
    port     = 5432
    dbname   = var.db_name
    engine   = "postgres"
  })
  depends_on = [aws_db_instance.postgres]
}

resource "aws_secretsmanager_secret" "app" {
  name       = "${var.name_prefix}/rds/app"
  kms_key_id = aws_kms_key.secrets.arn
  tags       = var.tags
}

resource "aws_secretsmanager_secret_version" "app_initial" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    username = "${var.app_db_username}_a"
    password = var.app_db_initial_password
    host     = aws_db_instance.postgres.address
    port     = 5432
    dbname   = var.db_name
    engine   = "postgres"
  })
  depends_on = [aws_db_instance.postgres]
}

# ---------------------------------------------------------------------------
# RDS
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  name       = "${var.name_prefix}-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id
  tags       = var.tags
}

resource "aws_db_instance" "postgres" {
  identifier              = "${var.name_prefix}-postgres"
  engine                  = "postgres"
  engine_version          = var.postgres_version
  instance_class          = var.db_instance_class
  allocated_storage       = 20
  storage_type            = "gp3"
  storage_encrypted       = true
  kms_key_id              = aws_kms_key.secrets.arn
  db_name                 = var.db_name
  username                = var.db_master_username
  password                = var.db_master_password
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  multi_az                = var.multi_az
  skip_final_snapshot     = !var.deletion_protection
  deletion_protection     = var.deletion_protection
  backup_retention_period = 7
  tags                    = var.tags
}

# ---------------------------------------------------------------------------
# EKS cluster (using community module for brevity)
# ---------------------------------------------------------------------------

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.name_prefix
  cluster_version = var.k8s_version

  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.private[*].id

  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]
      min_size       = 1
      max_size       = 3
      desired_size   = var.desired_nodes
    }
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# IRSA for external-secrets operator
# ---------------------------------------------------------------------------

resource "aws_iam_role" "external_secrets" {
  name = "${var.name_prefix}-external-secrets"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRoleWithWebIdentity"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider}:sub" = "system:serviceaccount:${var.external_secrets_namespace}:external-secrets"
          "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.tags
}

module "external_secrets_secret_access" {
  source = "../../terraform/modules/secrets-access-policy"

  name_prefix    = "${var.name_prefix}-ext-secrets"
  secret_arns    = [aws_secretsmanager_secret.app.arn]
  kms_key_arns   = [aws_kms_key.secrets.arn]
  iam_role_names = [aws_iam_role.external_secrets.name]

  tags = var.tags
}

# ---------------------------------------------------------------------------
# external-secrets Helm release
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "external_secrets" {
  metadata { name = var.external_secrets_namespace }
  depends_on = [module.eks]
}

resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = var.external_secrets_chart_version
  namespace  = var.external_secrets_namespace

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.external_secrets.arn
  }

  depends_on = [kubernetes_namespace.external_secrets]
}

# ---------------------------------------------------------------------------
# SecretStore (ClusterSecretStore) pointing at AWS Secrets Manager
# ---------------------------------------------------------------------------

resource "kubernetes_manifest" "secret_store" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata   = { name = "${var.name_prefix}-aws" }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.aws_region
          auth = {
            jwt = {
              serviceAccountRef = {
                name      = "external-secrets"
                namespace = var.external_secrets_namespace
              }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.external_secrets]
}

# ---------------------------------------------------------------------------
# ExternalSecret – syncs the app secret into a Kubernetes Secret
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "app" {
  metadata { name = var.app_namespace }
  depends_on = [module.eks]
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "${var.name_prefix}-db"
      namespace = var.app_namespace
    }
    spec = {
      refreshInterval = "1m"
      secretStoreRef = {
        name = "${var.name_prefix}-aws"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "${var.name_prefix}-db"
        creationPolicy = "Owner"
      }
      dataFrom = [
        {
          extract = {
            key = aws_secretsmanager_secret.app.name
          }
        }
      ]
    }
  }
  depends_on = [kubernetes_manifest.secret_store, kubernetes_namespace.app]
}

# ---------------------------------------------------------------------------
# Sample application Deployment
# ---------------------------------------------------------------------------

resource "kubernetes_deployment" "app" {
  metadata {
    name      = var.name_prefix
    namespace = var.app_namespace
    labels    = { app = var.name_prefix }
  }

  spec {
    replicas = var.desired_replicas

    selector {
      match_labels = { app = var.name_prefix }
    }

    template {
      metadata {
        labels = { app = var.name_prefix }
      }

      spec {
        container {
          name  = "app"
          image = var.app_image

          env_from {
            secret_ref {
              name = "${var.name_prefix}-db"
            }
          }

          port {
            container_port = var.app_port
          }

          liveness_probe {
            http_get {
              path = var.health_check_path
              port = var.app_port
            }
            initial_delay_seconds = 10
            period_seconds        = 15
          }
        }
      }
    }
  }

  depends_on = [kubernetes_manifest.external_secret]
}

# ---------------------------------------------------------------------------
# Rotation Lambda (triggers EKS rollout via kubeconfig secret)
# ---------------------------------------------------------------------------

# Store a kubeconfig in Secrets Manager so the Lambda can restart the pods
resource "aws_secretsmanager_secret" "kubeconfig" {
  name       = "${var.name_prefix}/kubeconfig"
  kms_key_id = aws_kms_key.secrets.arn
  tags       = var.tags
}

resource "aws_secretsmanager_secret_version" "kubeconfig" {
  secret_id     = aws_secretsmanager_secret.kubeconfig.id
  secret_string = module.eks.kubeconfig
}

module "rotation" {
  source = "../../terraform/modules/secrets-rotation-lambda"

  name_prefix       = var.name_prefix
  secret_arn        = aws_secretsmanager_secret.app.arn
  master_secret_arn = aws_secretsmanager_secret.master.arn
  rotation_type     = "ab"
  db_engine         = "postgres"
  rotation_days     = var.rotation_days

  vpc_subnet_ids         = aws_subnet.private[*].id
  vpc_security_group_ids = [aws_security_group.lambda.id]

  k8s_namespace         = var.app_namespace
  k8s_deployment        = var.name_prefix
  kubeconfig_secret_arn = aws_secretsmanager_secret.kubeconfig.arn

  tags = var.tags
}
