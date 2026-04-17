# ---------------------------------------------------------------------------
# EC2 Instance Role — grants AWS API access to the nodes themselves.
# Required for: SSM Session Manager (shell access), ECR image pulls, CloudWatch.
# This is separate from your SSO role — EC2 instances cannot use SSO.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "k8s_node" {
  name               = "${local.name_prefix}-node-role"
  description        = "Role attached to k8s lab EC2 instances (SSM, ECR, CloudWatch)"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name = "${local.name_prefix}-node-role"
  }
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.k8s_node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# SSM in this account logs sessions to s3://logging-us-east-1-<account_id>.
# The node role needs s3:GetEncryptionConfiguration so SSM can validate the
# bucket's encryption before starting a session.
resource "aws_iam_role_policy" "ssm_s3_logging" {
  name = "ssm-s3-logging"
  role = aws_iam_role.k8s_node.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetEncryptionConfiguration"]
        Resource = "arn:${local.partition}:s3:::logging-us-east-1-${local.account_id}"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_readonly" {
  role       = aws_iam_role.k8s_node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "cwagent" {
  role       = aws_iam_role.k8s_node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "k8s_node" {
  name = "${local.name_prefix}-node-profile"
  role = aws_iam_role.k8s_node.name
}
