terraform {
  required_version = ">= 1.10" # S3-native state locking (use_lockfile)

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # State lives in the shared bucket under the reserved terraform/ prefix; the lock is a
  # <key>.tflock object next to it (no DynamoDB). Create the bucket once with
  # infra/create_remote_state.sh. State holds the RDS password: keep it private.
  backend "s3" {
    bucket       = "modern-retail-data-platform-20261007"
    key          = "terraform/envs/dev/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  prefix     = "${var.project}-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id
  bucket_arn = "arn:aws:s3:::${var.bucket_name}"

  # Top-level bucket prefixes holding platform data. terraform/ (state) is deliberately excluded.
  data_prefixes = ["pos", "clickstream", "catalog", "inventory", "marketing", "reference"]
}
