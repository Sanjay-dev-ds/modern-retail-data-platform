TF_DIR := infra/terraform
TF_OUT  = terraform -chdir=$(TF_DIR) output -raw

.PHONY: tf-fmt tf-init tf-validate tf-plan tf-apply tf-destroy \
        dms-start dms-resume dms-stop dms-status ssm airflow-ui dbt-docs rds-tunnel rds-credentials ec2-start ec2-stop

tf-fmt:
	terraform -chdir=$(TF_DIR) fmt -recursive

tf-init:
	terraform -chdir=$(TF_DIR) init

tf-validate:
	terraform -chdir=$(TF_DIR) validate

tf-plan:
	terraform -chdir=$(TF_DIR) plan -out=tfplan

tf-apply:
	terraform -chdir=$(TF_DIR) apply tfplan

tf-destroy:
	terraform -chdir=$(TF_DIR) destroy

# DMS task, CDC only. First start: AFTER sql/pos/01_schema.sql and BEFORE the seed load,
# so the seeded history is captured as CDC inserts.
dms-start:
	aws dms start-replication-task --replication-task-arn $$($(TF_OUT) dms_task_arn) --start-replication-task-type start-replication

# Continue from where it stopped (no changes are lost while stopped, within WAL retention)
dms-resume:
	aws dms start-replication-task --replication-task-arn $$($(TF_OUT) dms_task_arn) --start-replication-task-type resume-processing

dms-stop:
	aws dms stop-replication-task --replication-task-arn $$($(TF_OUT) dms_task_arn)

# Task status and per-table change counts
dms-status:
	aws dms describe-replication-tasks --filters Name=replication-task-arn,Values=$$($(TF_OUT) dms_task_arn) \
	  --query 'ReplicationTasks[0].[Status,MigrationType,StopReason]' --output text
	aws dms describe-table-statistics --replication-task-arn $$($(TF_OUT) dms_task_arn) \
	  --query 'TableStatistics[].[TableName,Inserts,Updates,Deletes,TableState]' --output table

# Shell on the platform host (generator commands: see README)
ssm:
	$$($(TF_OUT) ssm_command)

# Tunnel the Airflow UI to http://localhost:8080 (keep running while you use the UI)
airflow-ui:
	$$($(TF_OUT) airflow_ui_tunnel_command)

# Tunnel dbt docs to http://localhost:8081. First start the server on the host:
#   sudo bash /opt/retail/scripts/dbt_docs.sh
dbt-docs:
	aws ssm start-session --target $$($(TF_OUT) instance_id) --document-name AWS-StartPortForwardingSession --parameters portNumber=8081,localPortNumber=8081

# Tunnel the private POS database (RDS) to localhost:15432 through the EC2 host, for DBeaver /
# psql. Keep it running while you use the database. RDS stays private.
rds-tunnel:
	aws ssm start-session --target $$($(TF_OUT) instance_id) --document-name AWS-StartPortForwardingSessionToRemoteHost \
	  --parameters host=$$($(TF_OUT) rds_endpoint),portNumber=5432,localPortNumber=15432

# Connection details for DBeaver (from the DB secret in Secrets Manager; prints the password)
rds-credentials:
	@aws secretsmanager get-secret-value --secret-id $$($(TF_OUT) db_secret_name) --query SecretString --output text \
	  | jq -r '"host:     localhost (via make rds-tunnel)\nport:     15432\ndatabase: \(.dbname)\nuser:     \(.username)\npassword: \(.password)\nssl:      require"'

ec2-start:
	aws ec2 start-instances --instance-ids $$($(TF_OUT) instance_id)

ec2-stop:
	aws ec2 stop-instances --instance-ids $$($(TF_OUT) instance_id)
