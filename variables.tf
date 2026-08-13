variable "aws_region" {
  description = "リソースを作成する AWS リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "environment" {
  description = "環境名 (dev / stg / prod など)"
  type        = string
  default     = "dev"
}

variable "readonly_user_name" {
  description = "参照専用 IAM ユーザーの名前"
  type        = string
  default     = "readonly"
}

variable "create_access_key" {
  description = "IAM ユーザーのアクセスキーを Terraform で作成するか。false ならコンソール等で別途発行する"
  type        = bool
  default     = false
}

variable "allow_self_credential_management" {
  description = "本人による自分のアクセスキー / パスワード / MFA の管理を許可するか"
  type        = bool
  default     = true
}
