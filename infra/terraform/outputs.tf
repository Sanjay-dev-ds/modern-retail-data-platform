output "bucket" {
  value = var.bucket_name
}

output "platform_role_arn" {
  value = aws_iam_role.platform.arn
}

output "rds_endpoint" {
  value = aws_db_instance.pos.address
}

output "db_secret_name" {
  value = aws_secretsmanager_secret.db.name
}

output "kinesis_stream" {
  value = aws_kinesis_stream.clickstream.name
}

output "firehose_stream" {
  value = aws_kinesis_firehose_delivery_stream.clickstream.name
}

output "dms_task_arn" {
  value = try(aws_dms_replication_task.pos[0].replication_task_arn, null)
}

output "glue_crawler" {
  value = aws_glue_crawler.raw.name
}

output "instance_id" {
  value = aws_instance.platform.id
}

output "ssm_command" {
  value = "aws ssm start-session --target ${aws_instance.platform.id}"
}

output "airflow_ui_tunnel_command" {
  description = "Forwards the Airflow UI to http://localhost:8080"
  value       = "aws ssm start-session --target ${aws_instance.platform.id} --document-name AWS-StartPortForwardingSession --parameters portNumber=8080,localPortNumber=8080"
}
