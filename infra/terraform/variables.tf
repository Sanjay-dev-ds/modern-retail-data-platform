variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "retail-data-platform"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "bucket_name" {
  description = "Existing bucket for raw landing data (shared with Terraform state under terraform/)"
  type        = string
  default     = "modern-retail-data-platform-20261007"
}

variable "rds_instance_class" {
  type    = string
  default = "db.t4g.small"
}

variable "enable_dms" {
  description = "Create the DMS replication instance, endpoints and task. Set false to stop DMS cost."
  type        = bool
  default     = true
}

variable "dms_instance_class" {
  description = "Smallest orderable class in us-east-1 (dms.t3.micro is no longer offered). Check with: aws dms describe-orderable-replication-instances"
  type        = string
  default     = "dms.t3.small"
}

variable "ec2_instance_type" {
  description = "Platform host running Airflow and the generators (4 GB RAM minimum)"
  type        = string
  default     = "t3.medium"
}

variable "airflow_version" {
  type    = string
  default = "3.3.2"
}

variable "repo_url" {
  description = "Git URL of the modern-retail-data-platform repo, cloned to /opt/retail on first boot. Empty skips the clone."
  type        = string
  default     = "https://github.com/Sanjay-dev-ds/modern-retail-data-platform.git"
}

variable "repo_branch" {
  type    = string
  default = "main"
}

variable "alert_email" {
  description = "Email for budget alerts. Empty disables the budget."
  type        = string
  default     = "sanjay28.js@gmail.com"
}

variable "monthly_budget_usd" {
  type    = number
  default = 50
}

# ---- Snowflake (see snowflake.tf and README "Load into Snowflake")
variable "snowflake_account" {
  description = "Snowflake account identifier, orgname-accountname (Snowsight: Admin > Accounts)"
  type        = string
  default     = ""
}

variable "snowflake_iam_user_arn" {
  description = "STORAGE_AWS_IAM_USER_ARN from DESC INTEGRATION S3_RAW_INT. Empty until setup.sql has run."
  type        = string
  default     = ""
}

variable "snowflake_external_id" {
  description = "STORAGE_AWS_EXTERNAL_ID from DESC INTEGRATION S3_RAW_INT"
  type        = string
  default     = ""
}
