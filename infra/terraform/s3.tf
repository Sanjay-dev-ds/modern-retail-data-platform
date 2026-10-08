# The bucket already exists (infra/create_remote_state.sh) and also holds Terraform state, so it
# is looked up, never created or destroyed here. Prefix contract:
#   pos/<schema>/<table>/...              DMS output (full load + CDC, Parquet)
#   clickstream/events/dt=/hh=/...        Firehose output (JSON lines, gzip)
#   clickstream/errors/...                Firehose delivery errors
#   catalog|inventory|marketing|reference/<entity>/dt=YYYY-MM-DD/...   batch files
#   terraform/...                         RESERVED: Terraform state

data "aws_s3_bucket" "raw" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_lifecycle_configuration" "raw" {
  bucket = data.aws_s3_bucket.raw.id

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "expire-firehose-errors"
    status = "Enabled"

    filter {
      prefix = "clickstream/errors/"
    }

    expiration {
      days = 14
    }
  }
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [local.bucket_arn, "${local.bucket_arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "raw" {
  bucket = data.aws_s3_bucket.raw.id
  policy = data.aws_iam_policy_document.bucket.json
}
