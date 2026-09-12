variable "github_org" {
  description = "GitHub organization/user that owns the repo, e.g. \"taixingbi\"."
  type        = string
}

variable "github_repo" {
  description = "Repository name, e.g. \"bedrock-gateway-platform\"."
  type        = string
}

variable "aws_region" {
  type = string
}

variable "create_oidc_provider" {
  description = "Whether to create the account-wide GitHub OIDC provider. Leave true unless one already exists in this account (the resource is a singleton -- a second `aws_iam_openid_connect_provider` for the same URL will fail to create)."
  type        = bool
  default     = true
}

variable "environments" {
  description = "Map of GitHub Environment name (repo Settings -> Environments, e.g. \"dev\"/\"prod\") to the name_prefix used by that environment's ecs_service module, e.g. { dev = { name_prefix = \"gateway-dev\" } }."
  type = map(object({
    name_prefix = string
  }))
}
