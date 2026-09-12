output "alb_dns_name" {
  description = "The ALB is private -- only reachable from inside the VPC (e.g. via ECS Exec), not the internet. Use api_gateway_url for real traffic."
  value       = module.ecs_service.alb_dns_name
}

output "api_gateway_url" {
  description = "Base URL. Append /v1/chat for JWT calls, /iam/v1/chat for SigV4-signed calls."
  value       = module.api_gateway.api_endpoint
}

output "execute_api_arn_iam_route" {
  description = "Grant execute-api:Invoke on this ARN to any IAM principal that should reach /iam/*."
  value       = module.api_gateway.execute_api_arn_iam_route
}

output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "ecs_cluster_name" {
  value = module.ecs_service.cluster_name
}

output "ecs_service_name" {
  value = module.ecs_service.service_name
}
