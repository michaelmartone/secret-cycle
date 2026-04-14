variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix applied to all resource names."
  type        = string
  default     = "secret-cycle-demo"
}

variable "db_master_username" {
  description = "Master username for the RDS instance."
  type        = string
  default     = "postgres"
}

variable "db_master_password" {
  description = "Master password for the RDS instance.  Use a secrets manager reference or tfvars."
  type        = string
  sensitive   = true
}

variable "db_name" {
  description = "Name of the initial database."
  type        = string
  default     = "appdb"
}

variable "app_db_username" {
  description = "Base username for the application database accounts.  A/B rotation creates <username>_a and <username>_b."
  type        = string
  default     = "appuser"
}

variable "app_db_initial_password" {
  description = "Initial password for the application database account (rotated immediately after first deployment)."
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
  description = "Enable Multi-AZ for the RDS instance."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Enable deletion protection on the RDS instance."
  type        = bool
  default     = false
}

variable "rotation_days" {
  description = "Number of days between automatic secret rotations."
  type        = number
  default     = 30
}

variable "app_image" {
  description = "Docker image URI for the application container."
  type        = string
}

variable "app_port" {
  description = "Container port the application listens on."
  type        = number
  default     = 8080
}

variable "health_check_path" {
  description = "ALB health check path."
  type        = string
  default     = "/healthz"
}

variable "task_cpu" {
  description = "ECS task CPU units."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "ECS task memory (MB)."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Desired number of ECS task replicas."
  type        = number
  default     = 2
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    Project     = "secret-cycle"
    ManagedBy   = "terraform"
  }
}
