#!/usr/bin/env bash
set -x
exec > >(tee /var/log/tf-user-data.log|logger -t user-data ) 2>&1

logger() {
  DT=$(date '+%Y/%m/%d %H:%M:%S')
  echo "$DT $0: $1"
}

logger "Running"

logger "==> Vault (server)"
# Vault expects the key to be concatenated with the CA
sudo mkdir -p /etc/vault.d/tls/
sudo mkdir -p /etc/vault.d/plugins/
sudo tee /etc/vault.d/tls/vault.crt > /dev/null <<EOF
$(cat /etc/ssl/certs/me.crt)
$(cat /usr/local/share/ca-certificates/01-me.crt)
EOF

echo "==> checking if we are using enterprise binaries"
echo "==> value of enterprise is ${enterprise}"

if [ ${enterprise} == 0 ]
then
logger "--> Fetching Vault OSS"
install_from_url "vault" "${vault_url}"

else
logger "--> Fetching Vault Ent"
install_from_url "vault" "${vault_ent_url}"
fi


logger "--> Writing configuration"
sudo mkdir -p /etc/vault.d
sudo tee /etc/vault.d/config.hcl > /dev/null <<EOF
cluster_name = "${namespace}-demostack"
storage "consul" {
  path = "vault/"
  service = "vault"
}
listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/etc/vault.d/tls/vault.crt"
  tls_key_file  = "/etc/ssl/certs/me.key"
   tls-skip-verify = true
}
seal "awskms" {
  region = "${region}"
  kms_key_id = "${kmskey}"
}
telemetry {
  prometheus_retention_time = "30s",
  disable_hostname = true
}
plugin_directory = "/etc/vault.d/plugins"
api_addr = "https://$(public_ip):8200"
disable_mlock = true
ui = true
EOF

logger "--> Writing profile"
sudo tee /etc/profile.d/vault.sh > /dev/null <<"EOF"
alias vualt="vault"
export VAULT_ADDR="https://active.vault.service.consul:8200"
EOF
source /etc/profile.d/vault.sh

logger "--> Generating systemd configuration"
sudo tee /etc/systemd/system/vault.service > /dev/null <<"EOF"
[Unit]
Description=Vault
Documentation=https://www.vaultproject.io/docs/
Requires=network-online.target
After=network-online.target
[Service]
Restart=on-failure
ExecStart=/usr/local/bin/vault server -config="/etc/vault.d/config.hcl"
ExecReload=/bin/kill -HUP $MAINPID
KillSignal=SIGINT
[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable vault
sudo systemctl start vault
sleep 8

logger "--> Initializing vault"
consul lock tmp/vault/lock "$(cat <<"EOF"
set -e
sleep 2
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_SKIP_VERIFY=true
if ! vault operator init -status >/dev/null; then
  vault operator init  -recovery-shares=1 -recovery-threshold=1 -key-shares=1 -key-threshold=1 > /tmp/out.txt
  cat /tmp/out.txt | grep "Recovery Key 1" | sed 's/Recovery Key 1: //' | consul kv put service/vault/recovery-key -
   cat /tmp/out.txt | grep "Initial Root Token" | sed 's/Initial Root Token: //' | consul kv put service/vault/root-token -

export VAULT_TOKEN=$(consul kv get service/vault/root-token)
echo "ROOT TOKEN: $VAULT_TOKEN"

sudo systemctl enable vault
sudo systemctl restart vault
else
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_SKIP_VERIFY=true
export VAULT_TOKEN=$(consul kv get service/vault/root-token)
echo "ROOT TOKEN: $VAULT_TOKEN"
sudo systemctl enable vault
sudo systemctl restart vault
fi
sleep 8
EOF
)"


echo "--> Waiting for Vault leader"
while ! host active.vault.service.consul &> /dev/null; do
  sleep 5
done



if [ ${enterprise} == 0 ]
then
echo "--> OSS - no license necessary"

else
echo "--> Ent - Appyling License"
export VAULT_ADDR="https://active.vault.service.consul:8200"
export VAULT_SKIP_VERIFY=true
export VAULT_TOKEN=$(consul kv get service/vault/root-token)
echo "ROOT TOKEN: $VAULT_TOKEN"
vault write sys/license text=${vaultlicense}
echo "--> Ent - License applied"
fi


echo "--> Attempting to create nomad role"

  echo "--> Adding Nomad policy"
  echo "--> Retrieving root token..."
  export VAULT_ADDR="https://active.vault.service.consul:8200"
  export VAULT_SKIP_VERIFY=true
  consul kv get service/vault/root-token | vault login -

  vault policy write nomad-server - <<EOR
  path "auth/token/create/nomad-cluster" {
    capabilities = ["update"]
  }
  path "auth/token/revoke-accessor" {
    capabilities = ["update"]
  }
  path "auth/token/roles/nomad-cluster" {
    capabilities = ["read"]
  }
  path "auth/token/lookup-self" {
    capabilities = ["read"]
  }
  path "auth/token/lookup" {
    capabilities = ["update"]
  }
  path "auth/token/revoke-accessor" {
    capabilities = ["update"]
  }
  path "sys/capabilities-self" {
    capabilities = ["update"]
  }
  path "auth/token/renew-self" {
    capabilities = ["update"]
  }
  path "kv/*" {
    capabilities = ["create", "read", "update", "delete", "list"]
}

