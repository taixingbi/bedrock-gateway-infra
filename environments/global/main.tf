# Account-wide resources: the GitHub OIDC provider and one deploy role
# per environment. Apply this once per AWS account, before environments/
# dev or environments/prod's CI deploy jobs can authenticate -- those
# environments' own Terraform doesn't touch this (see infra/README.md
# for the required apply order).

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

module "github_oidc" {
  source = "../../modules/github_oidc"

  github_org  = var.github_org
  github_repo = var.github_repo
  aws_region  = var.aws_region

  environments = {
    dev  = { name_prefix = "gateway-dev" }
    prod = { name_prefix = "gateway-prod" }
  }
}
