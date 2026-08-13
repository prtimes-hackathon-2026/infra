# 参照専用の IAM ユーザー。
# 権限は AWS 管理ポリシー ReadOnlyAccess に寄せている。個別サービスごとに
# read 用のポリシーを書き足すより、AWS 側の追随に任せたほうが穴が出にくい。
resource "aws_iam_user" "readonly" {
  name = var.readonly_user_name
  path = "/"

  # Terraform 管理外で作られたキーやログインプロファイルが残っていても destroy できるように
  force_destroy = true

  tags = {
    Name    = var.readonly_user_name
    Purpose = "read-only access"
  }
}

resource "aws_iam_user_policy_attachment" "readonly" {
  user       = aws_iam_user.readonly.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# `aws login` (AWS CLI のブラウザ経由サインイン) を使うための権限。
# signin サービスの OAuth2 トークン発行のみで、リソースへの権限は増えない。
# 実際に何ができるかは上の ReadOnlyAccess の範囲のまま。
resource "aws_iam_user_policy_attachment" "signin_local_development" {
  user       = aws_iam_user.readonly.name
  policy_arn = "arn:aws:iam::aws:policy/SignInLocalDevelopmentAccess"
}

# 自分のアクセスキーとパスワードだけは本人が回せるようにしておく。
# ReadOnlyAccess には書き込みが一切含まれないため、これがないとキーの
# ローテーションのたびに管理者を経由することになる。
resource "aws_iam_user_policy" "self_manage_credentials" {
  count = var.allow_self_credential_management ? 1 : 0

  name = "SelfManageCredentials"
  user = aws_iam_user.readonly.name

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
        Resource = aws_iam_user.readonly.arn
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
          aws_iam_user.readonly.arn,
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:mfa/$${aws:username}",
        ]
      },
    ]
  })
}

# マネジメントコンソールへのサインインを許可するためのログインプロファイル。
# 初期パスワードは Terraform が生成し、初回サインイン時に本人が変更する。
resource "aws_iam_user_login_profile" "readonly" {
  count = var.create_login_profile ? 1 : 0

  user            = aws_iam_user.readonly.name
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

# AWS CLI 用のアクセスキー。シークレットは state に平文で入る
# （state は Terraform Cloud が保持）。Terraform に持たせたくない場合は
# var.create_access_key = false にして、本人がコンソールで発行する。
resource "aws_iam_access_key" "readonly" {
  count = var.create_access_key ? 1 : 0

  user = aws_iam_user.readonly.name
}
