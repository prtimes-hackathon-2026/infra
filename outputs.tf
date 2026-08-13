output "account_id" {
  description = "Terraform Cloud が実際に認証できた AWS アカウント ID"
  value       = data.aws_caller_identity.current.account_id
}

output "caller_arn" {
  description = "Terraform Cloud が引き受けている IAM プリンシパルの ARN"
  value       = data.aws_caller_identity.current.arn
}

output "region" {
  description = "適用対象のリージョン"
  value       = data.aws_region.current.region
}

# ---------------------------------------------------------------------------
# アプリケーション
# ---------------------------------------------------------------------------

output "app_url" {
  description = "アプリケーションの URL。preview_domain を設定していればその apex を使う"
  value = format(
    "%s://%s",
    local.https_enabled ? "https" : "http",
    local.preview_domain_enabled ? var.preview_domain : aws_lb.app.dns_name,
  )
}

output "alb_dns_name" {
  description = "ALB の DNS 名。独自ドメインを使う場合はここに CNAME / ALIAS を向ける"
  value       = aws_lb.app.dns_name
}

output "alb_zone_id" {
  description = "Route 53 の ALIAS レコード用ホストゾーン ID"
  value       = aws_lb.app.zone_id
}

output "ecs_cluster_name" {
  description = "ECS クラスター名"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "ECS サービス名"
  value       = aws_ecs_service.app.name
}

output "log_group_name" {
  description = "アプリケーションログの CloudWatch Logs グループ"
  value       = aws_cloudwatch_log_group.app.name
}

# ---------------------------------------------------------------------------
# データベース
# ---------------------------------------------------------------------------

output "app_db_endpoint" {
  description = "アプリ用 RDS のエンドポイント (host:port)"
  value       = aws_db_instance.app.endpoint
}

output "app_db_name" {
  description = "アプリ用データベース名"
  value       = aws_db_instance.app.db_name
}

output "app_db_secret_arn" {
  description = "アプリ用 RDS の接続 URL (APP_DATABASE_URL) が入った Secrets Manager シークレット"
  value       = aws_secretsmanager_secret.app_db_url.arn
}

output "stats_db_endpoint" {
  description = "既存の統計用 RDS のエンドポイント"
  value       = "${data.aws_db_instance.stats.address}:${data.aws_db_instance.stats.port}"
}

output "stats_db_secret_arn" {
  description = "統計用 RDS の接続 URL を入れるシークレット。値は手動で設定する"
  value       = aws_secretsmanager_secret.stats_db_url.arn
}

# ---------------------------------------------------------------------------
# PR プレビュー環境
#
# ここから下は aws-preview ワークスペースが tfe_outputs で読む値。
# 消したり名前を変えたりすると向こうの plan が壊れるので注意すること。
# 共有するには、このワークスペースの Settings → Remote state sharing で
# aws-preview を許可しておく必要がある。
# ---------------------------------------------------------------------------

output "preview_domain" {
  description = "PR プレビューのドメイン。pr-<番号>.<domain> が各 PR の URL になる"
  value       = var.preview_domain
}

output "preview_zone_id" {
  description = "プレビュー用ドメインの Route 53 ホストゾーン ID"
  value       = one(aws_route53_zone.preview[*].zone_id)
}

output "preview_zone_name_servers" {
  description = "親ゾーンに NS レコードとして登録する値。ここを登録するまで証明書は検証されない"
  value       = try(aws_route53_zone.preview[0].name_servers, null)
}

output "preview_certificate_arn" {
  description = "プレビュー用ドメインの ACM 証明書 ARN"
  value       = one(aws_acm_certificate.preview[*].arn)
}

output "https_listener_arn" {
  description = "PR ごとのリスナールールを足す先の HTTPS リスナー"
  value       = one(aws_lb_listener.https[*].arn)
}

output "vpc_id" {
  description = "リソースを作成している VPC"
  value       = var.vpc_id
}

output "public_subnet_ids" {
  description = "ECS タスクを置くパブリックサブネット"
  value       = [for s in aws_subnet.public : s.id]
}

output "ecs_tasks_security_group_id" {
  description = "ECS タスク用 SG。プレビューのタスクもこれを共有する"
  value       = aws_security_group.ecs_tasks.id
}

output "ecs_cluster_arn" {
  description = "ECS クラスターの ARN"
  value       = aws_ecs_cluster.main.arn
}

output "task_execution_role_arn" {
  description = "ECS タスク実行ロール。シークレットの取得とイメージ pull に使う"
  value       = aws_iam_role.task_execution.arn
}

output "task_role_arn" {
  description = "ECS タスクロール。コンテナのコード自身が使う"
  value       = aws_iam_role.task.arn
}

output "container_port" {
  description = "アプリが listen するポート"
  value       = var.container_port
}

output "health_check_path" {
  description = "ALB のヘルスチェックパス"
  value       = var.health_check_path
}

output "registry_credentials_secret_arn" {
  description = "コンテナレジストリの認証情報シークレット (public なら null)"
  value       = var.registry_credentials_secret_arn
}

output "preview_db_address" {
  description = "プレビュー用 RDS のホスト名"
  value       = one(aws_db_instance.preview[*].address)
}

output "preview_db_port" {
  description = "プレビュー用 RDS のポート"
  value       = one(aws_db_instance.preview[*].port)
}

output "preview_admin_db_secret_arn" {
  description = "プレビュー用 RDS の管理者接続 URL。bootstrap コンテナだけが受け取る"
  value       = one(aws_secretsmanager_secret.preview_admin_db_url[*].arn)
}

# ---------------------------------------------------------------------------
# IAM (参照専用ユーザー)
# ---------------------------------------------------------------------------

output "readonly_user_arn" {
  description = "参照専用 IAM ユーザーの ARN"
  value       = aws_iam_user.readonly.arn
}

output "console_signin_url" {
  description = "IAM ユーザー用のマネジメントコンソール サインイン URL"
  value       = "https://${data.aws_caller_identity.current.account_id}.signin.aws.amazon.com/console"
}

output "readonly_console_password" {
  description = "参照専用 IAM ユーザーの初期コンソールパスワード。terraform output -raw で取り出す (login_profile_pgp_key を指定した場合は空)"
  value       = try(aws_iam_user_login_profile.readonly[0].password, null)
  sensitive   = true
}

output "readonly_console_password_encrypted" {
  description = "PGP 公開鍵で暗号化された初期コンソールパスワード (login_profile_pgp_key を指定したときのみ)"
  value       = try(aws_iam_user_login_profile.readonly[0].encrypted_password, null)
}

output "readonly_access_key_id" {
  description = "参照専用 IAM ユーザーのアクセスキー ID (var.create_access_key = true のとき)"
  value       = try(aws_iam_access_key.readonly[0].id, null)
}

output "readonly_secret_access_key" {
  description = "参照専用 IAM ユーザーのシークレットアクセスキー。terraform output -raw で取り出す"
  value       = try(aws_iam_access_key.readonly[0].secret, null)
  sensitive   = true
}

# ---------------------------------------------------------------------------
# IAM (GitHub Actions)
# ---------------------------------------------------------------------------

output "github_actions_deploy_role_arn" {
  description = "app リポジトリの Actions Variable AWS_DEPLOY_ROLE_ARN に設定するロールの ARN"
  value       = aws_iam_role.github_actions_deploy.arn
}
