###############################################################################
#  PROVIDERS & GLOBAL SETTINGS
###############################################################################
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {                     # Default provider: ap-southeast-2
  region  = "ap-southeast-2"
  }

provider "aws" {                     # Alias for CloudFront / ACM (us-east-1)
  alias   = "virginia"
  region  = "us-east-1"
  }
