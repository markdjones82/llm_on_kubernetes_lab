provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project     = "kubernetes-ai-agent"
      managed_by  = "terraform"
      account     = var.account_name
      git_repo    = "KUBERNETES_AI_AGENT_GENERIC"
      environment = var.env
    }
  }
}

terraform {
  # Local state — fine for a short lab. To migrate to S3 later:
  #   terraform init -migrate-state -backend-config=backends/sdlc.tfvars
  # (re-add backend "s3" block and uncomment bucket/key in backends/sdlc.tfvars)
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.id
  partition   = data.aws_partition.current.partition
  name_prefix = "kubernetes-ai-agent-${var.env}"
}
