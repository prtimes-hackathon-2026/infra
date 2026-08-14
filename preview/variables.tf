# ---------------------------------------------------------------------------
# GitHub Actions が書き換える変数
#
# ワークスペースの Terraform variable として **HCL 型** で登録する。
# app リポジトリのワークフローは JSON 形式で書き込む。HCL のオブジェクト
# 構文は key: value 表記も受け付けるので、JSON はそのまま有効な HCL 式として
# 解釈される (jq で読み書きできて都合がよい)。
#
#   [{"number": 123, "image_tag": "pr-123"}]
# ---------------------------------------------------------------------------

variable "preview_pull_requests" {
  description = "プレビューを立てる PR の一覧。ここから消えた PR のリソースは destroy される"

  type = list(object({
    number    = number
    image_tag = string
  }))

  default = []

  validation {
    condition = length(var.preview_pull_requests) == length(distinct([
      for pr in var.preview_pull_requests : pr.number
    ]))
    error_message = "preview_pull_requests に同じ PR 番号が 2 回以上含まれています。"
  }
}

# ---------------------------------------------------------------------------
# 接続先
# ---------------------------------------------------------------------------

variable "tfc_organization" {
  description = "共有基盤のワークスペースがある Terraform Cloud の組織"
  type        = string
  default     = "prtimes-hackathon-2026"
}

variable "shared_workspace" {
  description = "共有基盤のワークスペース名。ここの output を読む"
  type        = string
  default     = "aws"
}

variable "aws_region" {
  description = "リソースを作成する AWS リージョン。共有基盤と揃える"
  type        = string
  default     = "ap-northeast-1"
}

variable "image_repository" {
  description = "PR のイメージが入っているリポジトリ。image_tag と組み合わせて使う"
  type        = string
  default     = "ghcr.io/prtimes-hackathon-2026/app"
}

variable "openai_api_key_enabled" {
  description = <<-EOT
    プレビューの app コンテナに共有基盤の OPENAI_API_KEY を渡すか。
    渡すと PR のコードがそのキーを読めるので、外部からの PR も
    プレビューする運用に変えるときは false にする
    (AI コーチングの API だけが動かなくなる)。
  EOT
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# サイズと寿命
# ---------------------------------------------------------------------------

variable "task_cpu" {
  description = "プレビュータスクの CPU ユニット"
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "プレビュータスクのメモリ (MiB)"
  type        = number
  default     = 512
}

variable "log_retention_days" {
  description = "プレビューのログ保持日数"
  type        = number
  default     = 3
}

variable "capacity_provider" {
  description = "FARGATE または FARGATE_SPOT"
  type        = string
  default     = "FARGATE_SPOT"
}
