variable "name_prefix" {
  description = "Prefix applied to resource names, e.g. \"gateway-dev\"."
  type        = string
}

variable "environment" {
  description = "Environment tag, e.g. \"dev\" or \"prod\"."
  type        = string
}

variable "aws_region" {
  description = "AWS region (used for the CloudWatch log driver config)."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "image" {
  description = "Full image URI (ECR repo URL + tag) to run. Placeholder on first apply -- CI overwrites it on every deploy via a new task definition revision."
  type        = string
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "listener_port" {
  type    = number
  default = 80
}

variable "task_cpu" {
  description = "Fargate task CPU units (256 = 0.25 vCPU)."
  type        = number
  default     = 512
}

variable "task_memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 1024
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "container_env" {
  description = "Environment variables passed to the gateway-api container."
  type        = map(string)
  default     = {}
}

variable "bedrock_model_ids" {
  description = "Model/inference-profile IDs the task role may invoke, matching policies/route_sets.yaml (e.g. \"us.amazon.nova-micro-v1:0\")."
  type        = list(string)
}

variable "bedrock_profile_regions" {
  description = "Regions a \"us.\"-prefixed cross-region inference profile can route to; the underlying foundation-model ARN in each must also be authorized."
  type        = list(string)
  default     = ["us-east-1", "us-east-2", "us-west-2"]
}
