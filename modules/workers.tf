
# Gzip cloud-init config
data "cloudinit_config" "workers" {
  count = var.workers

  gzip          = true
  base64_encode = true

  #base
  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/templates/shared/base.sh", {
      region      = var.region
      enterprise  = var.enterprise
      node_name   = "${var.namespace}-worker-${count.index}"
      me_ca       = tls_self_signed_cert.root.cert_pem
      me_cert     = element(tls_locally_signed_cert.workers.*.cert_pem, count.index)
      me_key      = element(tls_private_key.workers.*.private_key_pem, count.index)
      vault0_cert = tls_locally_signed_cert.workers.0.cert_pem
      vault0_key  = tls_private_key.workers.0.private_key_pem
      public_key  = var.public_key
    })
  }

  #docker
  part {
    content_type = "text/x-shellscript"
    content      = file("${path.module}/templates/shared/docker.sh")
  }

  #consul
  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/templates/workers/consul.sh", {
      node_name = "${var.namespace}-worker-${count.index}"
      region    = var.region
      # Consul
      consullicense         = var.consullicense
      consul_gossip_key     = var.consul_gossip_key
      consul_join_tag_key   = "ConsulJoin"
      consul_join_tag_value = var.consul_join_tag_value
      consul_master_token   = var.consul_master_token
    })
  }

  #nomad
  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/templates/workers/nomad.sh", {
      node_name      = "${var.namespace}-worker-${count.index}"
      vault_api_addr = "https://${aws_route53_record.vault.fqdn}:8200"
      # Nomad
      cni_version = var.cni_version
    })
  }
  #EBS
  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/templates/workers/ebs_volumes.sh", {
      region         = var.region
      run_nomad_jobs = var.run_nomad_jobs
      nomad_servers  = var.servers
      # Nomad EBS Volumes
      index                        = count.index + 1
      count                        = var.workers
      dc1                          = data.aws_availability_zones.available.names[0]
      dc2                          = data.aws_availability_zones.available.names[1]
      dc3                          = data.aws_availability_zones.available.names[2]
      aws_ebs_volume_mysql_id      = aws_ebs_volume.shared.id
      aws_ebs_volume_mongodb_id    = aws_ebs_volume.mongodb.id
      aws_ebs_volume_prometheus_id = aws_ebs_volume.prometheus.id
      aws_ebs_volume_ollama_id     = aws_ebs_volume.ollama.id
      aws_ebs_volume_shared_id     = aws_ebs_volume.shared.id
    })
  }
  #end
}

resource "aws_iam_role" "nomad_worker" {
  name = "nomad_worker"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "mount_ebs_volumes" {
  name   = "mount-ebs-volumes"
  role   = aws_iam_role.nomad_worker.id
  policy = data.aws_iam_policy_document.mount_ebs_volumes.json
}

data "aws_iam_policy_document" "mount_ebs_volumes" {
  statement {
    effect = "Allow"

    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeTags",
      "ec2:DescribeVolumes",
      "ec2:AttachVolume",
      "ec2:DetachVolume",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_instance_profile" "nomad_worker" {
  name = "nomad_worker"
  role = aws_iam_role.nomad_worker.name
}

resource "aws_instance" "workers" {
  count = var.workers

  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type_worker
  key_name      = aws_key_pair.demostack.id

  subnet_id            = element(aws_subnet.demostack.*.id, count.index)
  iam_instance_profile = aws_iam_instance_profile.nomad_worker.name

  vpc_security_group_ids = [aws_security_group.demostack.id]
  lifecycle {
    ignore_changes = all
  }

  root_block_device {
    volume_size           = "240"
    delete_on_termination = "true"
  }

  ebs_block_device {
    device_name           = "/dev/xvdd"
    volume_type           = "gp2"
    volume_size           = "240"
    delete_on_termination = "true"
  }

  tags = merge(local.common_tags, {
    ConsulJoin = "${var.consul_join_tag_value}",
    Purpose    = var.namespace,
    Function   = "worker"
    Name       = "${var.namespace}-worker-${count.index}",
    }
  )

  user_data_base64 = element(data.cloudinit_config.workers.*.rendered, count.index)
}
