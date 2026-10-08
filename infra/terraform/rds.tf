# POS source database: PostgreSQL 16 with logical replication (required for DMS CDC).

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "aws_db_subnet_group" "pos" {
  name       = "${local.prefix}-pos"
  subnet_ids = aws_subnet.private[*].id
}

# rds.logical_replication is static; it takes effect at creation because the group is attached
# from the start. If you change it later, reboot the instance.
resource "aws_db_parameter_group" "pos" {
  name_prefix = "${local.prefix}-pos-"
  family      = "postgres16"
  description = "POS PostgreSQL with logical replication for DMS"

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "wal_sender_timeout"
    value = "0"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "pos" {
  identifier     = "${local.prefix}-pos"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.rds_instance_class

  allocated_storage     = 20
  max_allocated_storage = 50
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "retail"
  username = "retail_admin"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.pos.name
  vpc_security_group_ids = [aws_security_group.this.id]
  parameter_group_name   = aws_db_parameter_group.pos.name
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period    = 1
  auto_minor_version_upgrade = true
  apply_immediately          = true

  # Dev settings: no final snapshot, no deletion protection.
  skip_final_snapshot = true
  deletion_protection = false

  lifecycle {
    ignore_changes = [engine_version]
  }
}

# Connection details for scripts (DB_SECRET_ID on the host).
resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.prefix}/rds/pos"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = aws_db_instance.pos.username
    password = random_password.db.result
    host     = aws_db_instance.pos.address
    port     = aws_db_instance.pos.port
    dbname   = aws_db_instance.pos.db_name
  })
}

# Same database as Airflow connection "pos_db" (read by Airflow's Secrets Manager backend).
resource "aws_secretsmanager_secret" "airflow_pos_db" {
  name                    = "${local.prefix}/airflow/connections/pos_db"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "airflow_pos_db" {
  secret_id = aws_secretsmanager_secret.airflow_pos_db.id
  secret_string = jsonencode({
    conn_type = "postgres"
    host      = aws_db_instance.pos.address
    port      = aws_db_instance.pos.port
    schema    = aws_db_instance.pos.db_name
    login     = aws_db_instance.pos.username
    password  = random_password.db.result
    extra     = jsonencode({ sslmode = "require" })
  })
}
