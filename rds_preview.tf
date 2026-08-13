# ---------------------------------------------------------------------------
# プレビュー用 RDS
#
# PR ごとにインスタンスを立てると作成に 5〜10 分かかるので、インスタンスは 1 台
# 共有し、その中に PR ごとの database (pr_123) とロールを切る。database と
# ロールを実際に作るのは aws-preview 側のタスクに載る bootstrap コンテナで、
# ここで用意するのは「入れ物」と管理者資格情報だけ。
#
# 開発用 DB (aws_db_instance.app) と分けてあるのは、レビュー前のコードが流す
# マイグレーションの巻き添えを避けるため。
# ---------------------------------------------------------------------------

# 管理者パスワード。app 用 DB と同じく平文が Terraform state に入る
# (rds.tf の冒頭のコメントを参照)。URL エンコードを避けるため記号は使わない。
resource "random_password" "preview_db_admin" {
  count = var.preview_enabled ? 1 : 0

  length  = 40
  special = false
}

resource "aws_db_instance" "preview" {
  count = var.preview_enabled ? 1 : 0

  identifier = "${local.preview_name}-db"

  engine         = "postgres"
  engine_version = var.app_db_engine_version
  instance_class = var.preview_db_instance_class

  allocated_storage = var.preview_db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true
  multi_az          = false

  # 初期 database は管理者の接続先としてだけ使う。PR 用の database は
  # bootstrap コンテナが CREATE DATABASE で切る。
  db_name  = "postgres"
  username = var.preview_db_username
  password = random_password.preview_db_admin[0].result
  port     = 5432

  # サブネットグループとパラメータグループはアプリ用と同じもので足りる
  # (同じプライベートサブネット / 同じメジャーバージョン)。
  db_subnet_group_name   = aws_db_subnet_group.app.name
  parameter_group_name   = aws_db_parameter_group.app.name
  vpc_security_group_ids = [aws_security_group.preview_db[0].id]
  publicly_accessible    = false

  # 中身は使い捨てなのでバックアップは取らない。
  backup_retention_period = 0
  maintenance_window      = "sun:19:00-sun:20:00"

  auto_minor_version_upgrade = false
  deletion_protection        = false
  skip_final_snapshot        = true

  tags = {
    Name = "${local.preview_name}-db"
  }
}

resource "aws_security_group" "preview_db" {
  count = var.preview_enabled ? 1 : 0

  name        = "${local.preview_name}-db"
  description = "PostgreSQL from the application tasks only (PR previews)"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${local.preview_name}-db"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# プレビューのタスクは共有の ECS タスク SG をそのまま使う (docs/pr-preview.md
# 「PR ごとに作るリソース」参照)。ここを開けるのは 1 本で足りる。
resource "aws_vpc_security_group_ingress_rule" "preview_db_from_tasks" {
  count = var.preview_enabled ? 1 : 0

  security_group_id            = aws_security_group.preview_db[0].id
  description                  = "PostgreSQL from ECS tasks"
  referenced_security_group_id = aws_security_group.ecs_tasks.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "preview_db_from_pgadmin" {
  count = var.preview_enabled ? 1 : 0

  security_group_id            = aws_security_group.preview_db[0].id
  description                  = "PostgreSQL from pgAdmin EC2"
  referenced_security_group_id = data.aws_security_group.pgadmin.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# ---------------------------------------------------------------------------
# 管理者の接続 URL
#
# これを受け取るのは bootstrap コンテナだけ。PR 由来の app コンテナには
# PR 専用ロールの URL しか渡らない (aws-preview 側の modules/preview)。
# 読めるのはタスク実行ロールだけで、タスクロールには許可しない
# (iam_ecs.tf の ReadSecrets を参照)。
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "preview_admin_db_url" {
  count = var.preview_enabled ? 1 : 0

  name        = "${local.preview_name}/admin-db-url"
  description = "Admin ADMIN_DATABASE_URL for PR preview databases"

  # PR の開閉で作り直すことがあるので、削除後すぐ同名で作れるようにする。
  recovery_window_in_days = 0

  tags = {
    Name = "${local.preview_name}-admin-db-url"
  }
}

resource "aws_secretsmanager_secret_version" "preview_admin_db_url" {
  count = var.preview_enabled ? 1 : 0

  secret_id = aws_secretsmanager_secret.preview_admin_db_url[0].id

  secret_string = format(
    "postgresql://%s:%s@%s:%d/%s",
    var.preview_db_username,
    random_password.preview_db_admin[0].result,
    aws_db_instance.preview[0].address,
    aws_db_instance.preview[0].port,
    "postgres",
  )
}
