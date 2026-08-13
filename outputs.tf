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
