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
  name_prefix = "gateway-prod"
}

module "network" {
  source = "../../modules/network"

  name_prefix = local.name_prefix
  environment = "prod"
}

module "ecr" {
  source = "../../modules/ecr"

  repository_name = local.name_prefix
  environment     = "prod"
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
    Environment = "prod"
  }
}

module "ecs_service" {
  source = "../../modules/ecs_service"

  name_prefix                = local.name_prefix
  environment                = "prod"
  aws_region                 = var.aws_region
  vpc_id                     = module.network.vpc_id
  public_subnet_ids          = module.network.public_subnet_ids
  vpc_link_security_group_id = aws_security_group.vpc_link.id

  # No image has been pushed on a first apply -- CI registers the real
  # task definition revision on its first deploy (see infra/README.md).
  # The service will show 0 running tasks until then; expected.
  image = "${module.ecr.repository_url}:bootstrap"

  desired_count = var.desired_count
  task_cpu      = var.task_cpu
  task_memory   = var.task_memory

  bedrock_model_ids = var.bedrock_model_ids

  jobs_queue_arn  = aws_sqs_queue.jobs.arn
  jobs_table_arn  = aws_dynamodb_table.jobs.arn
  usage_table_arn = aws_dynamodb_table.usage.arn

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
    JOBS_QUEUE_URL        = aws_sqs_queue.jobs.url
    JOBS_TABLE_NAME       = aws_dynamodb_table.jobs.name
    USAGE_TABLE_NAME      = aws_dynamodb_table.usage.name
  }
}

# --- M7: async jobs -----------------------------------------------------

resource "aws_sqs_queue" "jobs_dlq" {
  name                      = "${local.name_prefix}-jobs-dlq"
  message_retention_seconds = 1209600 # 14 days

  tags = {
    Environment = "prod"
  }
}

resource "aws_sqs_queue" "jobs" {
  name                       = "${local.name_prefix}-jobs"
  visibility_timeout_seconds = 60 # must exceed the worker's expected per-job processing time

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jobs_dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Environment = "prod"
  }
}

resource "aws_dynamodb_table" "jobs" {
  name         = "${local.name_prefix}-jobs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "job_id"

  attribute {
    name = "job_id"
    type = "S"
  }

  tags = {
    Environment = "prod"
  }
}

# --- M8: FinOps -----------------------------------------------------------

resource "aws_dynamodb_table" "usage" {
  name         = "${local.name_prefix}-usage"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "tenant_id"
  range_key    = "month"

  attribute {
    name = "tenant_id"
    type = "S"
  }
  attribute {
    name = "month"
    type = "S"
  }

  tags = {
    Environment = "prod"
  }
}

module "worker_service" {
  source = "../../modules/worker_service"

  name_prefix       = "${local.name_prefix}-worker"
  environment       = "prod"
  aws_region        = var.aws_region
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  cluster_name      = module.ecs_service.cluster_name

  # Same image as gateway-api -- same codebase, different command.
  image   = "${module.ecr.repository_url}:bootstrap"
  command = ["python", "-m", "services.worker.main"]

  desired_count = 1
  task_cpu      = var.task_cpu
  task_memory   = var.task_memory

  bedrock_model_ids  = var.bedrock_model_ids
  sqs_queue_arn      = aws_sqs_queue.jobs.arn
  dynamodb_table_arn = aws_dynamodb_table.jobs.arn
  usage_table_arn    = aws_dynamodb_table.usage.arn

  container_env = {
    AWS_REGION            = var.aws_region
    BEDROCK_MODEL_ID      = var.bedrock_model_ids[0]
    SERVICE_NAME          = "${local.name_prefix}-worker"
    LOG_LEVEL             = "INFO"
    ROUTE_SET_CONFIG_PATH = "policies/route_sets.yaml"
    TENANT_POLICY_PATH    = "policies/tenants.yaml"
    IAM_TENANTS_PATH      = "policies/iam_tenants.yaml"
    JOBS_QUEUE_URL        = aws_sqs_queue.jobs.url
    JOBS_TABLE_NAME       = aws_dynamodb_table.jobs.name
    USAGE_TABLE_NAME      = aws_dynamodb_table.usage.name
  }
}

module "api_gateway" {
  source = "../../modules/api_gateway"

  name_prefix                = local.name_prefix
  alb_listener_arn           = module.ecs_service.alb_listener_arn
  vpc_link_subnet_ids        = module.network.public_subnet_ids
  vpc_link_security_group_id = aws_security_group.vpc_link.id
}

# --- M10: self-service portal ---------------------------------------------

module "ecr_portal" {
  source = "../../modules/ecr"

  repository_name = "${local.name_prefix}-portal"
  environment     = "prod"
}

module "portal_service" {
  source = "../../modules/portal_service"

  name_prefix       = "${local.name_prefix}-portal"
  environment       = "prod"
  aws_region        = var.aws_region
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids

  image = "${module.ecr_portal.repository_url}:bootstrap"

  container_env = {
    GATEWAY_API_URL = module.api_gateway.api_endpoint
  }
}
