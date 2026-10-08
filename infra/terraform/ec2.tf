# Single platform host: Airflow 3 (orchestration) and the synthetic data generators.
# Installed on first boot by scripts/airflow/install_airflow.sh. No inbound rules: shell and
# Airflow UI go through SSM (make ssm / make airflow-ui).

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  # Written to /etc/airflow/infra.env and read by the install script.
  host_env = {
    AWS_DEFAULT_REGION = var.region
    AIRFLOW_VERSION    = var.airflow_version
    SECRETS_PREFIX     = "${local.prefix}/airflow"
    RAW_BUCKET         = var.bucket_name
    DB_SECRET_ID       = aws_secretsmanager_secret.db.name
    KINESIS_STREAM     = aws_kinesis_stream.clickstream.name
    DMS_TASK_ARN       = try(aws_dms_replication_task.pos[0].replication_task_arn, "")
    GLUE_CRAWLER       = aws_glue_crawler.raw.name
    REPO_URL           = var.repo_url
    REPO_BRANCH        = var.repo_branch
  }

  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    exec > >(tee -a /var/log/platform-install.log) 2>&1
    mkdir -p /etc/airflow
    cat > /etc/airflow/infra.env <<'ENV'
    ${join("\n", [for k, v in local.host_env : "${k}=${v}"])}
    ENV
    echo '${base64encode(file("${path.module}/../../scripts/airflow/install_airflow.sh"))}' | base64 -d > /usr/local/sbin/install_airflow.sh
    chmod 700 /usr/local/sbin/install_airflow.sh
    /usr/local/sbin/install_airflow.sh
  EOT
}

resource "aws_instance" "platform" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.ec2_instance_type
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.platform.name
  associate_public_ip_address = true

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
  }

  # gzip keeps the embedded install script well under the 16 KB user_data limit.
  user_data_base64 = base64gzip(local.user_data)

  # The Airflow metadata DB lives on this host: don't replace it when the AMI or the install
  # script changes. Re-run the script over SSM to apply script changes.
  lifecycle {
    ignore_changes = [ami, user_data_base64]
  }

  tags = { Name = "${local.prefix}-platform" }

  depends_on = [aws_iam_role_policy.platform]
}
