variable "pull_request_number" {
  description = "プレビューを作る PR の番号"
  type        = number

  validation {
    condition     = var.pull_request_number > 0 && var.pull_request_number < 49000
    error_message = "リスナールールの優先度を 1000 + PR 番号で決めているため、49000 未満である必要があります。"
  }
}

variable "image" {
  description = "この PR のコードが入ったコンテナイメージ (タグまで含む)"
  type        = string
  nullable    = false
}

variable "app_name" {
  description = "リソース名のプレフィックス。共有基盤の app_name と揃える"
  type        = string
  default     = "webapp"
}

variable "preview_name" {
  description = "プレビュー用リソースの名前空間。ロググループとシークレットのパスに使う"
  type        = string
  default     = "webapp-preview"
}

variable "aws_region" {
  description = "リージョン。awslogs の設定に必要"
  type        = string
  nullable    = false
}

# ---------------------------------------------------------------------------
# 共有基盤から借りるもの (aws ワークスペースの output)
# ---------------------------------------------------------------------------

variable "vpc_id" {
  description = "ターゲットグループを作る VPC"
  type        = string
  nullable    = false
}

variable "subnet_ids" {
  description = "タスクを置くサブネット。共有のパブリックサブネット"
  type        = list(string)
  nullable    = false
}

variable "security_group_ids" {
  description = "タスクに付ける SG。共有の ECS タスク SG"
  type        = list(string)
  nullable    = false
}

variable "cluster_arn" {
  description = "相乗りする ECS クラスター"
  type        = string
  nullable    = false
}

variable "listener_arn" {
  description = "リスナールールを足す先の HTTPS リスナー"
  type        = string
  nullable    = false
}

variable "task_execution_role_arn" {
  description = "タスク実行ロール。シークレットの取得とイメージ pull に使う"
  type        = string
  nullable    = false
}

variable "task_role_arn" {
  description = "タスクロール。コンテナのコード自身が使う"
  type        = string
  nullable    = false
}

variable "preview_domain" {
  description = "プレビューのドメイン。pr-<番号>.<domain> でルーティングする"
  type        = string
  nullable    = false
}

variable "container_port" {
  description = "アプリが listen するポート"
  type        = number
  default     = 3000
}

variable "health_check_path" {
  description = "ALB のヘルスチェックパス"
  type        = string
  default     = "/api/health"
}

variable "registry_credentials_secret_arn" {
  description = "コンテナレジストリの認証情報。イメージが public なら null"
  type        = string
  default     = null
}

variable "stats_db_secret_arn" {
  description = "統計 DB の接続 URL。プレビューでも既存のものを共有する (参照専用)"
  type        = string
  nullable    = false
}

# ---------------------------------------------------------------------------
# プレビュー用 DB
# ---------------------------------------------------------------------------

variable "db_address" {
  description = "プレビュー用 RDS のホスト名"
  type        = string
  nullable    = false
}

variable "db_port" {
  description = "プレビュー用 RDS のポート"
  type        = number
  nullable    = false
  default     = 5432
}

variable "admin_db_secret_arn" {
  description = "プレビュー用 RDS の管理者接続 URL。bootstrap コンテナだけに渡す"
  type        = string
  nullable    = false
}

# ---------------------------------------------------------------------------
# サイズと寿命
# ---------------------------------------------------------------------------

variable "task_cpu" {
  description = "Fargate タスクの CPU ユニット"
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate タスクのメモリ (MiB)"
  type        = number
  default     = 512
}

variable "task_architecture" {
  description = "コンテナイメージの CPU アーキテクチャ"
  type        = string
  default     = "X86_64"
}

variable "log_retention_days" {
  description = "CloudWatch Logs の保持日数。プレビューは短くてよい"
  type        = number
  default     = 3
}

variable "bootstrap_image" {
  description = <<-EOT
    database とロールを作る bootstrap コンテナのイメージ。
    PR のコードが混入しないよう、上流の postgres 公式イメージをそのまま使う。
    Docker Hub のレート制限を避けて ECR Public を指定している。
  EOT
  type        = string
  default     = "public.ecr.aws/docker/library/postgres:17-alpine"
}

variable "container_environment" {
  description = "app コンテナに渡す追加の環境変数"
  type        = map(string)
  default     = {}
}

variable "capacity_provider" {
  description = "FARGATE または FARGATE_SPOT。プレビューは中断を許容して Spot を使う"
  type        = string
  default     = "FARGATE_SPOT"

  validation {
    condition     = contains(["FARGATE", "FARGATE_SPOT"], var.capacity_provider)
    error_message = "capacity_provider は FARGATE または FARGATE_SPOT を指定してください。"
  }
}
