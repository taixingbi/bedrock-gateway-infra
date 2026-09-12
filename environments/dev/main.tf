terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  name_prefix = "gateway-dev"
}

module "network" {
  source = "../../modules/network"

  name_prefix = local.name_prefix
  environment = "dev"
}

module "ecr" {
  source = "../../modules/ecr"

  repository_name = local.name_prefix
  environment     = "dev"
}

# Shared by ecs_service (the ALB's only allowed ingress) and api_gateway
# (the VPC Link's ENIs) -- created at the root to avoid a circular
# module dependency: ecs_service needs this SG id, api_gateway needs
# ecs_service's alb_listener_arn.
resource "aws_security_group" "vpc_link" {
  name        = "${local.name_prefix}-vpc-link"
  description = "API Gateway VPC Link ENIs -- egress only, reaches the private ALB"
  vpc_id      = module.network.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Environment = "dev"
  }
}

module "ecs_service" {
  source = "../../modules/ecs_service"

  name_prefix                = local.name_prefix
  environment                = "dev"
  aws_region                 = var.aws_region
  vpc_id                     = module.network.vpc_id
  public_subnet_ids          = module.network.public_subnet_ids
  vpc_link_security_group_id = aws_security_group.vpc_link.id

  # No image has been pushed on a first apply -- CI registers the real
  # task definition revision on its first deploy (see infra/README.md).
  # The service will show 0 running tasks until then; expected.
  image = "${module.ecr.repository_url}:bootstrap"

  desired_count          = var.desired_count
  task_cpu               = var.task_cpu
  task_memory            = var.task_memory
  enable_execute_command = true

  bedrock_model_ids = var.bedrock_model_ids

  container_env = {
    AWS_REGION            = var.aws_region
    BEDROCK_MODEL_ID      = var.bedrock_model_ids[0]
    GATEWAY_HOST          = "0.0.0.0"
    GATEWAY_PORT          = "8080"
    SERVICE_NAME          = local.name_prefix
    LOG_LEVEL             = "INFO"
    ROUTE_SET_CONFIG_PATH = "policies/route_sets.yaml"
    TENANT_POLICY_PATH    = "policies/tenants.yaml"
    IAM_TENANTS_PATH      = "policies/iam_tenants.yaml"
  }
}

module "api_gateway" {
  source = "../../modules/api_gateway"

  name_prefix                = local.name_prefix
  alb_listener_arn           = module.ecs_service.alb_listener_arn
  vpc_link_subnet_ids        = module.network.public_subnet_ids
  vpc_link_security_group_id = aws_security_group.vpc_link.id
}
