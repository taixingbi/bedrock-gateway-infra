# Account-wide resources: the GitHub OIDC provider (created once, here)
# and every OIDC role across all three split repos -- this repo owns
# IAM/OIDC for the whole platform, even though the app and policies
# repos' own CI is what actually assumes these roles. Apply this once
# per AWS account, before any of the three repos' CI can authenticate
# (see README.md for the required apply order, including the
# chicken-and-egg first-ever apply of this repo's own infra-apply role).

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

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  app_repo      = "bedrock-gateway-app"
  infra_repo    = "bedrock-gateway-infra"
  policies_repo = "bedrock-gateway-policies"
  portal_repo   = "bedrock-gateway-portal"
}

# --- App repo: push to ECR, deploy to ECS. Same shape this account
# already ran (and verified end to end) as the combined repo's
# "gha-deploy-{dev,prod}" roles, just renamed/re-scoped to the app
# repo's own OIDC trust. ---------------------------------------------

data "aws_iam_policy_document" "app_deploy" {
  for_each = { dev = "gateway-dev", prod = "gateway-prod" }

  statement {
    sid = "PushToEcr"
    actions = [
      "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage", "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
    ]
    resources = ["arn:aws:ecr:${var.aws_region}:${local.account_id}:repository/${each.value}*"]
  }

  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid       = "DeployToEcs"
    actions   = ["ecs:DescribeServices", "ecs:UpdateService"]
    resources = ["*"]
    condition {
      test     = "ArnLike"
      variable = "ecs:cluster"
      values   = ["arn:aws:ecs:${var.aws_region}:${local.account_id}:cluster/${each.value}*"]
    }
  }

  # Not cluster-scoped (task definitions are cluster-independent), so
  # the ecs:cluster condition above can't apply to these two.
  statement {
    sid       = "RegisterTaskDefinition"
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"]
    resources = ["*"]
  }

  statement {
    sid     = "PassEcsRoles"
    actions = ["iam:PassRole"]
    resources = [
      "arn:aws:iam::${local.account_id}:role/${each.value}*-execution",
      "arn:aws:iam::${local.account_id}:role/${each.value}*-task",
    ]
  }
}

module "github_oidc_app" {
  source = "../../modules/github_oidc"

  # The account-wide OIDC provider already exists (created by the
  # original bedrock-gateway-platform repo's environments/global apply,
  # before the app/infra/policies split) -- every call here references
  # it via data source rather than trying to create a second one for
  # the same URL, which AWS rejects as a duplicate.
  create_oidc_provider = false
  github_org           = var.github_org
  github_repo          = local.app_repo

  roles = {
    dev = {
      role_name   = "gha-app-deploy-dev"
      policy_json = data.aws_iam_policy_document.app_deploy["dev"].json
    }
    prod = {
      role_name   = "gha-app-deploy-prod"
      policy_json = data.aws_iam_policy_document.app_deploy["prod"].json
    }
  }
}

# --- Portal repo (M10): same shape as app_deploy above, minus
# PassRole -- portal_service has no task IAM role at all (the portal
# never calls an AWS API directly, only the gateway's own HTTP admin
# API), so there's no task role ARN to pass. ---------------------------

data "aws_iam_policy_document" "portal_deploy" {
  for_each = { dev = "gateway-dev-portal", prod = "gateway-prod-portal" }

  statement {
    sid = "PushToEcr"
    actions = [
      "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage", "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
    ]
    resources = ["arn:aws:ecr:${var.aws_region}:${local.account_id}:repository/${each.value}*"]
  }

  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid       = "DeployToEcs"
    actions   = ["ecs:DescribeServices", "ecs:UpdateService"]
    resources = ["*"]
    condition {
      test     = "ArnLike"
      variable = "ecs:cluster"
      values   = ["arn:aws:ecs:${var.aws_region}:${local.account_id}:cluster/${each.value}*"]
    }
  }

  statement {
    sid       = "RegisterTaskDefinition"
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"]
    resources = ["*"]
  }

  statement {
    sid       = "PassExecutionRole"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${each.value}*-execution"]
  }
}

module "github_oidc_portal" {
  source = "../../modules/github_oidc"

  create_oidc_provider = false
  github_org           = var.github_org
  github_repo          = local.portal_repo

  roles = {
    dev = {
      role_name   = "gha-portal-deploy-dev"
      policy_json = data.aws_iam_policy_document.portal_deploy["dev"].json
    }
    prod = {
      role_name   = "gha-portal-deploy-prod"
      policy_json = data.aws_iam_policy_document.portal_deploy["prod"].json
    }
  }
}

# --- This repo (infra): Terraform plan (read-only, safe on every PR)
# and apply (read-write, merge-only). Most of the services this repo's
# Terraform manages (EC2/VPC, ELBv2, ECS, ECR, API Gateway v2) don't
# support resource-level IAM scoping on their creation actions -- a
# vpc/subnet/security-group/ALB/etc. ARN doesn't exist until after
# it's created, so IAM can't restrict *which* one a CreateX call is
# allowed to make. Broad service-level grants (Resource "*") for those
# is standard practice for a Terraform CI role, not an oversight; IAM
# role management and the Terraform state backend *do* support real
# resource scoping, so those are scoped by name below. Tighten further
# once you've seen exactly what `apply` actually calls in practice. ---

