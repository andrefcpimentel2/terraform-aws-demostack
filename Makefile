# all: login init demostack apply
# .PHONY: all doormat_creds doormat_aws deploy destroy console
# TFC_ORG = emea-se-playground-2019
# WORKSPACE_DEMOSTACK = andre-AWS-Demostack
# WORKSPACE_DNS = andre-DNS-Zone
# login:
# 	doormat login
# init:
# 	terraform init
# demostack:
# 	doormat aws --account se_demos_dev tf-push --local
# apply:
# 	terraform init
# 	terraform plan
# 	terraform apply
# destroy:
# 	terraform destroy
all: cli deploy
.PHONY: all doormat_creds doormat_aws deploy destroy console cli
ACCOUNT = aws_andre_test
ORGANIZATION = emea-se-playground-2019
VAR_SET = varset-ejCyK41nYe16hgNt
check_creds = $(shell doormat --smoke-test 1>&2 2>/dev/null; echo $$?)
doormat_creds:
ifneq ($(check_creds), 0)
	doormat --refresh
endif
doormat_aws: doormat_creds
	doormat aws tf-push variable-set \
	--account $(ACCOUNT) --id $(VAR_SET)
