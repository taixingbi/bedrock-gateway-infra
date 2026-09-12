# ECS Fargate service fronted by an ALB. HTTP only for now -- add an
# ACM cert + HTTPS listener once there's a real domain (see infra/README.md).

resource "aws_ecs_cluster" "this" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = {
    Environment = var.environment
  }
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name_prefix}"
  retention_in_days = var.log_retention_days
}

# --- Security groups -------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "ALB ingress from the internet on ${var.listener_port}"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from anywhere"
    from_port   = var.listener_port
    to_port     = var.listener_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

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

resource "aws_security_group" "service" {
  name        = "${var.name_prefix}-service"
  description = "Gateway task ingress from the ALB only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "From ALB"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

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

# --- Load balancer -----------------------------------------------------

resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  tags = {
    Environment = var.environment
  }
}

resource "aws_lb_target_group" "this" {
  name        = "${var.name_prefix}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/healthz"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    matcher             = "200"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = var.listener_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
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

# Pulls the image from ECR and writes to CloudWatch -- standard ECS
# execution role, no application permissions.
resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# What the running application is allowed to do: call Bedrock. Nothing else.
resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

locals {
  # "us."-prefixed model IDs are cross-region inference profiles (see
  # policies/route_sets.yaml) -- Bedrock authorizes both the profile
  # ARN itself and the underlying foundation-model ARN in every region
  # the profile can route to. Non-"us."-prefixed IDs are used as plain
  # foundation-model ARNs in var.aws_region.
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

data "aws_iam_policy_document" "bedrock_invoke" {
  statement {
    sid = "InvokeBedrockModels"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = local.bedrock_model_arns
  }
}

resource "aws_iam_role_policy" "task_bedrock" {
  name   = "${var.name_prefix}-bedrock-invoke"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.bedrock_invoke.json
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
      name      = "gateway-api"
      image     = var.image
      essential = true
      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]
      environment = [
        for k, v in var.container_env : { name = k, value = v }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "gateway"
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
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.public_subnet_ids
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = "gateway-api"
    container_port   = var.container_port
  }

  # CI updates the running image with `aws ecs update-service
  # --force-new-deployment` against a new task definition revision it
  # registers itself; ignore drift here so `terraform apply` doesn't
  # fight deploys made outside of Terraform.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener.http]

  tags = {
    Environment = var.environment
  }
}
