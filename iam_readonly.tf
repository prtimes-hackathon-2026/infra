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

# AWS CLI 用のアクセスキー。シークレットは state に平文で入る
# （state は Terraform Cloud が保持）。Terraform に持たせたくない場合は
# var.create_access_key = false にして、本人がコンソールで発行する。
resource "aws_iam_access_key" "readonly" {
  count = var.create_access_key ? 1 : 0

  user = aws_iam_user.readonly.name
}
