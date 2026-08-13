output "url" {
  description = "この PR のプレビュー URL"
  value       = local.url
}

output "host_name" {
  description = "リスナールールが見ているホスト名"
  value       = local.host_name
}

output "service_name" {
  description = "ECS サービス名"
  value       = aws_ecs_service.this.name
}

output "log_group_name" {
  description = "bootstrap と app のログが出る CloudWatch Logs グループ"
  value       = aws_cloudwatch_log_group.this.name
}

output "database_name" {
  description = "この PR が使う database"
  value       = local.db_name
}
