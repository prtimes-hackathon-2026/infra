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
  vpc_id                          = local.shared.vpc_id
  subnet_ids                      = local.shared.public_subnet_ids
  security_group_ids              = [local.shared.ecs_tasks_security_group_id]
  cluster_arn                     = local.shared.ecs_cluster_arn
  listener_arn                    = local.shared.https_listener_arn
  task_execution_role_arn         = local.shared.task_execution_role_arn
  task_role_arn                   = local.shared.task_role_arn
  preview_domain                  = local.shared.preview_domain
  container_port                  = local.shared.container_port
  health_check_path               = local.shared.health_check_path
  registry_credentials_secret_arn = local.shared.registry_credentials_secret_arn
  stats_db_secret_arn             = local.shared.stats_db_secret_arn

  # プレビュー用 DB
  db_address          = local.shared.preview_db_address
  db_port             = local.shared.preview_db_port
  admin_db_secret_arn = local.shared.preview_admin_db_secret_arn

  # サイズと寿命
  task_cpu           = var.task_cpu
  task_memory        = var.task_memory
  log_retention_days = var.log_retention_days
  capacity_provider  = var.capacity_provider
}
