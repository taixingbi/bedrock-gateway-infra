output "app_deploy_role_arns" {
  description = "Set as AWS_APP_DEPLOY_ROLE_ARN_DEV / _PROD in bedrock-gateway-app's GitHub Environment variables."
  value       = module.github_oidc_app.role_arns
}

output "infra_role_arns" {
  description = "Set as AWS_INFRA_PLAN_ROLE_ARN / AWS_INFRA_APPLY_ROLE_ARN in bedrock-gateway-infra's (this repo's) own GitHub Environment variables."
  value       = module.github_oidc_infra.role_arns
}

output "policy_publish_role_arn" {
  description = "Set as AWS_POLICY_PUBLISH_ROLE_ARN in bedrock-gateway-policies's GitHub Environment variables."
  value       = module.github_oidc_policies.role_arns["publish"]
}

output "portal_deploy_role_arns" {
  description = "Set as AWS_PORTAL_DEPLOY_ROLE_ARN_DEV / _PROD in bedrock-gateway-portal's GitHub Environment variables."
  value       = module.github_oidc_portal.role_arns
}
