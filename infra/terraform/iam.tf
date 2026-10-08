# One service role for the whole platform. It is assumed by:
#   ec2.amazonaws.com       platform host (Airflow, generators)
#   dms.amazonaws.com       DMS S3 target endpoint
#   firehose.amazonaws.com  Kinesis -> S3 delivery
#   glue.amazonaws.com      Glue crawler

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = [
        "ec2.amazonaws.com",
        "dms.amazonaws.com",
        "firehose.amazonaws.com",
        "glue.amazonaws.com",
      ]
    }
  }
}

data "aws_iam_policy_document" "platform" {
  statement {
    sid       = "BucketLevel"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
    resources = [local.bucket_arn]
  }

  # Data prefixes only: the Terraform state under terraform/ stays out of reach.
  statement {
    sid = "DataObjects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:PutObjectTagging",
      "s3:AbortMultipartUpload",
    ]
    resources = [for p in local.data_prefixes : "${local.bucket_arn}/${p}/*"]
  }

  statement {
    sid = "Kinesis"
    actions = [
      "kinesis:PutRecord",
      "kinesis:PutRecords",
      "kinesis:DescribeStream",
      "kinesis:DescribeStreamSummary",
      "kinesis:GetShardIterator",
      "kinesis:GetRecords",
      "kinesis:ListShards",
    ]
    resources = [aws_kinesis_stream.clickstream.arn]
  }

  statement {
    sid       = "KinesisKms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["kinesis.${var.region}.amazonaws.com"]
    }
  }

  statement {
    sid       = "Secrets"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:${local.prefix}/*"]
  }

  statement {
    sid = "DmsOperate"
    actions = [
      "dms:DescribeReplicationTasks",
      "dms:DescribeTableStatistics",
      "dms:DescribeReplicationInstances",
      "dms:DescribeEndpoints",
      "dms:StartReplicationTask",
      "dms:StopReplicationTask",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "FirehoseLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.firehose.arn}:*"]
  }
}

resource "aws_iam_role" "platform" {
  name               = "${local.prefix}-platform"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy" "platform" {
  name   = "platform-access"
  role   = aws_iam_role.platform.id
  policy = data.aws_iam_policy_document.platform.json
}

# SSM Session Manager access for the EC2 host.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.platform.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Glue catalog and crawler permissions (also lets Airflow start the crawler).
resource "aws_iam_role_policy_attachment" "glue" {
  role       = aws_iam_role.platform.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_instance_profile" "platform" {
  name = "${local.prefix}-platform"
  role = aws_iam_role.platform.name
}

# Not a platform role: AWS requires a role with exactly this name before DMS can create
# resources in a VPC. Only created when DMS is enabled.
resource "aws_iam_role" "dms_vpc" {
  count = var.enable_dms ? 1 : 0

  name = "dms-vpc-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "dms.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dms_vpc" {
  count = var.enable_dms ? 1 : 0

  role       = aws_iam_role.dms_vpc[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonDMSVPCManagementRole"
}
