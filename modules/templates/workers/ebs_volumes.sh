#!/usr/bin/env bash



echo "--> Configuring EBS mounts"

echo "--> Ollama"
{
sudo tee  /etc/nomad.d/default_jobs/ollama_ebs_volume.hcl > /dev/null <<EOF
# volume registration
type  = "host"
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

####


echo "--> Waiting for all Nomad servers"
while [ "$(nomad server members 2>&1 | grep "alive" | wc -l)" -lt "${nomad_servers}" ]; do
  sleep 5
done


nomad volume register /etc/nomad.d/default_jobs/ollama_ebs_volume.hcl



echo "==> Configuring EBS mounts is Done!"