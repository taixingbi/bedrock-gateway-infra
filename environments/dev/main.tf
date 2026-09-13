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

    # Human auth (Cognito, via the portal) -- separate from the
    # AWS_IAM/SigV4 path service/application callers already use
    # (auth/aws_iam.py), which needs nothing here. Falls back to the
    # dev JWT keypair (config.py) if OIDC_JWKS_URL is ever unset.
    OIDC_JWKS_URL = "${module.cognito_idp.user_pool_endpoint}/.well-known/jwks.json"
    OIDC_ISSUER   = module.cognito_idp.user_pool_endpoint
    OIDC_AUDIENCE = module.cognito_idp.client_id
  }
}

# --- M7: async jobs -----------------------------------------------------

resource "aws_sqs_queue" "jobs_dlq" {
  name                      = "${local.name_prefix}-jobs-dlq"
  message_retention_seconds = 1209600 # 14 days

  tags = {
    Environment = "dev"
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
    Environment = "dev"
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
    Environment = "dev"
  }
}

# --- M8: FinOps -----------------------------------------------------------

# One row per (tenant_id, month) -- a new month is just a new row, no
# reset job needed. month is "YYYY-MM" UTC (see usage/store.py).
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
    Environment = "dev"
  }
}

module "worker_service" {
  source = "../../modules/worker_service"

  name_prefix       = "${local.name_prefix}-worker"
  environment       = "dev"
  aws_region        = var.aws_region
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  cluster_name      = module.ecs_service.cluster_name

  # Same image as gateway-api -- same codebase, different command. CI's
  # deploy-dev job updates this task definition alongside gateway-api's
  # on every push, both pointing at the one image it just built.
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
  environment     = "dev"
}

module "portal_service" {
  source = "../../modules/portal_service"

  name_prefix       = "${local.name_prefix}-portal"
  environment       = "dev"
  aws_region        = var.aws_region
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids

  # No image has been pushed on a first apply -- CI registers the real
  # task definition revision on its first deploy, same as gateway-api.
  image = "${module.ecr_portal.repository_url}:bootstrap"

  container_env = {
    # The portal's admin bearer-token auth goes over the open JWT
    # route -- not /iam/*, that one's for SigV4-signing machine callers.
    GATEWAY_API_URL = module.api_gateway.api_endpoint

    COGNITO_DOMAIN        = module.cognito_idp.hosted_ui_domain
    COGNITO_CLIENT_ID     = module.cognito_idp.client_id
    COGNITO_CLIENT_SECRET = module.cognito_idp.client_secret
    COGNITO_REGION        = var.aws_region
    PORTAL_BASE_URL       = local.portal_base_url
  }
}

# HTTPS front door -- Cognito's Hosted UI requires it (see the
# module's own comment). The ALB itself deliberately stays HTTP-only;
# only CloudFront's edge gets a certificate.
#
# Deliberately not yet wired into local.portal_base_url or
# module.cognito_idp's callback/logout URLs below: this distribution's
# domain_name isn't known until it's actually created (unlike the
# ALB's, which already existed before this Cognito work started --
# see the comment on local.portal_base_url). Land this module first,
# apply, then hardcode the real *.cloudfront.net domain the same way,
# and flip PORTAL_HTTPS to "true".
module "portal_cdn" {
  source = "../../modules/portal_cdn"

  name_prefix        = "${local.name_prefix}-portal"
  environment        = "dev"
  origin_domain_name = module.portal_service.alb_dns_name
}

# --- Human identity (Cognito) for the portal ------------------------------
#
# local.portal_base_url is a plain string, not module.portal_service's
# alb_dns_name output, deliberately: cognito_idp's callback_url needs
# the portal's URL, and portal_service's container_env (above) needs
# cognito_idp's client_id/secret -- referencing each other's *module*
# outputs both ways is a genuine Terraform cycle. The ALB's DNS name
# already exists and is stable (AWS assigns it once, at creation, and
# it doesn't change on later applies) -- so this hardcodes today's
# already-real value rather than re-deriving it circularly. Update this
# if the portal's ALB is ever destroyed and recreated (a new one gets a
# new DNS name).
locals {
  portal_base_url = "http://gateway-dev-portal-alb-1557235843.us-east-1.elb.amazonaws.com"
}

module "cognito_idp" {
  source = "../../modules/cognito_idp"

  name_prefix = local.name_prefix
  aws_region  = var.aws_region

  # TEMPORARY placeholders, not local.portal_base_url -- Cognito
  # rejects any non-https callback/logout URL except http://localhost
  # (confirmed live), and local.portal_base_url is still the plain-
  # HTTP ALB URL until module.portal_cdn's real domain is known (see
  # its comment above). Swap these for the real
  # https://<distribution>.cloudfront.net URLs in the very next
  # commit, once this apply creates the distribution and its domain
  # is known. Until then the Hosted UI login flow doesn't work end to
  # end, but every other resource here can still apply cleanly.
  callback_url = "http://localhost/api/auth/callback"
  logout_url   = "http://localhost/login"
}

# The one admin user this session actually needs -- Cognito emails a
# temporary password on creation (its built-in low-volume sender, no
# SES setup required); Hosted UI forces a password change on first
# login. Add more aws_cognito_user blocks (and matching
# aws_cognito_user_in_group ones) for additional admins.
resource "aws_cognito_user" "admin" {
  user_pool_id = module.cognito_idp.user_pool_id
  username     = "bitaihang@gmail.com"

  attributes = {
    email                   = "bitaihang@gmail.com"
    email_verified          = "true"
    "custom:tenant_id"      = "platform"
    "custom:application_id" = "portal"
  }

  desired_delivery_mediums = ["EMAIL"]
}

resource "aws_cognito_user_in_group" "admin_is_platform_admin" {
  user_pool_id = module.cognito_idp.user_pool_id
  username     = aws_cognito_user.admin.username
  group_name   = module.cognito_idp.platform_admin_group_name
}
