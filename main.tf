# Terraform Cloud から AWS に到達できているかの疎通確認用。
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  name = "${var.app_name}-${var.environment}"

  # PR プレビュー関連のリソースは environment ではなく preview で括る。
  # 共有基盤 (dev) とは寿命も権限の境界も別物なので、名前空間を分けておく。
  preview_name = "${var.app_name}-preview"
}
