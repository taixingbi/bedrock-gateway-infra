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

# API Gateway (the VPC Link's ENIs, and everything else under
# modules/api_gateway) moved out to the bedrock-api-gateway repo --
# see plan.md Section 25. This looks its security group up by name
# (never a cross-repo state reference) so ecs_service's ALB can allow
# it as ingress regardless of which repo created it.
data "aws_security_group" "api_gateway_vpc_link" {
  name   = "${local.name_prefix}-api-gw-vpc-link"
  vpc_id = module.network.vpc_id
}

module "ecs_service" {
  source = "../../modules/ecs_service"

  name_prefix                = local.name_prefix
  environment                = "dev"
  aws_region                 = var.aws_region
  vpc_id                     = module.network.vpc_id
  public_subnet_ids          = module.network.public_subnet_ids
  vpc_link_security_group_id = data.aws_security_group.api_gateway_vpc_link.id

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

    # M12 (plan.md Section 5): delegates AWS_IAM principal mapping to
    # authz-service instead of resolving it in-process. Plain HTTP --
    # this is an internal call between two ECS tasks in the same VPC,
    # never leaves it (module.authz_service's ALB is `internal = true`
    # and its security group only accepts traffic from this service's
    # own task SG).
    AUTHZ_SERVICE_URL = "http://${module.authz_service.alb_dns_name}"

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
    Environment = "dev"
  }
}

# One row per (request_id, timestamp) -- a request's audit history is
# always read as one ordered sequence, never looked up by event alone
# (see onboarding/audit.py).
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
    Environment = "dev"
  }
}

# Provisioned-only overlay on top of policies/tenants.yaml -- a tenant
# provisioned through onboarding lives here; an existing hand-managed
# tenant never does (see policy/store.py's LayeredPolicyStore).
resource "aws_dynamodb_table" "provisioned_tenant_policies" {
  name         = "${local.name_prefix}-provisioned-tenant-policies"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "tenant_id"

  attribute {
    name = "tenant_id"
    type = "S"
  }

  tags = {
    Environment = "dev"
  }
}

# Provisioned-only overlay on top of policies/iam_tenants.yaml -- same
# reasoning as provisioned_tenant_policies above, for the AWS_IAM/SigV4
# auth path (see auth/aws_iam.py's LayeredIamTenantResolver).
resource "aws_dynamodb_table" "provisioned_principal_mappings" {
  name         = "${local.name_prefix}-provisioned-principal-mappings"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "principal_arn"

  attribute {
    name = "principal_arn"
    type = "S"
  }

  tags = {
    Environment = "dev"
  }
}

# --- M12: Authorization Service (plan.md Section 5) -------------------

module "ecr_authz" {
  source = "../../modules/ecr"

  repository_name = "${local.name_prefix}-authz"
  environment     = "dev"
}

module "authz_service" {
  source = "../../modules/authz_service"

  name_prefix       = "${local.name_prefix}-authz"
  environment       = "dev"
  aws_region        = var.aws_region
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids

  # Only gateway-api may call this -- not API Gateway, not the
  # internet. See modules/authz_service's own comment.
  caller_security_group_id = module.ecs_service.task_security_group_id

  # No image has been pushed on a first apply -- CI registers the real
  # task definition revision on its first deploy, same as gateway-api.
  image = "${module.ecr_authz.repository_url}:bootstrap"

  provisioned_principal_mappings_table_arn = aws_dynamodb_table.provisioned_principal_mappings.arn

  container_env = {
    AWS_REGION                                = var.aws_region
    SERVICE_NAME                              = "${local.name_prefix}-authz"
    LOG_LEVEL                                 = "INFO"
    IAM_TENANTS_PATH                          = "policies/iam_tenants.yaml"
    PROVISIONED_PRINCIPAL_MAPPINGS_TABLE_NAME = aws_dynamodb_table.provisioned_principal_mappings.name
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
    # Hardcoded, not a module reference: api_gateway moved to the
    # bedrock-api-gateway repo (plan.md Section 25) -- this is that
    # repo's real, already-applied api_endpoint output. Update this if
    # that API Gateway is ever destroyed and recreated (a new one gets
    # a new endpoint).
    GATEWAY_API_URL = "https://as1n3q8d33.execute-api.us-east-1.amazonaws.com"

    COGNITO_DOMAIN        = module.cognito_idp.hosted_ui_domain
    COGNITO_CLIENT_ID     = module.cognito_idp.client_id
    COGNITO_CLIENT_SECRET = module.cognito_idp.client_secret
    COGNITO_REGION        = var.aws_region
    PORTAL_BASE_URL       = local.portal_base_url
    # Real HTTPS in front of the ALB now (module.portal_cdn) -- the
    # only path a browser can reach this portal through is CloudFront,
    # so the session cookie's Secure flag is safe to turn on.
    PORTAL_HTTPS = "true"
  }
}

# HTTPS front door -- Cognito's Hosted UI requires it (see the
# module's own comment). The ALB itself deliberately stays HTTP-only;
# only CloudFront's edge gets a certificate.
module "portal_cdn" {
  source = "../../modules/portal_cdn"

  name_prefix        = "${local.name_prefix}-portal"
  environment        = "dev"
  origin_domain_name = module.portal_service.alb_dns_name
}

# --- Human identity (Cognito) for the portal ------------------------------
#
# local.portal_base_url is a plain string, not module.portal_cdn's
# domain_name output, deliberately: cognito_idp's callback_url needs
# the portal's URL, and portal_service's container_env (above) needs
# cognito_idp's client_id/secret -- referencing each other's *module*
# outputs both ways is a genuine Terraform cycle. module.portal_cdn's
# domain is now created and stable (CloudFront distribution domains
# are assigned once, at creation, confirmed live as
# d3ofy46m4rhywg.cloudfront.net) -- so this hardcodes today's
# already-real value rather than re-deriving it circularly. Update
# this if the portal's CloudFront distribution is ever destroyed and
# recreated (a new one gets a new domain).
locals {
  portal_base_url = "https://d3ofy46m4rhywg.cloudfront.net"
}

module "cognito_idp" {
  source = "../../modules/cognito_idp"

  name_prefix  = local.name_prefix
  aws_region   = var.aws_region
  callback_url = "${local.portal_base_url}/api/auth/callback"
  logout_url   = "${local.portal_base_url}/login"
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
