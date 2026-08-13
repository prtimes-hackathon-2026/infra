terraform {
  required_version = ">= 1.9"

  cloud {
    # 環境変数 TF_CLOUD_ORGANIZATION / TF_WORKSPACE でも上書き可能
    organization = "prtimes-hackathon-2026"

    workspaces {
      # ワークスペース名は組織内で一意なので project の指定は不要
      name = "aws"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
