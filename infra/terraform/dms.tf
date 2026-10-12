# DMS Serverless, CDC only: stream POS changes from RDS to s3://<bucket>/pos/<schema>/<table>/
# as Parquet. No replication instance to size: capacity (DCUs) scales between the min and max
# below. CDC only = no full load, so start the replication BEFORE seeding the database; the seed
# then reaches S3 as CDC inserts. Terraform never starts it: `make dms-start`.
# DMS creates its service-linked role (AWSServiceRoleForDMSServerless) on the first start.

resource "aws_dms_replication_subnet_group" "this" {
  count = var.enable_dms ? 1 : 0

  replication_subnet_group_id          = "${local.prefix}-dms"
  replication_subnet_group_description = "DMS subnets for ${local.prefix}"
  subnet_ids                           = aws_subnet.private[*].id

  depends_on = [aws_iam_role_policy_attachment.dms_vpc]
}

resource "aws_dms_endpoint" "source" {
  count = var.enable_dms ? 1 : 0

  endpoint_id   = "${local.prefix}-pos-source"
  endpoint_type = "source"
  engine_name   = "postgres"
  server_name   = aws_db_instance.pos.address
  port          = aws_db_instance.pos.port
  database_name = aws_db_instance.pos.db_name
  username      = aws_db_instance.pos.username
  password      = random_password.db.result
  ssl_mode      = "require"

  # test_decoding avoids the pglogical extension; the heartbeat keeps the replication slot
  # advancing while the source is idle.
  extra_connection_attributes = "PluginName=test_decoding;heartbeatEnable=Y;heartbeatFrequency=1"
}

resource "aws_dms_s3_endpoint" "target" {
  count = var.enable_dms ? 1 : 0

  endpoint_id             = "${local.prefix}-s3-target"
  endpoint_type           = "target"
  bucket_name             = var.bucket_name
  bucket_folder           = "pos"
  service_access_role_arn = aws_iam_role.platform.arn
  encryption_mode         = "SSE_S3"

  data_format             = "parquet"
  parquet_version         = "parquet-2-0"
  compression_type        = "GZIP"
  timestamp_column_name   = "_dms_commit_ts"
  date_partition_enabled  = true
  date_partition_sequence = "YYYYMMDD"
  cdc_max_batch_interval  = 60
  cdc_min_file_size       = 32000

  depends_on = [aws_iam_role_policy.platform]
}

resource "aws_dms_replication_config" "pos" {
  count = var.enable_dms ? 1 : 0

  replication_config_identifier = "${local.prefix}-pos-cdc"
  replication_type              = "cdc"
  source_endpoint_arn           = aws_dms_endpoint.source[0].endpoint_arn
  target_endpoint_arn           = aws_dms_s3_endpoint.target[0].endpoint_arn
  start_replication             = false

  table_mappings = jsonencode({
    rules = [{
      "rule-type"      = "selection"
      "rule-id"        = "1"
      "rule-name"      = "pos-all"
      "object-locator" = { "schema-name" = "pos", "table-name" = "%" }
      "rule-action"    = "include"
    }]
  })

  # CloudWatch logging stays off (it needs another AWS-named role). Check progress with
  # `aws dms describe-replications` / `describe-replication-table-statistics`.
  replication_settings = jsonencode({
    Logging = { EnableLogging = false }
  })

  compute_config {
    replication_subnet_group_id = aws_dms_replication_subnet_group.this[0].replication_subnet_group_id
    vpc_security_group_ids      = [aws_security_group.this.id]
    min_capacity_units          = var.dms_min_capacity_units
    max_capacity_units          = var.dms_max_capacity_units
    multi_az                    = false
  }
}
