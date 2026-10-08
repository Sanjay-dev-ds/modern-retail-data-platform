# Glue catalog + crawler so raw landing data can be queried from Athena (validation only).
# The crawler runs on demand: `aws glue start-crawler` or from Airflow.

resource "aws_glue_catalog_database" "raw" {
  name = "${replace(local.prefix, "-", "_")}_raw"
}

resource "aws_glue_crawler" "raw" {
  name          = "${local.prefix}-raw"
  database_name = aws_glue_catalog_database.raw.name
  role          = aws_iam_role.platform.arn
  table_prefix  = "raw_"

  s3_target {
    path = "s3://${var.bucket_name}/pos/pos/"
  }

  s3_target {
    path = "s3://${var.bucket_name}/clickstream/events/"
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "UPDATE_IN_DATABASE"
  }

  depends_on = [aws_iam_role_policy_attachment.glue]
}
