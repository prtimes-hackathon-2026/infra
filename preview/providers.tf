provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = "preview"
      ManagedBy   = "terraform"
      Workspace   = terraform.workspace
    }
  }
}
