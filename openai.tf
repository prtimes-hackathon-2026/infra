# ---------------------------------------------------------------------------
# OpenAI API キー (app の PR羅針盤 AI コーチング機能が使う OPENAI_API_KEY)
#
# キーは Git にも Terraform state にも載せたくないので、Terraform が作るのは
# シークレットの箱と「置き換え前提のプレースホルダー」だけ。実際のキーは
# コンソール (または aws secretsmanager put-secret-value) で上書きし、以降
# Terraform は値の差分を見ない。
#
# 統計 DB の URL のように空の箱にしないのは、版が無いシークレットを参照すると
# タスクが ResourceNotFoundException で起動しなくなるため。アプリ側の
# OPENAI_API_KEY は任意 (app の src/shared/env.ts では optional) なので、
# キーを入れ忘れてもアプリ自体は起動し、AI コーチングの API だけが
# OpenAI からのエラーを返す状態で済む。
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "openai_api_key" {
  name        = "${local.name}/openai-api-key"
  description = "OPENAI_API_KEY for ${local.name}"

  # ハッカソン中に作り直すことを想定して、削除後すぐ同名で作れるようにする。
  recovery_window_in_days = 0

  tags = {
    Name = "${local.name}-openai-api-key"
  }
}

resource "aws_secretsmanager_secret_version" "openai_api_key" {
  secret_id     = aws_secretsmanager_secret.openai_api_key.id
  secret_string = "placeholder-replace-in-console"

  # 実キーは手で入れる運用なので、作成後の値は Terraform の管理外にする。
  # ここを外すと apply のたびにプレースホルダーへ巻き戻る。
  lifecycle {
    ignore_changes = [secret_string]
  }
}
