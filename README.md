# infra/

Terraform for the gateway's AWS deployment: ECS Fargate behind an ALB,
one ECR repo per environment, and the GitHub OIDC role CI uses to push
images and deploy -- no long-lived AWS keys in GitHub.

```
infra/
  modules/
    network/       VPC, public subnets, IGW, route table
    ecr/            ECR repo + lifecycle policy
    ecs_service/    ECS cluster, ALB, task definition, service, IAM roles
    github_oidc/    GitHub OIDC provider + one deploy role per environment
  environments/
    global/         Account-wide: the OIDC provider + deploy roles
    dev/             gateway-dev cluster/service/ALB
    prod/            gateway-prod cluster/service/ALB
```

**What this deliberately does not include:** HTTPS (no domain/ACM cert
yet -- the ALB is HTTP-only), a real IdP (the app still falls back to
its dev JWT keypair -- see `OIDC_JWKS_URL` in `.env.example` -- until
one is wired up), and private subnets/NAT (tasks run in public subnets
with a security group that only allows inbound from the ALB, to avoid
NAT gateway cost on a V1 MVP). Tighten these before this carries real
traffic.

## One-time account setup

**1. State backend (optional but recommended).** Each environment
keeps local state by default, which is fine for a single operator but
unsafe for a team (no locking, state lives on one laptop). To use S3 +
DynamoDB instead:

```bash
aws s3api create-bucket --bucket <your-tfstate-bucket> --region us-east-1
aws dynamodb create-table --table-name <your-tfstate-lock-table> \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

Then, in each of `environments/{global,dev,prod}/`, copy
`backend.tf.example` to `backend.tf`, fill in the bucket/table, and run
`terraform init -migrate-state`.

**2. Apply `environments/global`.** Creates the GitHub OIDC provider
(an account-wide singleton) and one IAM role per environment
(`gha-deploy-dev`, `gha-deploy-prod`), each assumable only by a GitHub
Actions job running under that GitHub Environment:

```bash
cd infra/environments/global
terraform init
terraform apply -var="github_org=<your-github-org-or-username>"
```

Note the two role ARNs in the output.

**3. Create the GitHub Environments.** In the repo's Settings ->
Environments, create `dev` and `prod`. Add each role ARN from step 2 as
a repo/environment **variable** (not secret -- it's not sensitive) named
`AWS_DEPLOY_ROLE_ARN_DEV` / `AWS_DEPLOY_ROLE_ARN_PROD`, matching what
`.github/workflows/ci.yml`'s deploy jobs read via `vars.*`. On `prod`,
add required reviewers so a deploy pauses for approval -- there's no
YAML-level equivalent of that gate.

**4. Apply `environments/dev` and `environments/prod`.** Creates the
VPC, ECR repo, ECS cluster/service, and ALB for each:

```bash
cd infra/environments/dev   # then prod
terraform init
terraform apply
```

The ECS service will show 0 running tasks after this -- the task
definition points at an image tag (`:bootstrap`) that doesn't exist in
ECR yet. That's expected; the next push to `main` runs CI's deploy job,
which builds the real image, pushes it, and registers a task definition
revision pointing at it (`terraform apply` afterwards leaves that
revision alone -- see the `ignore_changes` on `aws_ecs_service` in
`modules/ecs_service`).

## Day to day

- `terraform plan`/`apply` in `environments/dev` or `environments/prod`
  for infra changes (instance sizing, env vars, etc.).
- Application deploys happen through CI (`deploy-dev`/`deploy-prod`
  jobs in `.github/workflows/ci.yml`), not `terraform apply` -- Terraform
  owns the surrounding infrastructure, not the running image.
- `bedrock_model_ids` in each environment's `variables.tf` grants the
  task role `bedrock:InvokeModel`/`InvokeModelWithResponseStream` on
  exactly those models/inference profiles. Keep it in sync with
  `policies/route_sets.yaml`.
