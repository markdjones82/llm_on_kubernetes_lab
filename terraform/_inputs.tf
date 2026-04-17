variable "env" {
  type        = string
  description = "Environment name (dev, test, prod, etc.)"
  default     = "dev"
}

variable "account_name" {
  type        = string
  description = "Friendly AWS account name — used in default_tags."
  default     = "my-aws-account"
}

variable "subnet_id" {
  type        = string
  description = "Existing subnet ID to place all cluster nodes in. Preferred over subnet_name when you already know the subnet."
  default     = ""
}

variable "subnet_name" {
  type        = string
  description = "Name tag of the existing subnet to place all cluster nodes in. Use only when subnet_id is not set."
  default     = ""
}

variable "region" {
  type        = string
  description = "AWS region"
  default     = "us-east-1"
}

variable "instance_type_control_plane" {
  type        = string
  description = "EC2 instance type for the Kubernetes control plane node (min: 2 vCPU, 4GB RAM)"
  default     = "t3.medium"
}

variable "instance_type_worker" {
  type        = string
  description = "EC2 instance type for Kubernetes worker nodes"
  default     = "t3.large"
}

variable "worker_count" {
  type        = number
  description = "Number of CPU-only worker nodes"
  default     = 2
}

variable "enable_gpu_node" {
  type        = bool
  description = "Whether to provision a GPU-enabled worker node"
  default     = false
}

variable "instance_type_gpu" {
  type        = string
  description = "EC2 instance type for the GPU node (requires enable_gpu_node = true)"
  default     = "g5.xlarge"
}

variable "allowed_ssh_cidrs" {
  type        = list(string)
  description = "CIDR blocks allowed to SSH into cluster nodes. Restrict to your IP for safety."
  default     = ["0.0.0.0/0"]
}

variable "volume_size_gb" {
  type        = number
  description = "Root EBS volume size in GB for non-GPU instances (lab minimum: 40)"
  default     = 40
}

variable "ami_id" {
  type        = string
  description = "Override AMI ID for CPU nodes. Leave empty to use Ubuntu 24.04 LTS from Canonical."
  default     = ""
}

variable "gpu_ami_id" {
  type        = string
  description = "Override AMI ID for the GPU node. Leave empty to use Ubuntu 24.04 LTS from Canonical."
  default     = ""
}

variable "k8s_version" {
  type        = string
  description = "Kubernetes minor version (e.g. '1.35'). Used to select the kubeadm/kubectl apt repo and install the matching packages in userdata."
  default     = "1.35"
}

