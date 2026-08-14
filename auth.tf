# ---------------------------------------------------------------------------
# ログインの合言葉 (app の簡易ログインが使う AUTH_PASSWORD)
#
# app は利用者アカウントを持たず、共有の合言葉 1 つで入る仕組みになっている。
# 未設定のときの既定値は src/shared/env.ts に 'prtimes' と書かれているため、
# 渡さないまま公開すると、リポジトリを読める人には合言葉が筒抜けになる。
# そこで ECS のタスクにシークレットとして渡し、既定値を使わせない。
#
# 初期値は Terraform が乱数で作る。OPENAI_API_KEY のように固定の
# プレースホルダーを置くと、それがそのまま「Git に書いてある合言葉」に
# なってしまうため。平文は state に載るが (アプリ用 DB のパスワードと同じ)、
# Git には残らない。
#
# 決めた合言葉に変えるときは、apply の後にコンソールか
# aws secretsmanager put-secret-value で上書きする (README「デプロイ手順」)。
# 以降 Terraform は値の差分を見ない。
# ---------------------------------------------------------------------------

resource "random_password" "auth_password" {
  length = 24

  # 人が画面で打つ文字列なので記号は入れない。長さで強度を確保する。
  special = false
}

resource "aws_secretsmanager_secret" "auth_password" {
  name        = "${local.name}/auth-password"
  description = "AUTH_PASSWORD for ${local.name}"

  # ハッカソン中に作り直すことを想定して、削除後すぐ同名で作れるようにする。
  recovery_window_in_days = 0

  tags = {
    Name = "${local.name}-auth-password"
  }
}

resource "aws_secretsmanager_secret_version" "auth_password" {
  secret_id     = aws_secretsmanager_secret.auth_password.id
  secret_string = random_password.auth_password.result

  # 合言葉は運用で差し替える前提なので、作成後の値は Terraform の管理外にする。
  # ここを外すと apply のたびに生成した乱数へ巻き戻る。
  lifecycle {
    ignore_changes = [secret_string]
  }
}
