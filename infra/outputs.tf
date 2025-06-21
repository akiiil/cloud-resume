output "api_url" {
  description = "API Gateway endpoint for Lambda"
  value       = aws_apigatewayv2_api.http_api.api_endpoint
}