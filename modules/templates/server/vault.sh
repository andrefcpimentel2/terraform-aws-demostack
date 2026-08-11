#!/usr/bin/env bash

echo "==> getting the aws metadata token"
export TOKEN=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

echo "==> check token was set"
echo $TOKEN


echo "--> clean up any default config."
sudo rm  /etc/vault.d/*



echo "==> Vault (server)"
# Vault expects the key to be concatenated with the CA
sudo mkdir -p /mnt/vault
sudo mkdir -p /etc/vault.d/tls/
sudo mkdir -p /etc/vault.d/plugins/
sudo tee /etc/vault.d/tls/vault.crt > /dev/null <<EOF
$(cat /etc/ssl/certs/me.crt)
$(cat /usr/local/share/ca-certificates/01-me.crt)
EOF


echo "--> Writing configuration"
sudo mkdir -p /etc/vault.d
sudo tee /etc/vault.d/config.hcl > /dev/null <<EOF
cluster_name = "${namespace}-demostack"

# storage "consul" {
#   address = "http://$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/local-ipv4):8500"
#   path = "vault/"
#   service = "vault"
#   token="${consul_master_token}"
# }

service_registration "consul" {
  address = "http://$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/local-ipv4):8500"
  service = "vault"
  token="${consul_master_token}"
}


  storage "raft" {
  path    = "/mnt/vault"
  node_id = "vault_${node_name}"
  retry_join {
    auto_join = "provider=aws tag_key=${vault_join_tag_key} tag_value=${vault_join_tag_value} addr_type=private_v4"
    leader_tls_servername = "${namespace}-server-0.node.consul"
    leader_ca_cert_file = "/usr/local/share/ca-certificates/01-me.crt"
    leader_client_cert_file = "/etc/vault.d/tls/vault.crt"
    leader_client_key_file = "/etc/ssl/certs/me.key"
  }

}


plugin_directory = "/etc/vault.d/plugins"


listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/etc/vault.d/tls/vault.crt"
  tls_key_file  = "/etc/ssl/certs/me.key"
  # tls_min_version = "tls13"
  # tls-skip-verify = true
  http_idle_timeout = "30s"
  redact_version = true
  custom_response_headers {
    "default" = {
      "Clear-Site-Data" = [ "*","\"cache\"", "\"cookies\"", "\"storage\"", "\"executionContexts\""]
    }
  }
 }


seal "awskms" {
  region = "${region}"
  kms_key_id = "${kmskey}"
}
telemetry {
  prometheus_retention_time = "30s"
  disable_hostname          = true
}
replication {
      resolver_discover_servers = false
}
api_addr = "https://$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/local-ipv4):8200"
cluster_addr = "https://$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/local-ipv4):8201"
# api_addr = "${vault_api_addr}"
disable_mlock = true
ui = true
raw_storage_endpoint = true
EOF

echo "--> Writing profile"
sudo tee /etc/profile.d/vault.sh > /dev/null <<"EOF"
alias vualt="vault"
export VAULT_ADDR="https://$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/local-ipv4):8200"
EOF
source /etc/profile.d/vault.sh

echo "--> Generating systemd configuration"
sudo tee /etc/systemd/system/vault.service > /dev/null <<"EOF"
[Unit]
Description=Vault
Documentation=https://www.vaultproject.io/docs/
Requires=network-online.target
After=network-online.target
[Service]
Restart=on-failure
ExecStart=/usr/bin/vault server -config="/etc/vault.d/config.hcl"
ExecReload=/bin/kill -HUP $MAINPID
#Enterprise License
Environment=VAULT_LICENSE=${vaultlicense}
KillSignal=SIGINT
[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable vault
sudo systemctl start vault
sleep 8
if [ "${node_name}" == "${namespace}-server-0" ]
then
echo "--> Initializing vault from server 0"
export CONSUL_HTTP_TOKEN=${consul_master_token}
consul lock -name=vault-init tmp/vault/lock "$(cat <<"EOF"
set -e
sleep 2
export VAULT_ADDR="https://$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/local-ipv4):8200"
export VAULT_SKIP_VERIFY=true
if ! vault operator init -status >/dev/null; then
  vault operator init  -recovery-shares=1 -recovery-threshold=1  > /tmp/out.txt
  cat /tmp/out.txt | grep "Recovery Key 1" | sed 's/Recovery Key 1: //' | consul kv put service/vault/recovery-key -
   cat /tmp/out.txt | grep "Initial Root Token" | sed 's/Initial Root Token: //' | consul kv put service/vault/root-token -

export VAULT_TOKEN=$(consul kv get service/vault/root-token)
echo "ROOT TOKEN: $VAULT_TOKEN"

sudo systemctl enable vault
sudo systemctl restart vault
else
export VAULT_ADDR="https://$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/local-ipv4):8200"
export VAULT_SKIP_VERIFY=true
export VAULT_TOKEN=$(consul kv get service/vault/root-token)
echo "ROOT TOKEN: $VAULT_TOKEN"
sudo systemctl enable vault
sudo systemctl restart vault
fi
sleep 8
EOF
)"
fi



echo "--> Waiting for Vault to be active"
VAULT_ADDR="https://$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/local-ipv4):8200"
URL="$VAULT_ADDR/v1/sys/health"
HTTP_STATUS=0

while [[ $HTTP_STATUS -ne 200 && $HTTP_STATUS -ne 473 && $HTTP_STATUS -ne 429 ]]; do
  HTTP_STATUS=$(curl -k -o /dev/null -w "%%{http_code}" $URL)
  sleep 1
done

echo "HTTP status code is either 200 or 473. Continuing with the script..."

export VAULT_TOKEN=$(consul kv get service/vault/root-token)
export VAULT_ADDR="https://$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/local-ipv4):8200"
export VAULT_SKIP_VERIFY=true

if [ "${node_name}" == "${namespace}-server-0" ]
then
  echo "--> Enabling Vault file audit device"
  {
    vault audit enable file file_path=/var/log/vault_audit.log
  } ||
  {
    echo "--> Vault file audit device already enabled, moving on"
  }
fi


echo "--> Attempting to create nomad role"

  echo "--> Adding Nomad policy"
  echo "--> Retrieving root token..."
 export VAULT_TOKEN=$(consul kv get service/vault/root-token)

  export VAULT_ADDR="https://$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/local-ipv4):8200"
  export VAULT_SKIP_VERIFY=true

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

if [ ${index} == ${count} ]
then
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
else
echo "--> not the last worker, skip PKI config"
fi
echo "==> Configuring PKI mounts is Done!"

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

# all access to boundary namespace
path "boundary/*" {
    capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}


EOR
} ||
{
  echo "--> superuser role already configured, moving on"
}


echo "-->Boundary setup"
{
vault namespace create boundary
 }||
{
  echo "--> Boundary namespace already created, moving on"
}

echo "-->mount transit in boundary namespace"
{

vault secrets enable  -namespace=boundary -path=transit transit

 }||
{
  echo "--> transit already mounted, moving on"
}

echo "--> creating boundary root key"
{
vault  write -namespace=boundary -f  transit/keys/root
 }||
{
  echo "--> root key already exists, moving on"
}

echo "--> creating boundary worker-auth key"
{
vault write -namespace=boundary  -f  transit/keys/worker-auth

 }||
{
  echo "--> worker-auth key already exists, moving on"
}


echo "==> Vault audit logs to splunk"

echo "--> Install fluentbit"
sudo sh -c 'curl https://packages.fluentbit.io/fluentbit.key | gpg --dearmor > /usr/share/keyrings/fluentbit-keyring.gpg'
codename=$(grep -oP '(?<=VERSION_CODENAME=).*' /etc/os-release 2>/dev/null || lsb_release -cs 2>/dev/null)
echo "deb [signed-by=/usr/share/keyrings/fluentbit-keyring.gpg] https://packages.fluentbit.io/ubuntu/$codename $codename main" | sudo tee /etc/apt/sources.list.d/fluent-bit.list
sudo apt-get update
sudo apt-get install fluent-bit
sudo fluent-bit -c /etc/fluent-bit/fluent-bit.yaml
sudo tee /etc/fluent-bit/fluent-bit.yaml > /dev/null <<EOF
# Fluent Bit example configuration for Vault servers

# local environment variables
env:
    flush_interval: 1

# service configuration
service:
    flush:       ${flush_interval}
    log_level:   info
    http_server: off
    hc_http_status: on
    hc_period: 5
    hc_errors_count: 5
    hc_retry_failure_count: 5

parsers:
  - name: json
    format: json
  - name: vault_audit
    format: json
    time_key: time
    time_format: '%Y-%m-%dT%H:%M:%S %z'

pipeline:
    inputs:
        # Vault file audit device
        - name: tail
          path: /var/log/vault_audit.log
          parser: json
          tag: vault-audit
        # Vault telemetry metrics
        - name: statsd
          listen: 0.0.0.0
          metrics: on
          port: 8125
          tag: vault-metrics
        # System metrics
        - name: cpu
          tag: vault-system
        - name: disk
          tag: vault-system
          interval_sec: 1
          interval_nsec: 0
        - name: mem
          tag: vault-system
        - name: netif
          tag: vault-system
          interval_sec: 1
          interval_nsec: 0
          interface: ens4
        - name: proc
          proc_name: vault
          interval_sec: 1
          interval_nsec: 0
          fd: true
          mem: true
          tag: vault-system
    outputs:
        - name: splunk
          match: vault-metrics
          host: ${splunk_hec_url}
          port: 8088
          splunk_send_raw: on
          splunk_token: ${}
          tls: off
        - name: splunk
          match: vault-audit
          host: ${splunk_hec_url}
          port: 8088
          splunk_send_raw: off
          splunk_token: ${splunk_hec_token}
          tls: off
        - name: splunk
          match: vault-system
          host: ${splunk_hec_url}
          port: 8088
          splunk_send_raw: off
          splunk_token: ${splunk_hec_token}
          tls: off

EOF

sudo systemctl start fluent-bit

echo "==> Vault is done!"