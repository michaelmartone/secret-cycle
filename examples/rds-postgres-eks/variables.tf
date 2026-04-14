variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for all resource names."
  type        = string
  default     = "secret-cycle-eks"
}

variable "db_master_username" {
  description = "RDS master username."
  type        = string
  default     = "postgres"
}

variable "db_master_password" {
  description = "RDS master password."
  type        = string
  sensitive   = true
}

variable "db_name" {
  description = "Name of the initial database."
  type        = string
  default     = "appdb"
}

variable "app_db_username" {
  description = "Base username for application DB accounts (A/B: <username>_a / <username>_b)."
  type        = string
  default     = "appuser"
}

variable "app_db_initial_password" {
  description = "Initial password for the application DB account."
  type        = string
  sensitive   = true
}

variable "postgres_version" {
  description = "PostgreSQL engine version."
  type        = string
  default     = "15.4"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "multi_az" {
  description = "Enable Multi-AZ for RDS."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Enable deletion protection."
  type        = bool
  default     = false
}

variable "rotation_days" {
  description = "Days between automatic secret rotations."
  type        = number
  default     = 30
}

variable "k8s_version" {
  description = "Kubernetes version for the EKS cluster."
  type        = string
  default     = "1.29"
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS managed node group."
  type        = string
  default     = "t3.medium"
}

variable "desired_nodes" {
  description = "Desired number of EKS worker nodes."
  type        = number
  default     = 2
}

variable "external_secrets_namespace" {
  description = "Kubernetes namespace for the external-secrets operator."
  type        = string
  default     = "external-secrets"
}

variable "external_secrets_chart_version" {
  description = "Helm chart version for external-secrets."
  type        = string
  default     = "0.9.13"
}

variable "app_namespace" {
  description = "Kubernetes namespace for the application."
  type        = string
  default     = "default"
}

variable "app_image" {
  description = "Docker image URI for the application container."
  type        = string
}

variable "app_port" {
  description = "Container port."
  type        = number
  default     = 8080
}

variable "health_check_path" {
  description = "Health check HTTP path."
  type        = string
  default     = "/healthz"
}

variable "desired_replicas" {
  description = "Number of application pod replicas."
  type        = number
  default     = 2
}

variable "tags" {
  description = "Tags applied to all AWS resources."
  type        = map(string)
  default = {
    Project   = "secret-cycle"
    ManagedBy = "terraform"
  }
}
