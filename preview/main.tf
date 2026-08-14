# ---------------------------------------------------------------------------
# aws-preview ワークスペース
#
# 変数 preview_pull_requests を for_each するだけの薄いルート。PR ごとに
# ワークスペースを作らないので state が散らからず、リストから要素を消すだけで
# destroy になる。リストを書き換えるのは app リポジトリの GitHub Actions。
#
# 共有基盤の値は aws ワークスペースの output から読む。読めるようにするには
# aws 側の Settings → Remote state sharing でこのワークスペースを許可する
# 必要がある (詳細は docs/pr-preview.md)。
#
# tfe_outputs ではなく terraform_remote_state を使っているのは、
#   - HCP Terraform の run では API 認証情報が自動で用意されるため、
#     ワークスペースに TFE_TOKEN を置かずに済む (シークレットは Actions 用の
#     TFC_TOKEN 1 つだけで足りる)
#   - アクセス制御が Remote state sharing の設定として残り、監査できる
#     (tfe_outputs はこの制御を迂回する)
# の 2 点による。
# ---------------------------------------------------------------------------

data "terraform_remote_state" "shared" {
  backend = "remote"

  config = {
    organization = var.tfc_organization

    workspaces = {
      name = var.shared_workspace
    }
  }
}

locals {
  shared = data.terraform_remote_state.shared.outputs

  pull_requests = {
    for pr in var.preview_pull_requests : tostring(pr.number) => pr
  }
}

# 共有基盤側の準備ができていないのに apply すると、原因の分かりにくい
# エラーで落ちる。先に理由の分かる形で止める。
check "shared_workspace_is_ready" {
  assert {
    condition     = length(var.preview_pull_requests) == 0 || try(local.shared.https_listener_arn, null) != null
    error_message = "aws ワークスペースの https_listener_arn が空です。共有基盤側で preview_domain_delegated = true にして HTTPS を有効にしてください。"
  }

  assert {
    condition     = length(var.preview_pull_requests) == 0 || try(local.shared.preview_admin_db_secret_arn, null) != null
    error_message = "aws ワークスペースの preview_admin_db_secret_arn が空です。共有基盤側で preview_enabled = true にしてください。"
  }
}

module "preview" {
  source = "../modules/preview"

  for_each = local.pull_requests

  pull_request_number = each.value.number
  image               = "${var.image_repository}:${each.value.image_tag}"

  aws_region = var.aws_region

  # 共有基盤から借りるもの
  #
  # 値が null の output は state の outputs から属性ごと消える (null として
  # 残らない) ため、共有側で null になりうるものは try(..., null) で受ける。
  # そのまま参照すると原因の分かりにくい「Unsupported attribute」で落ち、
  # 上の check の警告も出ないまま終わってしまう。
  vpc_id                          = local.shared.vpc_id
  subnet_ids                      = local.shared.public_subnet_ids
  security_group_ids              = [local.shared.ecs_tasks_security_group_id]
  cluster_arn                     = local.shared.ecs_cluster_arn
  listener_arn                    = try(local.shared.https_listener_arn, null)
  task_execution_role_arn         = local.shared.task_execution_role_arn
  task_role_arn                   = local.shared.task_role_arn
  preview_domain                  = try(local.shared.preview_domain, null)
  container_port                  = local.shared.container_port
  health_check_path               = local.shared.health_check_path
  registry_credentials_secret_arn = try(local.shared.registry_credentials_secret_arn, null)
  stats_db_secret_arn             = local.shared.stats_db_secret_arn
  openai_api_key_secret_arn       = var.openai_api_key_enabled ? try(local.shared.openai_api_key_secret_arn, null) : null
  auth_password_secret_arn        = try(local.shared.auth_password_secret_arn, null)

  # プレビュー用 DB
  db_address          = try(local.shared.preview_db_address, null)
  db_port             = try(local.shared.preview_db_port, null)
  admin_db_secret_arn = try(local.shared.preview_admin_db_secret_arn, null)

  # サイズと寿命
  task_cpu           = var.task_cpu
  task_memory        = var.task_memory
  log_retention_days = var.log_retention_days
  capacity_provider  = var.capacity_provider
}
