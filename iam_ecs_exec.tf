# ---------------------------------------------------------------------------
# 参照 + ECS Exec 用の IAM ユーザー
#
# readonly と同じ ReadOnlyAccess に、ECS Exec (aws ecs execute-command) で
# サンドボックスのメンテナンス用タスクに入る権限だけを足したもの。
# 入った先から見えるのは統計 DB の複製だけで、本番の DB には届かない
# (ネットワーク境界は rds_sandbox.tf / ecs_sandbox.tf のコメントを参照)。
#
# readonly 本体に足していないのは、exec がコンテナ内で任意のコマンドを
# 実行できるため。「参照専用」と同じ重みでは配れないのでユーザーを分ける。
# ---------------------------------------------------------------------------

resource "aws_iam_user" "ecs_exec" {
  name = var.ecs_exec_user_name
  path = "/"

  # Terraform 管理外で作られたキーやログインプロファイルが残っていても destroy できるように
  force_destroy = true

  tags = {
    Name    = var.ecs_exec_user_name
    Purpose = "read-only access + ECS Exec into the sandbox"
  }
}

resource "aws_iam_user_policy_attachment" "ecs_exec_readonly" {
  user       = aws_iam_user.ecs_exec.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# readonly と同じく `aws login` (ブラウザ経由サインイン) を使えるようにする。
# 長期のアクセスキーを配らずに CLI から exec できる。
resource "aws_iam_user_policy_attachment" "ecs_exec_signin_local_development" {
  user       = aws_iam_user.ecs_exec.name
  policy_arn = "arn:aws:iam::aws:policy/SignInLocalDevelopmentAccess"
}

# ---------------------------------------------------------------------------
# ECS Exec の権限
#
# 呼び出す側に要るのは ecs:ExecuteCommand だけ。SSM のセッションは ECS が
# 裏で開くので ssm:StartSession は不要 (Session Manager で EC2 に入るときとは
# 必要な権限が違う)。コンテナ側の ssmmessages:* は各タスクロールに付けてある。
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_exec_user" {
  statement {
    sid     = "ExecuteCommandOnSandboxOnly"
    effect  = "Allow"
    actions = ["ecs:ExecuteCommand"]

    # サンドボックスのクラスターのタスクだけ。本番クラスター (webapp-dev) には
    # プレビューも含めて一切入れない。
    #
    # クラスター名から組み立てているのは、sandbox_enabled = false でも
    # このポリシーが壊れないようにするため (リソース参照だと count で落ちる)。
    resources = [
      "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task/${local.sandbox_name}/*",
    ]
  }

  # exec するには対象タスクの ID を引けないと始まらない。ReadOnlyAccess にも
  # 含まれているが、そちらを ViewOnlyAccess などに差し替えても壊れないように
  # このポリシー単体で完結させておく。
  statement {
    sid    = "FindTasks"
    effect = "Allow"

    actions = [
      "ecs:ListClusters",
      "ecs:DescribeClusters",
      "ecs:ListServices",
      "ecs:DescribeServices",
      "ecs:ListTasks",
      "ecs:DescribeTasks",
    ]

    resources = ["*"]
  }

  # ReadOnlyAccess には secretsmanager:GetSecretValue が含まれる。つまり
  # 何もしないと、本番コンテナに入れなくても手元から
  # `aws secretsmanager get-secret-value` で本番 DB の接続 URL を読めてしまい、
  # exec をサンドボックスに限定した意味が薄くなる。明示的な Deny で塞ぐ
  # (Deny は管理ポリシーの Allow に優先する)。
  #
  # サンドボックス自身のシークレット (webapp-sandbox/db-url) は対象外。
  # あれは複製の資格情報なので読めてよい。
  statement {
    sid    = "DenyProductionSecrets"
    effect = "Deny"

    actions = ["secretsmanager:GetSecretValue"]

    resources = [
      aws_secretsmanager_secret.app_db_url.arn,
      aws_secretsmanager_secret.stats_db_url.arn,
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${local.preview_name}/*",
    ]
  }
}

resource "aws_iam_user_policy" "ecs_exec_user" {
  name   = "ecs-execute-command-sandbox"
  user   = aws_iam_user.ecs_exec.name
  policy = data.aws_iam_policy_document.ecs_exec_user.json
}

# ---------------------------------------------------------------------------
# 資格情報まわり。readonly と同じ運用にそろえてあるので、
# create_access_key / create_login_profile / allow_self_credential_management は
# 両方のユーザーに効く。
# ---------------------------------------------------------------------------

# 自分のアクセスキーとパスワードだけは本人が回せるようにしておく。
resource "aws_iam_user_policy" "ecs_exec_self_manage_credentials" {
  count = var.allow_self_credential_management ? 1 : 0

  name = "SelfManageCredentials"
  user = aws_iam_user.ecs_exec.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageOwnAccessKeys"
        Effect = "Allow"
        Action = [
          "iam:CreateAccessKey",
          "iam:DeleteAccessKey",
          "iam:UpdateAccessKey",
          "iam:ListAccessKeys",
        ]
        Resource = aws_iam_user.ecs_exec.arn
      },
      {
        Sid    = "ManageOwnPasswordAndMFA"
        Effect = "Allow"
        Action = [
          "iam:ChangePassword",
          "iam:CreateVirtualMFADevice",
          "iam:EnableMFADevice",
          "iam:ResyncMFADevice",
          "iam:DeleteVirtualMFADevice",
          "iam:DeactivateMFADevice",
        ]
        Resource = [
          aws_iam_user.ecs_exec.arn,
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:mfa/$${aws:username}",
        ]
      },
    ]
  })
}

# マネジメントコンソールへのサインイン用。既定では作らない
# (run ロールに iam:*LoginProfile を付けていないため。詳細は README)。
resource "aws_iam_user_login_profile" "ecs_exec" {
  count = var.create_login_profile ? 1 : 0

  user            = aws_iam_user.ecs_exec.name
  password_length = var.login_profile_password_length

  # pgp_key を渡すと password ではなく encrypted_password が返り、
  # 初期パスワードが state に平文で残らない。
  pgp_key = var.login_profile_pgp_key

  password_reset_required = true

  lifecycle {
    # 本人がパスワードを変更すると AWS 側の password_reset_required は false になる。
    # これを差分として扱うとログインプロファイルが作り直され、パスワードが
    # 勝手にリセットされてしまうため無視する。password_length / pgp_key も
    # 既存プロファイルからは読み取れないので同様。
    ignore_changes = [
      password_reset_required,
      password_length,
      pgp_key,
    ]
  }
}

# AWS CLI 用のアクセスキー。シークレットは state に平文で入る。
resource "aws_iam_access_key" "ecs_exec" {
  count = var.create_access_key ? 1 : 0

  user = aws_iam_user.ecs_exec.name
}
