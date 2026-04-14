variable "name_prefix" {
  description = "Prefix applied to all resource names."
  type        = string
}

variable "secret_arn" {
  description = "ARN of the Secrets Manager secret to rotate."
  type        = string
}

variable "rotation_type" {
  description = "Rotation strategy: 'ab' (A/B username soft-handoff) or 'single' (rotate password in-place)."
  type        = string
  default     = "ab"
  validation {
    condition     = contains(["ab", "single"], var.rotation_type)
    error_message = "rotation_type must be 'ab' or 'single'."
  }
}

variable "db_engine" {
  description = "Database engine: 'postgres', 'mysql', or 'mariadb'."
  type        = string
  default     = "postgres"
}

variable "master_secret_arn" {
  description = "ARN of the master credentials secret used for DDL (required for A/B rotation)."
  type        = string
  default     = null
}

variable "lambda_source_dir" {
  description = "Local path to the directory containing secret_cycle.py and requirements.txt."
  type        = string
  default     = "../../../lambda"
}

variable "lambda_timeout" {
  description = "Lambda timeout in seconds."
  type        = number
  default     = 60
}

variable "lambda_memory_mb" {
  description = "Lambda memory in MB."
  type        = number
  default     = 128
}

variable "password_length" {
  description = "Length of the generated password."
  type        = number
  default     = 32
}

variable "rotation_days" {
  description = "Number of days between automatic rotations."
  type        = number
  default     = 30
}

variable "vpc_subnet_ids" {
  description = "Subnet IDs when deploying the Lambda inside a VPC (needed to reach the database)."
  type        = list(string)
  default     = []
}

variable "vpc_security_group_ids" {
  description = "Security group IDs for the Lambda VPC configuration."
  type        = list(string)
  default     = []
}

variable "ecs_cluster_arn" {
  description = "ARN of the ECS cluster to restart after rotation (optional)."
  type        = string
  default     = null
}

variable "ecs_cluster_name" {
  description = "Name of the ECS cluster (passed to the Lambda as ECS_CLUSTER)."
  type        = string
  default     = null
}

variable "ecs_service_arn" {
  description = "ARN of the ECS service to force-redeploy after rotation (optional)."
  type        = string
  default     = null
}

variable "ecs_service_name" {
  description = "Name of the ECS service (passed to the Lambda as ECS_SERVICE)."
  type        = string
  default     = null
}

variable "k8s_namespace" {
  description = "Kubernetes namespace for rollout-restart after rotation (optional)."
  type        = string
  default     = null
}

variable "k8s_deployment" {
  description = "Kubernetes deployment name for rollout-restart after rotation (optional)."
  type        = string
  default     = null
}

variable "kubeconfig_secret_arn" {
  description = "ARN of a Secrets Manager secret containing the kubeconfig YAML (optional)."
  type        = string
  default     = null
}

variable "extra_env_vars" {
  description = "Additional environment variables to pass to the Lambda function."
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
