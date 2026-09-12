# bedrock-gateway-infra

Terraform for everything [bedrock-gateway-app](https://github.com/taixingbi/bedrock-gateway-app)
runs on: VPC/networking, ALB + API Gateway VPC Link, ECS/Fargate, ECR,
IAM/OIDC (for all three split repos, not just this one), and CloudWatch.
Split out of the original combined repo (`bedrock-gateway-platform`,
now archived) so an app deploy never needs Terraform permissions and a
Terraform change never needs an app rebuild.

```
modules/
  network/       VPC, public subnets, IGW, route table
  ecr/            ECR repo + lifecycle policy
  ecs_service/    ECS cluster, private ALB, task definition, service, IAM roles
  api_gateway/    HTTP API + VPC Link, AWS_IAM and JWT routes to the same backend
  github_oidc/    Generic: OIDC provider + N IAM roles trusting N {repo, GitHub Environment} pairs
environments/
  global/         Account-wide: the OIDC provider + every role for all three repos
  dev/             gateway-dev cluster/service/ALB/API Gateway
  prod/            gateway-prod cluster/service/ALB/API Gateway
```

## Why this repo owns IAM/OIDC for all three split repos

`modules/github_oidc` is generic -- it knows how to create an OIDC
role trusting a given `{repo, GitHub Environment}` pair, and nothing
about what that role is allowed to do. `environments/global` calls it
three times: once for bedrock-gateway-app's deploy roles, once for
this repo's own plan/apply roles, once for bedrock-gateway-policies's
publish role. Centralizing this here (rather than each repo owning its
own OIDC role) means every permission grant in the whole platform is
reviewable in one Terraform diff, not scattered across three repos'
history.

**What this deliberately does not include:** HTTPS on the ALB (TLS
terminates at API Gateway instead), a real IdP for the JWT path (the
app still falls back to its dev JWT keypair until one is wired up), and
private subnets/NAT (tasks run in public subnets with a security group
that only allows inbound from the ALB, itself only reachable from API
Gateway's VPC Link -- avoids NAT gateway cost on a V1 MVP). Tighten
before this carries real production traffic.

## One-time account setup

**1. State backend.** Unlike the original combined repo (which got
away with local state since only one person ever ran `terraform
apply`), this repo's CI needs shared, lockable state --
`backend.tf.example` -> `backend.tf` (S3 bucket + DynamoDB lock table)
in each of `environments/{global,dev,prod}/` is **required**, not
optional, before wiring up this repo's CI:

```bash
aws s3api create-bucket --bucket <your-tfstate-bucket> --region us-east-1
aws dynamodb create-table --table-name <your-tfstate-lock-table> \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

Then `terraform init -migrate-state` in each environment.

**2. Apply `environments/global`.** Creates the GitHub OIDC provider
(account-wide singleton) and every role across all three repos:

```bash
cd environments/global
terraform init
terraform apply -var="github_org=<your-github-org-or-username>"
```

Note the role ARNs in the output -- **this is the chicken-and-egg
step**: this repo's own `gha-infra-plan`/`gha-infra-apply` roles don't
exist until this first local apply creates them, so this repo's CI
can't be the thing that creates them. Every apply after this first one
can run through CI.

**3. Create the GitHub Environments.** Across all three repos:
- bedrock-gateway-app: `dev`, `prod` -- set `AWS_APP_DEPLOY_ROLE_ARN_DEV`/`_PROD`.
- bedrock-gateway-infra (this repo): `plan`, `apply` -- set
  `AWS_INFRA_PLAN_ROLE_ARN`/`AWS_INFRA_APPLY_ROLE_ARN`. Add required
  reviewers on `apply` (or split further into `apply-dev`/`apply-prod`
  if you want dev to auto-apply but prod to always need a human).
- bedrock-gateway-policies: `publish` -- set `AWS_POLICY_PUBLISH_ROLE_ARN`
  (inert until the phase-2 DynamoDB-backed PolicyStore exists).

Restrict each Environment's deployment branches to `main` as a second
layer behind each workflow's own branch check.

**4. Apply `environments/dev` and `environments/prod`.** Same as
before the split -- creates/confirms the VPC, ECR repo, ECS
cluster/service, ALB, and API Gateway for each. If migrating from the
combined repo, this should show **zero changes** (same resource
addresses, same state) -- that's the actual proof the split didn't
touch any real infrastructure.

## Day to day

- PRs get `terraform fmt -check` + `validate` + `plan` (read-only,
  `gha-infra-plan`) automatically.
- `apply` runs on merge to `main` (`gha-infra-apply`), gated by
  whatever reviewers you configured on the `apply` GitHub Environment.
- Application deploys happen through bedrock-gateway-app's own CI, not
  through this repo -- this repo owns the surrounding infrastructure,
  never the running image.
- `bedrock_model_ids` in each environment's `variables.tf` grants the
  ECS task role `bedrock:InvokeModel`/`InvokeModelWithResponseStream`
  on exactly those models/inference profiles. Keep it in sync with
  whatever `route_sets.yaml` says in bedrock-gateway-policies.
- The `gha-infra-apply` role's IAM/EC2/ELBv2/ECS/ECR/API-Gateway
  permissions are intentionally broad-but-name-scoped rather than
  minimal -- most of these services don't support resource-level IAM
  scoping on creation actions (a VPC/ALB/etc. ARN doesn't exist until
  after it's created). See the comment in
  `environments/global/main.tf` above `data.aws_iam_policy_document.infra_apply`
  before tightening it further.
