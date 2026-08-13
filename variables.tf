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

variable "app_name" {
  description = "アプリケーション名。作成するリソース名のプレフィックスになる"
  type        = string
  default     = "webapp"
}

variable "vpc_id" {
  description = "リソースを作成する既存 VPC。統計用 RDS が入っているものを指定する"
  type        = string
  default     = "vpc-00a084258f8af45ee"
}

variable "public_subnets" {
  description = "アプリ用に作成するパブリックサブネット (AZ => CIDR)。ALB に必要なので 2 AZ 以上にする"
  type        = map(string)

  default = {
    "ap-northeast-1a" = "10.0.1.0/24"
    "ap-northeast-1c" = "10.0.2.0/24"
  }

  validation {
    condition     = length(var.public_subnets) >= 2
    error_message = "ALB は 2 つ以上の AZ のサブネットを必要とするため、2 件以上指定してください。"
  }
}

variable "stats_db_identifier" {
  description = "既存の統計用 RDS の DB インスタンス識別子"
  type        = string
  default     = "prtimes-hackathon-2026summer-db"
}

# ---------------------------------------------------------------------------
# コンテナ
# ---------------------------------------------------------------------------

variable "container_image" {
  description = "デプロイするコンテナイメージ (例: ghcr.io/<org>/<repo>:<tag>)"
  type        = string
}

variable "container_port" {
  description = "コンテナが listen するポート"
  type        = number
  default     = 8080
}

variable "container_environment" {
  description = "コンテナに渡す追加の環境変数"
  type        = map(string)
  default     = {}
}

variable "task_architecture" {
  description = "コンテナイメージの CPU アーキテクチャ (X86_64 / ARM64)"
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.task_architecture)
    error_message = "task_architecture は X86_64 または ARM64 を指定してください。"
  }
}

variable "task_cpu" {
  description = "Fargate タスクの CPU ユニット (256 / 512 / 1024 / ...)"
  type        = number
  default     = 512
}

variable "task_memory" {
  description = "Fargate タスクのメモリ (MiB)。task_cpu と組み合わせが決まっている"
  type        = number
  default     = 1024
}

variable "desired_count" {
  description = "常時起動しておくタスク数"
  type        = number
  default     = 1
}

variable "health_check_path" {
  description = "ALB ターゲットグループのヘルスチェックパス"
  type        = string
  default     = "/"
}

variable "container_insights" {
  description = "ECS Container Insights (disabled / enabled / enhanced)。CloudWatch の課金が増えるため既定は disabled。CPU / メモリの基本メトリクスは無効でも取れる"
  type        = string
  default     = "disabled"

  validation {
    condition     = contains(["disabled", "enabled", "enhanced"], var.container_insights)
    error_message = "container_insights は disabled / enabled / enhanced のいずれかを指定してください。"
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs の保持日数"
  type        = number
  default     = 14
}

# ---------------------------------------------------------------------------
# ALB
# ---------------------------------------------------------------------------

variable "alb_ingress_cidrs" {
  description = "ALB へのアクセスを許可する CIDR"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "certificate_arn" {
  description = "HTTPS を使う場合の ACM 証明書 ARN。null なら HTTP (80) のみ公開する"
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# アプリ用 RDS
# ---------------------------------------------------------------------------

variable "app_db_name" {
  description = "アプリ用データベースの初期データベース名"
  type        = string
  default     = "app"
}

variable "app_db_username" {
  description = "アプリ用データベースのマスターユーザー名"
  type        = string
  default     = "postgres"
}

variable "app_db_instance_class" {
  description = "アプリ用 RDS のインスタンスクラス。既定は統計 DB と同じ"
  type        = string
  default     = "db.t4g.small"
}

variable "app_db_allocated_storage" {
  description = "アプリ用 RDS のストレージ (GiB)"
  type        = number
  default     = 200
}

variable "app_db_engine_version" {
  description = "アプリ用 RDS の PostgreSQL バージョン。既定は統計 DB と同じ"
  type        = string
  default     = "17.7"
}

variable "app_db_backup_retention_days" {
  description = "アプリ用 RDS の自動バックアップ保持日数。0 で無効"
  type        = number
  default     = 7
}

variable "app_db_deletion_protection" {
  description = "アプリ用 RDS の削除保護。ハッカソン中の作り直しを想定して既定は false"
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# IAM (参照専用ユーザー)
# ---------------------------------------------------------------------------

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
