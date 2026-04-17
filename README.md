# Kubernetes AI Agent Generic

Terraform scaffolding for a small Kubernetes + GPU lab that runs inside an
**existing AWS VPC and subnet**.

---

## Alternative Setup: Without AWS

You can follow the [LAB_GUIDE](LAB_GUIDE.md) **without AWS infrastructure setup**. The guide is designed to work with:

- **Vanilla Kubernetes clusters** (any provider or on-premises)
- **Local development clusters** (Kind, K3s, minikube, etc.)
- **Existing managed Kubernetes** (EKS, GKE, AKS, etc.)

Simply skip the Terraform steps below and start with the Kubernetes setup instructions in the LAB_GUIDE.
---

## What Gets Provisioned

| Resource | Details |
|---|---|
| Networking | Uses your existing VPC and one existing subnet |
| Control Plane | 1× EC2 instance |
| Worker Nodes | 0..n EC2 instances |
| GPU Node _(optional)_ | 0 or 1 EC2 instance |
| AMI | Ubuntu 24.04 LTS (latest Canonical image by default) |
| SSH Key Pair | Auto-generated RSA-4096, saved under [terraform/](terraform/) |
| IAM Node Role | SSM + ECR read + CloudWatch |
| Security Group | K8s API, SSH, NodePort, overlay-network, and storage ports |
---

## Requirements for an Existing VPC/Subnet

Before you run Terraform, make sure the target subnet and VPC meet these
requirements:

1. **Existing subnet ID or unique subnet name**
   - Prefer `subnet_id` in the tfvars file.
   - `subnet_name` also works, but only if the `Name` tag is unique in the region.

2. **Enough free IP addresses**
   - You need room for at least the control plane plus however many worker nodes
     and optional GPU nodes you enable.

3. **Outbound access for package installs and image pulls**
   - The instances need egress to reach Ubuntu package repositories, Helm,
     container registries, and GitHub/GHCR.
   - In a private subnet, this usually means a **NAT gateway/NAT instance**.
   - If you rely on SSM without general internet egress, you still need either
     NAT or the appropriate **VPC endpoints** for SSM-related services and any
     package/image sources you use.

4. **DNS support enabled on the VPC**
   - VPC DNS resolution/hostnames should be enabled so package repositories and
     cluster components can resolve external names cleanly.

5. **AWS permissions**
   - Your credentials need permission to create EC2 instances, IAM roles,
     instance profiles, security groups, and key pairs in the target account.

6. **Access CIDRs chosen deliberately**
   - Set `allowed_ssh_cidrs` to the office/VPN/workstation CIDRs that should be
     allowed to reach SSH, the Kubernetes API on `6443`, and NodePort services.
---

## Quick Start

### 1. Copy the example tfvars file

```bash
cd terraform
cp vars/example.tfvars vars/myenv.tfvars
```

### 2. Edit the required values

At minimum, set these in [terraform/vars/example.tfvars](terraform/vars/example.tfvars):

- `account_name`
- `region`
- `subnet_id` **or** `subnet_name`
- `allowed_ssh_cidrs`

Common optional changes:

- `worker_count`
- `enable_gpu_node`
- `instance_type_gpu`
- `k8s_version`

### 3. Initialize and plan

```bash
terraform init
terraform plan -var-file=vars/myenv.tfvars
```

### 4. Apply

```bash
terraform apply -var-file=vars/myenv.tfvars
```

### 5. Connect to the instances

SSM is usually the easiest path:

```bash
aws ssm start-session --target <instance-id>
```

Or use the Terraform outputs for SSH over private IPs from a routable network:

```bash
terraform output ssh_connect_control_plane
terraform output ssh_connect_workers
```

### 6. Destroy when finished

```bash
terraform destroy -var-file=vars/myenv.tfvars
```

---

## Notes

- All nodes are placed in **one subnet** for simplicity.
- The code does **not** create a VPC, subnet, NAT gateway, or internet gateway.
- `subnet_id` is preferred for generic reuse because it avoids any dependency on
  local subnet naming conventions.
- The generated SSH private key filename is based on the environment name, for
  example `kubernetes-ai-agent-dev.pem`.

---

## Directory Structure

```
terraform/
├── versions.tf           # Terraform + provider version constraints
├── _providers.tf         # AWS provider and shared tags
├── _inputs.tf            # Input variables
├── _outputs.tf           # Useful outputs
├── vpc.tf                # Existing subnet lookup and derived VPC values
├── security_groups.tf    # K8s / SSH / NodePort / storage security group rules
├── ec2.tf                # Control plane, workers, optional GPU node
├── iam.tf                # Node IAM role and instance profile
├── key_pair.tf           # Generated SSH key pair
├── userdata/
│   ├── common.sh.tftpl   # Base cloud-init for CPU nodes
│   └── gpu.sh.tftpl      # Base cloud-init for GPU node
└── vars/
    └── example.tfvars    # Generic example values for existing VPC/subnet use
```

