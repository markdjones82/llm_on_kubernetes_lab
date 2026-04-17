env          = "dev"
region       = "us-east-1"
account_name = "my-aws-account"

# ---------------------------------------------------------------------------
# Existing network placement
# Set ONE of these. subnet_id is preferred because it avoids tag ambiguity.
# ---------------------------------------------------------------------------
# subnet_id = "subnet-0123456789abcdef0"  # Replace with your own subnet ID
# subnet_name = "private-apps-us-east-1a"  # Or use a unique subnet name
# ---------------------------------------------------------------------------
# Cluster sizing (lab minimums: 2 vCPU, 4 GB RAM, 40 GB disk)
# ---------------------------------------------------------------------------
instance_type_control_plane = "t3.medium"
instance_type_worker        = "t3.large"
worker_count                = 1
volume_size_gb              = 40

# ---------------------------------------------------------------------------
# GPU node (optional) — enable for GPU Operator / llama.cpp labs
# ---------------------------------------------------------------------------
enable_gpu_node   = true
instance_type_gpu = "g5.xlarge"

# ---------------------------------------------------------------------------
# Kubernetes version + AMI overrides
# Leave AMI values commented unless you need a specific image.
# ---------------------------------------------------------------------------
k8s_version = "1.35"
# ami_id     = "ami-xxxxxxxxxxxxxxxxx"
# gpu_ami_id = "ami-yyyyyyyyyyyyyyyyy"

# ---------------------------------------------------------------------------
# Access
# Restrict to your office/VPN/workstation CIDRs.
# Used for SSH, Kubernetes API (6443), and NodePort access.
# ---------------------------------------------------------------------------
allowed_ssh_cidrs = ["203.0.113.10/32"]