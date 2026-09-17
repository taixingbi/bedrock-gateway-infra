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

# API Gateway (the VPC Link's ENIs, and everything else under
# modules/api_gateway) moved out to the platform-api-gateway repo --
# see plan.md Section 25. This looks its security group up by name
# (never a cross-repo state reference) so ecs_service's ALB can allow
# it as ingress regardless of which repo created it. Not yet real for
# prod -- platform-api-gateway's own environments/prod hasn't been
# applied yet (prod is held, same standing pattern as everything
# else); this data source will fail to resolve until it has been.
data "aws_security_group" "api_gateway_vpc_link" {
  name   = "${local.name_prefix}-api-gw-vpc-link"
  vpc_id = module.network.vpc_id
}

module "ecs_service" {
  source = "../../modules/ecs_service"

  name_prefix                = local.name_prefix
  environment                = "prod"
  aws_region                 = var.aws_region
  vpc_id                     = module.network.vpc_id
  public_subnet_ids          = module.network.public_subnet_ids
  vpc_link_security_group_id = data.aws_security_group.api_gateway_vpc_link.id
  log_group_name             = "/ai-platform/ecs/bedrock-gateway-prod"

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

  onboarding_requests_table_arn            = aws_dynamodb_table.onboarding_requests.arn
  onboarding_audit_table_arn               = aws_dynamodb_table.onboarding_audit.arn
  provisioned_tenant_policies_table_arn    = aws_dynamodb_table.provisioned_tenant_policies.arn
  provisioned_principal_mappings_table_arn = aws_dynamodb_table.provisioned_principal_mappings.arn

  container_env = {
    AWS_REGION            = var.aws_region
    BEDROCK_MODEL_ID      = var.bedrock_model_ids[0]
    GATEWAY_HOST          = "0.0.0.0"
    GATEWAY_PORT          = "8080"
    SERVICE_NAME          = local.name_prefix
    ENVIRONMENT           = "prod"
    LOG_LEVEL             = "INFO"
    ROUTE_SET_CONFIG_PATH = "policies/route_sets.yaml"
    TENANT_POLICY_PATH    = "policies/tenants.yaml"
    IAM_TENANTS_PATH      = "policies/iam_tenants.yaml"
    JOBS_QUEUE_URL        = aws_sqs_queue.jobs.url
    JOBS_TABLE_NAME       = aws_dynamodb_table.jobs.name
    USAGE_TABLE_NAME      = aws_dynamodb_table.usage.name

    ONBOARDING_REQUESTS_TABLE_NAME            = aws_dynamodb_table.onboarding_requests.name
    ONBOARDING_AUDIT_TABLE_NAME               = aws_dynamodb_table.onboarding_audit.name
    PROVISIONED_TENANT_POLICIES_TABLE_NAME    = aws_dynamodb_table.provisioned_tenant_policies.name
    PROVISIONED_PRINCIPAL_MAPPINGS_TABLE_NAME = aws_dynamodb_table.provisioned_principal_mappings.name
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

# --- M11: Application Onboarding (plan section 22) -------------------------

resource "aws_dynamodb_table" "onboarding_requests" {
  name         = "${local.name_prefix}-onboarding-requests"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "request_id"

  attribute {
    name = "request_id"
    type = "S"
  }

  tags = {
    Environment = "prod"
  }
}

resource "aws_dynamodb_table" "onboarding_audit" {
  name         = "${local.name_prefix}-onboarding-audit"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "request_id"
  range_key    = "timestamp"

  attribute {
    name = "request_id"
    type = "S"
  }
  attribute {
    name = "timestamp"
    type = "N"
  }

  tags = {
    Environment = "prod"
  }
}

resource "aws_dynamodb_table" "provisioned_tenant_policies" {
  name         = "${local.name_prefix}-provisioned-tenant-policies"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "tenant_id"

  attribute {
    name = "tenant_id"
    type = "S"
  }

  tags = {
    Environment = "prod"
  }
}

resource "aws_dynamodb_table" "provisioned_principal_mappings" {
  name         = "${local.name_prefix}-provisioned-principal-mappings"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "principal_arn"

  attribute {
    name = "principal_arn"
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
  log_group_name    = "/ai-platform/ecs/bedrock-gateway-worker-prod"

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
    SERVICE               = "bedrock-gateway-worker"
    ENVIRONMENT           = "prod"
    LOG_LEVEL             = "INFO"
    ROUTE_SET_CONFIG_PATH = "policies/route_sets.yaml"
    TENANT_POLICY_PATH    = "policies/tenants.yaml"
    IAM_TENANTS_PATH      = "policies/iam_tenants.yaml"
    JOBS_QUEUE_URL        = aws_sqs_queue.jobs.url
    JOBS_TABLE_NAME       = aws_dynamodb_table.jobs.name
    USAGE_TABLE_NAME      = aws_dynamodb_table.usage.name
  }
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
  log_group_name    = "/ai-platform/ecs/bedrock-gateway-portal-prod"

  image = "${module.ecr_portal.repository_url}:bootstrap"

  container_env = {
    # Placeholder -- platform-api-gateway's environments/prod hasn't
    # been applied yet (prod is held). Replace with its real
    # api_endpoint output once it has, same as environments/dev/main.tf
    # already does.
    GATEWAY_API_URL = "https://not-yet-applied.invalid"
  }
}
