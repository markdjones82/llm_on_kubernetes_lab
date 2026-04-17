locals {
  use_subnet_id = trim(var.subnet_id) != ""
}

# Look up the existing subnet directly by ID when available.
data "aws_subnet" "selected_by_id" {
  count = local.use_subnet_id ? 1 : 0
  id    = var.subnet_id
}

# Fall back to a Name tag lookup when subnet_id is not provided.
data "aws_subnet" "selected_by_name" {
  count = local.use_subnet_id ? 0 : 1

  filter {
    name   = "tag:Name"
    values = [var.subnet_name]
  }
}

locals {
  subnet_id = local.use_subnet_id ? data.aws_subnet.selected_by_id[0].id : data.aws_subnet.selected_by_name[0].id
  vpc_id    = local.use_subnet_id ? data.aws_subnet.selected_by_id[0].vpc_id : data.aws_subnet.selected_by_name[0].vpc_id
}
