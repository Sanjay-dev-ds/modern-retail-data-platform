# Snowflake access for the ELT pipeline.
#   1. Key pair for the Snowflake service user RETAIL_SVC (no key file handled by hand).
#   2. Airflow connection snowflake_default in Secrets Manager (a DB credential, like pos_db).
#   3. snowflake/setup.sql rendered with this stack's values -> `terraform output -raw snowflake_setup_sql`,
#      run once in Snowsight as ACCOUNTADMIN.
# Snowflake reads S3 by assuming the platform role (trust statement in iam.tf, enabled once
# snowflake_iam_user_arn / snowflake_external_id from DESC INTEGRATION are set).

resource "tls_private_key" "snowflake" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

locals {
  snowflake = {
    user      = "RETAIL_SVC"
    role      = "RETAIL_ROLE"
    warehouse = "RETAIL_WH"
    database  = "RETAIL"
  }
  # Snowflake wants the public key body without the PEM header/footer lines.
  snowflake_public_key = join("", [
    for line in split("\n", trimspace(tls_private_key.snowflake.public_key_pem)) :
    line if !startswith(line, "-----")
  ])
  snowflake_s3_locations = [for p in ["pos/", "clickstream/events/", "catalog/products/"] : "s3://${var.bucket_name}/${p}"]
}

resource "aws_secretsmanager_secret" "snowflake_conn" {
  name                    = "${local.prefix}/airflow/connections/snowflake_default"
  description             = "Airflow connection to Snowflake (key-pair auth for RETAIL_SVC)"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "snowflake_conn" {
  secret_id = aws_secretsmanager_secret.snowflake_conn.id
  secret_string = jsonencode({
    conn_type = "snowflake"
    login     = local.snowflake.user
    schema    = "STAGING"
    extra = jsonencode({
      account             = var.snowflake_account
      warehouse           = local.snowflake.warehouse
      database            = local.snowflake.database
      role                = local.snowflake.role
      private_key_content = tls_private_key.snowflake.private_key_pem_pkcs8
    })
  })
}
