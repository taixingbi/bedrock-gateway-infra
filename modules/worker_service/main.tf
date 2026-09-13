# ECS Fargate service with no load balancer, no ALB, no inbound ingress
# at all -- this is a queue consumer, not something anything calls
# directly. Deliberately a separate module from ecs_service rather than
# a flag on it: ecs_service's ALB/target-group/listener/load_balancer{}
# block are unconditional resources coupled to the "gateway-api"
# container name, and this repo's existing convention is one narrowly-
# scoped module per concern (network/ecr/ecs_service/api_gateway) --
# forking is more in keeping with that than parametrizing ecs_service
# with an enable_alb branch through all of those resources.
#
# Runs in the same ECS cluster as gateway-api (var.cluster_name, from
# ecs_service's cluster_name output) -- one cluster per environment
# hosting multiple services, not a cluster per service.

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name_prefix}"
  retention_in_days = var.log_retention_days
}

# Egress only -- nothing ever initiates a connection to this task.
resource "aws_security_group" "worker" {
  name        = "${var.name_prefix}-worker"
  description = "Job worker egress only -- Bedrock, SQS, DynamoDB, ECR"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Environment = var.environment
  }
}

# --- IAM ---------------------------------------------------------------

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# Same Bedrock ARN-building logic as modules/ecs_service -- duplicated
# rather than shared, matching this repo's one-module-per-concern style
# (see that module's comment for why "us."-prefixed IDs need both the
# inference-profile ARN and the underlying foundation-model ARn in
# every region the profile can route to).
locals {
  us_profile_ids   = [for id in var.bedrock_model_ids : id if startswith(id, "us.")]
  direct_model_ids = [for id in var.bedrock_model_ids : id if !startswith(id, "us.")]

  inference_profile_arns = [
    for id in local.us_profile_ids :
    "arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${id}"
  ]
  underlying_model_arns = flatten([
    for id in local.us_profile_ids : [
      for region in var.bedrock_profile_regions :
      "arn:aws:bedrock:${region}::foundation-model/${trimprefix(id, "us.")}"
    ]
  ])
  direct_model_arns = [
    for id in local.direct_model_ids :
    "arn:aws:bedrock:${var.aws_region}::foundation-model/${id}"
  ]

  bedrock_model_arns = concat(local.inference_profile_arns, local.underlying_model_arns, local.direct_model_arns)
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "task" {
  statement {
    sid = "InvokeBedrockModels"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = local.bedrock_model_arns
  }

  # Long-poll and delete only -- no SendMessage (that's gateway-api's
  # job, see modules/ecs_service's jobs_access policy), and no
  # ChangeMessageVisibility beyond what ReceiveMessage's own
  # VisibilityTimeout already provides for a single-attempt worker.
  statement {
    sid       = "ConsumeJobs"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [var.sqs_queue_arn]
  }

  statement {
    sid       = "JobRecords"
    actions   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
    resources = [var.dynamodb_table_arn]
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "${var.name_prefix}-task"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

data "aws_iam_policy_document" "ecs_exec" {
  count = var.enable_execute_command ? 1 : 0

  statement {
    sid = "EcsExec"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task_ecs_exec" {
  count  = var.enable_execute_command ? 1 : 0
  name   = "${var.name_prefix}-ecs-exec"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.ecs_exec[0].json
}

# --- Task definition + service ------------------------------------------

resource "aws_ecs_task_definition" "this" {
  family                   = var.name_prefix
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "gateway-worker"
      image     = var.image
      command   = var.command
      essential = true
      # No portMappings -- this task accepts no inbound connections.
      environment = [
        for k, v in var.container_env : { name = k, value = v }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "worker"
        }
      }
    }
  ])

  tags = {
    Environment = var.environment
  }
}

resource "aws_ecs_service" "this" {
  name            = "${var.name_prefix}-service"
  cluster         = var.cluster_name
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.public_subnet_ids
    security_groups  = [aws_security_group.worker.id]
    assign_public_ip = true
  }

  enable_execute_command = var.enable_execute_command

  # Same reasoning as ecs_service: CI deploys by registering a new task
  # definition revision and force-updating the service directly,
  # outside Terraform.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  tags = {
    Environment = var.environment
  }
}
