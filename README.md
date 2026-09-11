# infra/ (placeholder)

Terraform for VPC, ALB, WAF, ECS, ECR, IAM/STS, KMS, Secrets Manager,
DynamoDB, Redis, SQS, S3, CloudWatch, Bedrock VPC endpoints (section 22 of
the plan) belongs here, organized as `modules/` + `environments/{dev,stage,prod}`.

Not built yet — M0 is application code only, run locally or via the
`Dockerfile` at the repo root. Add this once M1/M2 need real AWS
infrastructure (OIDC provider, DynamoDB for tenant policy, etc.).
