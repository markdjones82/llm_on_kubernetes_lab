resource "aws_security_group" "k8s_nodes" {
  name        = "${local.name_prefix}-k8s-nodes"
  description = "Security group for all Kubernetes cluster nodes"
  vpc_id      = local.vpc_id

  # SSH — internal network / VPN access only (set allowed_ssh_cidrs in vars)
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  # Kubernetes API server — internal access from your workstation via VPN
  ingress {
    description = "Kubernetes API Server"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  # All intra-cluster traffic (self-referencing)
  ingress {
    description = "All intra-cluster traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  # etcd
  ingress {
    description = "etcd server client API"
    from_port   = 2379
    to_port     = 2380
    protocol    = "tcp"
    self        = true
  }

  # kubelet, kube-scheduler, kube-controller-manager health
  ingress {
    description = "Kubelet API, kube-scheduler, kube-controller-manager"
    from_port   = 10250
    to_port     = 10259
    protocol    = "tcp"
    self        = true
  }

  # NodePort services — access Ollama and other apps from your internal network
  ingress {
    description = "NodePort Services"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  # Flannel VXLAN overlay
  ingress {
    description = "Flannel VXLAN"
    from_port   = 8472
    to_port     = 8472
    protocol    = "udp"
    self        = true
  }

  # Calico BGP
  ingress {
    description = "Calico BGP"
    from_port   = 179
    to_port     = 179
    protocol    = "tcp"
    self        = true
  }

  # Rook/Ceph storage ports (lab segment 5)
  ingress {
    description = "Ceph OSD"
    from_port   = 6800
    to_port     = 7300
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "Ceph MON"
    from_port   = 6789
    to_port     = 6789
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-k8s-nodes-sg"
  }
}
