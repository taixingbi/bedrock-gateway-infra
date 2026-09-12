output "api_endpoint" {
  description = "Base URL -- append /v1/chat for JWT calls, /iam/v1/chat for SigV4 calls."
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "api_id" {
  value = aws_apigatewayv2_api.this.id
}

output "execute_api_arn_iam_route" {
  description = "Grant execute-api:Invoke on this ARN to any IAM principal that should reach the /iam/* route."
  value       = "${aws_apigatewayv2_api.this.execution_arn}/*/*/iam/{proxy+}"
}
