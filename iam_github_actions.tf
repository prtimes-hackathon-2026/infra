# ---------------------------------------------------------------------------
# GitHub Actions からの自動デプロイ (OIDC)
#
# app リポジトリの main に push されると docker-publish.yml が :latest を
# 発行するが、タグが変わらないので ECS は勝手に入れ替わらない。ワークフローから
# update-service --force-new-deployment を叩くためのロールをここで用意する。
# アクセスキーは配らず、OIDC で一時認証情報を取らせる。
# ---------------------------------------------------------------------------

locals {
  github_oidc_host = "token.actions.githubusercontent.com"

  github_oidc_provider_arn = (
    var.create_github_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : data.aws_iam_openid_connect_provider.github[0].arn
  )

  # OIDC トークンの sub クレームは repo:<owner>/<repo>:ref:refs/heads/<branch>
  # の形になる。ここに挙げたブランチの実行だけがロールを引き受けられる。
  github_deploy_subjects = [
    for b in var.github_deploy_branches :
    "repo:${var.github_deploy_repository}:ref:refs/heads/${b}"
  ]
}

# OIDC プロバイダはアカウントに 1 つしか作れない。他の用途で作成済みなら
# create_github_oidc_provider = false にして既存を参照する。
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://${local.github_oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1

  url = "https://${local.github_oidc_host}"
}

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    # aud を絞らないと、GitHub が発行した任意のトークンでロールを
    # 引き受けられてしまう。sub と両方を必ず見る。
    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:sub"
      values   = local.github_deploy_subjects
    }
  }
}

resource "aws_iam_role" "github_actions_deploy" {
  name               = "${local.name}-github-actions-deploy"
  description        = "GitHub Actions が ECS サービスを強制デプロイするためのロール"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json
}

# できることは「このサービスを強制デプロイして、収束を待つ」だけ。
# タスク定義を作り直すわけではないので PassRole は要らない。
data "aws_iam_policy_document" "github_actions_deploy" {
  statement {
    sid    = "ForceNewDeployment"
    effect = "Allow"

    actions = [
      "ecs:UpdateService",
      "ecs:DescribeServices",
    ]

    resources = [aws_ecs_service.app.arn]
  }
}

resource "aws_iam_role_policy" "github_actions_deploy" {
  name   = "force-new-deployment"
  role   = aws_iam_role.github_actions_deploy.id
  policy = data.aws_iam_policy_document.github_actions_deploy.json
}
