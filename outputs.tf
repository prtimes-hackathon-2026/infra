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
  description = "アプリケーションの URL (ALB の DNS 名)"
  value       = "${var.certificate_arn == null ? "http" : "https"}://${aws_lb.app.dns_name}"
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
