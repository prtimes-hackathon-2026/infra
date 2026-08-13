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
  description = "デプロイするコンテナイメージ"
  type        = string
  default     = "ghcr.io/prtimes-hackathon-2026/app:latest"
}

variable "registry_credentials_secret_arn" {
  description = <<-EOT
    コンテナレジストリが認証を要求する場合に使う Secrets Manager シークレットの ARN。
    {"username": "<GitHubユーザー名>", "password": "<read:packages 権限の PAT>"} の JSON を入れる。
    イメージが public なら null のままでよい。
  EOT
  type        = string
  default     = null
}

variable "container_port" {
  description = "コンテナが listen するポート。app の Dockerfile は PORT=3000 / EXPOSE 3000"
  type        = number
  default     = 3000
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
  description = "ALB ターゲットグループのヘルスチェックパス。app の liveness エンドポイント"
  type        = string
  default     = "/api/health"
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
  description = <<-EOT
    HTTPS に使う ACM 証明書 ARN を外から与える場合に指定する。
    null のときは preview_domain で取った証明書を使う (両方 null なら HTTP のみ)。
  EOT
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# PR プレビュー環境 (詳細は docs/pr-preview.md)
# ---------------------------------------------------------------------------

variable "preview_domain" {
  description = <<-EOT
    PR プレビューに使うドメイン。このゾーンを Route 53 に作り、
    *.<domain> と <domain> を載せた ACM 証明書を取る。
    null にすると DNS と証明書を一切作らない。
  EOT
  type        = string
  default     = "preview-prtimes-hackathon-2026.naohanpen.dev"
}

variable "preview_domain_delegated" {
  description = <<-EOT
    親ゾーンから preview_domain への NS 委任が完了しているか。
    false の間は証明書の検証を待たず、HTTPS リスナーも作らない
    (委任前に検証を待つと apply が 75 分ハングしてから失敗するため)。
    output preview_zone_name_servers を親ゾーンに登録してから true にする。
  EOT
  type        = bool
  default     = false
}

variable "preview_enabled" {
  description = <<-EOT
    PR プレビュー用の RDS と管理者シークレットを作るか。
    false にすると aws-preview ワークスペースは動かせない (常時課金も無くなる)。
  EOT
  type        = bool
  default     = true
}

variable "preview_db_instance_class" {
  description = "プレビュー用 RDS のインスタンスクラス"
  type        = string
  default     = "db.t4g.micro"
}

variable "preview_db_allocated_storage" {
  description = "プレビュー用 RDS のストレージ (GiB)"
  type        = number
  default     = 20
}

variable "preview_db_username" {
  description = "プレビュー用 RDS のマスターユーザー名。bootstrap コンテナだけが使う"
  type        = string
  default     = "postgres"
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

variable "ecs_exec_user_name" {
  description = <<-EOT
    参照 + ECS Exec 用の IAM ユーザーの名前。ReadOnlyAccess に加えて、
    サンドボックスのメンテナンス用タスクへの ecs:ExecuteCommand を持つ。
    create_access_key / create_login_profile / allow_self_credential_management は
    readonly ユーザーと共通で、このユーザーにも同じように効く。
  EOT
  type        = string
  default     = "ecs-exec"
}

# ---------------------------------------------------------------------------
# サンドボックス (統計 DB の複製 + メンテナンス用タスク)
# ---------------------------------------------------------------------------

variable "sandbox_enabled" {
  description = <<-EOT
    統計 DB の複製と、それを触るメンテナンス用タスクを作るか。
    false にすると RDS も ECS サービスも消えて課金が止まる
    (ecs_exec ユーザー自体は残るが、入れる先が無くなる)。
  EOT
  type        = bool
  default     = true
}

variable "sandbox_snapshot_version" {
  description = <<-EOT
    複製元スナップショットの世代。この値を上げるとスナップショットを取り直し、
    複製インスタンスも最新データで作り直される (= 数分のダウンタイム)。
    スナップショット取得は運営の統計 DB に対する操作になるので、
    利用の少ない時間帯に回すこと。
  EOT
  type        = number
  default     = 1
}

variable "sandbox_db_instance_class" {
  description = "複製 DB のインスタンスクラス。既定は統計 DB と同じ"
  type        = string
  default     = "db.t4g.small"
}

variable "sandbox_db_name" {
  description = <<-EOT
    複製 DB に接続するときの初期データベース名。統計 DB には初期データベース名が
    設定されていないため、実際のデータが入った DB 名が別にある場合はそれを指定する
    (分からなければ postgres のまま繋いで \l で一覧できる)。
  EOT
  type        = string
  default     = "postgres"
}

variable "sandbox_maintenance_image" {
  description = <<-EOT
    メンテナンス用タスクのイメージ。psql が入っていればよいので上流の
    postgres 公式イメージを使う (Docker Hub のレート制限を避けて ECR Public)。
    alpine タグは使わないこと。ECS Exec が注入する SSM エージェントが
    glibc リンクで、musl の alpine では exec に失敗する。
  EOT
  type        = string
  default     = "public.ecr.aws/docker/library/postgres:17"
}

variable "sandbox_maintenance_desired_count" {
  description = "メンテナンス用タスクの常駐数。0 にすると DB を残したままタスクだけ止められる"
  type        = number
  default     = 1
}

variable "sandbox_capacity_provider" {
  description = "メンテナンス用タスクの起動タイプ。Spot は中断されると exec のセッションが切れる"
  type        = string
  default     = "FARGATE_SPOT"

  validation {
    condition     = contains(["FARGATE", "FARGATE_SPOT"], var.sandbox_capacity_provider)
    error_message = "sandbox_capacity_provider は FARGATE または FARGATE_SPOT を指定してください。"
  }
}

# ---------------------------------------------------------------------------
# GitHub Actions からの自動デプロイ
# ---------------------------------------------------------------------------

variable "github_deploy_repository" {
  description = "デプロイを許可する GitHub リポジトリ (owner/repo)"
  type        = string
  default     = "prtimes-hackathon-2026/app"
}

variable "github_deploy_subject_prefix" {
  description = <<-EOT
    OIDC トークンの sub クレームの前半部分。実際の値は
      gh api /repos/<owner>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix
    で確認できる。null にすると repo:<github_deploy_repository> を使う。
  EOT
  type        = string
  default     = "repo:prtimes-hackathon-2026@316162909/app@1332584890"
}

variable "github_deploy_branches" {
  description = "デプロイを許可するブランチ。ここに挙げたブランチの workflow だけがロールを引き受けられる"
  type        = list(string)
  default     = ["main"]
}

variable "create_github_oidc_provider" {
  description = <<-EOT
    GitHub Actions 用の OIDC プロバイダを Terraform で作るか。
    アカウントに既にある場合 (他のリポジトリ用に作成済みなど) は false にする。
    その場合は既存のプロバイダを参照するだけで、作成も削除もしない。
  EOT
  type        = bool
  default     = true
}
