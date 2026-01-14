all: cli deploy
.PHONY: all doormat_creds doormat_aws deploy destroy console cli
ACCOUNT = aws_andre_test
ORGANIZATION = emea-se-playground-2019
VAR_SET = varset-ejCyK41nYe16hgNt
check_creds = $(shell doormat --smoke-test 1>&2 2>/dev/null; echo $$?)
login:
		doormat login
init:
		terraform init
demostack:
		doormat aws --account $(ACCOUNT)  tf-push --local
varset:
		doormat aws tf-push variable-set --account $(ACCOUNT) --id $(VAR_SET)
apply:
		terraform init
		terraform plan
		terraform apply
destroy:
		terraform destroy