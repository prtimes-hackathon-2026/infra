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

variable "db_identifier" {
  description = "Terraform 管理下に取り込む RDS インスタンスの識別子"
  type        = string
  default     = "prtimes-hackathon-2026summer-db"
}

variable "db_backup_retention_period" {
  description = "自動バックアップの保持日数。0 で無効 (既存の値)。1 以上に変える際は下記の注意を読むこと"
  type        = number

  # 既定は 0。現状の AWS 側の値に合わせてあり、これを変えないかぎり import は
  # 差分なしで通る。0 -> 1 以上への変更はインスタンスの再起動 (数十秒〜数分の
  # 断) を伴うため、メンテナンスウィンドウか停止できるタイミングで行うこと。
  default = 0

  validation {
    condition     = var.db_backup_retention_period >= 0 && var.db_backup_retention_period <= 35
    error_message = "db_backup_retention_period は 0〜35 の範囲で指定してください。"
  }
}

variable "db_deletion_protection" {
  description = "RDS の削除保護を有効にするか。既定は false (既存の値)"
  type        = bool

  # true にすると無停止で削除保護が入る。CloudFormation のスタック削除も
  # 失敗するようになるため、事故防止としては効果が大きい。
  default = false
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

  # 既定は false。作成には run ロールに iam:*LoginProfile が必要で、
  # 現状は付与していない。コンソールのパスワードは管理者が手動で設定する。
  default = false
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
