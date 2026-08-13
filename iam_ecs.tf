data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    # 他アカウントから自アカウントのロールを引き受けさせる混乱した代理人対策
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# ---------------------------------------------------------------------------
# 実行ロール: ECS エージェントがイメージ pull・ログ送信・シークレット取得に使う
# ---------------------------------------------------------------------------

resource "aws_iam_role" "task_execution" {
  name               = "${local.name}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "task_execution_secrets" {
  statement {
    sid     = "ReadSecrets"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]

    resources = concat(
      [
        aws_secretsmanager_secret.app_db_url.arn,
        aws_secretsmanager_secret.stats_db_url.arn,
      ],
      var.registry_credentials_secret_arn == null ? [] : [var.registry_credentials_secret_arn],
    )
  }

  # RDS 管理のシークレットは KMS で暗号化されているため、復号も必要。
  statement {
    sid       = "DecryptSecrets"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "task_execution_secrets" {
  name   = "read-db-secrets"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.task_execution_secrets.json
}

# ---------------------------------------------------------------------------
# タスクロール: アプリのコード自身が使う権限
# ---------------------------------------------------------------------------

resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# ECS Exec (aws ecs execute-command) でコンテナに入れるようにしておく。
# 踏み台なしでマイグレーションや調査ができて、ハッカソン中は効く。
data "aws_iam_policy_document" "task_exec_command" {
  statement {
    sid    = "EcsExec"
    effect = "Allow"

    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task_exec_command" {
  name   = "ecs-exec"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_exec_command.json
}
