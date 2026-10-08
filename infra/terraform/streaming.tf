# Clickstream: Kinesis Data Stream -> Firehose -> s3://<bucket>/clickstream/events/dt=/hh=/

resource "aws_kinesis_stream" "clickstream" {
  name             = "${local.prefix}-clickstream"
  retention_period = 24
  encryption_type  = "KMS"
  kms_key_id       = "alias/aws/kinesis"

  stream_mode_details {
    stream_mode = "ON_DEMAND"
  }
}

resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/${local.prefix}-clickstream"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_stream" "firehose" {
  name           = "S3Delivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

resource "aws_kinesis_firehose_delivery_stream" "clickstream" {
  name        = "${local.prefix}-clickstream-to-s3"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.clickstream.arn
    role_arn           = aws_iam_role.platform.arn
  }

  extended_s3_configuration {
    role_arn            = aws_iam_role.platform.arn
    bucket_arn          = local.bucket_arn
    prefix              = "clickstream/events/dt=!{timestamp:yyyy-MM-dd}/hh=!{timestamp:HH}/"
    error_output_prefix = "clickstream/errors/!{firehose:error-output-type}/dt=!{timestamp:yyyy-MM-dd}/"
    buffering_size      = 64
    buffering_interval  = 60
    compression_format  = "GZIP"

    # Firehose concatenates records; this adds the newline that makes the output JSON Lines,
    # so producers must NOT append their own.
    processing_configuration {
      enabled = true

      processors {
        type = "AppendDelimiterToRecord"

        parameters {
          parameter_name  = "Delimiter"
          parameter_value = "\\n"
        }
      }
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose.name
    }
  }

  depends_on = [aws_iam_role_policy.platform]
}
