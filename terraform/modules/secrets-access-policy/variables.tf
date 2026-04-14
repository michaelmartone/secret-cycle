variable "name_prefix" {
  description = "Prefix used for the IAM policy name."
  type        = string
}

variable "secret_arns" {
  description = "List of Secrets Manager secret ARNs the policy should allow reading."
  type        = list(string)
}

variable "kms_key_arns" {
  description = "Optional KMS key ARNs used to encrypt the secrets (required for CMK-encrypted secrets)."
  type        = list(string)
  default     = []
}

variable "iam_role_names" {
  description = "IAM role names to attach the policy to (e.g. ECS task execution role, EKS node role)."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to the IAM policy."
  type        = map(string)
  default     = {}
}
