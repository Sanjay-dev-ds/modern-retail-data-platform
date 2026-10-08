TF_DIR := infra/terraform
TF_OUT  = terraform -chdir=$(TF_DIR) output -raw

.PHONY: tf-fmt tf-init tf-validate tf-plan tf-apply tf-destroy \
        dms-start dms-resume dms-stop ssm airflow-ui ec2-start ec2-stop

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

# First start (full load, then CDC). Run only after sql/pos/01_schema.sql and the seed load.
dms-start:
	aws dms start-replication-task --replication-task-arn $$($(TF_OUT) dms_task_arn) --start-replication-task-type start-replication

dms-resume:
	aws dms start-replication-task --replication-task-arn $$($(TF_OUT) dms_task_arn) --start-replication-task-type resume-processing

dms-stop:
	aws dms stop-replication-task --replication-task-arn $$($(TF_OUT) dms_task_arn)

# Shell on the platform host (generator commands: see README)
ssm:
	$$($(TF_OUT) ssm_command)

# Tunnel the Airflow UI to http://localhost:8080 (keep running while you use the UI)
airflow-ui:
	$$($(TF_OUT) airflow_ui_tunnel_command)

ec2-start:
	aws ec2 start-instances --instance-ids $$($(TF_OUT) instance_id)

ec2-stop:
	aws ec2 stop-instances --instance-ids $$($(TF_OUT) instance_id)
