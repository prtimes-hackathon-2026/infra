# Terraform Cloud から AWS に到達できているかの疎通確認用。
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  name = "${var.app_name}-${var.environment}"
}
