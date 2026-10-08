-- Snowflake setup for the retail ELT pipeline (a Terraform template, see infra/terraform/outputs.tf).
-- Get the rendered script and run it ONCE in a Snowsight worksheet ("Run All"):
--   terraform -chdir=infra/terraform output -raw snowflake_setup_sql | pbcopy
-- Safe to re-run: IF NOT EXISTS everywhere except the data-less stages (the integration's
-- external ID never changes).
-- Last statement: DESC INTEGRATION -> copy STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID
-- into terraform.tfvars (snowflake_iam_user_arn, snowflake_external_id) and apply again.

USE ROLE ACCOUNTADMIN;

-- Compute: smallest warehouse, suspends after 60 s idle.
CREATE WAREHOUSE IF NOT EXISTS ${warehouse}
  WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE;

-- One role owns everything the pipeline touches.
CREATE ROLE IF NOT EXISTS ${role};
GRANT ROLE ${role} TO ROLE SYSADMIN;
GRANT USAGE, OPERATE ON WAREHOUSE ${warehouse} TO ROLE ${role};
CREATE DATABASE IF NOT EXISTS ${database};
GRANT OWNERSHIP ON DATABASE ${database} TO ROLE ${role} COPY CURRENT GRANTS;

-- Service user for Airflow/dbt: key-pair auth only (private key is in AWS Secrets Manager).
CREATE USER IF NOT EXISTS ${user}
  TYPE = SERVICE DEFAULT_ROLE = ${role} DEFAULT_WAREHOUSE = ${warehouse}
  COMMENT = 'Airflow + dbt (retail-data-platform)';
ALTER USER ${user} SET RSA_PUBLIC_KEY = '${public_key}';
GRANT ROLE ${role} TO USER ${user};

-- S3 access: Snowflake assumes the AWS platform role. Only the three data prefixes are allowed.
CREATE STORAGE INTEGRATION IF NOT EXISTS S3_RAW_INT
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = '${role_arn}'
  STORAGE_ALLOWED_LOCATIONS = (${s3_locations});
GRANT USAGE ON INTEGRATION S3_RAW_INT TO ROLE ${role};

-- Everything below is owned by the pipeline role.
USE ROLE ${role};
CREATE SCHEMA IF NOT EXISTS ${database}.RAW;
CREATE SCHEMA IF NOT EXISTS ${database}.STAGING;
CREATE SCHEMA IF NOT EXISTS ${database}.CORE;
CREATE SCHEMA IF NOT EXISTS ${database}.MARTS;
USE SCHEMA ${database}.RAW;

CREATE FILE FORMAT IF NOT EXISTS parquet_fmt TYPE = PARQUET USE_LOGICAL_TYPE = TRUE;  -- DMS timestamps/decimals keep their types
CREATE FILE FORMAT IF NOT EXISTS json_fmt TYPE = JSON;  -- gzip detected automatically
CREATE FILE FORMAT IF NOT EXISTS csv_fmt
  TYPE = CSV PARSE_HEADER = TRUE FIELD_OPTIONALLY_ENCLOSED_BY = '"' ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;

-- One stage per source (a stage URL must be inside the integration's allowed locations).
-- File formats are fully qualified: a stage resolves the name at COPY time in the *session's*
-- schema (Airflow's is STAGING), not in RAW. Stages hold no data, so OR REPLACE is safe.
CREATE OR REPLACE STAGE pos_stage
  URL = 's3://${bucket}/pos/pos/' STORAGE_INTEGRATION = S3_RAW_INT
  FILE_FORMAT = (FORMAT_NAME = '${database}.RAW.PARQUET_FMT');
CREATE OR REPLACE STAGE clickstream_stage
  URL = 's3://${bucket}/clickstream/events/' STORAGE_INTEGRATION = S3_RAW_INT
  FILE_FORMAT = (FORMAT_NAME = '${database}.RAW.JSON_FMT');
CREATE OR REPLACE STAGE catalog_stage
  URL = 's3://${bucket}/catalog/products/' STORAGE_INTEGRATION = S3_RAW_INT
  FILE_FORMAT = (FORMAT_NAME = '${database}.RAW.CSV_FMT');

-- RAW tables. POS (DMS Parquet) and clickstream (JSON) land as VARIANT: schema-on-read, so a
-- source column change never breaks the load. dbt staging models type and dedupe them.
CREATE TABLE IF NOT EXISTS pos_stores            (record VARIANT, _file STRING, _loaded_at TIMESTAMP_LTZ);
CREATE TABLE IF NOT EXISTS pos_customers         (record VARIANT, _file STRING, _loaded_at TIMESTAMP_LTZ);
CREATE TABLE IF NOT EXISTS pos_transactions      (record VARIANT, _file STRING, _loaded_at TIMESTAMP_LTZ);
CREATE TABLE IF NOT EXISTS pos_transaction_lines (record VARIANT, _file STRING, _loaded_at TIMESTAMP_LTZ);
CREATE TABLE IF NOT EXISTS pos_payments          (record VARIANT, _file STRING, _loaded_at TIMESTAMP_LTZ);
CREATE TABLE IF NOT EXISTS clickstream_events    (record VARIANT, _file STRING, _loaded_at TIMESTAMP_LTZ);

-- Catalog CSV loads by column name: pack_size (the supplier's unannounced schema drift) is
-- already a column, and any other new column is simply ignored until it is added here.
CREATE TABLE IF NOT EXISTS catalog_products (
  sku                 STRING,
  product_name        STRING,
  brand               STRING,
  category            STRING,
  subcategory         STRING,
  unit_cost           NUMBER(10, 2),
  list_price          NUMBER(10, 2),
  is_active           BOOLEAN,
  supplier_updated_at TIMESTAMP_NTZ,
  pack_size           STRING,
  _file               STRING,
  _loaded_at          TIMESTAMP_LTZ
);

-- Copy these two values into terraform.tfvars, then `make tf-plan tf-apply`.
USE ROLE ACCOUNTADMIN;
DESC INTEGRATION S3_RAW_INT;
