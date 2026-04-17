# Ubuntu 24.04 LTS (Noble) — official Canonical AMI.
# Both CPU and GPU nodes use the same base image; GPU-specific packages
# (NVIDIA drivers, nvidia-container-toolkit) are installed by userdata.
data "aws_ami" "ubuntu_24" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  # var.ami_id allows a one-off override for any node.
  # Default is the latest Ubuntu 24.04 LTS from Canonical.
  cpu_node_ami = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu_24.id
  gpu_node_ami = var.gpu_ami_id != "" ? var.gpu_ami_id : data.aws_ami.ubuntu_24.id
}

# ---------------------------------------------------------------------------
# Control Plane Node  (1x t3.medium — 2 vCPU / 4 GB / 40 GB)
# ---------------------------------------------------------------------------
resource "aws_instance" "control_plane" {
  ami                    = local.cpu_node_ami
  instance_type          = var.instance_type_control_plane
  subnet_id              = local.subnet_id
  key_name               = aws_key_pair.k8s_lab.key_name
  vpc_security_group_ids = [aws_security_group.k8s_nodes.id]
  iam_instance_profile   = aws_iam_instance_profile.k8s_node.name

  root_block_device {
    volume_size           = var.volume_size_gb
    volume_type           = "gp3"
    delete_on_termination = true
    tags = {
      Name = "${local.name_prefix}-control-plane-root"
    }
  }

  user_data = base64encode(templatefile("${path.module}/userdata/common.sh.tftpl", {
    hostname        = "k8s-control-plane"
    k8s_version     = var.k8s_version
    ssh_private_key = tls_private_key.k8s_lab.private_key_pem
  }))

  tags = {
    Name = "${local.name_prefix}-control-plane"
    Role = "control-plane"
  }
}

# ---------------------------------------------------------------------------
# CPU Worker Nodes  (2x t3.large — 2 vCPU / 8 GB / 40 GB each)
# ---------------------------------------------------------------------------
resource "aws_instance" "workers" {
  count                  = var.worker_count
  ami                    = local.cpu_node_ami
  instance_type          = var.instance_type_worker
  subnet_id              = local.subnet_id
  key_name               = aws_key_pair.k8s_lab.key_name
  vpc_security_group_ids = [aws_security_group.k8s_nodes.id]
  iam_instance_profile   = aws_iam_instance_profile.k8s_node.name

  root_block_device {
    volume_size           = var.volume_size_gb
    volume_type           = "gp3"
    delete_on_termination = true
    tags = {
      Name = "${local.name_prefix}-worker-${count.index + 1}-root"
    }
  }

  user_data = base64encode(templatefile("${path.module}/userdata/common.sh.tftpl", {
    hostname        = "k8s-worker-${count.index + 1}"
    k8s_version     = var.k8s_version
    ssh_private_key = ""
  }))

  tags = {
    Name = "${local.name_prefix}-worker-${count.index + 1}"
    Role = "worker"
  }
}

# ---------------------------------------------------------------------------
# GPU Worker Node  (optional — g4dn.xlarge: 4 vCPU / 16 GB / NVIDIA T4)
# Enable with: enable_gpu_node = true in vars
# ---------------------------------------------------------------------------
resource "aws_instance" "gpu_node" {
  count                  = var.enable_gpu_node ? 1 : 0
  ami                    = local.gpu_node_ami
  instance_type          = var.instance_type_gpu
  subnet_id              = local.subnet_id
  key_name               = aws_key_pair.k8s_lab.key_name
  vpc_security_group_ids = [aws_security_group.k8s_nodes.id]
  iam_instance_profile   = aws_iam_instance_profile.k8s_node.name

  root_block_device {
    # Extra space for NVIDIA drivers, CUDA toolkit, and LLM model weights (multiple models)
    volume_size           = 150
    volume_type           = "gp3"
    delete_on_termination = true
    tags = {
      Name = "${local.name_prefix}-gpu-worker-root"
    }
  }

  user_data = base64encode(templatefile("${path.module}/userdata/gpu.sh.tftpl", {
    hostname    = "k8s-gpu-worker"
    k8s_version = var.k8s_version
  }))

  tags = {
    Name = "${local.name_prefix}-gpu-worker"
    Role = "gpu-worker"
  }
}