data "aws_iam_policy_document" "infra_plan" {
  statement {
    sid = "ReadOnly"
    actions = [
      "ec2:Describe*",
      "elasticloadbalancing:Describe*",
      "ecs:Describe*", "ecs:List*",
      "ecr:Describe*", "ecr:List*", "ecr:GetLifecyclePolicy",
      "apigateway:GET",
      "logs:Describe*", "logs:List*",
      "iam:Get*", "iam:List*",
      "sts:GetCallerIdentity",
      # Describe*, not just DescribeTable: refreshing an
      # aws_dynamodb_table's full state also calls
      # DescribeContinuousBackups (PITR), DescribeTimeToLive, etc --
      # same "Describe*" wildcard already used for every other service
      # in this statement, for the same reason.
      "dynamodb:GetItem", "dynamodb:Describe*", "dynamodb:ListTagsOfResource",
      "sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:ListQueues", "sqs:ListQueueTags",
      "s3:GetObject", "s3:ListBucket",
    ]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "infra_apply" {
  statement {
    sid       = "Ec2Broad"
    actions   = ["ec2:*"]
    resources = ["*"]
  }
  statement {
    sid       = "ElbBroad"
    actions   = ["elasticloadbalancing:*"]
    resources = ["*"]
  }
  statement {
    sid       = "EcsBroad"
    actions   = ["ecs:*"]
    resources = ["*"]
  }
  statement {
    sid       = "EcrBroad"
    actions   = ["ecr:*"]
    resources = ["*"]
  }
  statement {
    sid       = "ApiGatewayBroad"
    actions   = ["apigateway:*"]
    resources = ["*"]
  }
  statement {
    sid       = "LogsBroad"
    actions   = ["logs:*"]
    resources = ["*"]
  }
  # M7: SQS/DynamoDB resource ARNs (queue URL, table name) don't exist
  # until creation, same reasoning as every other broad grant above --
  # not scopable ahead of time.
  statement {
    sid       = "SqsBroad"
    actions   = ["sqs:*"]
    resources = ["*"]
  }
  statement {
    sid       = "DynamoDbBroad"
    actions   = ["dynamodb:*"]
    resources = ["*"]
  }

  # IAM role names ARE predictable ahead of time (unlike VPC/ALB/etc.
  # IDs), so this one can actually be scoped by name.
  statement {
    sid = "ManageGatewayAndOidcRoles"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies", "iam:TagRole", "iam:UntagRole", "iam:PassRole",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/gateway-*",
      "arn:aws:iam::${local.account_id}:role/gha-*",
    ]
  }
  statement {
    sid = "ManageOidcProvider"
    actions = [
      "iam:CreateOpenIDConnectProvider", "iam:GetOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint", "iam:TagOpenIDConnectProvider",
      "iam:ListOpenIDConnectProviders", "iam:DeleteOpenIDConnectProvider",
    ]
    # The provider resource's ARN is account+host, not name-based --
    # nothing narrower to scope this to.
    resources = ["*"]
  }
  statement {
    sid       = "TerraformStateDynamoDbLock"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:DescribeTable"]
    resources = ["arn:aws:dynamodb:*:${local.account_id}:table/*tfstate*"]
  }
  statement {
    sid       = "TerraformStateS3"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::*tfstate*", "arn:aws:s3:::*tfstate*/*"]
  }
}

module "github_oidc_infra" {
  source = "../../modules/github_oidc"

  create_oidc_provider = false # references the existing account-wide provider, same as above
  github_org           = var.github_org
  github_repo          = local.infra_repo

  roles = {
    plan = {
      role_name   = "gha-infra-plan"
      policy_json = data.aws_iam_policy_document.infra_plan.json
    }
    # Split dev/prod so the OIDC trust condition itself enforces the
    # separation, not just the GitHub Environment's approval UI: a job
    # whose sub claim says "environment:apply-dev" cannot assume
    # gha-infra-apply-prod's role even if someone edited the workflow
    # to skip the required-reviewer gate. Same policy document for both
    # for now (TODO: scope prod's role tighter than dev's once there's
    # something concrete to restrict it to).
    apply-dev = {
      role_name   = "gha-infra-apply-dev"
      policy_json = data.aws_iam_policy_document.infra_apply.json
    }
    apply-prod = {
      role_name   = "gha-infra-apply-prod"
      policy_json = data.aws_iam_policy_document.infra_apply.json
    }
  }
}

# --- Policies repo: write-only to wherever policy delivery ends up.
# Phase 1 (interim, current) has nothing for this role to actually do --
# delivery is a manual copy into the app repo, not an automated publish.
# Scoped ahead of time to phase 2's planned DynamoDB table name so the
# trust relationship/role identity already exists; inert until that
# table does. -----------------------------------------------------------

data "aws_iam_policy_document" "policy_publish" {
  statement {
    sid       = "PublishToPolicyTable"
    actions   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DescribeTable"]
    resources = ["arn:aws:dynamodb:${var.aws_region}:${local.account_id}:table/gateway-policies"]
  }
}

module "github_oidc_policies" {
  source = "../../modules/github_oidc"

  create_oidc_provider = false
  github_org           = var.github_org
  github_repo          = local.policies_repo

  roles = {
    publish = {
      role_name   = "gha-policy-publish"
      policy_json = data.aws_iam_policy_document.policy_publish.json
    }
  }

  depends_on = [module.github_oidc_app]
}