path "pki/*" {
    capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

EOR

  vault policy write test - <<EOR
  path "kv/*" {
    capabilities = ["list"]
}

path "kv/test" {
    capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "kv/data/test" {
    capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "pki/*" {
    capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}


path "kv/metadata/cgtest" {
    capabilities = ["list"]
}


path "kv/data/cgtest" {
    capabilities = ["create", "read", "update", "delete", "list", "sudo"]
    control_group = {
        factor "approvers" {
            identity {
                group_names = ["approvers"]
                approvals = 1
            }
        }
    }
}

EOR


  echo "--> Creating Nomad token role"
  vault write auth/token/roles/nomad-cluster \
    name=nomad-cluster \
    period=259200 \
    renewable=true \
    orphan=false \
    disallowed_policies=nomad-server \
    explicit_max_ttl=0

 echo "--> Mount KV in Vault"
 {
 vault secrets enable -version=2 kv &&
  echo "--> KV Mounted succesfully"
 } ||
 {
   echo "--> KV Already mounted, moving on"
 }

 echo "--> Creating Initial secret for Nomad KV"
  vault kv put kv/test message='Hello world'


 echo "--> nomad nginx-vault-pki demo prep"
{
vault secrets enable pki
 }||
{
  echo "--> pki already enabled, moving on"
}

 {
vault write pki/root/generate/internal common_name=service.consul
}||
{
  echo "--> pki generate internal already configured, moving on"
}
{
vault write pki/roles/consul-service generate_lease=true allowed_domains="service.consul" allow_subdomains="true"
}||
{
  echo "--> pki role already configured, moving on"
}

{
vault policy write superuser - <<EOR
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
  }

  path "kv/*" {
    capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "kv/test/*" {
    capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "pki/*" {
    capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "sys/control-group/authorize" {
    capabilities = ["create", "update"]
}

# To check control group request status
path "sys/control-group/request" {
    capabilities = ["create", "update"]
}


EOR
} ||
{
  echo "--> superuser role already configured, moving on"
}

echo "--> Setting up Github auth"
 {
 vault auth enable github &&
 vault write auth/github/config organization=hashicorp &&
 vault write auth/github/map/teams/team-se  value=default,superuser
  echo "--> github auth done"
 } ||
 {
   echo "--> github auth mounted, moving on"
 }

 echo "--> Setting up vault prepared query"
 {
 curl http://localhost:8500/v1/query \
    --request POST \
    --data \
'{
  "Name": "vault",
  "Service": {
    "Service": "vault",
    "Tags":  ["active"],
    "Failover": {
      "NearestN": 2
    }
  }
}'
  echo "--> consul query done"
 } ||
 {
   echo "-->consul query already done, moving on"
 }


 echo "-->Enabling transform"
vault secrets enable  -path=/data-protection/masking/transform transform

logger "-->Configuring CCN role for transform"
vault write /data-protection/masking/transform/role/ccn transformations=ccn


logger "-->Configuring transformation template"
vault write /data-protection/masking/transform/transformation/ccn \
        type=masking \
        template="card-mask" \
        masking_character="#" \
        allowed_roles=ccn
        
logger "-->Configuring template masking"
vault write /data-protection/masking/transform/template/card-mask type=regex \
        pattern="(\d{4})-(\d{4})-(\d{4})-\d{4}" \
        alphabet="builtin/numeric"
        
logger "-->Test transform"
vault write /data-protection/masking/transform/encode/ccn value=2345-2211-3333-4356

logger "-->Installing Oracle DB plugin"
sudo wget -P /tmp/ https://releases.hashicorp.com/vault-plugin-database-oracle/0.2.1/vault-plugin-database-oracle_0.2.1_linux_amd64.zip 

sudo unzip -q /tmp/vault-plugin-database-oracle_0.2.1_linux_amd64.zip -d /etc/vault.d/plugins/
sudo chmod +x /etc/vault.d/plugins/vault-plugin-database-oracle

shasum -a 256 /etc/vault.d/plugins/vault-plugin-database-oracle > /tmp/oracle-plugin.sha256
sudo chmod 777 /tmp/oracle-plugin.sha256
#sudo setcap cap_ipc_lock=+ep /etc/vault.d/plugins/vault-plugin-database-oracle

logger "==> Enable Oracle Plugin"
vault write sys/plugins/catalog/database/vault-plugin-database-oracle \
    sha256=$(cat /tmp/oracle-plugin.sha256 | head -n1 | awk '{print $1;}') \
    command="vault-plugin-database-oracle"

logger "==> Enable Database path"
vault secrets enable database

logger "==> Configuring Oracle Plugin"
vault write database/config/oracle  \
    plugin_name=vault-plugin-database-oracle \
    allowed_roles="*" \
    connection_url='{{username}}/{{password}}@//${rds_address}:1521/VAULT' \
    username='${rds_username}' \
    password='${rds_password}'

logger "==> Configuring Oracle DB role"
vault write database/roles/my-role db_name=oracle creation_statements="CREATE USER {{name}} IDENTIFIED BY {{password}};GRANT SELECT ON session_privs TO {{name}};" default_ttl="1h" max_ttl="24h"

logger "==> Creating Oracle DB Dynamic secret"
vault read database/creds/my-role

logger "==> Vault is done!"