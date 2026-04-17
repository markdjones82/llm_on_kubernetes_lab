output "control_plane_private_ip" {
  description = "Private IP of the Kubernetes control plane node"
  value       = aws_instance.control_plane.private_ip
}

output "worker_private_ips" {
  description = "Private IPs of the Kubernetes worker nodes"
  value       = aws_instance.workers[*].private_ip
}

output "gpu_node_private_ip" {
  description = "Private IP of the GPU worker node (null if not enabled)"
  value       = var.enable_gpu_node ? aws_instance.gpu_node[0].private_ip : null
}

output "vpc_id" {
  description = "ID of the VPC containing the selected subnet"
  value       = local.vpc_id
}

output "subnet_id" {
  description = "ID of the subnet used by all cluster nodes"
  value       = local.subnet_id
}

output "ssh_private_key_path" {
  description = "Local path to the generated SSH private key file"
  value       = local_file.private_key.filename
  sensitive   = true
}

output "ssh_connect_control_plane" {
  description = "SSH command to connect to the control plane node (requires internal network / VPN access)"
  value       = "ssh -i ./${basename(local_file.private_key.filename)} ubuntu@${aws_instance.control_plane.private_ip}"
}

output "ssh_connect_workers" {
  description = "SSH commands to connect to each worker node (requires internal network / VPN access)"
  value = [
    for i, ip in aws_instance.workers[*].private_ip :
    "ssh -i ./${basename(local_file.private_key.filename)} ubuntu@${ip}  # worker-${i + 1}"
  ]
}
