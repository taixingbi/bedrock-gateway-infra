variable "name_prefix" {
  description = "Prefix applied to resource names, e.g. \"gateway-dev\"."
  type        = string
}

variable "environment" {
  description = "Environment tag, e.g. \"dev\" or \"prod\"."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets, one per AZ."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}
