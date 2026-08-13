terraform {
  required_version = ">= 1.9"

  cloud {
    organization = "prtimes-hackathon-2026"

    workspaces {
      # 共有基盤の aws とは別のワークスペース。PR の開閉で共有基盤の plan が
      # 走らず、プレビューの apply が失敗しても共有基盤の state に影響しない。
      # ワークスペースの Working Directory には preview を設定する。
      name = "aws-preview"
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
