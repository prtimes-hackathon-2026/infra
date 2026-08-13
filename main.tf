# Terraform Cloud から AWS に到達できているかの疎通確認用。
# 実リソースを追加したら、この2つは残しても消しても構いません。
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}
