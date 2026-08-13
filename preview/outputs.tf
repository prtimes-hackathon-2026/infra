output "preview_urls" {
  description = "PR 番号 => プレビュー URL。ワークフローはここではなくドメインから URL を組み立てる"
  value       = { for k, m in module.preview : k => m.url }
}

output "preview_services" {
  description = "PR 番号 => ECS サービス名"
  value       = { for k, m in module.preview : k => m.service_name }
}

output "preview_log_groups" {
  description = "PR 番号 => CloudWatch Logs グループ"
  value       = { for k, m in module.preview : k => m.log_group_name }
}

output "preview_databases" {
  description = "PR 番号 => database 名。PR を閉じても database 自体は残る (docs/pr-preview.md 参照)"
  value       = { for k, m in module.preview : k => m.database_name }
}
