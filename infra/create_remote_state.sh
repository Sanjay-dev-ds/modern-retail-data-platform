#!/usr/bin/env bash
# One-time bootstrap of the shared bucket (Terraform state under terraform/, raw landing data
# under pos/, clickstream/, ...). State locking uses an S3 lock file, so no DynamoDB table.
# Names must match the backend block in infra/terraform/versions.tf.
set -euo pipefail

BUCKET=modern-retail-data-platform-20261007
REGION=us-east-1

aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

