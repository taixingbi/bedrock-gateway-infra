# One IAM role per environment, each assumable only by a GitHub Actions
# workflow run scoped to that GitHub Environment (repo Settings ->
# Environments) -- e.g. a job with `environment: prod` can assume the
# prod role, a job with `environment: dev` cannot. This is what lets
# GitHub's environment protection rules (required reviewers, etc.) gate
# a real AWS credential, not just a workflow label.
#
# The OIDC provider itself is an account-wide singleton (thumbprint
# fixed by GitHub), so it's created once here in environments/global,
# never in environments/dev or environments/prod.

data "aws_caller_identity" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # GitHub's OIDC intermediate CA thumbprint. AWS validates the full
  # chain itself now, but the field is still required at creation time.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
  account_id        = data.aws_caller_identity.current.account_id
}

data "aws_iam_policy_document" "assume" {
  for_each = var.environments

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringLike (not StringEquals): GitHub's newer OIDC tokens append
    # immutable owner/repo IDs to the sub claim --
    # "repo:org@123/repo@456:environment:X" instead of the classic
    # "repo:org/repo:environment:X" -- and which format a given repo
    # gets isn't something this module controls. Match both forms, with
    # the wildcard only after an explicit "@" so this can't accidentally
    # match an unrelated org/repo sharing the same name prefix.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_org}/${var.github_repo}:environment:${each.key}",
        "repo:${var.github_org}@*/${var.github_repo}@*:environment:${each.key}",
      ]
    }
  }
}

resource "aws_iam_role" "deploy" {
  for_each = var.environments

  name               = "gha-deploy-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.assume[each.key].json
}

# Scoped by naming convention (name_prefix = "gateway-<env>") rather
# than exact ARNs from the dev/prod Terraform state, so this module
# never has to read that state -- keep environments/dev and
# environments/prod's name_prefix in sync with this pattern.
data "aws_iam_policy_document" "deploy" {
  for_each = var.environments

  statement {
    sid = "PushToEcr"
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = ["arn:aws:ecr:${var.aws_region}:${local.account_id}:repository/${each.value.name_prefix}*"]
  }

  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "DeployToEcs"
    actions = [
      "ecs:DescribeServices",
      "ecs:UpdateService",
    ]
    resources = ["*"]
    condition {
      test     = "ArnLike"
      variable = "ecs:cluster"
      values   = ["arn:aws:ecs:${var.aws_region}:${local.account_id}:cluster/${each.value.name_prefix}*"]
    }
  }

  # RegisterTaskDefinition and DescribeTaskDefinition aren't scoped to
  # a cluster (task definitions are cluster-independent), so the
  # ecs:cluster condition above can't apply to them.
  statement {
    sid       = "RegisterTaskDefinition"
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"]
    resources = ["*"]
  }

  statement {
    sid     = "PassEcsRoles"
    actions = ["iam:PassRole"]
    resources = [
      "arn:aws:iam::${local.account_id}:role/${each.value.name_prefix}*-execution",
      "arn:aws:iam::${local.account_id}:role/${each.value.name_prefix}*-task",
    ]
  }
}

resource "aws_iam_role_policy" "deploy" {
  for_each = var.environments

  name   = "gha-deploy-${each.key}"
  role   = aws_iam_role.deploy[each.key].id
  policy = data.aws_iam_policy_document.deploy[each.key].json
}
