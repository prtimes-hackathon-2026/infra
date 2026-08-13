provider "aws" {
  region = var.aws_region

  # 全リソースに共通タグを付与しておくと、コンソール側での棚卸しが楽になる
  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "terraform"
      Workspace   = terraform.workspace
    }
  }
}
