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

variable "create_login_profile" {
  description = "マネジメントコンソールへのサインインを許可するか (ログインプロファイルを作成する)"
  type        = bool
  default     = true
}

variable "login_profile_password_length" {
  description = "Terraform が生成する初期パスワードの長さ"
  type        = number
  default     = 20

  validation {
    condition     = var.login_profile_password_length >= 8 && var.login_profile_password_length <= 128
    error_message = "login_profile_password_length は 8〜128 の範囲で指定してください。"
  }
}

variable "login_profile_pgp_key" {
  description = "初期パスワードの暗号化に使う PGP 公開鍵 (base64) または keybase:<username>。null なら平文で state に保存される"
  type        = string
  default     = null
}

variable "allow_self_credential_management" {
  description = "本人による自分のアクセスキー / パスワード / MFA の管理を許可するか"
  type        = bool
  default     = true
}
