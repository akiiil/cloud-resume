###############################################################################
#  BACKEND  ➜ Lambda  +  DynamoDB  +  HTTP API
###############################################################################
# -- IAM role + basic CloudWatch logs
resource "aws_iam_role" "lambda_exec_role" {
  name = "lambda_exec_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}
resource "aws_iam_role_policy_attachment" "lambda_basic_logs" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# -- DynamoDB table + seed item (counter initialised once)
resource "aws_dynamodb_table" "viewer_counter" {
  name         = "cloudres-iac"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "viewer_id"
  attribute {
    name = "viewer_id"
    type = "S"
  }
}
resource "aws_dynamodb_table_item" "initialize_counter" {
  table_name = aws_dynamodb_table.viewer_counter.name
  hash_key   = "viewer_id"
  item = jsonencode({
    viewer_id    = { S = "1" }
    viewer_count = { N = "0" }
  })
  lifecycle { ignore_changes = [item] }   # don’t reset on each apply
}

# -- Lambda package
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/backend/lambda_function.py"
  output_path = "${path.module}/backend/lambda_function.zip"
}
resource "aws_lambda_function" "visitor_counter" {
  function_name    = "VisitorCounter"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
}

# -- Inline IAM policy to access the DynamoDB table
resource "aws_iam_policy" "lambda_dynamo_policy" {
  name = "lambda-dynamodb-policy"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:Scan"]
      Resource = aws_dynamodb_table.viewer_counter.arn
    }]
  })
}
resource "aws_iam_role_policy_attachment" "lambda_policy_attach" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = aws_iam_policy.lambda_dynamo_policy.arn
}

# -- HTTP API (API Gateway v2) + Lambda integration
resource "aws_apigatewayv2_api" "http_api" {
  name          = "visitor-http-api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins     = ["https://iac.akilriaz.xyz"]
    allow_methods     = ["GET", "OPTIONS"]
    allow_headers     = ["*"]
    expose_headers    = ["*"]
    max_age           = 3600
    allow_credentials = false
  }
}
resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.visitor_counter.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}
resource "aws_apigatewayv2_route" "default_route" {
  api_id   = aws_apigatewayv2_api.http_api.id
  route_key = "GET /"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}
resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.visitor_counter.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

###############################################################################
#  FRONTEND  ➜  Private S3 Bucket  +  CloudFront (OAC)  +  Route 53  +  ACM
###############################################################################
# -- S3 bucket (private)
resource "aws_s3_bucket" "frontend_bucket" {
  bucket         = "iac.akilriaz.xyz"
  force_destroy  = true
  tags           = { Name = "Cloud Resume Frontend Bucket" }
}
resource "aws_s3_bucket_ownership_controls" "ownership" {
  bucket = aws_s3_bucket.frontend_bucket.id
  rule { object_ownership = "BucketOwnerEnforced" }
}
resource "aws_s3_bucket_public_access_block" "public_access" {
  bucket                  = aws_s3_bucket.frontend_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -- CloudFront Origin-Access-Control (us-east-1)
resource "aws_cloudfront_origin_access_control" "frontend_oac" {
  provider = aws.virginia
  name                              = "frontend-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# -- Bucket policy to allow CloudFront (via OAC) to read
resource "aws_s3_bucket_policy" "allow_cloudfront_oac" {
  bucket = aws_s3_bucket.frontend_bucket.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid       = "AllowCloudFrontRead"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.frontend_bucket.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.frontend_distribution.arn
        }
      }
    }]
  })
}

# -- Route 53 hosted zone (lookup)
data "aws_route53_zone" "root" {
  name         = "akilriaz.xyz."
  private_zone = false
}

# -- ACM certificate (must be in us-east-1 for CloudFront)
resource "aws_acm_certificate" "cert" {
  provider          = aws.virginia
  domain_name       = "iac.akilriaz.xyz"
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options :
    dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }
  zone_id = data.aws_route53_zone.root.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.value]
}
resource "aws_acm_certificate_validation" "cert" {
  provider                = aws.virginia
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# -- CloudFront distribution
resource "aws_cloudfront_distribution" "frontend_distribution" {
  provider = aws.virginia
  enabled  = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases             = ["iac.akilriaz.xyz"]

  origin {
    domain_name              = aws_s3_bucket.frontend_bucket.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend_oac.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cert.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  tags = { Environment = "CloudResume" }
}

# -- DNS record → CloudFront
resource "aws_route53_record" "iac_subdomain" {
  zone_id = data.aws_route53_zone.root.zone_id
  name    = "iac.akilriaz.xyz"
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.frontend_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.frontend_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}

# -- Upload all static assets
resource "aws_s3_object" "frontend_assets" {
  for_each = fileset("${path.module}/frontend", "**")
  bucket   = aws_s3_bucket.frontend_bucket.id
  key      = each.value
  source   = "${path.module}/frontend/${each.value}"
  etag     = filemd5("${path.module}/frontend/${each.value}")

  content_type = lookup({
    html = "text/html" 
    js = "application/javascript" 
    css = "text/css"
    json = "application/json" 
    png = "image/png" 
    jpg = "image/jpeg"
    jpeg = "image/jpeg" 
    svg = "image/svg+xml" 
    ico = "image/x-icon"
    webp = "image/webp" 
    txt = "text/plain"
  }, split(".", each.value)[length(split(".", each.value)) - 1], "binary/octet-stream")

  cache_control = "no-cache, no-store, must-revalidate"
}
