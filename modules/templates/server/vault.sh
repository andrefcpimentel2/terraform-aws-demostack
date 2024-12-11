#!/usr/bin/env bash
echo "--> clean up any default config."
sudo rm  /etc/vault.d/*



echo "==> Vault (server)"
# Vault expects the key to be concatenated with the CA
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

storage "consul" {
  address = "http://$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4):8500"
  path = "vault/"
  service = "vault"
  token="${consul_master_token}"
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
  dogstatsd_addr = "localhost:8125"
  enable_hostname_label = true
  prometheus_retention_time = "0h"
}

replication {
      resolver_discover_servers = false
}

api_addr = "https://$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4):8200"
# api_addr = "https://vault.service.${region}.consul:8200"
# api_addr = "${vault_api_addr}"
plugin_directory = "/etc/vault.d/plugins"
disable_mlock = true
ui = true
EOF

echo "--> Writing profile"
sudo tee /etc/profile.d/vault.sh > /dev/null <<"EOF"
alias vualt="vault"
export VAULT_ADDR="https://active.vault.service.consul:8200"
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

echo "--> Initializing vault"
export CONSUL_HTTP_TOKEN=${consul_master_token}
consul lock -name=vault-init tmp/vault/lock "$(cat <<"EOF"
set -e
sleep 2
export VAULT_ADDR="https://127.0.0.1:8200"
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

echo "--> Attempting to create nomad role"

  echo "--> Adding Nomad policy"
  echo "--> Retrieving root token..."
 export VAULT_TOKEN=$(consul kv get service/vault/root-token)

  export VAULT_ADDR="https://active.vault.service.consul:8200"
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


echo "==> Start Monitoring setup"

echo "==> Start Fluentd"

sudo apt install ntp
curl -fsSL https://toolbelt.treasuredata.com/sh/install-ubuntu-jammy-fluent-package5-lts.sh | sh
sleep 5
fluent-gem install fluent-plugin-splunk-enterprise

sudo tee /etc/fluent/fluentd.conf > /dev/null <<"EOF"
<source>
  @type tail
  path /vault/logs/vault-audit.log
  pos_file /vault/logs/vault-audit-log.pos
  <parse>
    @type json
    time_format %iso8601
  </parse>
  tag vault_audit
</source>

<filter vault_audit>
  @type record_transformer
  <record>
    cluster v5
  </record>
</filter>

<match vault_audit.**>
  @type splunk_hec
  hec_host ${splunk_addr}
  hec_port ${splunk_port}
  hec_token ${fluentd_splunk_token}
</match>
EOF

sudo systemctl restart td-agent
sleep 10

echo "==> Start Telegraf"

curl --silent --location -O \
https://repos.influxdata.com/influxdata-archive.key \
&& echo "943666881a1b8d9b849b74caebf02d3465d6beb716510d86a39f6c8e8dac7515  influxdata-archive.key" \
| sha256sum -c - && cat influxdata-archive.key \
| gpg --dearmor \
| sudo tee /etc/apt/trusted.gpg.d/influxdata-archive.gpg > /dev/null \
&& echo 'deb [signed-by=/etc/apt/trusted.gpg.d/influxdata-archive.gpg] https://repos.influxdata.com/debian stable main' \
| sudo tee /etc/apt/sources.list.d/influxdata.list
sudo apt-get update && sudo apt-get install telegraf

sudo tee /etc/telegraf/telegraf.conf > /dev/null <<"EOF"

# Global tags relate to and are available for use in Splunk searches
# Of particular note are the index tag, which is required to match the
# configured metrics index name and the cluster tag which should match the
# value of Vault's cluster_name configuration option value.

[global_tags]
  index="vault-metrics"
  datacenter = "us-east-1"
  role       = "vault-server"
  cluster    = "vtl"

# Agent options around collection interval, sizes, jitter and so on
[agent]
  interval = "10s"
  round_interval = true
  metric_batch_size = 1000
  metric_buffer_limit = 10000
  collection_jitter = "0s"
  flush_interval = "10s"
  flush_jitter = "0s"
  precision = ""
  hostname = ""
  omit_hostname = false

# An input plugin that listens on UDP/8125 for statsd compatible telemetry
# messages using Datadog extensions which are emitted by Vault
[[inputs.statsd]]
  protocol = "udp"
  service_address = ":8125"
  metric_separator = "."
  datadog_extensions = true

# An output plugin that can transmit metrics over HTTP to Splunk
# You must specify a valid Splunk HEC token as the Authorization value
[[outputs.http]]
  url = "https://${splunk_addr}:${splunk_port}/services/collector"
  data_format="splunkmetric"
  splunkmetric_hec_routing=true
  [outputs.http.headers]
    Content-Type = "application/json"
    Authorization = "Splunk ${telegraf_splunk_token}"

# Read metrics about cpu usage using default configuration values
[[inputs.cpu]]
  percpu = true
  totalcpu = true
  collect_cpu_time = false
  report_active = false

# Read metrics about memory usage
[[inputs.mem]]
  # No configuration required

# Read metrics about swap memory usage
[[inputs.swap]]
  # No configuration required

# Read metrics about disk usage using default configuration values
[[inputs.disk]]
  ## By default stats will be gathered for all mount points.
  ## Set mount_points will restrict the stats to only the specified mount points.
  ## mount_points = ["/"]
  ## Ignore mount points by filesystem type.
  ignore_fs = ["tmpfs", "devtmpfs", "devfs", "iso9660", "overlay", "aufs", "squashfs"]

[[inputs.diskio]]
  # devices = ["sda", "sdb"]
  # skip_serial_number = false

[[inputs.kernel]]
  # No configuration required

[[inputs.linux_sysctl_fs]]
  # No configuration required

[[inputs.net]]
  # Specify an interface or all
  # interfaces = ["enp0s*"]

[[inputs.netstat]]
  # No configuration required

[[inputs.processes]]
  # No configuration required

[[inputs.procstat]]
 pattern = "(vault)"

[[inputs.system]]
  # No configuration required
EOF

sudo systemctl restart telegraf
sleep 10

echo "==> Monitoring is done!"

vault audit enable file file_path=/vault/logs/vault-audit.log mode=744

echo "==> Vault is done!"

