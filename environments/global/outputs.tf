output "deploy_role_arns" {
  description = "Set these as AWS_DEPLOY_ROLE_ARN_DEV / AWS_DEPLOY_ROLE_ARN_PROD in GitHub Actions repo variables."
  value       = module.github_oidc.role_arns
}
