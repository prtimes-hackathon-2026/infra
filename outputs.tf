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
