# examples/rds-postgres-ecs/main.tf
#
# End-to-end demo: RDS PostgreSQL + AWS Secrets Manager (A/B rotation) + ECS.
#
# Resources created:
#   * VPC with public/private subnets
#   * RDS PostgreSQL instance (private subnet)
#   * Secrets Manager secret for master credentials
#   * Secrets Manager secret for application credentials (a/b rotation)
#   * Lambda rotation function (via secrets-rotation-lambda module)
#   * ECS cluster, task definition, and Fargate service
#   * ALB (Application Load Balancer) in front of the ECS service
#   * IAM roles & security groups
#
# The application reads database credentials from Secrets Manager at runtime
# so it always uses the current active username/password.

terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

# ---------------------------------------------------------------------------
# Networking
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
  tags                    = merge(var.tags, { Name = "${var.name_prefix}-public-${count.index}" })
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = merge(var.tags, { Name = "${var.name_prefix}-private-${count.index}" })
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
  description = "Allow PostgreSQL from ECS tasks and Lambda"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id, aws_security_group.lambda.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-rds-sg" })
}

resource "aws_security_group" "ecs_tasks" {
  name        = "${var.name_prefix}-ecs-tasks"
  description = "ECS task security group"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-ecs-tasks-sg" })
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

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "ALB security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb-sg" })
}

# ---------------------------------------------------------------------------
# KMS key for Secrets Manager
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
# Secrets Manager – master credentials
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

# ---------------------------------------------------------------------------
# Secrets Manager – application credentials (a/b rotation)
# ---------------------------------------------------------------------------

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
# RDS PostgreSQL
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
# Rotation Lambda
# ---------------------------------------------------------------------------

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

  ecs_cluster_arn  = aws_ecs_cluster.main.arn
  ecs_cluster_name = aws_ecs_cluster.main.name
  ecs_service_arn  = aws_ecs_service.app.id
  ecs_service_name = aws_ecs_service.app.name

  tags = var.tags
}

# Grant ECS task execution role access to both secrets and KMS key
module "app_secret_access" {
  source = "../../terraform/modules/secrets-access-policy"

  name_prefix    = var.name_prefix
  secret_arns    = [aws_secretsmanager_secret.app.arn]
  kms_key_arns   = [aws_kms_key.secrets.arn]
  iam_role_names = [aws_iam_role.ecs_task_execution.name]

  tags = var.tags
}

# ---------------------------------------------------------------------------
# ECS
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "main" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = var.tags
}

resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.name_prefix}-ecs-task-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task" {
  name = "${var.name_prefix}-ecs-task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
  tags = var.tags
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.name_prefix}"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.name_prefix}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = var.app_image
      essential = true
      portMappings = [{ containerPort = var.app_port, protocol = "tcp" }]

      # Inject the secret as an environment variable at task startup.
      # The ECS agent resolves the Secrets Manager ARN automatically.
      secrets = [
        {
          name      = "DB_SECRET"
          valueFrom = aws_secretsmanager_secret.app.arn
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "app"
        }
      }
    }
  ])

  tags = var.tags
}

resource "aws_alb" "main" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  tags               = var.tags
}

resource "aws_alb_target_group" "app" {
  name        = "${var.name_prefix}-tg"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = var.health_check_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
  }

  tags = var.tags
}

resource "aws_alb_listener" "http" {
  load_balancer_arn = aws_alb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_alb_target_group.app.arn
  }
}

resource "aws_ecs_service" "app" {
  name            = "${var.name_prefix}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_alb_target_group.app.arn
    container_name   = "app"
    container_port   = var.app_port
  }

  # Ignore task definition changes so Terraform doesn't redeploy on every plan
  lifecycle {
    ignore_changes = [task_definition]
  }

  depends_on = [aws_alb_listener.http, module.app_secret_access]

  tags = var.tags
}
