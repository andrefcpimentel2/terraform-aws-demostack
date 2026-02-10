#!/usr/bin/env bash




####


echo "--> Waiting for all Nomad servers"
while [ "$(nomad server members 2>&1 | grep "alive" | wc -l)" -lt "${nomad_servers}" ]; do
  sleep 5
done

echo "--> Configuring EBS mounts"

export NODE_ID=$(nomad node status -self | grep ID | awk -F '=' '{print $2}'

echo "--> Ollama"
{
sudo tee  /etc/nomad.d/default_jobs/ollama_ebs_volume.hcl > /dev/null <<EOF
# volume registration
type  = "host"
node_id = "$NODE_ID"
name = "ollama"
capacity = "80GB"
capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}
plugin_id = "mkdir"
EOF
} || {
    echo "--> ollama failed, probably already done"
}



nomad volume register /etc/nomad.d/default_jobs/ollama_ebs_volume.hcl



echo "==> Configuring EBS mounts is Done!"