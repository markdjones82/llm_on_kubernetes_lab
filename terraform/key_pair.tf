resource "tls_private_key" "k8s_lab" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "k8s_lab" {
  key_name   = "${local.name_prefix}-keypair"
  public_key = tls_private_key.k8s_lab.public_key_openssh

  tags = {
    Name = "${local.name_prefix}-keypair"
  }
}

# Write the private key locally — chmod 0600 set automatically
resource "local_file" "private_key" {
  content         = tls_private_key.k8s_lab.private_key_pem
  filename        = "${path.module}/${local.name_prefix}.pem"
  file_permission = "0600"
}
