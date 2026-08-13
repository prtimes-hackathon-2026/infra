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

# --- RDS (CloudFormation から取り込む既存インスタンス) -------------------------

variable "rds_identifier" {
  description = "取り込む RDS インスタンスの識別子"
  type        = string
  default     = "prtimes-hackathon-2026summer-db"
}

variable "rds_instance_class" {
  description = "RDS のインスタンスクラス。現状は CloudFormation のパラメータ (db.m7i.large) から手動で変更されている"
  type        = string
  default     = "db.t4g.small"
}

variable "rds_allocated_storage" {
  description = "RDS のストレージ容量 (GiB)"
  type        = number
  default     = 1000
}

variable "rds_iops" {
  description = "gp3 ストレージにプロビジョニングする IOPS"
  type        = number
  default     = 12000
}

variable "rds_storage_throughput" {
  description = "gp3 ストレージのスループット (MiB/s)"
  type        = number
  default     = 500
}

variable "rds_subnet_group_name" {
  description = "RDS が属する DB サブネットグループ名 (CloudFormation 管理)"
  type        = string
  default     = "prtimes-hackathon-2026summer-dbsubnetgroup-6r3h5y8laexs"
}

variable "rds_security_group_id" {
  description = "RDS にアタッチされているセキュリティグループ ID (CloudFormation 管理)"
  type        = string
  default     = "sg-07a56fdc4aafa5704"
}

variable "rds_deletion_protection" {
  description = "RDS の削除保護。ハッカソン終了まで有効にしておくことを推奨"
  type        = bool

  # 現状の実リソースは false。import 直後に差分を出さないため既定も false にしてある。
  # true に変えて apply すれば削除保護が入る。
  default = false
}
