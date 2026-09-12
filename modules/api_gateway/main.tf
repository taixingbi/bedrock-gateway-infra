# Front door for the gateway: one HTTP API, one VPC Link to the private
# ALB (see modules/ecs_service), and two routes that reach the exact
# same backend but differ in who's allowed to call them and what
# identity headers the backend can trust:
#
#   ANY /iam/{proxy+}  AWS_IAM   -- SigV4-signed calls. API Gateway
#                                   verifies the signature itself (this
#                                   module does none of that) and
#                                   overwrites x-platform-principal-arn/
#                                   x-platform-account-id with its own
#                                   verified $context.identity.* values,
#                                   discarding whatever the client sent.
#   ANY /{proxy+}      NONE      -- Bearer JWT calls, verified by the app
#                                   itself exactly as before. The two
#                                   identity headers are stripped here
#                                   (remove, not just "don't set") so a
#                                   client can never inject them on this
#                                   route and impersonate the IAM path.
#
# A single aws_apigatewayv2_route can't carry two different
# authorization_type values, which is why this is two routes (sharing
# one VPC Link and ALB target) rather than one.

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name_prefix}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_vpc_link" "this" {
  name               = "${var.name_prefix}-vpc-link"
  subnet_ids         = var.vpc_link_subnet_ids
  security_group_ids = [var.vpc_link_security_group_id]
}

locals {
  # $request.path.proxy is the {proxy+} catch-all's value (e.g. a client
  # calling /iam/v1/chat has $request.path.proxy == "v1/chat"); prefixing
  # with "/" gives the backend the same path it would see called
  # directly ("/v1/chat").
  path_rewrite = { "overwrite:path" = "/$${request.path.proxy}" }
}

resource "aws_apigatewayv2_integration" "iam" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "HTTP_PROXY"
  integration_uri        = var.alb_listener_arn
  integration_method     = "ANY"
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.this.id
  payload_format_version = "1.0"

  request_parameters = merge(local.path_rewrite, {
    "overwrite:header.${var.principal_arn_header}" = "$${context.identity.userArn}"
    "overwrite:header.${var.account_id_header}"    = "$${context.identity.accountId}"
  })
}

resource "aws_apigatewayv2_integration" "open" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "HTTP_PROXY"
  integration_uri        = var.alb_listener_arn
  integration_method     = "ANY"
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.this.id
  payload_format_version = "1.0"

  # Empty string is API Gateway's documented "remove this header"
  # value -- not "don't set", but "strip it if the client sent it".
  # This is the control that makes the IAM route's header-trust safe:
  # without it, a client could set x-platform-principal-arn directly on
  # this open route and the app would trust it.
  request_parameters = merge(local.path_rewrite, {
    "remove:header.${var.principal_arn_header}" = ""
    "remove:header.${var.account_id_header}"    = ""
  })
}

resource "aws_apigatewayv2_route" "iam" {
  api_id             = aws_apigatewayv2_api.this.id
  route_key          = "ANY /iam/{proxy+}"
  authorization_type = "AWS_IAM"
  target             = "integrations/${aws_apigatewayv2_integration.iam.id}"
}

resource "aws_apigatewayv2_route" "open" {
  api_id             = aws_apigatewayv2_api.this.id
  route_key          = "ANY /{proxy+}"
  authorization_type = "NONE"
  target             = "integrations/${aws_apigatewayv2_integration.open.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true
}
