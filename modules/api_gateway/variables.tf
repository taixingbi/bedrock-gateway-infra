variable "name_prefix" {
  description = "Prefix applied to resource names, e.g. \"gateway-dev\"."
  type        = string
}

variable "alb_listener_arn" {
  description = "The private ALB listener to integrate with (modules/ecs_service's alb_listener_arn output)."
  type        = string
}

variable "vpc_link_subnet_ids" {
  description = "Subnets for the VPC Link's ENIs. Can be the same public subnets the ALB/ECS tasks use -- the VPC Link itself needs no internet route, only a path to the ALB."
  type        = list(string)
}

variable "vpc_link_security_group_id" {
  description = "Security group attached to the VPC Link's ENIs; must be allowed as ingress on the ALB's security group."
  type        = string
}

variable "principal_arn_header" {
  description = "Header the IAM route overwrites with the verified caller ARN, and the open route strips. Must match services/gateway/auth/aws_iam.py's HEADER_PRINCIPAL_ARN."
  type        = string
  default     = "x-platform-principal-arn"
}

variable "account_id_header" {
  description = "Header the IAM route overwrites with the verified caller's account ID, and the open route strips. Must match services/gateway/auth/aws_iam.py's HEADER_ACCOUNT_ID."
  type        = string
  default     = "x-platform-account-id"
}
